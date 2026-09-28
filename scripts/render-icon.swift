import AppKit
import SwiftUI

// Legacy macOS ICNS images supply their own silhouette. Keep the square source
// unmasked for reuse with the newer Icon Composer / system-masked icon pipeline.
guard CommandLine.arguments.count == 3,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let source = NSBitmapImageRep(data: data),
      let sourceImage = source.cgImage else {
    fatalError("Usage: render-icon.swift SOURCE.png OUTPUT.png")
}

let size = source.pixelsWide
guard size == source.pixelsHigh, size >= 1024,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("The source icon must be square and at least 1024 pixels wide")
}

let scale = CGFloat(size) / 1024
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
// These export dimensions are tuned for the pre-26 macOS Dock, not HIG constants.
let tile = canvas.insetBy(dx: 100 * scale, dy: 100 * scale)
let silhouette = RoundedRectangle(cornerRadius: 185 * scale, style: .continuous)
    .path(in: tile).cgPath

context.clear(canvas)
context.addPath(silhouette)
context.clip()
// Preserve the centered artwork's scale: only the outer background is masked.
context.interpolationQuality = .none
context.draw(sourceImage, in: canvas)

guard let result = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
    fatalError("Could not render the macOS icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
