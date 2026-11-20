/*
 * WatchRecognizer - one look at a frame for Watch for text: is the view usable, and what text is in it
 *
 * Signs, not pages: Vision's fast recognition level with no language correction (it would "fix"
 * 42A or B00TS into words), every line kept with its box. Read text uses the accurate level for
 * pages; watching runs about twice a second, so speed matters more than the last few percent.
 * The covered / too-dark check runs first on a 48x72 brightness grid (WatchViewCheck) and OCR is
 * skipped when it fails. Blocking; call off the main actor.
 */

import CoreGraphics
import UIKit
import Vision

struct WatchLook: Sendable {
  var issue: WatchViewIssue?
  /// nil when the view check failed and OCR was skipped.
  var page: WatchPage?
  var ocrMilliseconds: Int
}

enum WatchRecognizerError: Error {
  case noImage
}

enum WatchRecognizer {
  static let gridWidth = 48
  static let gridHeight = 72

  static func look(at image: UIImage) throws -> WatchLook {
    guard let cgImage = image.cgImage else { throw WatchRecognizerError.noImage }
    if let issue = WatchViewCheck.issue(luma: luma(cgImage)) {
      return WatchLook(issue: issue, page: nil, ocrMilliseconds: 0)
    }
    let started = DispatchTime.now().uptimeNanoseconds
    let page = try recognize(cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    return WatchLook(issue: nil, page: page, ocrMilliseconds: ms)
  }

  static func recognize(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> WatchPage {
    let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
    let size =
      rotated
      ? CGSize(width: cgImage.height, height: cgImage.width)
      : CGSize(width: cgImage.width, height: cgImage.height)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
    let lines: [WatchLine] = (request.results ?? []).compactMap { observation in
      guard let top = observation.topCandidates(1).first, !top.string.isEmpty else { return nil }
      // Vision: normalized, origin bottom-left. Here: pixels, origin top-left.
      let box = observation.boundingBox
      return WatchLine(
        text: top.string,
        box: CGRect(
          x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width,
          height: box.height * size.height))
    }
    return WatchPage(lines: lines, imageSize: size)
  }

  /// Brightness on a small grey copy, row-major, 0...255. Orientation doesn't matter for it.
  static func luma(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: gridWidth, height: gridHeight, bitsPerComponent: 8, bytesPerRow: gridWidth,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .low
      context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
      return true
    }
    // An image that can't be drawn mustn't read as "covered".
    return drawn ? pixels : []
  }
}
