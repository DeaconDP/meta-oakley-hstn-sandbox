/*
 * ImportedPages - text out of an imported photo or PDF page, on the phone only
 *
 * A PDF page with a text layer is read from that layer: the exact words, no OCR guesses, every word
 * at full confidence. Lines come from PDFKit with their positions, so ReadingOrder handles columns
 * and headings the same way as for a camera page. A page without one (a scan, a photo saved as a
 * PDF) is rendered and read with TextRecognizer, like a photo.
 *
 * Pictures from elsewhere are often whole pages or full screenshots, where body text is a small
 * share of the height. The camera's minimum text height (1/64) would skip it, so imports use
 * `ocrMinimumTextHeight`. Big photos are scaled down to `maxPixelSize` first (memory, speed).
 *
 * Blocking calls; run them off the main actor. Nothing leaves the phone: no cloud reading here,
 * whatever the natural-voice setting says.
 */

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit

enum ImportedPages {
  /// Smallest text, as a share of the image height, that OCR looks for in an import.
  static let ocrMinimumTextHeight: Float = 1.0 / 128
  /// Long side of a photo or rendered PDF page handed to OCR.
  static let maxPixelSize: CGFloat = 2600
  /// A text layer counts when it has at least this many letters or digits.
  static let minimumTextLayerCharacters = 3

  enum Source: Equatable, Sendable {
    /// The PDF's own text: exact words.
    case textLayer
    /// OCR of the picture or of the rendered page.
    case recognized
  }

  struct PageText: Equatable, Sendable {
    var page: ReadPage
    var source: Source

    var isEmpty: Bool { page.lines.allSatisfy { $0.words.isEmpty } }
  }

  enum ImportError: Error, Equatable {
    case unreadableImage
    case unreadablePDF
    case lockedPDF
  }

  // MARK: Photos

  /// OCR of a photo or screenshot file's bytes.
  static func recognizeImage(data: Data) throws -> PageText {
    guard let image = downscaledImage(data: data, maxPixelSize: maxPixelSize) else { throw ImportError.unreadableImage }
    return try recognize(image)
  }

  static func recognize(_ image: UIImage) throws -> PageText {
    let recognized = try TextRecognizer.recognize(image, minimumTextHeight: ocrMinimumTextHeight)
    return PageText(page: recognized.page, source: .recognized)
  }

  /// Decodes at most `maxPixelSize` on the long side, upright (EXIF orientation applied).
  static func downscaledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: flattenedOnWhite(cgImage))
  }

  /// A picture with transparency (a PNG exported from a PDF, a cut-out) on white. Vision reads
  /// transparent pixels as black, so black text on a clear background would vanish.
  static func flattenedOnWhite(_ image: CGImage) -> CGImage {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return image
    default: break
    }
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(UIColor.white.cgColor)
    context.fill(rect)
    context.draw(image, in: rect)
    return context.makeImage() ?? image
  }

  // MARK: PDF pages

  /// True when the page carries real text (not just an empty or whitespace layer).
  static func hasTextLayer(_ page: PDFPage) -> Bool {
    let characters = (page.string ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    return characters >= minimumTextLayerCharacters
  }

  /// The text layer as lines with positions (points, top-left origin). nil without a text layer.
  static func textLayerPage(_ page: PDFPage) -> ReadPage? {
    guard hasTextLayer(page) else { return nil }
    let bounds = page.bounds(for: .cropBox)
    var lines: [ReadLine] = []
    if let selection = page.selection(for: bounds) {
      for line in selection.selectionsByLine() {
        let words = (line.string ?? "").split(whereSeparator: \.isWhitespace).map {
          ReadWord(text: String($0), confidence: 1)
        }
        guard !words.isEmpty else { continue }
        let box = line.bounds(for: page)
        lines.append(
          ReadLine(
            words: words,
            box: CGRect(x: box.minX - bounds.minX, y: bounds.maxY - box.maxY, width: box.width, height: box.height)))
      }
    }
    if lines.isEmpty, let string = page.string {
      lines = fallbackLines(string, width: bounds.width)
    }
    return ReadPage(lines: lines, imageSize: bounds.size)
  }

  /// When PDFKit gives no line selections: one line per text line, stacked, with the width
  /// standing in for the length so short lines (headings) still end their sentence.
  static func fallbackLines(_ string: String, width: CGFloat) -> [ReadLine] {
    let rows = string.components(separatedBy: .newlines)
    let longest = max(1, rows.map(\.count).max() ?? 1)
    var lines: [ReadLine] = []
    var y: CGFloat = 0
    for row in rows {
      defer { y += 12 }
      let words = row.split(whereSeparator: \.isWhitespace).map { ReadWord(text: String($0), confidence: 1) }
      guard !words.isEmpty else { continue }
      let lineWidth = max(1, width * CGFloat(row.count) / CGFloat(longest))
      lines.append(ReadLine(words: words, box: CGRect(x: 0, y: y, width: lineWidth, height: 10)))
    }
    return lines
  }

  /// Renders the page upright on white, at most `maxPixelSize` on the long side.
  static func render(_ page: PDFPage, maxPixelSize: CGFloat = maxPixelSize) -> UIImage {
    let bounds = page.bounds(for: .cropBox)
    let rotated = page.rotation % 180 != 0
    let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    let scale = maxPixelSize / max(1, max(size.width, size.height))
    let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    // A rotated page: PDFKit's thumbnail applies the rotation (and paints white).
    if rotated { return page.thumbnail(of: target, for: .cropBox) }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: target, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: target))
      let cg = context.cgContext
      cg.translateBy(x: 0, y: target.height)
      cg.scaleBy(x: scale, y: -scale)
      page.draw(with: .cropBox, to: cg)
    }
  }

  /// The page's text: the text layer when it has one, else OCR of the rendered page.
  static func text(of page: PDFPage) throws -> PageText {
    if let layer = textLayerPage(page) { return PageText(page: layer, source: .textLayer) }
    return try recognize(render(page))
  }

  // MARK: Text

  /// Sentences in reading order, as the camera reader splits them.
  static func sentences(_ page: ReadPage) -> [[ReadWord]] {
    SentenceSplitter.sentences(blocks: ReadingOrder.blocks(page.lines))
  }

  /// Plain text in reading order, paragraphs separated by a blank line (for Ask).
  static func plainText(_ page: ReadPage) -> String {
    ReadingOrder.blocks(page.lines)
      .map { block in block.map(\.text).joined(separator: "\n") }
      .joined(separator: "\n\n")
  }
}

/// A PDF opened for reading, one page at a time. PDFDocument isn't Sendable; the reader only ever
/// asks for one page at a time from a background task, and the lock keeps that true.
final class ImportedPDF: @unchecked Sendable {
  private let document: PDFDocument
  private let lock = NSLock()

  let pageCount: Int

  init(data: Data) throws {
    guard let document = PDFDocument(data: data) else { throw ImportedPages.ImportError.unreadablePDF }
    guard !document.isLocked else { throw ImportedPages.ImportError.lockedPDF }
    self.document = document
    pageCount = document.pageCount
  }

  convenience init(url: URL) throws {
    guard let data = try? Data(contentsOf: url) else { throw ImportedPages.ImportError.unreadablePDF }
    try self.init(data: data)
  }

  /// Blocking. `index` is zero-based.
  func text(ofPage index: Int) throws -> ImportedPages.PageText {
    try lock.withLock {
      guard let page = document.page(at: index) else { throw ImportedPages.ImportError.unreadablePDF }
      return try ImportedPages.text(of: page)
    }
  }
}
