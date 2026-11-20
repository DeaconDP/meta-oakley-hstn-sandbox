/*
 * AskWording - the sentences "Ask about the text" speaks
 *
 * Answers are heard, not read: short, the useful part first, no lists, and always a way on ("say
 * more", "say next"). Quotes from the text are clipped to about 30 words around what was asked.
 * Ported from Android's tools/ask/AskWording.kt, with the iOS-only lines (online answers, the
 * dictionary credit) added. Pure.
 */

import Foundation

enum AskWording {
  static let name = "Ask about the text"

  static let canOnly =
    "I can only define words, tell you who someone is, recap, and find things in the text. I can't answer that one."
  static let canOnlyWithKeyHint =
    "I can only define words, tell you who someone is, recap, and find things in the text. "
    + "To answer other questions, add an OpenAI key in Settings."
  static let askingOnline = "Asking online."
  static let nothingMore = "That's all I have."
  static let noWordYet = "Ask me what a word means first, then say spell it."
  static let nothingToUndo = "Say the word again, or say spell, then the word."
  static let notReady = "The dictionary didn't load, so I can't define words right now."
  static let carryOnHint = "Say carry on to keep reading."
  static let nothingRead = "I haven't read anything yet. Read some text first, then ask me about it."
  static let notInText = "The text doesn't say."
  static let failed = "Sorry, I couldn't answer that just now."
  static let notUnderstood = "Ask me what a word means, who someone is, what happened, or what the text said about something."

  static let start = "Ask me about what was just read. For example: what does a word mean, who is someone, or recap."
  static let help = "Ask about the text. Ask what a word means or who someone is, or say recap. After an answer, say more."
  static let dictionaryCredit =
    "Definitions from WordNet 3.0, Copyright 2006 by Princeton University. All rights reserved. Used under the WordNet licence."
  static let privacyOnDevice = "Questions are answered on this phone. Nothing is sent anywhere."
  static let privacyOnline =
    "Definitions, names, recaps and searches stay on this phone. Other questions are sent to OpenAI with the text you heard, never a picture, only when you ask one."

  private static let posNames: [Character: String] = ["n": "noun", "v": "verb", "a": "adjective", "r": "adverb"]

  static func posName(_ pos: Character) -> String { posNames[pos] ?? "word" }

  private static func article(_ word: String) -> String {
    "aeiou".contains(word.first?.lowercased().first ?? "x") ? "an" : "a"
  }

  private static let maxSenses = 8
  private static let clipWords = 30

  /// "Recondite, adjective: difficult to penetrate." plus a second sense if both are short. The
  /// rest, two at a time, for "more".
  static func definition(word: String, senses: [WordNetDictionary.Sense], from: String? = nil) -> (String, [String]) {
    guard let first = senses.first else { return (notInDictionary(word), []) }
    var text = capitalise(word)
    if let from, from != word { text += ", from \(from)" }
    text += ", \(posName(first.pos)): \(sentence(first.gloss))"
    var used = 1
    if senses.count > 1 {
      let second = senses[1]
      if first.gloss.count + second.gloss.count < 150 {
        let lead =
          second.pos == first.pos ? "Or: " : "As \(article(posName(second.pos))) \(posName(second.pos)): "
        text += " \(lead)\(sentence(second.gloss))"
        used = 2
      }
    }
    let rest = Array(senses.dropFirst(used).prefix(maxSenses - used))
    var chunks: [String] = []
    var pos = senses[used - 1].pos
    var index = 0
    while index < rest.count {
      let pair = rest[index..<min(index + 2, rest.count)]
      let chunk = pair.map { sense -> String in
        let lead =
          sense.pos != pos ? "As \(article(posName(sense.pos))) \(posName(sense.pos)): " : "Another meaning: "
        pos = sense.pos
        return lead + sentence(sense.gloss)
      }.joined(separator: " ")
      chunks.append(chunk)
      index += 2
    }
    if !chunks.isEmpty { text += " Say more for other meanings." }
    return (text, chunks)
  }

  static func didYouMean(_ word: String) -> String { "Did you mean \(word)?" }

  static func notInDictionary(_ word: String) -> String { "I couldn't find \(word) in my dictionary." }

  static func spell(_ word: String) -> String {
    let trimmed = word.trimmingCharacters(in: .whitespaces)
    let letters: [String] = trimmed.compactMap { c in
      if c.isLetter || c.isNumber { return c.uppercased() }
      if c == "-" { return "hyphen" }
      if c == "'" || c == "\u{2019}" { return "apostrophe" }
      if c == " " { return "space" }
      return nil
    }
    return "\(capitalise(trimmed)) is spelt \(letters.joined(separator: ", "))."
  }

  static func notReadAbout(_ name: String) -> String { "I haven't read anything about \(name) yet." }

  /// "Holmes first comes up here: ... Most recently: ..." The rest, most recent first, for "more".
  static func mentions(name rawName: String, found: [AskFound], keys: [String], lastTime: Bool) -> (String, [String]) {
    let name = capitalise(rawName)
    let prefix = lastTime ? "Last time: " : ""
    guard found.count > 1 else {
      return ("\(prefix)\(name) is mentioned once: \(clip(found[0].sentence, keys: keys))", [])
    }
    let first = found[0]
    let latest = Array(found.dropFirst().suffix(2))
    let words = ([first] + latest).reduce(0) { $0 + AskWords.of($1.sentence).count }
    let spoken = words <= 70 ? latest : Array(latest.suffix(1))
    var text = "\(prefix)\(name) first comes up here: \(clip(first.sentence, keys: keys))"
    text += " Most recently: " + spoken.map { clip($0.sentence, keys: keys) }.joined(separator: " ")
    let rest = found.dropFirst().dropLast(spoken.count).reversed().map { "Earlier: " + clip($0.sentence, keys: keys) }
    return (rest.isEmpty ? text : "\(text) Say more for other mentions.", Array(rest))
  }

  static func nothingFound(_ subject: String) -> String { "I didn't find anything about \(subject) in what I've read." }

  /// "About the fire: ... That's 1 of 3. Say next for the next one."
  static func matches(subject: String, found: [AskFound], keys: [String]) -> (String, [String]) {
    let head = "About \(subject): \(clip(found[0].sentence, keys: keys))"
    let rest = found.dropFirst().enumerated().map { "Match \($0.offset + 2) of \(found.count): \(clip($0.element.sentence, keys: keys))" }
    return (rest.isEmpty ? head : "\(head) That's 1 of \(found.count). Say next for the next one.", rest)
  }

  static func recap(_ sentences: [String], lastTime: Bool) -> String {
    (lastTime ? "Last time, we left off here: " : "The last bit was: ") + sentences.joined(separator: " ")
  }

  // MARK: Helpers

  static func capitalise(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  /// A gloss as a spoken sentence: one full stop.
  static func sentence(_ gloss: String) -> String {
    var g = gloss.trimmingCharacters(in: .whitespaces)
    while let last = g.last, last == "." || last == ";" || last == "," { g.removeLast() }
    return g + "."
  }

  private static let quoteTrim = CharacterSet(charactersIn: "\"\u{201C}\u{201D},.?!;:")

  /// `sentence` cut to about 30 words around the first of `keys`, with "..." where cut.
  static func clip(_ sentence: String, keys: [String]) -> String {
    let words = sentence.split(separator: " ").map(String.init)
    guard words.count > clipWords else { return sentence }
    let at = max(
      0,
      words.firstIndex { w in
        keys.contains { AskWords.sameName($0, AskWords.norm(w.trimmingCharacters(in: quoteTrim))) }
      } ?? 0)
    let start = min(max(0, at - clipWords / 3), words.count - clipWords)
    let end = start + clipWords
    return (start > 0 ? "... " : "") + words[start..<end].joined(separator: " ") + (end < words.count ? " ..." : "")
  }

  /// How to say a name asked about that isn't in the text: "mr bennet" to "Mr. Bennet".
  static func spokenName(_ subject: String) -> String {
    subject.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).map { part -> String in
      let w = String(part)
      switch w.lowercased() {
      case "mr", "mrs", "ms", "dr", "st": return capitalise(w.lowercased()) + "."
      case "the", "of", "a", "an": return w.lowercased()
      default: return capitalise(w)
      }
    }.joined(separator: " ")
  }
}
