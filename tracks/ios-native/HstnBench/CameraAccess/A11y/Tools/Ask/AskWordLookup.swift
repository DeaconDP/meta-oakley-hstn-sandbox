/*
 * AskWordLookup - which word the user means, and what the dictionary says about it
 *
 * Speech recognition is bad at exactly the words people ask about: "recondite" comes back as
 * "recon dight" or "reconnect". So a word asked about is first looked for in the text that was
 * read (with inflections: "expound" finds "expounding"); if it isn't there, the closest word in the
 * text that sounds or looks like it is offered ("Did you mean recondite?"); only then is the word
 * looked up as heard. The word in the text decides which part of speech comes first ("expounding":
 * the verb). Ported from Android's tools/ask/WordLookup.kt. Pure.
 */

import Foundation

struct AskWordLookup: Sendable {
  /// What to define. `corrected`: the text's word was offered instead of what was heard.
  struct Choice: Equatable, Sendable {
    var word: String
    var heard: String
    var inText: Bool
    var corrected: Bool
  }

  /// A definition ready to speak: the first answer and the rest for "more".
  struct Definition: Equatable, Sendable {
    var word: String
    var lemma: String?
    var text: String
    var more: [String]
  }

  let dictionary: WordNetDictionary
  let lemmatiser: AskLemmatiser

  init(dictionary: WordNetDictionary) {
    self.dictionary = dictionary
    lemmatiser = AskLemmatiser(dictionary: dictionary)
  }

  /// Distinct words of the text, with hyphenated words also split.
  func vocabulary(_ sentences: [String]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for sentence in sentences {
      for word in AskWords.of(sentence) {
        if seen.insert(word).inserted { out.append(word) }
        if word.contains("-") {
          for part in word.split(separator: "-").map(String.init) where seen.insert(part).inserted { out.append(part) }
        }
      }
    }
    return out
  }

  /// The word to define for `heard`, given the text read. nil only if `heard` is empty.
  /// `allowCorrection` false takes the word as heard ("no, the one I said").
  func choose(_ heard: String, sentences: [String], allowCorrection: Bool = true) -> Choice? {
    let h = AskLemmatiser.clean(heard)
    guard !h.isEmpty else { return nil }
    let vocab = vocabulary(sentences)
    if let form = inText(h, sentences: sentences, vocab: vocab) {
      // "define expound" with "expounding" in the text: define what was asked, if it's a word.
      let word = form != h && lemmatiser.lemma(h) != nil ? h : form
      return Choice(word: word, heard: h, inText: true, corrected: false)
    }
    if allowCorrection, let closest = closest(h, vocab: vocab) {
      return Choice(word: closest, heard: h, inText: true, corrected: true)
    }
    return Choice(word: h, heard: h, inText: false, corrected: false)
  }

  /// The form in the text that `h` names: itself, an inflection of it, or the words run together.
  func inText(_ h: String, sentences: [String], vocab: [String]? = nil) -> String? {
    let vocab = vocab ?? vocabulary(sentences)
    if h.contains(" ") {
      let flat = sentences.map { AskWords.of($0).joined(separator: " ") }.joined(separator: " ")
      if " \(flat) ".contains(" \(h) ") { return h }
      let joined = h.replacingOccurrences(of: " ", with: "")
      return vocab.contains(joined) ? joined : nil
    }
    if vocab.contains(h) { return h }
    let mine = Set(lemmatiser.lemmas(h).map(\.lemma))
    guard !mine.isEmpty else { return nil }
    for word in vocab where word.count >= 3 && word.prefix(2) == h.prefix(2) {
      if lemmatiser.lemmas(word).contains(where: { mine.contains($0.lemma) }) { return word }
    }
    return nil
  }

  /// The word in `vocab` that `h` was most likely misheard from, or nil. A word that's in the
  /// dictionary as heard needs a closer match (the user may really mean it).
  func closest(_ h: String, vocab: [String]) -> String? {
    let heardIsWord = lemmatiser.lemma(h) != nil
    var best: String?
    var bestScore = 0.0
    for word in vocab {
      if word.count < 4 || AskWords.stopwords.contains(word) || word.contains(where: HeardText.isDigit) { continue }
      let letters = AskWords.letterSimilarity(h, word)
      let sound = AskWords.soundSimilarity(h, word)
      let ok = heardIsWord ? sound >= 0.8 && letters >= 0.5 : sound >= 0.75 || letters >= 0.6
      guard ok else { continue }
      // Prefer words the dictionary knows, then the closest, then the longer (rarer) word.
      let known = lemmatiser.lemma(word) != nil ? 1.0 : 0.0
      let score = known + letters + sound + Double(word.count) / 1000
      if score > bestScore {
        bestScore = score
        best = word
      }
    }
    return best
  }

  /// The definition of `word` (as in the text, or heard): headword, part of speech, senses.
  func define(_ word: String) -> Definition {
    var lemmas = lemmatiser.lemmas(word)
    // "expounding" in the text is the verb, though WordNet also has the noun "expounding".
    if word.hasSuffix("ing") || word.hasSuffix("ed") {
      lemmas = lemmas.enumerated().sorted { a, b in
        let x = a.element.pos == "v" ? 0 : 1
        let y = b.element.pos == "v" ? 0 : 1
        return x != y ? x < y : a.offset < b.offset
      }.map(\.element)
    }
    let tieOrder: [Character] = ["a", "v", "n", "r"]
    for lemma in lemmas {
      guard let entry = dictionary.entry(lemma.lemma) else { continue }
      // Most senses first; on a tie adjective, verb, noun, adverb ("ephemeral": the adjective).
      let byCount = entry.parts.sorted { a, b in
        let countA = entry.senseCount(a)
        let countB = entry.senseCount(b)
        if countA != countB { return countA > countB }
        return (tieOrder.firstIndex(of: a) ?? 9) < (tieOrder.firstIndex(of: b) ?? 9)
      }
      let order: [Character]
      if let pos = lemma.pos, entry.parts.contains(pos) {
        order = [pos] + byCount.filter { $0 != pos }
      } else {
        order = byCount
      }
      let (text, more) = AskWording.definition(
        word: word, senses: dictionary.senses(entry, posOrder: order), from: lemma.lemma == word ? nil : lemma.lemma)
      return Definition(word: word, lemma: lemma.lemma, text: text, more: more)
    }
    return Definition(word: word, lemma: nil, text: AskWording.notInDictionary(word), more: [])
  }
}
