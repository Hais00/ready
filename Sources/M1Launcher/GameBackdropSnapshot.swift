// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit

/// One image of Ready's own window, taken before mounting its interface.
/// No display capture, permission request, picker, persistent image or stream.
enum GameBackdropSnapshot {
  @MainActor
  private final class CompletionGate {
    weak var window: NSWindow?
    let windowID: CGWindowID
    private var completion: (@MainActor (CGImage?) -> Void)?
    private(set) var finished = false

    init(window: NSWindow, completion: @escaping @MainActor (CGImage?) -> Void) {
      self.window = window
      self.windowID = CGWindowID(window.windowNumber)
      self.completion = completion
    }

    var isCurrent: Bool {
      guard let window else { return false }
      return window.isVisible && window.windowNumber > 0
        && CGWindowID(window.windowNumber) == windowID
    }

    func finish(_ image: CGImage?) {
      guard !finished else { return }
      finished = true
      let callback = completion
      completion = nil
      callback?(isCurrent ? image : nil)
    }
  }

  @MainActor
  static func capture(window: NSWindow, completion: @escaping @MainActor (CGImage?) -> Void) {
    guard #available(macOS 14.4, *), window.isVisible, window.windowNumber > 0 else {
      completion(nil)
      return
    }
    let gate = CompletionGate(window: window, completion: completion)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      gate.finish(nil)
    }
    Task { @MainActor in
      do {
        // Unlike broad shareable-content enumeration, currentProcess describes
        // only content available to this process without new TCC consent.
        let content = try await SCShareableContent.currentProcess
        guard !gate.finished, gate.isCurrent,
          let own = content.windows.first(where: {
            $0.windowID == gate.windowID && $0.owningApplication?.processID == getpid()
          }) else {
          gate.finish(nil)
          return
        }
        let size = own.frame.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
          gate.finish(nil)
          return
        }
        let scale = min(1, min(640 / size.width, 640 / size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, min(640, Int((size.width * scale).rounded())))
        configuration.height = max(1, min(640, Int((size.height * scale).rounded())))
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
        guard !gate.finished, gate.isCurrent else {
          gate.finish(nil)
          return
        }
        DispatchQueue.global(qos: .utility).async {
          let backdrop = renderBackdrop(image)
          Task { @MainActor in gate.finish(backdrop) }
        }
      } catch {
        gate.finish(nil)
      }
    }
  }

  private static func renderBackdrop(_ image: CGImage) -> CGImage? {
    guard image.width > 0, image.height > 0, image.width <= 640, image.height <= 640 else {
      return nil
    }
    let input = CIImage(cgImage: image)
    let extent = input.extent
    let blurred = input.clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
      .cropped(to: extent)
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let softImage = context.createCGImage(blurred, from: extent, format: .RGBA8,
      colorSpace: colorSpace, deferred: false),
      let bitmap = CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    bitmap.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    bitmap.fill(bounds)
    bitmap.draw(softImage, in: bounds)
    // Apply black after CoreImage's linear-light filter. This makes the visual
    // result approximately half the encoded RGB values, rather than ~75%.
    bitmap.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.50)
    bitmap.fill(bounds)
    return bitmap.makeImage()
  }
}
