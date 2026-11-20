/*
 * HeardText - turning what the recogniser heard into text a tool grammar can match
 *
 * Ported from Android's tools/core/Phrases.kt so Watch for text and Ask about the text match the
 * same phrases on both platforms. Two forms:
 * - light: lower case, punctuation out (apostrophes and decimal points kept), spaces collapsed.
 *   Every word is still there, so an argument ("watch for the right exit") keeps its words.
 * - normalize: light, then an address ("reader, ...", "glasses, ...") and filler words ("please",
 *   "um", "can you", ...) dropped. Grammar rules match this whole, so "I'll watch for it later"
 *   nearby doesn't count as a command, but "please watch for 42" does.
 *
 * Also a small NSRegularExpression wrapper: Swift's own Regex has no lookbehind, and the Android
 * grammars use it. Pure, unit-tested through the tool grammars.
 */

import Foundation

enum HeardText {
  /// Words people add around a command that don't change it.
  static let fillers: [String] = [
    "please", "um", "umm", "uh", "er", "erm", "okay", "ok", "alright", "right", "so",
    "can you", "could you", "would you", "will you", "i want you to", "i'd like you to",
    "just", "now", "thanks", "thank you",
  ]

  /// Addresses in front of a command: "reader, ...", "hey glasses, ...". Only dropped when something follows.
  static let address = Pattern("^(hey |ok |okay )?(the )?(reader|book reader|glasses|app|assistant|speakup|speak up) (?=\\S)")

  private static let notAllowed = Pattern("[^a-z0-9.' ]")
  private static let looseDot = Pattern("(?<![0-9])\\.|\\.(?![0-9])")
  private static let spaces = Pattern("\\s+")
  private static let fillerPatterns: [Pattern] = fillers.map {
    Pattern("(^| )\(NSRegularExpression.escapedPattern(for: $0))(?= |$)")
  }

  static func light(_ transcript: String) -> String {
    var text = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    text = notAllowed.replace(in: text, with: " ")
    text = looseDot.replace(in: text, with: " ")
    text = spaces.replace(in: text, with: " ")
    return text.trimmingCharacters(in: .whitespaces)
  }

  static func normalize(_ transcript: String) -> String {
    var text = address.replace(in: light(transcript), with: "").trimmingCharacters(in: .whitespaces)
    for filler in fillerPatterns { text = filler.replace(in: text, with: " ") }
    return spaces.replace(in: text, with: " ").trimmingCharacters(in: .whitespaces)
  }

  private static let politeTail = Pattern("(?: (?:please|thanks|thank you|for me))+$")

  /// What follows `lead` in `light` text, polite words trimmed off the end:
  /// after("watch for", "watch for the right exit please") = "the right exit".
  static func after(_ lead: Pattern, in light: String) -> String? {
    guard let range = lead.firstRange(in: light) else { return nil }
    var rest = String(light[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    rest = politeTail.replace(in: rest, with: "").trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : rest
  }

  /// 0-9 only (Character.isNumber also takes other scripts' digits and fractions).
  static func isDigit(_ character: Character) -> Bool {
    ("0"..."9").contains(character)
  }

  /// Edit distance between two strings, by Character.
  static func levenshtein(_ a: String, _ b: String) -> Int {
    if a == b { return 0 }
    let x = Array(a)
    let y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var previous = Array(0...y.count)
    var current = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
      current[0] = i
      for j in 1...y.count {
        let cost = x[i - 1] == y[j - 1] ? 0 : 1
        current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[y.count]
  }

  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// A compiled NSRegularExpression with the few operations the grammars need.
  struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
      // The patterns are constants in this module; a bad one is a programming error.
      // swiftlint:disable:next force_try
      regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private func whole(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    /// The whole of `text` matches.
    func matches(_ text: String) -> Bool {
      guard let match = regex.firstMatch(in: text, range: whole(text)) else { return false }
      return match.range == whole(text)
    }

    func contains(_ text: String) -> Bool {
      regex.firstMatch(in: text, range: whole(text)) != nil
    }

    /// Capture groups of a whole-text match (index 0 is the whole match); nil groups are nil.
    func wholeMatchGroups(_ text: String) -> [String?]? {
      guard let match = regex.firstMatch(in: text, range: whole(text)), match.range == whole(text) else { return nil }
      return (0..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
      }
    }

    /// Groups of the first match anywhere.
    func firstGroups(_ text: String) -> [String?]? {
      guard let match = regex.firstMatch(in: text, range: whole(text)) else { return nil }
      return (0..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
      }
    }

    func firstRange(in text: String) -> Range<String.Index>? {
      guard let match = regex.firstMatch(in: text, range: whole(text)) else { return nil }
      return Range(match.range, in: text)
    }

    /// Every match: its text and its range.
    func allMatches(in text: String) -> [(text: String, range: Range<String.Index>)] {
      regex.matches(in: text, range: whole(text)).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        return (String(text[range]), range)
      }
    }

    func replace(in text: String, with template: String) -> String {
      regex.stringByReplacingMatches(in: text, range: whole(text), withTemplate: template)
    }
  }
}
