/*
 * LabelsRegex - a small NSRegularExpression wrapper for the label and light tools' pure logic
 *
 * The rules were written and tested as Java regexes on Android (tools/labels, tools/light).
 * NSRegularExpression is ICU, close enough to Java that the patterns carry over unchanged
 * (lookbehind, backreferences, \b). Offsets are UTF-16, like Kotlin's, so ranges from one match
 * can be used on the same string with NSString.
 */

import Foundation

struct LabelsRegex: @unchecked Sendable {
  /// Immutable after init; NSRegularExpression is thread-safe for matching.
  let regex: NSRegularExpression
  private let whole: NSRegularExpression

  init(_ pattern: String, ignoreCase: Bool = false) {
    let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
    // Patterns are constants checked by the unit tests; a bad one is a programming error.
    regex = try! NSRegularExpression(pattern: pattern, options: options)
    whole = try! NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: options)
  }

  /// One match: its range in UTF-16 units, and its groups ("" for a group that didn't take part,
  /// as Kotlin's groupValues).
  struct Hit {
    let range: NSRange
    let groups: [String]

    var value: String { groups[0] }
    func group(_ index: Int) -> String { index < groups.count ? groups[index] : "" }
    var start: Int { range.location }
    /// One past the last character.
    var end: Int { range.location + range.length }
  }

  func first(in text: String) -> Hit? {
    let ns = text as NSString
    guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return Self.hit(result, ns)
  }

  func all(in text: String) -> [Hit] {
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Self.hit($0, ns) }
  }

  func contains(_ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
  }

  /// The whole of `text` matches (Kotlin's `matches`).
  func matches(_ text: String) -> Bool {
    whole.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
  }

  /// Every match replaced by `transform(match)`.
  func replace(in text: String, _ transform: (Hit) -> String) -> String {
    let ns = NSMutableString(string: text)
    for hit in all(in: text).reversed() {
      ns.replaceCharacters(in: hit.range, with: transform(hit))
    }
    return ns as String
  }

  private static func hit(_ result: NSTextCheckingResult, _ ns: NSString) -> Hit {
    let groups = (0..<result.numberOfRanges).map { index -> String in
      let range = result.range(at: index)
      return range.location == NSNotFound ? "" : ns.substring(with: range)
    }
    return Hit(range: result.range, groups: groups)
  }
}

/// UTF-16 helpers matching Kotlin's String functions, for code ported from the Android tools.
enum LabelsString {
  static func length(_ text: String) -> Int { (text as NSString).length }

  static func substring(_ text: String, from start: Int, to end: Int? = nil) -> String {
    let ns = text as NSString
    let upper = min(ns.length, end ?? ns.length)
    let lower = min(max(0, start), upper)
    return ns.substring(with: NSRange(location: lower, length: upper - lower))
  }

  /// `text` with `range` replaced by spaces of the same length.
  static func blank(_ text: String, _ range: NSRange) -> String {
    (text as NSString).replacingCharacters(in: range, with: String(repeating: " ", count: range.length))
  }

  /// Kotlin's lastIndexOf(char, startIndex): searching backwards from `from` (inclusive).
  static func lastIndex(of character: Character, in text: String, from: Int) -> Int? {
    let units = Array(text.utf16)
    guard let unit = String(character).utf16.first, !units.isEmpty else { return nil }
    var index = min(from, units.count - 1)
    while index >= 0 {
      if units[index] == unit { return index }
      index -= 1
    }
    return nil
  }

  /// Kotlin's indexOf(char, startIndex): searching forwards from `from` (inclusive).
  static func index(of character: Character, in text: String, from: Int) -> Int? {
    let units = Array(text.utf16)
    guard let unit = String(character).utf16.first else { return nil }
    var index = max(0, from)
    while index < units.count {
      if units[index] == unit { return index }
      index += 1
    }
    return nil
  }

  static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Characters in `set` removed from both ends.
  static func trim(_ text: String, _ set: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: set))
  }

  static func trimEnd(_ text: String, _ set: String) -> String {
    var result = Substring(text)
    while let last = result.last, set.contains(last) { result = result.dropLast() }
    return String(result)
  }
}
