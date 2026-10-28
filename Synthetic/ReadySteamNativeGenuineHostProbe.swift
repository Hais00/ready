// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Explicit Root-controlled genuine-host probe. Does not start a game SDK,
/// obtain credentials, read account files or interpret a SteamID as ownership.
@main
private struct ReadySteamNativeGenuineHostProbe {
  private enum SafeFailure: String, Error {
    case invalidArguments="invalid_arguments", invalidLifeline="invalid_lifeline"
    case invalidInput="invalid_input", inputTimeout="input_timeout"
    case invalidBinding="invalid_binding", fixtureBinding="fixture_binding_rejected"
    case hostSetup="host_setup_failed"
  }
  private final class Control: @unchecked Sendable {
    private let lock=NSLock()
    private var closed=false,invalid=false
    func record(invalid:Bool) { lock.lock();closed=true;self.invalid=invalid;lock.unlock() }
    var snapshot:(closed:Bool,invalid:Bool) { lock.lock();defer{lock.unlock()};return(closed,invalid) }
  }
  private struct Arguments {
    let binding:URL
    let bindingSHA256:String
    let profile:UUID
    let stateRoot:URL
    let lifeline:Int32
    init() throws {
      let values=Array(CommandLine.arguments.dropFirst())
      guard values.count==10 else{throw SafeFailure.invalidArguments}
      var fields=[String:String]()
      for index in stride(from:0,to:values.count,by:2) {
        guard ["--binding","--binding-sha256","--profile","--state-root","--lifeline-fd"].contains(values[index]),
          fields.updateValue(values[index+1],forKey:values[index])==nil else{throw SafeFailure.invalidArguments}
      }
      guard let binding=fields["--binding"],binding.hasPrefix("/"),
        let digest=fields["--binding-sha256"],digest.count==64,
        digest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
        let profile=fields["--profile"].flatMap(UUID.init(uuidString:)),
        let root=fields["--state-root"],root.hasPrefix("/"),
        let number=fields["--lifeline-fd"],!number.isEmpty,number.utf8.allSatisfy({(48...57).contains($0)}),
        let fd=Int32(number),fd>=3 else{throw SafeFailure.invalidArguments}
      self.binding=URL(fileURLWithPath:binding);bindingSHA256=digest;self.profile=profile
      stateRoot=URL(fileURLWithPath:root);lifeline=fd
    }
  }
  @discardableResult private static func emit(_ value:[String:Any])->Bool {
    guard var data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else{return false}
    data.append(10)
    do{try FileHandle.standardOutput.write(contentsOf:data);return true}catch{return false}
  }
  private static func validateLifeline(_ fd:Int32) throws {
    var life=stat(),input=stat()
    guard fd>=3,fstat(fd,&life)==0,(life.st_mode&S_IFMT)==S_IFIFO,life.st_uid==getuid(),
      fstat(0,&input)==0,(input.st_mode&S_IFMT)==S_IFIFO,input.st_uid==getuid(),
      life.st_dev != input.st_dev || life.st_ino != input.st_ino,
      fcntl(fd,F_GETFL)>=0,fcntl(fd,F_GETFL)&O_ACCMODE==O_RDONLY,
      fcntl(0,F_GETFL)>=0,fcntl(0,F_GETFL)&O_ACCMODE==O_RDONLY else{throw SafeFailure.invalidLifeline}
    let flags=fcntl(fd,F_GETFD),inputFlags=fcntl(0,F_GETFD)
    guard flags>=0,inputFlags>=0,fcntl(fd,F_SETFD,flags|FD_CLOEXEC)==0,
      fcntl(0,F_SETFD,inputFlags|FD_CLOEXEC)==0 else{throw SafeFailure.invalidLifeline}
  }
  private static func readFrame() throws -> Data {
    let flags=fcntl(0,F_GETFL)
    guard flags>=0,fcntl(0,F_SETFL,flags|O_NONBLOCK)==0 else{throw SafeFailure.invalidInput}
    let deadline=DispatchTime.now().uptimeNanoseconds+3_000_000_000
    var frame=Data(),buffer=[UInt8](repeating:0,count:4096)
    defer{buffer.withUnsafeMutableBytes{_=$0.initializeMemory(as:UInt8.self,repeating:0)}}
    do {
      while true {
        let now=DispatchTime.now().uptimeNanoseconds
        guard now<deadline else{throw SafeFailure.inputTimeout}
        let milliseconds=Int32(max(1,min(3000,(deadline-now+999_999)/1_000_000)))
        var waiting=pollfd(fd:0,events:Int16(POLLIN|POLLHUP),revents:0)
        let available=Darwin.poll(&waiting,1,milliseconds)
        if available<0&&errno==EINTR{continue}
        guard available>=0 else{throw SafeFailure.invalidInput}
        if available==0{continue}
        let count=Darwin.read(0,&buffer,min(buffer.count,8285-frame.count))
        if count<0&&(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK){continue}
        guard count>=0 else{throw SafeFailure.invalidInput}
        if count==0{break}
        guard frame.count+count<=8284 else{throw SafeFailure.invalidInput}
        frame.append(contentsOf:buffer.prefix(count))
      }
      close(0)
      guard frame.count>=28,frame.prefix(8)==Data("RDYAUTH1".utf8) else{throw SafeFailure.invalidInput}
      return frame
    } catch {
      frame.resetBytes(in:0..<frame.count);frame.removeAll(keepingCapacity:false);throw error
    }
  }
  private static func gameID(_ frame:Data) throws -> UInt32 {
    guard frame.count>=28 else{throw SafeFailure.invalidInput}
    let value=frame.withUnsafeBytes { bytes -> UInt32 in
      let fields=bytes.bindMemory(to:UInt8.self)
      return (24..<28).reduce(UInt32(0)) {($0<<8)|UInt32(fields[$1])}
    }
    guard value>0 else{throw SafeFailure.invalidInput};return value
  }
  @MainActor private static func run() throws -> Int32 {
    let arguments=try Arguments()
    try validateLifeline(arguments.lifeline)
    _=fcntl(STDOUT_FILENO,F_SETNOSIGPIPE,1)
    let control=Control()
    var host:SteamNativeHostProcess?
    let watcher=DispatchQueue(label:"ready.steam.genuine-probe.parent-lifeline")
    watcher.async {
      var byte:UInt8=0
      var invalid=false
      while true {
        var waiting=pollfd(fd:arguments.lifeline,events:Int16(POLLIN|POLLHUP),revents:0)
        let available=Darwin.poll(&waiting,1,-1)
        if available<0&&errno==EINTR{continue}
        if available<0{invalid=true;break}
        let count=Darwin.read(arguments.lifeline,&byte,1)
        if count<0&&(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK){continue}
        invalid=count != 0;break // Any byte is a protocol error. Only EOF is valid.
      }
      close(arguments.lifeline);control.record(invalid:invalid)
      DispatchQueue.main.async{host?.stop()}
    }
    var frame=try readFrame()
    defer{frame.resetBytes(in:0..<frame.count);frame.removeAll(keepingCapacity:false)}
    let app=try gameID(frame)
    let binding:SteamNativeHostProcess.Binding
    do{binding=try .load(manifestURL:arguments.binding,expectedSHA256:arguments.bindingSHA256)}
    catch{throw SafeFailure.invalidBinding}
    guard !binding.fixtureOnly else{throw SafeFailure.fixtureBinding}
    let initial=control.snapshot
    if initial.invalid{throw SafeFailure.invalidLifeline}
    if initial.closed {
      emit(["type":"wrapper_exit","hostCode":NSNull(),"signal":NSNull(),"cancelled":true,"invalidEvents":false])
      return 0
    }
    var result:SteamNativeHostProcess.Exit?
    var outputFailed=false
    do {
      host=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&frame,profile:arguments.profile,
        sessionID:UUID(),gameID:app,profileStateRoot:arguments.stateRoot,mode:.cached,
        onEvent:{event in if !emit(event){outputFailed=true;host?.stop()}},onExit:{result=$0})
    } catch{throw SafeFailure.hostSetup}
    // An EOF detected during validation/spawn must revoke the newly owned host
    // before the main queue can deliver a queued ready callback.
    if control.snapshot.closed{host?.stop()}
    while result==nil{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    guard let ended=result else{throw SafeFailure.hostSetup}
    let invalid=ended.invalidEvents||control.snapshot.invalid||outputFailed
    let terminal:[String:Any] = ["type":"wrapper_exit","hostCode":ended.code.map{Int($0)} as Any? ?? NSNull(),
      "signal":ended.signal.map{Int($0)} as Any? ?? NSNull(),"cancelled":ended.cancelled,"invalidEvents":invalid]
    let delivered=emit(terminal)
    return !invalid&&delivered&&ended.signal==nil&&(ended.code==42||ended.code==44) ? 0:1
  }
  @MainActor static func main() {
    let status:Int32
    do{status=try run()}
    catch let failure as SafeFailure{emit(["type":"wrapper_error","code":failure.rawValue]);status=1}
    catch{emit(["type":"wrapper_error","code":"probe_failed"]);status=1}
    Darwin.exit(status)
  }
}
