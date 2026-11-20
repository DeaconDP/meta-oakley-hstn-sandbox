/*
 * ToolImageSampler - a camera frame scaled down to a small pixel array, for the light and label tools
 *
 * The probe reads 96 px wide frames, colour 160 px, the barcode hint 480 px greyscale rows (the
 * same sizes as Android). Drawing through UIKit honours the image's orientation, so "left" in the
 * array is left in the picture. Nothing is kept: the arrays are dropped once measured.
 * Safe off the main thread (UIImage drawing and CGContext are).
 */

import CoreGraphics
import UIKit

enum ToolImageSampler {
  /// Probe frames are scaled to this width (96x128 for a 3:4 phone frame).
  static let probeWidth = 96
  /// Colour frames are scaled to this width: the centre patch is then 32x32.
  static let colourWidth = 160
  /// Barcode hint rows: this wide, this many rows.
  static let hintWidth = 480
  static let hintRows = 48

  /// `image` scaled to `width` (keeping its shape), as packed ARGB pixels (0xAARRGGBB).
  static func argb(_ image: UIImage, width maxWidth: Int) -> (pixels: [UInt32], width: Int, height: Int)? {
    guard let dims = size(image, maxWidth) else { return nil }
    let (w, h) = dims
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      draw(image, into: context, width: w, height: h)
      return true
    }
    guard drawn else { return nil }
    var pixels = [UInt32](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      let r = UInt32(bytes[i * 4])
      let g = UInt32(bytes[i * 4 + 1])
      let b = UInt32(bytes[i * 4 + 2])
      pixels[i] = 0xFF00_0000 | r << 16 | g << 8 | b
    }
    return (pixels, w, h)
  }

  /// `rows` full-width greyscale rows, evenly spaced from top to bottom, `width` wide.
  static func lumaRows(_ image: UIImage, width maxWidth: Int = hintWidth, rows: Int = hintRows) -> (luma: [UInt8], width: Int, rows: Int)? {
    guard let dims = size(image, maxWidth), dims.1 >= rows else { return nil }
    let (w, h) = dims
    var gray = [UInt8](repeating: 0, count: w * h)
    let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      draw(image, into: context, width: w, height: h)
      return true
    }
    guard drawn else { return nil }
    var out = [UInt8](repeating: 0, count: w * rows)
    for r in 0..<rows {
      let y = min(h - 1, r * h / rows + h / (2 * rows))
      for x in 0..<w { out[r * w + x] = gray[y * w + x] }
    }
    return (out, w, rows)
  }

  private static func size(_ image: UIImage, _ maxWidth: Int) -> (Int, Int)? {
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    guard pixelWidth >= 1, pixelHeight >= 1 else { return nil }
    let w = min(maxWidth, Int(pixelWidth))
    let h = max(1, Int((Double(pixelHeight) * Double(w) / Double(pixelWidth)).rounded()))
    return (w, h)
  }

  /// Draws with UIKit so the orientation is applied; UIKit's origin is top-left, so flip first.
  private static func draw(_ image: UIImage, into context: CGContext, width: Int, height: Int) {
    context.interpolationQuality = .medium
    if image.imageOrientation == .up, let cgImage = image.cgImage {
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return
    }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(context)
    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
    UIGraphicsPopContext()
  }
}
