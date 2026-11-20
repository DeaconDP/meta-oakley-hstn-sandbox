/*
 * BarcodeHint - is there something barcode-like in the frame, and how big and central is it?
 *
 * Port of Android's tools/labels/BarcodeHint.kt. While searching, the label reader plays
 * geiger-style ticks that get faster and higher as a barcode-like patch gets bigger and nearer the
 * middle, so the user can turn the packet towards it before Vision can decode it. A barcode is many
 * dark/light changes along a row that repeat almost exactly in rows a little lower (the bars are
 * vertical). Text also has many changes along a row, but a row a few percent of the frame lower
 * looks different. The caller passes full-width rows (bars are only a few pixels wide) sampled at
 * even heights.
 */

import Foundation

/// A barcode-like patch, as fractions of the frame (0...1).
struct BarRegion: Equatable, Sendable {
  var left: Double
  var right: Double
  var top: Double
  var bottom: Double

  var width: Double { right - left }
  var centerX: Double { (left + right) / 2 }
  var centerY: Double { (top + bottom) / 2 }

  /// 0...1: how big and central the patch is. A barcode a third of the frame wide in the middle is
  /// about 0.6; one filling half the width, centred, is 1.
  var closeness: Double {
    let size = min(max(width / 0.5, 0), 1)
    let off = max(abs(centerX - 0.5), abs(centerY - 0.5)) * 2
    return min(max(size.squareRoot() * (1 - 0.6 * min(max(off, 0), 1)), 0), 1)
  }
}

enum BarcodeHint {
  /// Fewest dark/light changes in a run for a row to look like bars (EAN-13 has 58).
  static let minTransitions = 18
  /// Rows compared with the row this many samples below.
  static let rowStep = 2
  /// Fraction of pixels that must match between the two rows.
  static let minAgreement = 0.85

  /// `luma` is `rows` rows of `width` brightness values (0...255), evenly spaced from top to bottom
  /// of the frame. Returns the biggest barcode-like patch, or nil.
  static func find(_ luma: [UInt8], width: Int, rows: Int) -> BarRegion? {
    guard luma.count == width * rows, width >= 32, rows >= rowStep + 2 else { return nil }
    let bits = (0..<rows).map { binarize(luma, offset: $0 * width, width: width) }
    let spans = bits.map { barSpan($0, width: width) }

    // A row counts if it has a bar span that the row rowStep below repeats.
    var good = [Bool](repeating: false, count: rows)
    for r in 0..<(rows - rowStep) {
      guard let s = spans[r] else { continue }
      if agreement(bits[r], bits[r + rowStep], s.lowerBound, s.upperBound) >= minAgreement { good[r] = true }
    }
    // The biggest group of consecutive good rows (one missing row allowed).
    var best: BarRegion?
    var bestArea = 0.0
    var r = 0
    while r < rows {
      guard good[r], let first = spans[r] else {
        r += 1
        continue
      }
      var end = r
      var left = first.lowerBound
      var right = first.upperBound
      var k = r + 1
      while k < rows, good[k] || (k + 1 < rows && good[k + 1]) {
        if good[k], let span = spans[k] {
          end = k
          left = min(left, span.lowerBound)
          right = max(right, span.upperBound)
        }
        k += 1
      }
      let region = BarRegion(
        left: Double(left) / Double(width), right: Double(right + 1) / Double(width), top: Double(r) / Double(rows),
        bottom: Double(end + rowStep + 1) / Double(rows))
      let area = region.width * (region.bottom - region.top)
      if area > bestArea {
        bestArea = area
        best = region
      }
      r = k
    }
    return best
  }

  /// Dark (true) / light per pixel, against a moving average, so uneven lighting doesn't matter.
  private static func binarize(_ luma: [UInt8], offset: Int, width: Int) -> [Bool] {
    let half = 12
    var prefix = [Int](repeating: 0, count: width + 1)
    var low = 255
    var high = 0
    for x in 0..<width {
      let v = Int(luma[offset + x])
      prefix[x + 1] = prefix[x] + v
      low = min(low, v)
      high = max(high, v)
    }
    if high - low < 40 { return [Bool](repeating: false, count: width) }
    return (0..<width).map { x in
      let a = max(0, x - half)
      let b = min(width, x + half + 1)
      let mean = (prefix[b] - prefix[a]) / (b - a)
      return Int(luma[offset + x]) < mean - 8
    }
  }

  /// The longest run of closely spaced changes in a row, as start...end pixels, or nil.
  private static func barSpan(_ bits: [Bool], width: Int) -> ClosedRange<Int>? {
    let maxGap = max(6, width / 24)
    var bestStart = -1
    var bestEnd = -1
    var bestCount = 0
    var runStart = -1
    var last = -1
    var count = 0
    for x in 1..<width where bits[x] != bits[x - 1] {
      if last >= 0, x - last <= maxGap {
        count += 1
      } else {
        runStart = x
        count = 1
      }
      last = x
      if count > bestCount {
        bestCount = count
        bestStart = runStart
        bestEnd = x
      }
    }
    if bestCount < minTransitions || bestEnd - bestStart < width / 8 { return nil }
    return bestStart...bestEnd
  }

  private static func agreement(_ a: [Bool], _ b: [Bool], _ from: Int, _ to: Int) -> Double {
    var same = 0
    for x in from...to where a[x] == b[x] { same += 1 }
    return Double(same) / Double(to - from + 1)
  }

  /// Geiger ticks for a patch: 1 to 4 ticks in the interval until the next frame, higher when closer
  /// (500 to 1400 Hz).
  static func ticks(for closeness: Double) -> (count: Int, hz: Double) {
    (1 + Int(min(max(closeness, 0), 1) * 3.99), 500 + 900 * min(max(closeness, 0), 1))
  }
}
