/*
 * AddressWord - the word that says "this is for the app", which used to be the fixed "reader"
 * (notes/customisation-ios-words.md, C3 "Wake and address word")
 *
 * VoiceCommandParser strips it from the front of a transcript ("reader, stop"), and the spoken
 * prompts say it ("Say reader, help"). Both run off the main actor, so the current word lives here
 * behind a lock; WordsArea owns the stored value and keeps this copy in step.
 *
 * One or two words. The default also accepts "readers", a common mishearing. A chosen word accepts
 * its plural too ("robins"), for the same reason.
 */

import Foundation
import os

enum AddressWord {
  static let defaultWord = "reader"

  private static let state = OSAllocatedUnfairLock(initialState: defaultWord)

  /// The word as the user says it: "reader", "robin", "hey sam".
  static var current: String {
    get { state.withLock { $0 } }
    set {
      let cleaned = normalized(newValue)
      state.withLock { $0 = cleaned.isEmpty ? defaultWord : cleaned }
    }
  }

  static var isDefault: Bool { current == defaultWord }

  /// Lower case, punctuation out, one space between words: what the parser compares.
  static func normalized(_ word: String) -> String {
    VoiceCommandParser.normalize(word).joined(separator: " ")
  }

  /// How many of the first `tokens` are the address word, or nil if they aren't it.
  static func length(atStartOf tokens: ArraySlice<String>) -> Int? {
    let word = current.split(separator: " ").map(String.init)
    guard !word.isEmpty, tokens.count >= word.count else { return nil }
    let head = Array(tokens.prefix(word.count))
    if head == word { return word.count }
    // The plural: "readers", "robins".
    var plural = word
    plural[plural.count - 1] += "s"
    return head == plural ? word.count : nil
  }

  /// `words` said to the app: "reader open mail reader".
  static func prefixed(_ words: String) -> String { "\(current) \(words)" }
}

/// The words around a command that don't change it, as VoiceCommandParser strips them.
enum WordsText {
  private static let leading: [[String]] = [
    ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["please"], ["just"], ["now"], ["um"], ["uh"],
    ["er"], ["ok"], ["okay"], ["so"],
  ]
  private static let trailing: [[String]] = [["thank", "you"], ["for", "me"], ["please"], ["now"], ["thanks"]]

  /// Lower-case words with punctuation gone, any address word and polite filler off the ends.
  /// `keepAddressWord` is for a new word's name, which is checked against the address word.
  static func tokens(_ text: String, keepAddressWord: Bool = false) -> [String] {
    var tokens = VoiceCommandParser.normalize(text)
    if !keepAddressWord, let used = AddressWord.length(atStartOf: tokens[...]), tokens.count > used {
      tokens.removeFirst(used)
    }
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
    return tokens
  }

  static func phrase(_ text: String) -> String { tokens(text).joined(separator: " ") }

  /// A word or macro name as stored: like phrase, but a leading address word stays, so the
  /// conflict check can refuse it.
  static func name(_ text: String) -> String { tokens(text, keepAddressWord: true).joined(separator: " ") }

  /// Settings JSON with sorted keys, so equal settings give equal snapshots.
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
  }

  /// "a, b, or c" / "a and b".
  static func list(_ items: [String], conjunction: String = "and") -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    case 2: return "\(items[0]) \(conjunction) \(items[1])"
    default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items.last!
    }
  }

  static func count(_ number: Int) -> String {
    let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    return number < words.count ? words[number] : String(number)
  }

  static func capitalisedFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }
}
