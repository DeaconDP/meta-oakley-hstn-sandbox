/*
 * AskTextTools - finding things in the text that was read: sentences, mentions, matches, a recap
 *
 * Ported from Android's tools/ask/TextTools.kt, rules unchanged. Everything Ask does without the
 * dictionary works on the sentences already heard:
 *
 *   AskSentences  split text into sentences (not after "Mr." or "St."; paragraphs always break).
 *   AskReadText   the sentences heard so far from a RecentText snapshot, and a short tail to keep
 *                 for "what happened last time".
 *   AskWords      word lists, a sound-alike key and similarity scores, for loose matching: speech
 *                 recognition hears "Mr. Bennett" for "Mr. Bennet" and "recon dight" for "recondite".
 *   AskMentions   "who is Watson": the sentences that mention a name.
 *   AskSearch     "what did it say about the fire": sentences with the words asked about.
 *   AskRecap      the last few sentences, about 60 words.
 * Pure, unit-tested on the Conan Doyle and Wells fixture pages.
 */

import Foundation

enum AskSentences {
  private static let abbreviations: Set<String> = [
    "mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "rev", "capt", "col", "gen", "lt", "sgt", "mt", "no", "vol", "ch",
    "fig", "e.g", "i.e", "etc", "vs", "messrs", "mme", "mlle", "esq",
  ]
  private static let paragraphBreak = HeardText.Pattern("\\n\\s*\\n")
  private static let spaces = HeardText.Pattern("\\s+")
  private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
  private static let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "("]

  /// Sentences in `text`, trimmed, whitespace collapsed. A blank line always ends a sentence.
  static func split(_ text: String) -> [String] {
    var out: [String] = []
    let paragraphs = paragraphBreak.replace(in: text, with: "\u{0}").split(separator: "\u{0}", omittingEmptySubsequences: true)
    for paragraph in paragraphs {
      let p = Array(spaces.replace(in: String(paragraph), with: " ").trimmingCharacters(in: .whitespaces))
      guard !p.isEmpty else { continue }
      var start = 0
      var i = 0
      while i < p.count {
        let c = p[i]
        if c == "." || c == "!" || c == "?" {
          var end = i + 1
          while end < p.count, closers.contains(p[end]) { end += 1 }
          let atEnd = end >= p.count
          let nextIsStart =
            !atEnd && p[end] == " " && end + 1 < p.count
            && (p[end + 1].isUppercase || openers.contains(p[end + 1]) || HeardText.isDigit(p[end + 1]))
          if atEnd || nextIsStart {
            let before = String(p[start..<i])
            let lastWord = (before.split(separator: " ").last.map(String.init) ?? before).lowercased()
              .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}("))
            let isAbbreviation =
              c == "." && (abbreviations.contains(lastWord) || (lastWord.count == 1 && lastWord.first?.isLetter == true))
            if !isAbbreviation || atEnd {
              out.append(String(p[start..<end]).trimmingCharacters(in: .whitespaces))
              start = end
            }
          }
          i = end
          continue
        }
        i += 1
      }
      if start < p.count {
        let rest = String(p[start...]).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
      }
    }
    return out
  }
}

enum AskReadText {
  /// The sentences `snapshot`'s tool has read out, oldest first: every passage, the last one only
  /// up to and including the sentence being read now, if it's found.
  static func sentences(_ snapshot: RecentText.Snapshot?) -> [String] {
    guard let snapshot else { return [] }
    let passages = snapshot.passages
    guard let lastPassage = passages.last else { return snapshot.current.map(AskSentences.split) ?? [] }
    let earlier = passages.dropLast().flatMap(AskSentences.split)
    let last = AskSentences.split(lastPassage)
    guard let current = snapshot.current, let at = locate(last, current) else { return earlier + last }
    return earlier + last.prefix(at + 1)
  }

  /// Index of the sentence in `sentences` that best matches `sentence` (loosely), or nil.
  static func locate(_ sentences: [String], _ sentence: String) -> Int? {
    let want = Set(AskWords.of(sentence))
    guard !want.isEmpty else { return nil }
    var best = -1
    var bestScore = 0.0
    for (index, candidate) in sentences.enumerated() {
      let have = Set(AskWords.of(candidate))
      // The chunk being read can be part of a long sentence, or several short ones.
      let score = Double(want.intersection(have).count) / Double(min(want.count, max(1, have.count)))
      if score > bestScore + 1e-9 {
        bestScore = score
        best = index
      }
    }
    return bestScore >= 0.6 ? best : nil
  }

  /// The last heard sentences, at most `maxCharacters`, whole sentences.
  static func tail(_ snapshot: RecentText.Snapshot?, maxCharacters: Int = 3_000) -> String? {
    let all = sentences(snapshot)
    guard !all.isEmpty else { return nil }
    var kept: [String] = []
    var size = 0
    for sentence in all.reversed() {
      if !kept.isEmpty, size + sentence.count + 1 > maxCharacters { break }
      kept.insert(sentence, at: 0)
      size += sentence.count + 1
    }
    return kept.joined(separator: " ")
  }
}

enum AskWords {
  private static let word = HeardText.Pattern("[A-Za-z0-9]+(?:['\u{2019}-][A-Za-z0-9]+)*")

  static let stopwords: Set<String> = [
    "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as", "is", "was", "are",
    "were", "be", "been", "it", "its", "this", "that", "these", "those", "he", "she", "they", "him", "her", "them", "his",
    "their", "i", "me", "my", "we", "us", "our", "you", "your", "what", "which", "who", "whom", "about", "had", "has", "have",
    "do", "did", "does", "not", "no", "so", "if", "then", "there", "here", "said", "say", "says", "anything", "something",
    "bit", "part", "thing", "any", "all", "some", "very", "upon", "into", "would", "could", "should", "will", "shall", "one",
    "two", "up", "out", "over",
  ]

  /// Titles dropped from a name asked about ("Mr. Bennet" to bennet).
  static let titles: Set<String> = [
    "mr", "mister", "mrs", "missus", "ms", "miss", "dr", "doctor", "sir", "lady", "lord", "madam", "madame", "professor",
    "prof", "captain", "colonel", "inspector", "the", "a", "an", "old", "young", "master", "uncle", "aunt", "st", "saint",
  ]

  /// Lower-case words of `text`, possessive 's dropped, apostrophes straightened.
  static func of(_ text: String) -> [String] {
    word.allMatches(in: text).map { norm($0.text) }.filter { !$0.isEmpty }
  }

  /// One word, lower case, possessive dropped.
  static func norm(_ word: String) -> String {
    var w = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    if w.hasSuffix("'s") { w.removeLast(2) }
    if w.hasSuffix("'") { w.removeLast() }
    return w.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
  }

  /// The words of `text` as written (for saying a name the way the text has it).
  static func asWritten(_ text: String) -> [String] {
    word.allMatches(in: text).map { match in
      var w = match.text
      if w.hasSuffix("'s") || w.hasSuffix("\u{2019}s") { w.removeLast(2) }
      return w
    }
  }

  private static let soundRules: [(HeardText.Pattern, String)] = [
    (HeardText.Pattern("^kn|^gn|^pn"), "n"), (HeardText.Pattern("^wr"), "r"), (HeardText.Pattern("^ps"), "s"),
    (HeardText.Pattern("^x"), "s"), (HeardText.Pattern("ght"), "t"), (HeardText.Pattern("tch"), "ch"),
    (HeardText.Pattern("sch"), "sk"), (HeardText.Pattern("ph"), "f"), (HeardText.Pattern("ck"), "k"),
    (HeardText.Pattern("qu"), "kw"), (HeardText.Pattern("dg"), "j"), (HeardText.Pattern("c(?=[eiy])"), "s"),
    (HeardText.Pattern("c"), "k"), (HeardText.Pattern("q"), "k"), (HeardText.Pattern("x"), "ks"),
    (HeardText.Pattern("z"), "s"), (HeardText.Pattern("mb$"), "m"), (HeardText.Pattern("wh"), "w"),
    (HeardText.Pattern("gh"), ""), (HeardText.Pattern("(?<=[^aeiou])h"), ""), (HeardText.Pattern("(?<=[aeiou])[wy]"), ""),
  ]

  /// A rough sound-alike key: consonant skeleton with common spellings merged.
  static func soundKey(_ word: String) -> String {
    var w = String(word.lowercased().filter { ("a"..."z").contains($0) })
    guard !w.isEmpty else { return "" }
    for (pattern, replacement) in soundRules { w = pattern.replace(in: w, with: replacement) }
    guard let first = w.first else { return "" }
    var key = String("aeiouy".contains(first) ? "a" : first)
    for c in w.dropFirst() where !"aeiouy".contains(c) && key.last != c { key.append(c) }
    return key
  }

  /// 1 = same letters, 0 = nothing alike (spaces ignored).
  static func letterSimilarity(_ a: String, _ b: String) -> Double {
    let x = a.lowercased().filter { $0.isLetter || $0.isNumber }
    let y = b.lowercased().filter { $0.isLetter || $0.isNumber }
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    return 1 - Double(HeardText.levenshtein(x, y)) / Double(max(x.count, y.count))
  }

  /// 1 = sounds the same (by soundKey), 0 = nothing alike.
  static func soundSimilarity(_ a: String, _ b: String) -> Double {
    let x = soundKey(a.replacingOccurrences(of: " ", with: ""))
    let y = soundKey(b.replacingOccurrences(of: " ", with: ""))
    if x.count < 2 || y.count < 2 { return x == y && !x.isEmpty ? 0.5 : 0 }
    return 1 - Double(HeardText.levenshtein(x, y)) / Double(max(x.count, y.count))
  }

  private static func dropS(_ text: String) -> String { text.hasSuffix("s") ? String(text.dropLast()) : text }

  /// Two words that are probably the same name, heard or read a little differently.
  static func sameName(_ heard: String, _ written: String) -> Bool {
    if heard == written { return true }
    if dropS(heard) == dropS(written) { return true }
    guard heard.count >= 4, written.count >= 4 else { return false }
    let distance = HeardText.levenshtein(heard, written)
    let allowed = max(heard.count, written.count) >= 7 ? 2 : 1
    if distance <= allowed, heard.first == written.first { return true }
    return heard.first == written.first && soundKey(heard) == soundKey(written) && distance <= 3
  }
}

/// A sentence and where it is in the sentences read (0 = the first).
struct AskFound: Equatable, Sendable {
  var index: Int
  var sentence: String
}

enum AskMentions {
  /// The words of a name asked about that have to appear: titles and "the" dropped.
  static func keyWords(_ subject: String) -> [String] {
    let words = AskWords.of(subject)
    let kept = words.filter { !AskWords.titles.contains($0) }
    return kept.isEmpty ? words.filter { !["the", "a", "an"].contains($0) } : kept
  }

  /// Sentences that mention `subject`, in reading order. All its key words must be in the
  /// sentence (loosely); a sentence with only the last one (the surname) also counts if the text
  /// writes that word as a name.
  static func find(_ sentences: [String], _ subject: String) -> [AskFound] {
    let keys = keyWords(subject)
    guard !keys.isEmpty else { return [] }
    let words = sentences.map(AskWords.of)
    func has(_ i: Int, _ key: String) -> Bool { words[i].contains { AskWords.sameName(key, $0) } }
    let all = sentences.indices.filter { i in keys.allSatisfy { has(i, $0) } }
    if keys.count == 1 { return all.map { AskFound(index: $0, sentence: sentences[$0]) } }
    let last = keys[keys.count - 1]
    let capitalised = sentences.contains { s in
      AskWords.asWritten(s).contains { ($0.first?.isUppercase ?? false) && AskWords.sameName(last, AskWords.norm($0)) }
    }
    let surname = capitalised ? sentences.indices.filter { has($0, last) } : []
    return Array(Set(all + surname)).sorted().map { AskFound(index: $0, sentence: sentences[$0]) }
  }

  /// How the text writes the name asked about ("holmes" to "Holmes", "mr bennet" to "Mr. Bennet").
  static func displayName(_ sentences: [String], _ found: [AskFound], _ subject: String) -> String {
    let keys = keyWords(subject)
    let shortTitles: Set<String> = ["mr", "mrs", "ms", "dr", "st"]
    for item in found {
      let written = AskWords.asWritten(item.sentence)
      guard let index = written.firstIndex(where: { w in keys.contains { AskWords.sameName($0, AskWords.norm(w)) } }) else {
        continue
      }
      var a = index
      var b = index
      // Back over titles, and capitalised words that aren't just starting the sentence ("Well, Watson").
      while a > 0, written[a - 1].first?.isUppercase == true, !AskWords.stopwords.contains(AskWords.norm(written[a - 1])),
        a - 1 > 0 || AskWords.titles.contains(AskWords.norm(written[a - 1]))
      {
        a -= 1
      }
      while b < written.count - 1, written[b + 1].first?.isUppercase == true,
        keys.contains(where: { AskWords.sameName($0, AskWords.norm(written[b + 1])) })
      {
        b += 1
      }
      let run = written[a...b].map { shortTitles.contains(AskWords.norm($0)) ? "\($0)." : $0 }.joined(separator: " ")
      return run.first?.isUppercase == true ? run : subject
    }
    return subject.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }
}

enum AskSearch {
  /// The words of a search worth matching ("the fire" to fire).
  static func keyWords(_ subject: String) -> [String] {
    var seen = Set<String>()
    return AskWords.of(subject).filter { !AskWords.stopwords.contains($0) && seen.insert($0).inserted }
  }

  private static func stem(_ word: String) -> String {
    var w = word
    if w.hasSuffix("'s") { w.removeLast(2) }
    if w.count > 5, w.hasSuffix("ing") { return String(w.dropLast(3)) }
    if w.count > 4, w.hasSuffix("ed") { return String(w.dropLast(2)) }
    if w.count > 4, w.hasSuffix("es") { return String(w.dropLast(2)) }
    if w.count > 3, w.hasSuffix("s") { return String(w.dropLast()) }
    return w
  }

  private static func matches(_ key: String, _ word: String) -> Bool {
    if key == word { return true }
    let k = stem(key)
    let w = stem(word)
    if k == w || (k.count >= 4 && (w.hasPrefix(k) || k.hasPrefix(w)) && min(k.count, w.count) >= 4) { return true }
    // Loose (misheard) matching only for longer words: "fire" must not find "fine".
    return key.count >= 6 && AskWords.sameName(key, word)
  }

  /// Sentences with the words of `subject`, best first: most key words matched, then reading
  /// order. One or two words need all of them; longer searches need two thirds.
  static func find(_ sentences: [String], _ subject: String) -> [AskFound] {
    var keys = keyWords(subject)
    if keys.isEmpty { keys = AskWords.of(subject) }
    guard !keys.isEmpty else { return [] }
    let need = keys.count <= 2 ? keys.count : (keys.count * 2 + 2) / 3
    let phrase = keys.joined(separator: " ")
    var scored: [(index: Int, score: Int, sentence: String)] = []
    for (index, sentence) in sentences.enumerated() {
      let plain = AskWords.of(sentence)
      let words = plain.flatMap { $0.contains("-") ? [$0] + $0.split(separator: "-").map(String.init) : [$0] }
      let hit = keys.filter { key in words.contains { matches(key, $0) } }.count
      guard hit >= need else { continue }
      scored.append((index, hit + (plain.joined(separator: " ").contains(phrase) ? 1 : 0), sentence))
    }
    return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
      .map { AskFound(index: $0.index, sentence: $0.sentence) }
  }
}

enum AskRecap {
  /// The last sentences, at least one, about `words` words in all.
  static func last(_ sentences: [String], words: Int = 60) -> [String] {
    var out: [String] = []
    var count = 0
    for sentence in sentences.reversed() {
      let n = AskWords.of(sentence).count
      if !out.isEmpty, count + n > words { break }
      out.insert(sentence, at: 0)
      count += n
    }
    return out
  }
}
