/*
 * WatchTarget - what the user asked to watch for, made ready for matching
 *
 * Ported from Android's tools/watch/WatchTarget.kt. The user says it ("watch for 42", "look out
 * for platform three", "the 73 bus") and the recogniser writes it down its own way, so this turns
 * it into a short list of tokens: whole numbers ("42"), codes that mix digits and letters ("12B")
 * and words ("platform", "boots"). Number words become digits when the whole target is a number
 * ("forty two", "four two", "one oh one") or when they follow a sign word such as platform, gate or
 * room ("platform three"), but not inside ordinary words ("one way" stays words). Words a bus front
 * doesn't show ("bus", "number", "route", "the") are dropped when there's a number. "12 b" becomes
 * the code "12B". `display` is what is said back. Pure, unit-tested.
 */

import Foundation

enum WatchTokenKind: Equatable, Sendable {
  /// Digits only: matched exactly ("42" never matches "421").
  case number
  /// Digits and letters ("12B", "A4"): exact, ignoring case.
  case code
  /// Letters only: matched loosely (OCR noise, case, a missing letter).
  case word
}

struct WatchTargetToken: Equatable, Sendable {
  var text: String
  var kind: WatchTokenKind
}

struct WatchTarget: Equatable, Sendable {
  var tokens: [WatchTargetToken]

  /// What is said back: "42", "platform 3", "12B".
  var display: String {
    tokens.map { $0.kind == .code ? $0.text.uppercased() : $0.text }.joined(separator: " ")
  }

  /// A single whole number ("42"): the kind that gets "I see 24, not 42".
  var isSingleNumber: Bool { tokens.count == 1 && tokens[0].kind == .number }

  /// Words that introduce a number on a sign: number words after them become digits.
  private static let cues: Set<String> = [
    "platform", "gate", "room", "stop", "stand", "bay", "terminal", "floor", "level", "exit", "door", "track", "pier",
    "zone", "aisle", "bus", "route", "number", "no", "flat", "unit", "block", "lift", "carriage", "coach", "seat", "row",
  ]
  private static let numberNoise: Set<String> = ["bus", "number", "no", "route", "the", "a", "an"]
  private static let leading: Set<String> = ["the", "a", "an", "some", "sign", "signs"]
  private static let notAllowed = HeardText.Pattern("[^a-z0-9' ]")

  /// `raw` is what the user said after "watch for". nil if nothing usable is left.
  static func parse(_ raw: String) -> WatchTarget? {
    let cleaned = notAllowed.replace(in: raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), with: " ")
    var words = cleaned.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
      .filter { !$0.isEmpty }
    while let first = words.first, leading.contains(first) { words.removeFirst() }
    while let last = words.last, last == "please" || last == "sign" { words.removeLast() }
    guard !words.isEmpty else { return nil }

    words = numberWordsToDigits(words)
    if words.contains(where: isAllDigits) {
      let kept = words.filter { !numberNoise.contains($0) }
      if !kept.isEmpty { words = kept }
    }
    words = joinNumberAndLetter(words)

    let tokens = words.map { $0.replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
      .map { WatchTargetToken(text: $0, kind: kind(of: $0)) }
    return tokens.isEmpty ? nil : WatchTarget(tokens: tokens)
  }

  static func kind(of token: String) -> WatchTokenKind {
    if isAllDigits(token) { return .number }
    if token.contains(where: HeardText.isDigit) { return .code }
    return .word
  }

  static func isAllDigits(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy(HeardText.isDigit)
  }

  private static func numberWordsToDigits(_ words: [String]) -> [String] {
    if let whole = WatchNumberWords.parse(words) { return [whole] }
    var out: [String] = []
    var index = 0
    while index < words.count {
      let afterCue = index > 0 && cues.contains(words[index - 1])
      if afterCue, WatchNumberWords.isNumberWord(words[index]) {
        var runEnd = index
        while runEnd < words.count, WatchNumberWords.isNumberWord(words[runEnd]) { runEnd += 1 }
        var end = runEnd
        var value: String?
        while end > index, value == nil {
          value = WatchNumberWords.parse(Array(words[index..<end]))
          if value == nil { end -= 1 }
        }
        if let value {
          out.append(value)
          index = end
          continue
        }
      }
      out.append(words[index])
      index += 1
    }
    return out
  }

  private static func joinNumberAndLetter(_ words: [String]) -> [String] {
    var out: [String] = []
    for word in words {
      if let last = out.last, isAllDigits(last), word.count == 1, word.first?.isLetter == true {
        out[out.count - 1] = last + word
      } else {
        out.append(word)
      }
    }
    return out
  }
}

/// Spoken numbers to digits: "forty two" = 42, "four two" = 42, "one oh one" = 101.
enum WatchNumberWords {
  private static let digits: [String: Int] = [
    "zero": 0, "oh": 0, "o": 0, "nought": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9,
  ]
  private static let teens: [String: Int] = [
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19,
  ]
  private static let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
    "ninety": 90,
  ]

  static func isNumberWord(_ word: String) -> Bool {
    digits[word] != nil || teens[word] != nil || tens[word] != nil || word == "hundred" || word == "and"
      || WatchTarget.isAllDigits(word)
  }

  /// The digits for the whole of `words`, or nil if they aren't exactly one number.
  static func parse(_ words: [String]) -> String? {
    guard !words.isEmpty else { return nil }
    if words.count == 1, WatchTarget.isAllDigits(words[0]) { return words[0] }
    // Digit by digit: "four two", "one oh one".
    if words.count >= 2, words.allSatisfy({ digits[$0] != nil }) {
      return words.map { String(digits[$0]!) }.joined()
    }
    if words.contains(where: { $0 == "o" || $0 == "oh" }) { return nil }
    var index = 0
    var total = 0
    var any = false
    func peek() -> String? { index < words.count ? words[index] : nil }
    if let first = peek(), let unit = digits[first], words.count > 1, words[1] == "hundred" {
      total += unit * 100
      index += 2
      any = true
      if peek() == "and" { index += 1 }
    } else if peek() == "hundred" {
      total += 100
      index += 1
      any = true
      if peek() == "and" { index += 1 }
    }
    if let word = peek() {
      if let teen = teens[word] {
        total += teen
        index += 1
        any = true
      } else if let ten = tens[word] {
        total += ten
        index += 1
        any = true
        if let unitWord = peek(), let unit = digits[unitWord], unit > 0 {
          total += unit
          index += 1
        }
      } else if let unit = digits[word] {
        total += unit
        index += 1
        any = true
      }
    }
    return any && index == words.count ? String(total) : nil
  }
}
