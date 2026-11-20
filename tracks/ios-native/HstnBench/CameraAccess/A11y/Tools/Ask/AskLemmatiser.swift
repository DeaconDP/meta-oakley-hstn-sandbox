/*
 * AskLemmatiser - from a word as read or heard to the dictionary's headword
 *
 * "expounding" to expound, "travellers" to traveller, "mice" to mouse, "colour" / "color",
 * "realised" to realize. WordNet's own approach (morphy): irregular forms first, then suffix rules
 * per part of speech, keeping only bases the dictionary has as that part of speech. On top:
 * undoubling ("stopped" to stop), "-ly" adverbs to adjectives, hyphens, possessives, and British /
 * American spellings (-our/-or, -ise/-ize, -yse/-yze, -tre/-ter, -ll-/-l-, ae/oe, -ogue,
 * -ence/-ense, grey/gray, programme). Ported from Android's tools/ask/Lemmatiser.kt. Pure; the
 * dictionary is passed in as two functions so the rules can be tested alone.
 */

import Foundation

struct AskLemmatiser: Sendable {
  struct Lemma: Equatable, Sendable {
    var lemma: String
    /// The part of speech the inflection points to; nil when taken as written.
    var pos: Character?
  }

  private let partsOf: @Sendable (String) -> [Character]
  private let irregular: @Sendable (String) -> [WordNetDictionary.Irregular]

  init(
    partsOf: @escaping @Sendable (String) -> [Character],
    irregular: @escaping @Sendable (String) -> [WordNetDictionary.Irregular] = { _ in [] }
  ) {
    self.partsOf = partsOf
    self.irregular = irregular
  }

  init(dictionary: WordNetDictionary) {
    self.init(partsOf: { dictionary.entry($0)?.parts ?? [] }, irregular: { dictionary.irregular($0) })
  }

  private struct SuffixRule {
    var pos: Character
    var suffix: String
    var ending: String
  }

  private static let rules: [SuffixRule] = [
    .init(pos: "n", suffix: "ses", ending: "s"), .init(pos: "n", suffix: "xes", ending: "x"),
    .init(pos: "n", suffix: "zes", ending: "z"), .init(pos: "n", suffix: "ches", ending: "ch"),
    .init(pos: "n", suffix: "shes", ending: "sh"), .init(pos: "n", suffix: "men", ending: "man"),
    .init(pos: "n", suffix: "ies", ending: "y"), .init(pos: "n", suffix: "s", ending: ""),
    .init(pos: "v", suffix: "ies", ending: "y"), .init(pos: "v", suffix: "es", ending: "e"),
    .init(pos: "v", suffix: "es", ending: ""), .init(pos: "v", suffix: "ed", ending: "e"),
    .init(pos: "v", suffix: "ed", ending: ""), .init(pos: "v", suffix: "ing", ending: "e"),
    .init(pos: "v", suffix: "ing", ending: ""), .init(pos: "v", suffix: "s", ending: ""),
    .init(pos: "v", suffix: "ied", ending: "y"), .init(pos: "a", suffix: "est", ending: ""),
    .init(pos: "a", suffix: "er", ending: ""), .init(pos: "a", suffix: "est", ending: "e"),
    .init(pos: "a", suffix: "er", ending: "e"), .init(pos: "a", suffix: "iest", ending: "y"),
    .init(pos: "a", suffix: "ier", ending: "y"), .init(pos: "r", suffix: "ly", ending: ""),
    .init(pos: "r", suffix: "ily", ending: "y"), .init(pos: "r", suffix: "ally", ending: ""),
  ]

  private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

  /// Every headword `word` could be, best first: as written, irregular, then by rule.
  func lemmas(_ word: String) -> [Lemma] {
    let w = Self.clean(word)
    guard !w.isEmpty else { return [] }
    var out: [Lemma] = []
    var seen = Set<String>()
    func add(_ lemma: String, _ pos: Character?) {
      if !lemma.isEmpty, seen.insert(lemma).inserted { out.append(Lemma(lemma: lemma, pos: pos)) }
    }
    let forms = [w] + Self.hyphenForms(w) + Self.spellings(w)
    for form in forms where !partsOf(form).isEmpty { add(form, nil) }
    for form in forms {
      for item in irregular(form) where !partsOf(item.base).isEmpty { add(item.base, item.pos) }
    }
    for form in forms {
      for rule in Self.rules where form.hasSuffix(rule.suffix) && form.count - rule.suffix.count >= 2 {
        let stem = String(form.dropLast(rule.suffix.count))
        var bases = [stem + rule.ending]
        // stopped to stopp to stop; travelled to travell to travel
        let letters = Array(stem)
        if rule.ending.isEmpty, rule.pos != "n", letters.count >= 3, letters[letters.count - 1] == letters[letters.count - 2],
          !Self.vowels.contains(letters[letters.count - 1])
        {
          bases.append(String(stem.dropLast()))
        }
        // An adverb's base is an adjective; everything else must have the rule's part of speech.
        let want: Character = rule.pos == "r" ? "a" : rule.pos
        for base in bases {
          for candidate in [base] + Self.spellings(base) where partsOf(candidate).contains(want) {
            add(candidate, want)
          }
        }
      }
    }
    return out
  }

  /// The best headword, or nil if the dictionary has nothing for `word`.
  func lemma(_ word: String) -> Lemma? { lemmas(word).first }

  private static let notAllowed = HeardText.Pattern("[^a-z0-9' .-]")
  private static let spaces = HeardText.Pattern("\\s+")

  /// Lower case, possessive and outer punctuation off, spaces collapsed.
  static func clean(_ word: String) -> String {
    var w = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    w = notAllowed.replace(in: w, with: " ")
    w = spaces.replace(in: w, with: " ")
    w = w.trimmingCharacters(in: CharacterSet(charactersIn: " '.-"))
    if w.hasSuffix("s'") {
      w.removeLast()
    } else if w.hasSuffix("'s") {
      w.removeLast(2)
    }
    return w
  }

  private static func hyphenForms(_ w: String) -> [String] {
    w.contains("-") ? [w.replacingOccurrences(of: "-", with: " "), w.replacingOccurrences(of: "-", with: "")] : []
  }

  private static let swaps: [(HeardText.Pattern, String)] = [
    (HeardText.Pattern("our(?=s?$|ed$|ing$|ite|able|er|ful|less)"), "or"),
    (HeardText.Pattern("(?<=[^aeiou])or(?=s?$|ed$|ing$|ite|able|ful|less)"), "our"),
    (HeardText.Pattern("is(?=e$|es$|ed$|ing$|ation|er$|ers$)"), "iz"),
    (HeardText.Pattern("iz(?=e$|es$|ed$|ing$|ation|er$|ers$)"), "is"),
    (HeardText.Pattern("ys(?=e$|es$|ed$|ing$)"), "yz"),
    (HeardText.Pattern("yz(?=e$|es$|ed$|ing$)"), "ys"),
    (HeardText.Pattern("tre(?=s?$)"), "ter"),
    (HeardText.Pattern("(?<=[^aeiou])ter(?=s?$)"), "tre"),
    (HeardText.Pattern("(?<=[aeiou])ll(?=ed$|ing$|er$|ers$|or$|ors$|ery$)"), "l"),
    (HeardText.Pattern("(?<=[aeiou])l(?=ed$|ing$|er$|ers$|or$|ors$|ery$)"), "ll"),
    (HeardText.Pattern("ae"), "e"),
    (HeardText.Pattern("oe(?=[a-z])"), "e"),
    (HeardText.Pattern("ogue(?=s?$)"), "og"),
    (HeardText.Pattern("(?<=[aeiou][a-z])og(?=s?$)"), "ogue"),
    (HeardText.Pattern("ence(?=s?$)"), "ense"),
    (HeardText.Pattern("ense(?=s?$)"), "ence"),
    (HeardText.Pattern("grey"), "gray"),
    (HeardText.Pattern("gray"), "grey"),
    (HeardText.Pattern("amme(?=s?$)"), "am"),
    (HeardText.Pattern("eable$"), "able"),
  ]

  /// Other spellings of `w` (British and American), up to two changes deep. Not `w` itself.
  static func spellings(_ w: String) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    var frontier = [w]
    for _ in 0..<2 {
      var next: [String] = []
      for form in frontier {
        for (pattern, replacement) in swaps where pattern.contains(form) {
          let variant = pattern.replace(in: form, with: replacement)
          if variant != w, seen.insert(variant).inserted {
            out.append(variant)
            next.append(variant)
          }
        }
      }
      frontier = next
    }
    return Array(out.prefix(24))
  }
}
