/*
 * ReadFraming - is this frame worth reading, and if not, what should the wearer do
 *
 * Runs on the OCR result plus a cheap brightness/sharpness measure, before (or instead of)
 * reading. notes/a11y-prior-art.md > 3 "Framing guidance": text present, cut off at an edge, too
 * small, blurry or dark, each with a direction the wearer can act on.
 *
 * Left and right. The HSTN camera faces forward from the frame of the glasses, so its image is
 * the wearer's view, not a mirror (unlike a selfie camera): image x grows towards the wearer's
 * RIGHT. Text touching the image's right edge carries on past the right of what the camera sees,
 * so the wearer turns their head right to bring it in; touching the bottom edge, they tilt down.
 * The camera also sits on the LEFT temple, a few centimetres left of the nose, so a page held
 * straight in front of the face lands right of centre in the image and its right side is the
 * first thing cut off (AFB review in notes/a11y-prior-art.md > 1a). That is why "no text" advice
 * says to hold the page "a little to your right". Not yet checked on real HSTN frames: confirm
 * with a page that says LEFT and RIGHT on its two halves before trusting the wording.
 *
 * Thresholds marked [est] are first guesses for 540x960 mock frames, to tune on hardware.
 */

import CoreGraphics
import Foundation

enum FramingEdge: String, CaseIterable, Sendable {
  case left
  case right
  case top
  case bottom
}

enum FramingVerdict: Equatable, Sendable {
  case good
  /// Readable, but lines run into these edges, so some words are missing.
  case cutOff(Set<FramingEdge>)
  case noText
  case tooDark
  case tooBlurry
  /// Text is there but too few pixels tall to read reliably.
  case tooSmall

  /// The guidance replaces reading (nothing worth reading in this frame).
  var blocksReading: Bool {
    switch self {
    case .good, .cutOff: false
    case .noText, .tooDark, .tooBlurry, .tooSmall: true
    }
  }

  var logName: String {
    switch self {
    case .good: "good"
    case .cutOff(let edges): "cut_" + FramingEdge.allCases.filter(edges.contains).map(\.rawValue).joined(separator: "_")
    case .noText: "no_text"
    case .tooDark: "dark"
    case .tooBlurry: "blurry"
    case .tooSmall: "small"
    }
  }
}

/// Mean brightness (0 black ... 1 white) and sharpness (variance of the Laplacian on a small
/// greyscale copy, in 0...255 units). Both are cheap: a ~240 px wide image, one pass each.
struct FrameQuality: Equatable, Sendable {
  var brightness: Double
  var sharpness: Double

  /// Unknown quality never blocks reading.
  static let unknown = FrameQuality(brightness: 0.5, sharpness: .infinity)

  static func measure(gray: [UInt8], width: Int, height: Int) -> FrameQuality {
    guard width >= 3, height >= 3, gray.count >= width * height else { return .unknown }
    var sum = 0.0
    for value in gray.prefix(width * height) { sum += Double(value) }
    let brightness = sum / Double(width * height) / 255

    var lapSum = 0.0
    var lapSquares = 0.0
    var count = 0.0
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let center = Int(gray[y * width + x])
        let laplacian =
          Int(gray[(y - 1) * width + x]) + Int(gray[(y + 1) * width + x]) + Int(gray[y * width + x - 1])
          + Int(gray[y * width + x + 1]) - 4 * center
        let value = Double(laplacian)
        lapSum += value
        lapSquares += value * value
        count += 1
      }
    }
    let mean = lapSum / count
    return FrameQuality(brightness: brightness, sharpness: lapSquares / count - mean * mean)
  }
}

enum FramingAdvisor {
  /// A line within this share of the frame size of an edge counts as touching it. [est]
  static let edgeMargin: CGFloat = 0.025
  /// Median line height in pixels below which text is "too small". [est] Vision needs roughly
  /// 10-20 px of text height; below 16 px words start to go wrong at stream quality.
  static let minLineHeight: CGFloat = 16
  /// Up to this height, low confidence also counts as "too small" rather than "unclear words".
  static let lowConfidenceLineHeight: CGFloat = 24
  static let lowConfidence: Float = 0.5
  /// [est] Mean brightness below this is too dark to read.
  static let darkBelow = 0.16
  /// [est] Laplacian variance below this is too blurry, measured on the ~240 px copy.
  static let blurryBelow = 25.0

  static func assess(_ page: ReadPage, quality: FrameQuality) -> FramingVerdict {
    let lines = page.lines.filter { !$0.words.isEmpty }
    let dark = quality.brightness < darkBelow
    let blurry = quality.sharpness < blurryBelow
    guard !lines.isEmpty else {
      if dark { return .tooDark }
      if blurry { return .tooBlurry }
      return .noText
    }
    let heights = lines.map(\.box.height).sorted()
    let medianHeight = heights[heights.count / 2]
    let words = lines.flatMap(\.words)
    let meanConfidence = words.map(\.confidence).reduce(0, +) / Float(max(1, words.count))
    if medianHeight < minLineHeight { return .tooSmall }
    if meanConfidence < lowConfidence {
      // Mostly unreadable words: name the cause instead of reading guesses.
      if dark { return .tooDark }
      if blurry { return .tooBlurry }
      if medianHeight < lowConfidenceLineHeight { return .tooSmall }
    }
    let edges = cutEdges(lines, imageSize: page.imageSize)
    return edges.isEmpty ? .good : .cutOff(edges)
  }

  /// Edges that some line of text touches.
  static func cutEdges(_ lines: [ReadLine], imageSize: CGSize) -> Set<FramingEdge> {
    let marginX = imageSize.width * edgeMargin
    let marginY = imageSize.height * edgeMargin
    var edges: Set<FramingEdge> = []
    for line in lines {
      if line.box.minX <= marginX { edges.insert(.left) }
      if line.box.maxX >= imageSize.width - marginX { edges.insert(.right) }
      if line.box.minY <= marginY { edges.insert(.top) }
      if line.box.maxY >= imageSize.height - marginY { edges.insert(.bottom) }
    }
    return edges
  }
}
