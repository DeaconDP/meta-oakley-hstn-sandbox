/*
 * LightMeter - how bright the view is, and the probe tone's pitch for it
 *
 * Port of Android's tools/light/LightMeter.kt. The light probe answers "is the light on?", "are the
 * curtains open?" and "where's the window?" with a tone whose pitch follows brightness as the user
 * turns the phone (or their head, with the glasses). This file is the arithmetic, on a downscaled
 * frame of packed ARGB pixels:
 *  - `measure`: centre-weighted brightness in linear light (the middle half of the frame counts
 *    three times, so the tone points where the camera points), mean luma, the share of blown-out
 *    pixels, and which third (left, middle, right) is brightest.
 *  - PitchMap: brightness -> frequency, logarithmic both ways. Perceived brightness is roughly log
 *    luminance and perceived pitch is log frequency, so each doubling of light (one camera "stop")
 *    raises the tone by the same musical interval: 9 stops span 3 octaves, 220-1760 Hz.
 *  - PitchSmoother: an exponential average in that log space with a small dead band, so camera
 *    noise and compression flicker don't make the tone warble.
 *  - `level`: dark / dim / normal indoor / bright / very bright. Relative to the exposure the camera
 *    chose (on the phone the tool locks it while probing, see PhoneExposureLock), not lux, and the
 *    spoken level says so.
 */

import Foundation

enum LightLevel: Sendable {
  case dark, dim, normal, bright, veryBright

  var spoken: String {
    switch self {
    case .dark: "Dark"
    case .dim: "Dim"
    case .normal: "Normal indoor light"
    case .bright: "Bright"
    case .veryBright: "Very bright"
    }
  }
}

enum LightSide: Int, Sendable {
  case left, middle, right
}

struct LightReading: Equatable, Sendable {
  /// Centre-weighted relative luminance, linear 0...1. What the tone follows.
  var luminance: Double
  /// Whole-frame mean luma 0...255 (gamma-encoded, as the camera delivers it).
  var meanLuma: Double
  /// Share of pixels with a channel at 250+: a lamp, a window, the sun.
  var clipped: Double
  /// The clearly brightest third of the view, or nil if they're about even.
  var brightestSide: LightSide?
}

enum LightMeter {
  static func measure(_ pixels: [UInt32], width: Int, height: Int) -> LightReading? {
    guard pixels.count == width * height, width >= 3, height >= 3 else { return nil }
    var weighted = 0.0
    var weights = 0.0
    var lumaSum = 0
    var clipped = 0
    var thirds = [0.0, 0.0, 0.0]
    var thirdCounts = [0, 0, 0]
    for y in 0..<height {
      let midY = y >= height / 4 && y < height * 3 / 4
      for x in 0..<width {
        let p = pixels[y * width + x]
        let lum = ColourSpace.luminance(p)
        let w = midY && x >= width / 4 && x < width * 3 / 4 ? 3.0 : 1.0
        weighted += lum * w
        weights += w
        lumaSum += ColourSpace.luma(p)
        if ColourSpace.red(p) >= 250 || ColourSpace.green(p) >= 250 || ColourSpace.blue(p) >= 250 { clipped += 1 }
        let t = min(max(x * 3 / width, 0), 2)
        thirds[t] += lum
        thirdCounts[t] += 1
      }
    }
    let means = (0..<3).map { thirds[$0] / Double(max(1, thirdCounts[$0])) }
    let best = (0..<3).max { means[$0] < means[$1] }!
    let others = (0..<3).filter { $0 != best }.map { means[$0] }.max()!
    let side = means[best] > 0.02 && means[best] > others * 1.6 ? LightSide(rawValue: best) : nil
    return LightReading(
      luminance: weighted / weights, meanLuma: Double(lumaSum) / Double(pixels.count), clipped: Double(clipped) / Double(pixels.count),
      brightestSide: side)
  }

  /// The spoken level for a reading; see the header for why it's relative.
  static func level(_ r: LightReading) -> LightLevel {
    if r.meanLuma < 20 { return .dark }
    if r.meanLuma < 60 { return .dim }
    if r.meanLuma >= 200 || r.clipped > 0.3 { return .veryBright }
    if r.meanLuma >= 150 { return .bright }
    return .normal
  }
}

enum PitchMap {
  static let minHz = 220.0
  static let maxHz = 1760.0
  /// Darkest luminance with its own pitch: 9 stops below white.
  static let floor = 1.0 / 512

  /// 0 (dark) ... 1 (white), linear in stops.
  static func position(_ luminance: Double) -> Double {
    let l = min(max(luminance, floor), 1)
    return (log(l) - log(floor)) / -log(floor)
  }

  /// Frequency for a position, exponential so equal steps sound equal.
  static func frequency(_ position: Double) -> Double {
    minHz * pow(maxHz / minHz, min(max(position, 0), 1))
  }

  static func frequency(forLuminance luminance: Double) -> Double { frequency(position(luminance)) }
}

/// Smooths the tone's position (0...1). `alpha` is how far each update moves towards the new value:
/// 0.4 at 4 updates a second settles in about a second. Changes smaller than `deadBand` are ignored.
struct PitchSmoother: Sendable {
  var alpha = 0.4
  var deadBand = 0.004
  private(set) var position: Double?

  init(alpha: Double = 0.4, deadBand: Double = 0.004) {
    self.alpha = alpha
    self.deadBand = deadBand
  }

  mutating func update(_ target: Double) -> Double {
    guard let p = position else {
      position = target
      return target
    }
    let next = p + alpha * (target - p)
    if abs(next - p) >= deadBand { position = next }
    return position!
  }

  mutating func reset() { position = nil }
}
