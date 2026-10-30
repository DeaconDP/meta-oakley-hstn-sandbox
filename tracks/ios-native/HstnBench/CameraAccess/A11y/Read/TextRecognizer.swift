/*
 * TextRecognizer - on-device OCR with Apple Vision, plus the cheap frame-quality measure
 *
 * Nothing leaves the phone: VNRecognizeTextRequest runs locally, and the frame is dropped once
 * the result is built (no frames stored, ROADMAP "Privacy").
 *
 * Settings:
 * - `.accurate`: the neural recognizer. `.fast` is the character-by-character one; it is quicker
 *   but much worse on 540x960 stream frames, and reading wrong words fast is not the goal.
 * - Language correction ON. It is a language model pass, and the worry for verbatim reading is
 *   that it "fixes" a word into a more likely one. It was kept anyway: at stream resolution most
 *   errors are character-level (rn/m, l/1, e/c) on ordinary words, which correction repairs, and
 *   the case where a fix would be dangerous (numbers, doses, money) is guarded separately:
 *   ReadSpeech withholds any dose or amount below 0.8 confidence, and WordConfidence marks a word
 *   unsure when Vision's runner-up candidates disagree on it, which is where corrections show up.
 *   Turning it off is the right call for codes and serial numbers; that would be a separate mode.
 * - English only, matching the app's spoken language.
 * - minimumTextHeight 1/64 of the image (15 px at 960): below Vision's 1/32 default, so small
 *   print is found and reported as "too small" (with a photo fallback) instead of "no text".
 */

import CoreGraphics
import ImageIO
import UIKit
import Vision

enum TextRecognizerError: Error {
  case noImage
}

struct RecognizedFrame: Sendable {
  var page: ReadPage
  var quality: FrameQuality
  /// Time spent in Vision alone.
  var ocrMilliseconds: Int
}

enum TextRecognizer {
  static let alternatives = 3
  static let minimumTextHeight: Float = 1.0 / 64

  /// Blocking; call off the main actor.
  static func recognize(_ image: UIImage) throws -> RecognizedFrame {
    guard let cgImage = image.cgImage else { throw TextRecognizerError.noImage }
    let orientation = CGImagePropertyOrientation(image.imageOrientation)
    let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
    let size = rotated
      ? CGSize(width: cgImage.height, height: cgImage.width)
      : CGSize(width: cgImage.width, height: cgImage.height)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = minimumTextHeight

    let started = DispatchTime.now().uptimeNanoseconds
    try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
    let ocrMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

    let lines: [ReadLine] = (request.results ?? []).compactMap { observation in
      let candidates = observation.topCandidates(alternatives)
      guard let top = candidates.first else { return nil }
      let words = WordConfidence.words(
        top: top.string, confidence: top.confidence,
        alternatives: candidates.dropFirst().map { ($0.string, $0.confidence) })
      guard !words.isEmpty else { return nil }
      // Vision: normalized, origin bottom-left. Reader: pixels, origin top-left.
      let box = observation.boundingBox
      let rect = CGRect(
        x: box.minX * size.width, y: (1 - box.maxY) * size.height,
        width: box.width * size.width, height: box.height * size.height)
      return ReadLine(words: words, box: rect)
    }
    return RecognizedFrame(
      page: ReadPage(lines: lines, imageSize: size), quality: measureQuality(cgImage), ocrMilliseconds: ocrMilliseconds)
  }

  /// Brightness and sharpness on a ~240 px wide greyscale copy. Orientation doesn't matter for
  /// either, so the unrotated image is used.
  static func measureQuality(_ image: CGImage) -> FrameQuality {
    let width = min(240, image.width)
    let height = max(3, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? FrameQuality.measure(gray: pixels, width: width, height: height) : .unknown
  }
}

extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .upMirrored: self = .upMirrored
    case .downMirrored: self = .downMirrored
    case .leftMirrored: self = .leftMirrored
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
