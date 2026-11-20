/*
 * WatchTextMatcher - does this frame's text contain what we're watching for, and where?
 *
 * Ported from Android's tools/watch/TextMatcher.kt, rules unchanged. Each OCR line is split into
 * tokens: whole numbers, decimals ("4.2", "10:30"), codes ("42A") and words.
 * - Numbers are exact. "42" matches the token 42 anywhere in a line ("42 Victoria", "No. 42"), and
 *   a sign word stuck to it ("No42", "Platform3"), but never 421, 142, 4.2 or 42A. OCR's
 *   letter-for-digit slips inside a number are undone first ("4O" = 40, "1l" = 11).
 * - Codes ("12B") are exact, ignoring case; "12 B" split by OCR also matches.
 * - Words are loose: case and punctuation ignored, a small edit distance by length (none up to 3
 *   letters, 1 up to 7, 2 beyond), and digits OCR puts in words read as letters ("B00TS" = boots).
 * - Several tokens ("platform 3") must sit side by side on one line, in order, or run together in
 *   one OCR token ("PLATFORM3").
 * The position is the matched characters' share of the line's box, so "42" at the left end of a
 * wide bus-front line is placed left of the line's centre. Near misses ("I see 24, not 42") are for
 * single-number targets: two digits swapped, or (3+ digits) one digit different. Pure.
 */

import CoreGraphics
import Foundation

/// One OCR line: its text and box in pixels, top-left origin.
struct WatchLine: Equatable, Sendable {
  var text: String
  var box: CGRect
}

/// Everything OCR found in one frame.
struct WatchPage: Equatable, Sendable {
  var lines: [WatchLine]
  var imageSize: CGSize
}

/// Where a match was: `x` is its horizontal centre, 0 = left edge, 1 = right edge.
struct WatchSpot: Equatable, Sendable {
  var text: String
  var x: Double
  var heightFraction: Double
}

/// What one frame showed: the target (best sighting), a near miss, or neither.
struct WatchFrameMatch: Equatable, Sendable {
  var hit: WatchSpot?
  var nearMiss: String?

  static let none = WatchFrameMatch(hit: nil, nearMiss: nil)
}

enum WatchOCRKind: Equatable, Sendable { case number, decimal, code, word }

/// One token of recognised text; `start`/`end` are Character offsets in the line.
struct WatchOCRToken: Equatable, Sendable {
  var text: String
  var kind: WatchOCRKind
  var start: Int
  var end: Int
}

enum WatchTextMatcher {
  private static let token = HeardText.Pattern("\\d+(?:[.,:]\\d+)+|[\\p{L}\\p{N}'|]+")
  private static let prefixedNumber = HeardText.Pattern("^([a-z]+)(\\d+)$")

  /// Sign words OCR may run into a number: "No42", "Platform3".
  private static let numberPrefixes: Set<String> = [
    "no", "nr", "num", "number", "bus", "route", "platform", "plat", "gate", "room", "stop", "stand", "bay",
  ]

  static func tokens(_ line: String) -> [WatchOCRToken] {
    token.allMatches(in: line).compactMap { match in
      let raw = match.text.replacingOccurrences(of: "'", with: "")
      guard !raw.isEmpty else { return nil }
      let text = raw.lowercased()
      let start = line.distance(from: line.startIndex, to: match.range.lowerBound)
      let end = line.distance(from: line.startIndex, to: match.range.upperBound)
      let kind: WatchOCRKind
      if let first = match.text.first, HeardText.isDigit(first), text.contains(where: { $0 == "." || $0 == "," || $0 == ":" }) {
        kind = .decimal
      } else if text.allSatisfy(HeardText.isDigit) {
        kind = .number
      } else if text.contains(where: HeardText.isDigit) {
        let asDigits = digitSlips(text)
        if asDigits.allSatisfy(HeardText.isDigit) {
          return WatchOCRToken(text: asDigits, kind: .number, start: start, end: end)
        }
        kind = .code
      } else {
        kind = .word
      }
      return WatchOCRToken(text: text.replacingOccurrences(of: "|", with: "l"), kind: kind, start: start, end: end)
    }
  }

  /// Letters OCR reads in place of digits, inside something with digits: O to 0, I/l/| to 1.
  static func digitSlips(_ text: String) -> String {
    String(text.map { character -> Character in
      switch character {
      case "o": "0"
      case "i", "l", "|": "1"
      default: character
      }
    })
  }

  /// Digits OCR reads in place of letters, inside a word: 0 to o, 1 to l, 5 to s.
  static func letterSlips(_ text: String) -> String {
    String(text.map { character -> Character in
      switch character {
      case "0": "o"
      case "1": "l"
      case "5": "s"
      default: character
      }
    })
  }

  static func allowedEdits(length: Int) -> Int {
    length <= 3 ? 0 : (length <= 7 ? 1 : 2)
  }

  static func wordMatches(target: String, ocr: String) -> Bool {
    let seen = letterSlips(ocr)
    if seen == target { return true }
    let allowed = allowedEdits(length: target.count)
    if allowed == 0 || abs(seen.count - target.count) > allowed { return false }
    return HeardText.levenshtein(target, seen) <= allowed
  }

  private static func stripZeros(_ text: String) -> String {
    let stripped = text.drop(while: { $0 == "0" })
    return stripped.isEmpty ? "0" : String(stripped)
  }

  static func tokenMatches(_ target: WatchTargetToken, _ seen: WatchOCRToken) -> Bool {
    switch target.kind {
    case .number:
      switch seen.kind {
      case .number:
        return stripZeros(seen.text) == stripZeros(target.text)
      case .code:
        guard let groups = prefixedNumber.wholeMatchGroups(seen.text), let prefix = groups[1], let digits = groups[2] else {
          return false
        }
        return numberPrefixes.contains(prefix) && stripZeros(digits) == stripZeros(target.text)
      default:
        return false
      }
    case .code:
      return seen.kind == .code && codeMatches(target: target.text, ocr: seen.text)
    case .word:
      return (seen.kind == .word || seen.kind == .code) && wordMatches(target: target.text, ocr: seen.text)
    }
  }

  /// Position by position, undoing OCR slips: a digit where the target has a digit.
  private static func codeMatches(target: String, ocr: String) -> Bool {
    guard target.count == ocr.count else { return false }
    return zip(target, ocr).allSatisfy { want, got in
      HeardText.isDigit(want) ? digitSlips(String(got)).first == want : letterSlips(String(got)).first == want
    }
  }

  /// The Character range of the target in `line`, or nil.
  static func findInLine(_ target: WatchTarget, _ line: String) -> Range<Int>? {
    let seen = tokens(line)
    guard !seen.isEmpty else { return nil }
    let count = target.tokens.count
    if seen.count >= count {
      for start in 0...(seen.count - count)
      where (0..<count).allSatisfy({ tokenMatches(target.tokens[$0], seen[start + $0]) }) {
        return seen[start].start..<seen[start + count - 1].end
      }
    }
    // A code split by OCR: "12 B".
    if count == 1, target.tokens[0].kind == .code, seen.count >= 2 {
      for index in 0..<(seen.count - 1) {
        let first = seen[index]
        let second = seen[index + 1]
        if first.kind == .number || first.kind == .word, first.text + second.text == target.tokens[0].text {
          return first.start..<second.end
        }
      }
    }
    // Several target tokens run together in one OCR token: "PLATFORM3".
    if count >= 2 {
      let joined = target.tokens.map(\.text).joined()
      if let one = seen.first(where: { joinedMatches(target: joined, ocr: $0.text) }) { return one.start..<one.end }
    }
    // One long word split by OCR: "BO OTS".
    if count == 1, target.tokens[0].kind == .word, target.tokens[0].text.count >= 5, seen.count >= 2 {
      for index in 0..<(seen.count - 1)
      where seen[index].kind == .word && seen[index + 1].kind == .word
        && seen[index].text + seen[index + 1].text == target.tokens[0].text {
        return seen[index].start..<seen[index + 1].end
      }
    }
    return nil
  }

  /// Digits exact, letters loose.
  private static func joinedMatches(target: String, ocr: String) -> Bool {
    guard target.filter(HeardText.isDigit) == ocr.filter(HeardText.isDigit) else { return false }
    let targetLetters = target.filter { !HeardText.isDigit($0) }
    let ocrLetters = ocr.filter { !HeardText.isDigit($0) }
    if targetLetters.isEmpty { return ocrLetters.isEmpty }
    return wordMatches(target: targetLetters, ocr: ocrLetters)
  }

  /// Same length, not equal: two digits swapped, or (3+ digits) one digit different.
  static func isNearMiss(target: String, seen: String) -> Bool {
    guard seen.count == target.count, seen != target else { return false }
    let want = Array(target)
    let got = Array(seen)
    let diff = want.indices.filter { want[$0] != got[$0] }
    if diff.count == 2, want[diff[0]] == got[diff[1]], want[diff[1]] == got[diff[0]] { return true }
    return diff.count == 1 && want.count >= 3
  }

  /// The best sighting in `page` (the tallest, so probably the nearest), or a near miss.
  static func find(_ target: WatchTarget, in page: WatchPage) -> WatchFrameMatch {
    var best: WatchSpot?
    var near: String?
    let width = max(1, page.imageSize.width)
    let height = max(1, page.imageSize.height)
    for line in page.lines {
      if let range = findInLine(target, line.text) {
        let length = Double(max(1, line.text.count))
        let middle = Double(range.lowerBound + range.upperBound) / 2 / length
        let xPixels = Double(line.box.minX) + Double(line.box.width) * middle
        let characters = Array(line.text)
        let matched = String(characters[range.clamped(to: 0..<characters.count)]).trimmingCharacters(in: .whitespaces)
        let spot = WatchSpot(
          text: matched, x: min(1, max(0, xPixels / Double(width))), heightFraction: Double(line.box.height) / Double(height))
        if best == nil || spot.heightFraction > best!.heightFraction { best = spot }
      } else if near == nil, target.isSingleNumber {
        near = tokens(line.text).first { $0.kind == .number && isNearMiss(target: target.tokens[0].text, seen: $0.text) }?.text
      }
    }
    if let best { return WatchFrameMatch(hit: best, nearMiss: nil) }
    return WatchFrameMatch(hit: nil, nearMiss: near)
  }
}
