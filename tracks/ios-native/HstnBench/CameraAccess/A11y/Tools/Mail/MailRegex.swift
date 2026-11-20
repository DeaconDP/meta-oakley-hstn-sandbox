/*
 * MailRegex - a small wrapper over NSRegularExpression for the mail reader's fixed patterns
 *
 * The Android rules use Java regexes with lookbehind, which Swift's own Regex doesn't support, so
 * the port uses ICU (NSRegularExpression), which reads the same patterns. Every range here is a
 * UTF-16 NSRange, like Kotlin's String indices, so offsets carry over from the Android code as-is.
 */

import Foundation

/// Patterns are fixed at compile time and NSRegularExpression is immutable, so sharing is safe.
struct MailRegex: @unchecked Sendable {
  let regex: NSRegularExpression
  /// The same pattern anchored at both ends, for Kotlin's matches / matchEntire.
  private let whole: NSRegularExpression

  init(_ pattern: String, ignoreCase: Bool = false) {
    let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
    // A bad pattern is a programming error; the tests compile every one.
    regex = try! NSRegularExpression(pattern: pattern, options: options)
    whole = try! NSRegularExpression(pattern: "^(?:\(pattern))$", options: options)
  }

  func matches(in text: String) -> [NSTextCheckingResult] {
    regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  func firstMatch(in text: String) -> NSTextCheckingResult? {
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  func contains(_ text: String) -> Bool { firstMatch(in: text) != nil }

  /// The match only if it covers the whole of `text` (Kotlin's matchEntire / matches).
  func wholeMatch(_ text: String) -> NSTextCheckingResult? {
    whole.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  func matchesWhole(_ text: String) -> Bool { wholeMatch(text) != nil }

  /// Each match replaced by `transform(match)`.
  func replace(in text: String, _ transform: (NSTextCheckingResult) -> String) -> String {
    let ns = text as NSString
    var out = ""
    var cursor = 0
    for match in matches(in: text) {
      out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      out += transform(match)
      cursor = match.range.location + match.range.length
    }
    out += ns.substring(from: cursor)
    return out
  }

  /// Replaced with a template ("$1 reference").
  func replace(in text: String, template: String) -> String {
    regex.stringByReplacingMatches(
      in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
  }
}

extension NSTextCheckingResult {
  /// Capture group `index` of `text`, or nil when the group didn't take part.
  func group(_ index: Int, in text: String) -> String? {
    let range = self.range(at: index)
    guard range.location != NSNotFound else { return nil }
    return (text as NSString).substring(with: range)
  }

  /// The whole match.
  func value(in text: String) -> String { (text as NSString).substring(with: range) }
}

/// UTF-16 helpers, so index arithmetic matches the Kotlin original.
extension String {
  var utf16Count: Int { (self as NSString).length }

  func utf16Substring(_ start: Int, _ end: Int) -> String {
    let ns = self as NSString
    let s = max(0, min(start, ns.length))
    let e = max(s, min(end, ns.length))
    return ns.substring(with: NSRange(location: s, length: e - s))
  }

  /// The UTF-16 offset of `needle` at or after `from`, or nil.
  func utf16Index(of needle: String, from: Int) -> Int? {
    let ns = self as NSString
    guard from <= ns.length else { return nil }
    let found = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
    return found.location == NSNotFound ? nil : found.location
  }

  func utf16Char(_ index: Int) -> Character {
    let unit = (self as NSString).character(at: index)
    return Character(UnicodeScalar(unit) ?? " ")
  }

  /// Kotlin trimEnd / trim of particular characters.
  func trimmingTrailing(_ characters: Set<Character>) -> String {
    var s = Substring(self)
    while let last = s.last, characters.contains(last) { s = s.dropLast() }
    return String(s)
  }

  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

  var trimmedEnd: String {
    var s = Substring(self)
    while let last = s.last, last.isWhitespace { s = s.dropLast() }
    return String(s)
  }

  /// First character upper case (Kotlin replaceFirstChar { it.uppercase() }).
  var capitalisedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}

extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}

extension Array {
  /// A stable sort (Kotlin's sortedBy is stable; Swift's sort isn't promised to be).
  func stableSorted<Key: Comparable>(by key: (Element) -> Key) -> [Element] {
    enumerated().sorted { a, b in
      let ka = key(a.element)
      let kb = key(b.element)
      return ka != kb ? ka < kb : a.offset < b.offset
    }.map(\.element)
  }
}
