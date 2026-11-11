// Generates the app icon from logo.png, on the macOS icon grid.
//
//   swift scripts/make-icon.swift logo.png app/Resources/AppIcon-1024.png
//
// - The logo tile is cropped and put into the standard macOS shape:
//   824×824 squircle on a 1024×1024 canvas (100 px margin), continuous corners of
//   radius 185.4. With this shape macOS 26 shows the icon as it is, instead of
//   enclosing it in a grey frame.
// - Everything outside the shape is transparent, so the black corners disappear.
// - If the logo has tighter corners than the macOS shape, it is enlarged slightly
//   until no black pixel is left inside the shape.
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
  FileHandle.standardError.write("Usage: swift make-icon.swift logo.png output.png\n".data(using: .utf8)!)
  exit(1)
}

let canvas = 1024
let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4
/// A pixel is "background black" if no channel exceeds this threshold.
let blackThreshold: UInt8 = 24

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
  FileHandle.standardError.write("Cannot read \(args[1])\n".data(using: .utf8)!)
  exit(1)
}

func rgba(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
  let width = image.width, height = image.height
  var data = [UInt8](repeating: 0, count: width * height * 4)
  let context = CGContext(
    data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return (data, width, height)
}

// Logo tile: the rectangle of non-black pixels, read along the median lines.
let pixels = rgba(logo)
func isBlack(_ x: Int, _ y: Int) -> Bool {
  let i = (y * pixels.width + x) * 4
  return pixels.data[i] <= blackThreshold && pixels.data[i + 1] <= blackThreshold && pixels.data[i + 2] <= blackThreshold
}
let midY = pixels.height / 2, midX = pixels.width / 2
let left = (0 ..< pixels.width).first { !isBlack($0, midY) }!
let right = (0 ..< pixels.width).reversed().first { !isBlack($0, midY) }!
let top = (0 ..< pixels.height).first { !isBlack(midX, $0) }!
let bottom = (0 ..< pixels.height).reversed().first { !isBlack(midX, $0) }!
// CoreGraphics coordinates: origin at the bottom left.
let tile = CGRect(x: left, y: pixels.height - 1 - bottom, width: right - left + 1, height: bottom - top + 1)
print("Logo tile: \(Int(tile.width))×\(Int(tile.height)) px")

let shapePath = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: shapeRect).cgPath

/// Draws the tile (enlarged by `zoom` around the center) inside the shape.
func render(zoom: CGFloat) -> CGImage {
  let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  context.addPath(shapePath)
  context.clip()
  let drawn = shapeRect.insetBy(dx: -shapeRect.width * (zoom - 1) / 2, dy: -shapeRect.height * (zoom - 1) / 2)
  // Scale of the whole logo such that the tile occupies `drawn`.
  let scaleX = drawn.width / tile.width, scaleY = drawn.height / tile.height
  let full = CGRect(
    x: drawn.minX - tile.minX * scaleX,
    y: drawn.minY - tile.minY * scaleY,
    width: CGFloat(pixels.width) * scaleX,
    height: CGFloat(pixels.height) * scaleY
  )
  context.draw(logo, in: full)
  return context.makeImage()!
}

/// Nearly black, fully opaque pixels inside the shape (the corner remnants).
func blackInsideShape(_ image: CGImage) -> Int {
  let out = rgba(image)
  var count = 0
  for y in 0 ..< out.height {
    for x in 0 ..< out.width {
      let i = (y * out.width + x) * 4
      if out.data[i + 3] == 255, out.data[i] <= blackThreshold, out.data[i + 1] <= blackThreshold, out.data[i + 2] <= blackThreshold {
        count += 1
      }
    }
  }
  return count
}

var zoom: CGFloat = 1.0
var image = render(zoom: zoom)
var leftover = blackInsideShape(image)
print(String(format: "Zoom %.3f: %d black pixels inside the shape", zoom, leftover))
while leftover > 0 && zoom < 1.15 {
  zoom += 0.005
  image = render(zoom: zoom)
  leftover = blackInsideShape(image)
}
print(String(format: "Final zoom %.3f: %d black pixels inside the shape", zoom, leftover))

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
  FileHandle.standardError.write("Write failed\n".data(using: .utf8)!)
  exit(1)
}
print("Wrote \(args[2]) (\(canvas)×\(canvas), sRGB with transparency)")
