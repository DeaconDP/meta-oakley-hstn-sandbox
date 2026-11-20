/*
 * SettingsWords - small shared pieces for the settings grammars and spoken lines
 *
 * Normalising an utterance the same way VoiceCommandParser does (lowercase, punctuation gone,
 * apostrophes closed up), peeling polite filler off, reading a number ("1.5", "one point five"),
 * and saying numbers back ("1.2 times", "normal speed").
 */

import Foundation

enum SettingsWords {
  /// "Can you make it faster please" -> "make it faster". Whole words, lowercased.
  static func phrase(_ utterance: String) -> String {
    var tokens = VoiceCommandParser.normalize(utterance)
    let leading: [[String]] = [
      ["can", "you"], ["could", "you"], ["would", "you"], ["please"], ["just"], ["now"], ["um"], ["uh"], ["er"], ["ok"],
      ["okay"], ["so"], ["lets"], ["i", "want", "to"], ["id", "like", "to"],
    ]
    let trailing: [[String]] = [["please"], ["thanks"], ["thank", "you"], ["now"]]
    var changed = true
    while changed {
      changed = false
      for filler in leading where tokens.count > filler.count && Array(tokens.prefix(filler.count)) == filler {
        tokens.removeFirst(filler.count)
        changed = true
      }
      for filler in trailing where tokens.count > filler.count && Array(tokens.suffix(filler.count)) == filler {
        tokens.removeLast(filler.count)
        changed = true
      }
    }
    return tokens.joined(separator: " ")
  }

  /// The words after `prefix`, or nil. `prefix` is a whole-word phrase ("switch to").
  static func rest(of phrase: String, after prefix: String) -> String? {
    guard phrase.hasPrefix(prefix + " ") else { return nil }
    let rest = String(phrase.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : rest
  }

  private static let units: [String: Double] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "half": 0.5, "a": 1,
  ]

  /// A number from normalised words: "1 5" (from "1.5"), "one point five", "two", "one and a half".
  static func number(_ words: String) -> Double? {
    let tokens = words.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }
    if tokens.count == 1 {
      if let value = Double(tokens[0]) { return value }
      return tokens[0] == "a" ? nil : units[tokens[0]]
    }
    // "1 5" is what normalising "1.5" leaves; "one point five" the spoken form.
    if tokens.count == 2, let whole = Double(tokens[0]), let fraction = Double("0." + tokens[1]) { return whole + fraction }
    if tokens.count == 3, tokens[1] == "point", let whole = digit(tokens[0]), let fraction = digit(tokens[2]) {
      return whole + fraction / 10
    }
    if tokens.count == 4, tokens[1] == "and", tokens[2] == "a", tokens[3] == "half", let whole = digit(tokens[0]) {
      return whole + 0.5
    }
    return nil
  }

  private static func digit(_ token: String) -> Double? {
    if let value = Double(token) { return value }
    return token == "a" ? nil : units[token]
  }

  /// 1.2 -> "1.2", 1.0 -> "1", 0.25 -> "0.25".
  static func decimal(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    var text = String(format: "%.2f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    return text
  }

  /// "normal speed", "1.2 times".
  static func rate(_ multiplier: Double) -> String {
    abs(multiplier - 1) < 0.001 ? "normal speed" : "\(decimal(multiplier)) times"
  }

  /// "a, b and c".
  static func list(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
  }

  /// First letter upper-case, for the start of a spoken sentence.
  static func sentence(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  /// Encodes with sorted keys, so equal values give equal bytes (undo and "keep that" compare).
  static func encode<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data("{}".utf8)
  }
}
