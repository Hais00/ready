// SPDX-License-Identifier: GPL-3.0-only
// Diagnostic QR encoder. The ephemeral challenge enters through stdin, never
// argv/environment; no credential token or ticket is accepted by this tool.
import Foundation
import CoreImage
import AppKit

guard CommandLine.arguments.count == 2 else { exit(64) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty, input.count <= 8192,
  let filter = CIFilter(name: "CIQRCodeGenerator")
else { exit(65) }
filter.setValue(input, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
else { exit(65) }
let context = CIContext(options: [.useSoftwareRenderer: true])
guard let cg = context.createCGImage(output, from: output.extent),
  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
else { exit(70) }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: destination.path) else { exit(73) }
do {
  try png.write(to: destination, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
} catch { exit(73) }
