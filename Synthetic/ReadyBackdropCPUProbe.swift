// SPDX-License-Identifier: GPL-3.0-only
// Own procedural colors only; never invokes capture on a visible window.
import AppKit
import Foundation

@main
struct ReadyBackdropCPUProbe {
  @MainActor
  static func main() {
    let width = 640, height = 400
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { fatalError("Own source context") }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    let sourcePixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        sourcePixels[offset] = x < width / 2 ? 255 : 0
        sourcePixels[offset + 1] = 0
        sourcePixels[offset + 2] = x < width / 2 ? 0 : 255
        sourcePixels[offset + 3] = 255
      }
    }
    let input = context.makeImage()!
    let began = CFAbsoluteTimeGetCurrent()
    guard let output = GameBackdropSnapshot.renderBackdrop(input),
      let bytes = CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { fatalError("Own software backdrop") }
    let filterMilliseconds = (CFAbsoluteTimeGetCurrent() - began) * 1000
    bytes.draw(output, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = bytes.data!.assumingMemoryBound(to: UInt8.self)
    func pixel(_ x: Int) -> [Int] { (0..<4).map { Int(pixels[(200 * width + x) * 4 + $0]) } }
    let red = pixel(160), blue = pixel(480), edge = pixel(319)
    FileHandle.standardError.write(Data("own-filter red:\(red) blue:\(blue) edge:\(edge)\n".utf8))
    precondition(red[0] > 110 && red[0] <= 140 && red[1] < 35 && red[2] < 35 && red[3] == 255)
    precondition(blue[2] > 110 && blue[2] <= 140 && blue[0] < 35 && blue[1] < 35 && blue[3] == 255)
    precondition(edge[0] > 40 && edge[2] > 40 && abs(edge[0] - edge[2]) < 40)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 20, height: 20),
      styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var calls = 0
    GameBackdropSnapshot.capture(window: window) { image in
      precondition(image == nil)
      calls += 1
    }
    precondition(calls == 1)
    var gateCalls = 0
    let gate = GameBackdropSnapshot.CompletionGate(window: window) { image in
      precondition(image == nil)
      gateCalls += 1
    }
    gate.finish(output)
    gate.finish(nil)
    precondition(gateCalls == 1 && gate.finished)
    window.close()
    let report: [String: Any] = ["passed": true, "proceduralPixelsOnly": true,
      "softwareGaussian14": true, "postGaussianBlackAlpha": 0.50, "outputOpaque": true,
      "redRegion": red, "blueRegion": blue, "mixedBoundary": edge,
      "CPUFilterMilliseconds": filterMilliseconds,
      "hiddenWindowFallbackExactlyOnce": true, "completionGateExactlyOnce": true,
      "captureAPIsInvoked": false, "screenshotOrUserGameUsed": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
  }
}
