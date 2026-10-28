# SPDX-License-Identifier: GPL-3.0-only
"""Resolve launch entries from real store metadata, never by guessing an EXE.

All executable and working-directory paths are confined to installDir after
symlink resolution. Arguments are arrays of literal strings; no shell is used.
"""
import hashlib,json,os,pathlib,plistlib,re,shlex,struct,subprocess
from bridge import BridgeError,ROOT,inspect_native

def windows_arguments(command):
    """Microsoft CRT argument rules, for an argument tail (not argv[0]).

    https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
    No environment expansion, command substitution, globbing or cmd.exe parsing.
    """
    if not isinstance(command,str) or '\x00' in command or len(command)>131072:
        raise BridgeError('invalid_launch_metadata','Invalid Windows argument string')
    result=[];at=0
    while at<len(command):
        while at<len(command) and command[at] in ' \t':at+=1
        if at>=len(command):break
        arg=[];quoted=False
        while at<len(command):
            c=command[at]
            if c in ' \t' and not quoted:break
            slashes=0
            while at<len(command) and command[at]=='\\':slashes+=1;at+=1
            if at<len(command) and command[at]=='"':
                arg.extend('\\'*(slashes//2))
                if slashes%2:arg.append('"');at+=1
                elif quoted and at+1<len(command) and command[at+1]=='"':arg.append('"');at+=2
                else:quoted=not quoted;at+=1
                continue
            arg.extend('\\'*slashes)
            if at>=len(command):break
            if command[at] in ' \t' and not quoted:break
            arg.append(command[at]);at+=1
        result.append(''.join(arg))
        while at<len(command) and command[at] in ' \t':at+=1
    return result

def arguments(value,platform):
    if value is None:return []
    if isinstance(value,list):
        if len(value)>1024 or any(not isinstance(v,str) or '\x00' in v or len(v)>131072 for v in value):
            raise BridgeError('invalid_launch_metadata','Launch arguments must be literal strings')
        return value
    if not isinstance(value,str):raise BridgeError('invalid_launch_metadata','Invalid launch arguments')
    if platform=='windows':return windows_arguments(value)
    try:return shlex.split(value,posix=True)
    except ValueError:raise BridgeError('invalid_launch_metadata','Unbalanced macOS launch argument quotes') from None

def inside(root,value,default=None):
    """Resolve Windows or POSIX relative metadata paths with bounded case folding."""
    if value in (None,''):
        if default is not None:return default
        raise BridgeError('invalid_launch_metadata','Executable path is missing')
    if not isinstance(value,str) or '\x00' in value or len(value)>32768:
        raise BridgeError('invalid_launch_metadata','Invalid launch path')
    path=value.replace('\\','/')
    if path.startswith('/') or re.match(r'^[a-zA-Z]:',path) or '://' in path:
        raise BridgeError('unsafe_launch_path','Absolute executable paths are not accepted from store metadata')
    parts=pathlib.PurePosixPath(path).parts
    if '..' in parts:raise BridgeError('unsafe_launch_path','Launch path escapes the installation')
    current=root
    for part in parts:
        if part in ('','.'):continue
        next_path=current/part
        if not next_path.exists() and current.is_dir():
            matches=[p for p in current.iterdir() if p.name.casefold()==part.casefold()]
            if len(matches)>1:raise BridgeError('ambiguous_launch_path','Multiple case-insensitive matches for a launch path')
            if matches:next_path=matches[0]
        current=next_path.resolve()
        if not current.is_relative_to(root):raise BridgeError('unsafe_launch_path','Launch path leaves the installation through a symlink')
    if not current.is_relative_to(root):raise BridgeError('unsafe_launch_path','Launch path escapes the installation')
    return current

def pe_architecture(path):
    try:
        with path.open('rb') as f:
            head=f.read(64)
            if len(head)<64 or head[:2]!=b'MZ':raise ValueError()
            offset=struct.unpack_from('<I',head,0x3c)[0]
            if offset>1024*1024 or offset+6>path.stat().st_size:raise ValueError()
            f.seek(offset);pe=f.read(6)
            if pe[:4]!=b'PE\0\0':raise ValueError()
            machine=struct.unpack_from('<H',pe,4)[0]
            arch={0x14c:'x86',0x8664:'x86_64',0xaa64:'arm64'}.get(machine)
            if arch is None:raise ValueError()
            return arch
    except (OSError,ValueError,struct.error):raise BridgeError('invalid_launch_binary','The declared Windows executable has no supported PE header') from None

def verify_macos_executable(path):
    """Reject malformed/non-executable Mach-O and explicit iOS/simulator builds."""
    try:
        length=path.stat().st_size
        with path.open('rb') as f:
            def check_slice(offset,size,expected_cpu=None):
                if offset<0 or size<28 or offset+size>length:raise ValueError()
                f.seek(offset);head=f.read(32);magic=head[:4]
                if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe'):endian='<'
                elif magic in (b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce'):endian='>'
                else:raise ValueError()
                cpu,subtype,filetype,ncmds,cmdbytes=struct.unpack_from(endian+'IIIII',head,4)
                if expected_cpu is not None and cpu!=expected_cpu:raise ValueError()
                if filetype!=2 or ncmds>4096 or cmdbytes>1024*1024:raise ValueError()
                header_size=32 if magic in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf') else 28
                if header_size+cmdbytes>size:raise ValueError()
                f.seek(offset+header_size);commands=f.read(cmdbytes);at=0
                for _ in range(ncmds):
                    if at+8>len(commands):raise ValueError()
                    cmd,cmdsize=struct.unpack_from(endian+'II',commands,at)
                    if cmdsize<8 or at+cmdsize>len(commands):raise ValueError()
                    if cmd==0x32:
                        if cmdsize<24:raise ValueError()
                        platform=struct.unpack_from(endian+'I',commands,at+8)[0]
                        if platform not in (1,6):raise BridgeError('unsupported_platform','Mach-O targets iOS, a simulator, or another non-macOS platform')
                    elif cmd in (0x25,0x2f,0x30):raise BridgeError('unsupported_platform','Mach-O targets a non-macOS platform')
                    at+=cmdsize
            f.seek(0);head=f.read(4096);magic=head[:4]
            if magic in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf',b'\xbe\xba\xfe\xca',b'\xbf\xba\xfe\xca'):
                endian='<' if magic in (b'\xbe\xba\xfe\xca',b'\xbf\xba\xfe\xca') else '>';wide=magic in (b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca');stride=32 if wide else 20
                count=struct.unpack_from(endian+'I',head,4)[0]
                if count>64 or len(head)<8+count*stride:raise ValueError()
                for i in range(count):
                    start=8+i*stride;cpu=struct.unpack_from(endian+'I',head,start)[0]
                    if wide:offset,size=struct.unpack_from(endian+'QQ',head,start+8)
                    else:offset,size=struct.unpack_from(endian+'II',head,start+8)
                    check_slice(offset,size,cpu)
            else:check_slice(0,length)
    except (OSError,ValueError,struct.error):raise BridgeError('invalid_launch_binary','Malformed or non-executable Mach-O file') from None

def json_document(path,json5=False):
    try:
        if path.stat().st_size>8*1024*1024:raise BridgeError('invalid_launch_metadata','Launch manifest is too large')
        raw=path.read_text(encoding='utf-8-sig')
    except OSError:raise BridgeError('missing_launch_metadata','Store launch manifest is missing') from None
    try:return json.loads(raw)
    except json.JSONDecodeError:
        if not json5:raise BridgeError('invalid_launch_metadata','Invalid store launch JSON') from None
    # Nile's open JSON5 dependency is already installed locally by store_bootstrap.
    from runtime_paths import tools_root
    py=tools_root()/'venv/bin/python'
    if not py.exists():raise BridgeError('backend_missing','JSON5 launch manifest requires the open store helper environment')
    code='import json,json5,sys;json.dump(json5.loads(sys.stdin.read()),sys.stdout)'
    try:
        result=subprocess.run([str(py),'-c',code],input=raw,capture_output=True,text=True,timeout=15,check=True)
        return json.loads(result.stdout)
    except (subprocess.SubprocessError,json.JSONDecodeError):raise BridgeError('invalid_launch_metadata','Invalid Amazon JSON5 launch manifest') from None

def candidate(root,entry,platform,source,index):
    exe=inside(root,entry.get('executable'))
    if not exe.exists():raise BridgeError('missing_launch_binary','Declared launch executable is not installed')
    if platform=='macOS':
        if exe.suffix.lower()=='.app':
            relative=str(exe.relative_to(root))
            info=inside(root,relative+'/Contents/Info.plist')
            try:plist=plistlib.loads(info.read_bytes())
            except (OSError,ValueError,plistlib.InvalidFileException):raise BridgeError('invalid_launch_binary','Application Info.plist is invalid') from None
            if plist.get('LSRequiresIPhoneOS'):raise BridgeError('unsupported_platform','This is an iOS application, not a macOS game')
            name=plist.get('CFBundleExecutable')
            if not isinstance(name,str) or '/' in name or '\\' in name or name in ('.','..',''):
                raise BridgeError('invalid_launch_binary','Application executable is invalid')
            exe=inside(root,relative+'/Contents/MacOS/'+name)
        if not exe.is_file() or not os.access(exe,os.X_OK):raise BridgeError('invalid_launch_binary','The macOS executable is missing or not executable')
        verify_macos_executable(exe)
        native=inspect_native(str(exe));exe=pathlib.Path(native['path']).resolve()
        if not exe.is_relative_to(root):raise BridgeError('unsafe_launch_path','Application executable leaves the installation')
        architecture=native['architecture']
        if architecture=='unknown':raise BridgeError('invalid_launch_binary','Unsupported Mach-O architecture')
    else:
        if not exe.is_file():raise BridgeError('invalid_launch_binary','Windows launch entry is not a regular file')
        architecture=pe_architecture(exe)
    args=arguments(entry.get('arguments'),platform)
    if any('%command%' in arg.lower() for arg in args):raise BridgeError('unsupported_launch_template','Launch entry contains an unresolved command template')
    default=root if source.startswith(('gog:','amazon:')) else exe.parent
    cwd=inside(root,entry.get('workingDirectory'),default=default)
    if not cwd.is_dir():raise BridgeError('missing_launch_directory','Declared working directory is not installed')
    identity=json.dumps([str(exe.relative_to(root)),args,str(cwd.relative_to(root))],ensure_ascii=False,separators=(',',':'))
    key=hashlib.sha256(identity.encode()).hexdigest()[:12]
    return {'id':platform+':'+key,'platform':platform,'architecture':architecture,'executable':str(exe),'arguments':args,'installed':True,
            'verification':'Store launch metadata and binary header verified; execution not yet tested',
            'workingDirectory':str(cwd),'source':source,'primary':entry.get('primary') is True,'label':entry.get('label') or exe.name}

def entries_from_metadata(request,config,secret_dir,path):
    store=request['store'];options=request.get('options',{});platform=options.get('platform','windows');metadata=options.get('metadata') or {};gid=str(options['gameID'])
    entries=[]
    if store=='steam':
        launches=metadata.get('launch') or []
        if not isinstance(launches,list):raise BridgeError('invalid_launch_metadata','Steam launch metadata must be a list')
        for index,launch in enumerate(launches):
            if not isinstance(launch,dict):continue
            systems=[s.strip().lower() for s in str(launch.get('oslist') or '').split(',') if s.strip()]
            target='macos' if platform=='macOS' else 'windows'
            if systems and target not in systems:continue
            entries.append({'executable':launch.get('executable'),'arguments':launch.get('arguments'),
                            'workingDirectory':launch.get('workingdir') or launch.get('workingDirectory'),
                            'primary':str(launch.get('type') or '').lower()=='default','label':launch.get('description'),
                            'source':f'steam:PICS/config/launch/{index}'})
    elif store=='epic':
        locations=[secret_dir/'legendary-config/installed.json',config/platform/'installed.json']
        for location in locations:
            if not location.is_file():continue
            data=json_document(location);entry=data.get(gid) if isinstance(data,dict) else None
            if not isinstance(entry,dict):continue
            declared=pathlib.Path(entry.get('install_path','')).expanduser().resolve()
            if declared!=path:raise BridgeError('unsafe_launch_path','Epic metadata refers to a different installation')
            entries.append({'executable':entry.get('executable'),'arguments':entry.get('launch_parameters'),
                            'workingDirectory':None,'primary':True,'label':entry.get('title'),'source':'epic:Legendary/installed.json'})
            break
    elif store=='gog':
        info=path/f'goggame-{gid}.info';bundle_root=path
        if not info.is_file() and platform=='macOS':
            matches=[]
            if path.suffix=='.app':matches=[path/'Contents/Resources'/f'goggame-{gid}.info']
            else:matches=[p/'Contents/Resources'/f'goggame-{gid}.info' for p in path.glob('*.app')]
            matches=[p for p in matches if p.is_file()]
            if len(matches)>1:raise BridgeError('ambiguous_launch_metadata','Multiple GOG app bundles expose launch manifests')
            if matches:info=matches[0];bundle_root=info.parent.parent.parent
        if info.is_file():
            if not info.resolve().is_relative_to(path):raise BridgeError('unsafe_launch_path','GOG launch manifest leaves the installation')
            data=json_document(info)
            for index,task in enumerate(data.get('playTasks',[])):
                if task.get('type','FileTask') not in ('FileTask','file','File'):continue
                raw=task.get('path')
                # macOS play tasks are relative to the downloaded .app root, per gogdl.
                if raw and bundle_root!=path:raw=str(bundle_root.relative_to(path))+'/'+raw
                cwd=task.get('workingDir')
                if cwd and bundle_root!=path:cwd=str(bundle_root.relative_to(path))+'/'+cwd
                elif not cwd and bundle_root!=path:cwd=str(bundle_root.relative_to(path))
                entries.append({'executable':raw,'arguments':task.get('arguments'),'workingDirectory':cwd,
                                'primary':task.get('isPrimary') is True,'label':task.get('name'),'source':f'gog:{info.name}/playTasks/{index}'})
    elif store=='amazon':
        info=path/'fuel.json'
        if info.is_file():
            if not info.resolve().is_relative_to(path):raise BridgeError('unsafe_launch_path','Amazon launch manifest leaves the installation')
            data=json_document(info,json5=True);main=data.get('Main') or {}
            entries.append({'executable':main.get('Command'),'arguments':main.get('Args'),'workingDirectory':main.get('WorkingSubdirOverride'),
                            'primary':True,'label':'Play','source':'amazon:fuel.json/Main'})
    return entries

def resolve_installed_launch(request,config,secret_dir,path):
    path=path.resolve();platform=request.get('options',{}).get('platform','windows');found=[];issues=[];invalid_primary=False
    try:entries=entries_from_metadata(request,config,secret_dir,path)
    except BridgeError as e:entries=[];issues.append({'code':e.code,'message':e.message})
    for i,entry in enumerate(entries):
        try:found.append(candidate(path,entry,platform,entry['source'],i))
        except BridgeError as e:
            invalid_primary |= entry.get('primary') is True
            issues.append({'source':entry['source'],'code':e.code,'message':e.message})
    # Metadata often has duplicate launch entries for architecture flags. Collapse
    # only exactly equivalent executable+argv+cwd, preserving primary designation.
    unique={}
    for entry in found:
        if entry['id'] in unique:unique[entry['id']]['primary'] |= entry['primary']
        else:unique[entry['id']]=entry
    found=list(unique.values());primary=[e for e in found if e['primary']]
    selected=primary[0] if len(primary)==1 and not invalid_primary else found[0] if len(found)==1 and not issues else None
    return {'installedVariant':selected,'workingDirectory':selected['workingDirectory'] if selected else None,
            'launchCandidates':found,'launchIssues':issues,'launchSelectionRequired':selected is None}
