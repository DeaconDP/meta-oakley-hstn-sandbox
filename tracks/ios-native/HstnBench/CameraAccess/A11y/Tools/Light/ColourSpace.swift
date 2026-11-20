/*
 * ColourSpace - turning camera pixels into numbers that match how people see colour
 *
 * Port of Android's tools/light/ColourSpace.kt. Camera pixels are sRGB: gamma-encoded, and equal
 * steps in them are not equal steps to the eye. Everything the light tool measures goes through
 * here: sRGB 0...255 -> linear light (for brightness and white balance, which are physical) -> OKLab
 * (for naming colours, which is perceptual: equal distances look about equally different, and
 * lightness, chroma and hue are separate axes). OKLab is Björn Ottosson's 2020 space; it fixes
 * CIELAB's blue-to-purple hue drift, which matters for "navy" vs "purple". Pixels are packed ARGB
 * UInt32s (0xAARRGGBB), as ToolImageSampler gives them.
 */

import Foundation

/// A colour in OKLab. `l` is lightness 0...1; `a` green-red and `b` blue-yellow, about -0.4...0.4.
struct Oklab: Equatable, Sendable {
  var l: Double
  var a: Double
  var b: Double

  /// Colourfulness: 0 for greys, ~0.1 for muted colours, 0.2-0.3 for vivid ones.
  var chroma: Double { (a * a + b * b).squareRoot() }

  /// Hue angle in degrees, 0...360 (red ~30, yellow ~110, green ~140, blue ~265).
  var hue: Double { (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }

  func distance(to other: Oklab, lightnessWeight: Double = 1) -> Double {
    let dl = (l - other.l) * lightnessWeight
    let da = a - other.a
    let db = b - other.b
    return (dl * dl + da * da + db * db).squareRoot()
  }
}

/// Linear-light RGB, each 0...1 (more than 1 after a white-balance gain; clamp before encoding).
struct LinearRGB: Equatable, Sendable {
  var r: Double
  var g: Double
  var b: Double
}

enum ColourSpace {
  private static let toLinearTable: [Double] = (0..<256).map { i in
    let c = Double(i) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  static func red(_ argb: UInt32) -> Int { Int((argb >> 16) & 0xFF) }
  static func green(_ argb: UInt32) -> Int { Int((argb >> 8) & 0xFF) }
  static func blue(_ argb: UInt32) -> Int { Int(argb & 0xFF) }

  static func argb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    0xFF00_0000 | UInt32(min(max(r, 0), 255)) << 16 | UInt32(min(max(g, 0), 255)) << 8 | UInt32(min(max(b, 0), 255))
  }

  /// sRGB 0...255 to linear light 0...1.
  static func toLinear(_ channel: Int) -> Double { toLinearTable[min(max(channel, 0), 255)] }

  /// Linear 0...1 back to sRGB 0...255 (clamped).
  static func toSrgb(_ linear: Double) -> Int {
    let c = min(max(linear, 0), 1)
    let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    return min(max(Int(s * 255 + 0.5), 0), 255)
  }

  static func linear(_ argb: UInt32) -> LinearRGB {
    LinearRGB(r: toLinear(red(argb)), g: toLinear(green(argb)), b: toLinear(blue(argb)))
  }

  /// Gamma-encoded brightness 0...255 (Rec. 709 weights on the sRGB values), as a camera "luma".
  static func luma(_ argb: UInt32) -> Int {
    Int(0.2126 * Double(red(argb)) + 0.7152 * Double(green(argb)) + 0.0722 * Double(blue(argb)) + 0.5)
  }

  /// Relative luminance 0...1 (linear light), the physical brightness.
  static func luminance(_ argb: UInt32) -> Double {
    0.2126 * toLinear(red(argb)) + 0.7152 * toLinear(green(argb)) + 0.0722 * toLinear(blue(argb))
  }

  static func oklab(_ c: LinearRGB) -> Oklab {
    let r = min(max(c.r, 0), 1)
    let g = min(max(c.g, 0), 1)
    let b = min(max(c.b, 0), 1)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return Oklab(
      l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
  }

  static func oklab(_ argb: UInt32) -> Oklab { oklab(linear(argb)) }

  static func oklab(_ r: Int, _ g: Int, _ b: Int) -> Oklab { oklab(argb(r, g, b)) }

  /// Linear RGB back to a packed sRGB colour (for the on-screen swatch).
  static func argb(_ c: LinearRGB) -> UInt32 { argb(toSrgb(c.r), toSrgb(c.g), toSrgb(c.b)) }
}
