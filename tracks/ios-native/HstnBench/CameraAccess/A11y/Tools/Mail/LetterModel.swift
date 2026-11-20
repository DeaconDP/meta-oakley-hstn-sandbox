/*
 * LetterModel - one photographed page of a letter (or envelope), as OCR saw it
 *
 * Port of the Android LetterModel.kt. It keeps what the mail reader needs: which block each line
 * came from, and the confidence of each word (and of each character, when the engine gives one),
 * so the money rule can refuse an amount when any part of it is unsure.
 *
 * iOS difference: Android's ML Kit gives a block per paragraph and a confidence and box per
 * character. Apple Vision (TextRecognizer, shared with Read text) gives one observation per line,
 * one confidence per line, and up to three candidate readings. WordConfidence turns the candidates
 * into per-word confidence: a word the runner-up readings disagree on (and for numbers and money,
 * any disagreement at all) drops below the threshold. So on iOS `symbolConfidences` and
 * `symbolBoxes` stay empty, every line starts as its own block (LetterLayout merges stacked lines,
 * which Android needed anyway because ML Kit did the same on the Galaxy A26), and the
 * missing-character box check below only runs if a future OCR pass fills in character boxes.
 * Coordinates are image pixels, origin top-left. Pure Swift, no Vision.
 */

import CoreGraphics
import Foundation

/// One word. `confidence` 0...1 or nil if unknown; `symbolConfidences` one per UTF-16 unit of
/// `text` when the engine gives them (empty otherwise, always on iOS today).
struct LetterWord: Equatable, Sendable {
  var text: String
  var confidence: Float?
  var symbolConfidences: [Float] = []
  /// One box per character of `text` when the engine gives them (empty otherwise).
  var symbolBoxes: [CGRect] = []
}

/// One line, from block number `block`. `words` may be empty (then `confidence` is all we know).
struct LetterLine: Equatable, Sendable {
  var text: String
  var box: CGRect
  var block: Int
  var confidence: Float?
  var words: [LetterWord] = []

  /// The lowest confidence of any character in [start, end) of `text` (UTF-16 offsets), from the
  /// most detailed level available: characters, then words, then the line. nil if none was given.
  func minConfidence(_ start: Int, _ end: Int, digitsOnly: Bool = false) -> Float? {
    if words.isEmpty { return confidence }
    var cursor = 0
    var lowest: Float?
    var anyWord = false
    for word in words {
      // Words that don't line up with the text: fall back to the line.
      guard let at = text.utf16Index(of: word.text, from: cursor) else { return confidence }
      let length = word.text.utf16Count
      cursor = at + length
      let wordStart = at
      let wordEnd = at + length
      if wordEnd <= start || wordStart >= end { continue }
      anyWord = true
      var value: Float?
      if word.symbolConfidences.count == length {
        var lowestSymbol: Float?
        for i in max(wordStart, start)..<min(wordEnd, end) {
          if digitsOnly && !text.utf16Char(i).isASCIIDigit { continue }
          let symbol = word.symbolConfidences[i - wordStart]
          lowestSymbol = lowestSymbol.map { min($0, symbol) } ?? symbol
        }
        value = lowestSymbol ?? word.confidence
      } else {
        value = word.confidence
      }
      if let value { lowest = lowest.map { min($0, value) } ?? value }
    }
    return anyWord ? (lowest ?? confidence) : confidence
  }

  /// True if the characters in [start, end) look like one went missing: a digit's box much wider
  /// than the others, a point that wide (a smudged digit absorbed into its neighbour), or a gap
  /// between two characters wide enough for another one. Seen on Android: "£84.17" with the 4
  /// smudged came back as "£8.17" with every remaining digit confident. Needs character boxes;
  /// false without them (the case on iOS today, see the file comment).
  func looksLikeAMissingCharacter(_ start: Int, _ end: Int) -> Bool {
    var cursor = 0
    var boxes: [(Character, CGRect)] = []
    for word in words {
      guard let at = text.utf16Index(of: word.text, from: cursor) else { return false }
      let length = word.text.utf16Count
      cursor = at + length
      guard word.symbolBoxes.count == length else { continue }
      for i in 0..<length where (start..<end).contains(at + i) {
        boxes.append((word.text.utf16Char(i), word.symbolBoxes[i]))
      }
    }
    let digits = boxes.filter { $0.0.isASCIIDigit }.map(\.1)
    guard digits.count >= 2 else { return false }
    let widths = digits.map(\.width).sorted()
    let typical = max(widths[widths.count / 2], 1)
    let height = digits.map(\.height).sorted()[digits.count / 2]
    // Digits are about half as wide as they are tall; a digit box far wider holds two characters.
    if digits.contains(where: { $0.width > max(typical * 1.6, height * 0.9) }) { return true }
    // A point or comma as wide as half a digit has swallowed something.
    if boxes.contains(where: { ($0.0 == "." || $0.0 == ",") && $0.1.width > typical * 0.6 }) { return true }
    // A gap a whole digit wide. (Normal gaps beside a narrow "1" are about 0.7 of a digit.)
    let ordered = boxes.map(\.1).stableSorted { $0.minX }
    for i in ordered.indices.dropFirst() where ordered[i].minX - ordered[i - 1].maxX > typical * 0.9 {
      return true
    }
    return false
  }
}

/// A photographed page: its size and lines in engine order.
struct LetterScan: Equatable, Sendable {
  var width: Int
  var height: Int
  var lines: [LetterLine]

  var text: String { lines.map(\.text).joined(separator: "\n") }
}

extension LetterScan {
  /// From the shared Vision result (TextRecognizer). Each Vision line is its own block; a line's
  /// confidence is its best word's (the undisputed words keep Vision's line confidence), and each
  /// word keeps the confidence WordConfidence gave it from the candidate readings.
  init(page: ReadPage) {
    self.init(
      width: Int(page.imageSize.width.rounded()),
      height: Int(page.imageSize.height.rounded()),
      lines: page.lines.enumerated().compactMap { index, line in
        guard !line.words.isEmpty else { return nil }
        return LetterLine(
          text: line.text, box: line.box, block: index, confidence: line.words.map(\.confidence).max(),
          words: line.words.map { LetterWord(text: $0.text, confidence: $0.confidence) })
      })
  }
}
