/*
 * ReadSpeech - turns a sentence of recognized words into what is spoken, chunk by chunk
 *
 * Rules (ROADMAP "Ground rules", step 5):
 * - Word for word. Nothing is summarised, reordered or "fixed".
 * - Unsure words are flagged, not dropped: the "uncertain" earcon plays just before the word
 *   (with earcons off, or at detailed verbosity, it is also said: "unclear word").
 * - Never guess a dose or an amount of money. A number next to a currency sign/word or a dose
 *   unit (mg, ml, tablets, units...) is only read when the recognizer was sure of it AND of its
 *   unit. Otherwise the number is replaced by "a dose I can't read reliably" or "an amount I
 *   can't read reliably", followed by a pointer to check it elsewhere. Reading a dose or price
 *   that was read clearly is still only reading print, not advice: this is not a medical or
 *   money-reading device (README disclaimer).
 * - Chunks are split at clause punctuation, so the first words of a page start speaking without
 *   waiting for a long sentence to be synthesized, and next/previous still work per sentence.
 *
 * Pure: verbosity and the earcon setting are parameters, so all of it is unit-tested.
 */

import Foundation

/// What a withheld number was.
enum SensitiveKind: String, Sendable {
  case dose
  case money
}

/// One utterance. `flagged` plays the "uncertain" earcon before it.
struct SpokenChunk: Equatable, Sendable {
  var text: String
  var flagged: Bool
}

struct RenderedSentence: Equatable, Sendable {
  /// For the large-print transcript: the words as read, unsure ones marked with "(?)", withheld
  /// numbers as "[dose unreadable]" / "[amount unreadable]".
  var display: String
  var chunks: [SpokenChunk]
  var uncertainWords: Int
  var withheld: SensitiveKind?
}

enum ReadSpeech {
  /// Words below this are flagged as unsure.
  static let uncertainBelow: Float = 0.5
  /// Dose and money numbers (and their units) need at least this to be read out.
  static let sensitiveNumberBelow: Float = 0.8
  /// A clause boundary is used only if both sides have at least this many words.
  static let minClauseWords = 3

  static let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₹", "¢"]
  static let currencyWords: Set<String> = [
    "usd", "eur", "gbp", "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "pence", "yen",
    "rupee", "rupees",
  ]
  static let doseUnits: Set<String> = [
    "mg", "mcg", "µg", "μg", "ug", "ml", "cc", "iu", "unit", "units", "tablet", "tablets", "tab", "tabs", "capsule",
    "capsules", "cap", "caps", "drop", "drops", "puff", "puffs", "spray", "sprays", "tsp", "tbsp", "teaspoon",
    "teaspoons", "tablespoon", "tablespoons", "mmol", "pill", "pills", "dose", "doses",
  ]
  static let numberWords: Set<String> = [
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "half",
  ]

  static func render(_ words: [ReadWord], verbosity: Verbosity, earconsEnabled: Bool) -> RenderedSentence {
    var chunks: [SpokenChunk] = []
    var current: [String] = []
    var currentFlagged = false
    var display: [String] = []
    var uncertain = 0
    var withheld: SensitiveKind?
    var inUncertainRun = false

    func flush() {
      if !current.isEmpty { chunks.append(SpokenChunk(text: current.joined(separator: " "), flagged: currentFlagged)) }
      current = []
      currentFlagged = false
    }

    var index = 0
    while index < words.count {
      if let span = sensitiveSpan(at: index, in: words) {
        let sure = words[span.lowerBound..<span.upperBound].allSatisfy { $0.confidence >= sensitiveNumberBelow }
        if !sure {
          flush()
          chunks.append(SpokenChunk(text: SpokenMessage.readWithheld(span.kind), flagged: true))
          display.append(span.kind == .dose ? "[dose unreadable]" : "[amount unreadable]")
          withheld = withheld ?? span.kind
          inUncertainRun = false
          index = span.upperBound
          continue
        }
      }

      let word = words[index]
      if word.confidence < uncertainBelow {
        uncertain += 1
        display.append(word.text + "(?)")
        if !inUncertainRun {
          flush()
          currentFlagged = true
          if let prefix = uncertainPrefix(verbosity: verbosity, earconsEnabled: earconsEnabled) { current.append(prefix) }
        }
        inUncertainRun = true
      } else {
        display.append(word.text)
        inUncertainRun = false
      }
      current.append(word.text)
      index += 1
    }
    flush()

    var split = chunks.flatMap { chunk in
      clauses(chunk.text).enumerated().map { SpokenChunk(text: $1, flagged: chunk.flagged && $0 == 0) }
    }
    if let withheld {
      split.append(SpokenChunk(text: SpokenMessage.readCheckWithheld(withheld), flagged: false))
    }
    return RenderedSentence(display: display.joined(separator: " "), chunks: split, uncertainWords: uncertain, withheld: withheld)
  }

  /// What is said before an unsure word, besides the earcon. Nothing when the earcon says it.
  static func uncertainPrefix(verbosity: Verbosity, earconsEnabled: Bool) -> String? {
    if !earconsEnabled { return verbosity == .short ? "unclear:" : "unclear word:" }
    return verbosity == .detailed ? "unclear word:" : nil
  }

  // MARK: Numbers that must not be guessed

  struct SensitiveSpan {
    var lowerBound: Int
    var upperBound: Int
    var kind: SensitiveKind
  }

  /// If an amount starts at `index`, the words that make it up: a standalone currency sign
  /// ("$" "12.99"), or a number with a currency or dose unit attached ("$12.99", "500mg") or
  /// right after it ("12.99 dollars", "2 tablets").
  static func sensitiveSpan(at index: Int, in words: [ReadWord]) -> SensitiveSpan? {
    func core(_ offset: Int) -> String? {
      index + offset < words.count ? stripped(words[index + offset].text).lowercased() : nil
    }
    guard let first = core(0) else { return nil }
    if first.count == 1, let symbol = first.first, currencySymbols.contains(symbol), let number = core(1), isNumber(number) {
      let trailingWord = core(2).map(currencyWords.contains) == true ? 1 : 0
      return SensitiveSpan(lowerBound: index, upperBound: index + 2 + trailingWord, kind: .money)
    }
    guard isNumber(first) else { return nil }
    let next = core(1)
    let suffix = attachedSuffix(first)
    if first.contains(where: currencySymbols.contains) || suffix.map(currencyWords.contains) == true {
      let trailingWord = next.map(currencyWords.contains) == true ? 1 : 0
      return SensitiveSpan(lowerBound: index, upperBound: index + 1 + trailingWord, kind: .money)
    }
    if let next, currencyWords.contains(next) {
      return SensitiveSpan(lowerBound: index, upperBound: index + 2, kind: .money)
    }
    if let suffix, isDoseUnit(suffix) {
      return SensitiveSpan(lowerBound: index, upperBound: index + 1, kind: .dose)
    }
    if let next, isDoseUnit(next) {
      return SensitiveSpan(lowerBound: index, upperBound: index + 2, kind: .dose)
    }
    return nil
  }

  /// The letters straight after a leading number: "mg" in "500mg", "mg/5ml" in "2.5mg/5ml".
  static func attachedSuffix(_ core: String) -> String? {
    guard let firstLetter = core.firstIndex(where: { $0.isLetter || $0 == "µ" || $0 == "μ" }),
      core[core.startIndex..<firstLetter].contains(where: \.isNumber)
    else { return nil }
    return String(core[firstLetter...])
  }

  static func isNumber(_ word: String) -> Bool {
    word.contains(where: \.isNumber) || numberWords.contains(stripped(word).lowercased())
  }

  /// "mg", "tablets", and compound units like "mg/5ml".
  static func isDoseUnit(_ word: String) -> Bool {
    if doseUnits.contains(word) { return true }
    guard let slash = word.firstIndex(of: "/") else { return false }
    return doseUnits.contains(String(word[..<slash]))
  }

  private static func stripped(_ word: String) -> String {
    word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’"))
  }

  // MARK: Clauses

  /// Splits at ",", ";", ":" and dashes when both sides keep at least `minClauseWords` words.
  static func clauses(_ text: String) -> [String] {
    let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var clauses: [String] = []
    var current: [String] = []
    for (index, word) in words.enumerated() {
      current.append(word)
      let remaining = words.count - index - 1
      let boundary = word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") || word == "—" || word == "–"
      if boundary, current.count >= minClauseWords, remaining >= minClauseWords {
        clauses.append(current.joined(separator: " "))
        current = []
      }
    }
    if !current.isEmpty { clauses.append(current.joined(separator: " ")) }
    return clauses
  }
}
