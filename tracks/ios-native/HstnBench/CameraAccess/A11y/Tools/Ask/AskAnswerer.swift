/*
 * AskAnswerer - answering questions about the text on the phone, with no cloud model
 *
 * The main path, not a fallback: most users have no key. AskGrammar says what kind of question it
 * is; this answers from the text heard so far (AskReadText) and the bundled dictionary:
 *
 *   define  "what does recondite mean"  the word in the text (or the closest one that sounds like
 *                                       it: "Did you mean recondite?"), part of speech, one or two
 *                                       senses; "more" for the rest; "no" takes the word as heard.
 *   spell   "spell it"                  the last word talked about, letter by letter.
 *   who     "who is Holmes"             first mention and the latest one or two.
 *   what    "what's the Time Machine"   a name in the text if it's there, else the dictionary.
 *   recap   "where did we leave off"    the last ~60 words heard, or the end of the last session.
 *   find    "what did it say about X"   matching sentences; "next" for the next one.
 *   open    "why did he do that"        says what it can do, or (only with a key) asks online.
 *
 * It never makes anything up: every answer is a quote from the text or a dictionary sense.
 * Follow-ups are offered for two minutes (AskFollowUps). Ported from Android's
 * tools/ask/OnDeviceAsk.kt; unit-tested on the real dictionary and the book fixture text.
 */

import Foundation

@MainActor
final class AskAnswerer {
  /// At most this much recent text goes online (about 2,500 words).
  static let onlineMaxCharacters = 12_000

  let followUps: AskFollowUps

  private let dictionary: @Sendable () async -> WordNetDictionary?
  private let previousSession: () -> String?
  /// Asked at each open question, so a key added in Settings counts at once. nil: stay on the phone.
  private let online: @MainActor () -> (any AskOnline)?

  private var more: [String] = []
  private var lastWord: String?
  private var heardWord: String?
  private var hinted = false
  private var lookup: AskWordLookup?

  /// True when "no" would undo a "Did you mean".
  var offersNo: Bool { heardWord != nil }

  init(
    dictionary: @escaping @Sendable () async -> WordNetDictionary?,
    previousSession: @escaping () -> String? = { nil },
    online: @escaping @MainActor () -> (any AskOnline)? = { nil },
    followUps: AskFollowUps = AskFollowUps()
  ) {
    self.dictionary = dictionary
    self.previousSession = previousSession
    self.online = online
    self.followUps = followUps
  }

  var hasOnline: Bool { online() != nil }

  /// The kind of question `transcript` is, follow-ups included while they're open. nil if it isn't one.
  func classify(_ transcript: String) -> AskQuestion? {
    AskGrammar.classify(transcript: transcript, followUps: followUps)
  }

  /// Answers `question` (as the user said it) from `snapshot`.
  /// - Parameters:
  ///   - offerCarryOn: a reader was paused for the question; the first answer says how to go on.
  ///   - aside: a short note to speak while an online answer is on its way ("Asking online.").
  func answer(
    _ question: String, snapshot: RecentText.Snapshot?, offerCarryOn: Bool = false, aside: (String) -> Void = { _ in }
  ) async -> AskResult {
    let parsed = classify(question) ?? AskQuestion(kind: .open, subject: nil)
    let result = await answer(parsed, asked: question, snapshot: snapshot, aside: aside)
    if case .answer = result {
      followUps.open(more: true, no: heardWord != nil)
    } else {
      followUps.close()
    }
    if case .answer(let text) = result, offerCarryOn, !hinted, snapshot?.current != nil, parsed.kind != .more {
      hinted = true
      return .answer(text + " " + AskWording.carryOnHint)
    }
    return result
  }

  private func answer(_ q: AskQuestion, asked: String, snapshot: RecentText.Snapshot?, aside: (String) -> Void) async -> AskResult {
    let current = AskReadText.sentences(snapshot)
    let previous = previousSession().map(AskSentences.split) ?? []
    let usePrevious = current.isEmpty && !previous.isEmpty
    let corpus = usePrevious ? previous : current
    if q.kind != .more, q.kind != .no, q.kind != .spell { heardWord = nil }
    let subject = q.subject ?? ""

    switch q.kind {
    case .more:
      return .answer(more.isEmpty ? AskWording.nothingMore : more.removeFirst())
    case .no:
      guard let heard = heardWord else { return .answer(AskWording.nothingToUndo) }
      heardWord = nil
      return await define(heard, corpus: corpus, allowCorrection: false)
    case .define:
      return await define(subject, corpus: corpus, allowCorrection: true)
    case .spell:
      return await spell(q.subject, corpus: corpus)
    case .who:
      guard !corpus.isEmpty else { return .nothingRead }
      return who(subject, corpus: corpus, lastTime: usePrevious)
        ?? .answer(AskWording.notReadAbout(AskWording.spokenName(subject)))
    case .what:
      if let found = who(subject, corpus: corpus, lastTime: usePrevious) { return found }
      if let lookup = await wordLookup(), lookup.lemmatiser.lemma(subject) != nil {
        return await define(subject, corpus: corpus, allowCorrection: false)
      }
      if corpus.isEmpty { return .nothingRead }
      return .answer(AskWording.notReadAbout(AskWording.spokenName(subject)))
    case .recap:
      let from = current.isEmpty ? previous : current
      guard !from.isEmpty else { return .nothingRead }
      more = []
      return .answer(AskWording.recap(AskRecap.last(from), lastTime: current.isEmpty))
    case .find:
      return find(subject, corpus: corpus)
    case .open:
      more = []
      guard let online = online() else { return .answer(AskWording.canOnly) }
      guard !corpus.isEmpty else { return .nothingRead }
      aside(AskWording.askingOnline)
      let text = String(corpus.joined(separator: " ").suffix(Self.onlineMaxCharacters))
      return await online.ask(question: asked, text: text)
    }
  }

  private func wordLookup() async -> AskWordLookup? {
    if let lookup { return lookup }
    guard let dictionary = await dictionary() else { return nil }
    let made = AskWordLookup(dictionary: dictionary)
    lookup = made
    return made
  }

  private func define(_ heard: String, corpus: [String], allowCorrection: Bool) async -> AskResult {
    guard let lookup = await wordLookup() else { return .answer(AskWording.notReady) }
    guard let choice = lookup.choose(heard, sentences: corpus, allowCorrection: allowCorrection) else {
      return .answer(AskWording.nothingToUndo)
    }
    let definition = lookup.define(choice.word)
    lastWord = choice.word
    more = definition.more
    if choice.corrected {
      heardWord = choice.heard
      return .answer(AskWording.didYouMean(choice.word) + " " + definition.text)
    }
    return .answer(definition.text)
  }

  private func spell(_ subject: String?, corpus: [String]) async -> AskResult {
    guard let subject else { return .answer(lastWord.map(AskWording.spell) ?? AskWording.noWordYet) }
    let heard = AskLemmatiser.clean(subject)
    // Spell the text's word when that's what was meant ("spell recon dight": recondite).
    var word = heard
    if let lookup = await wordLookup() {
      word = lookup.inText(heard, sentences: corpus) ?? lookup.closest(heard, vocab: lookup.vocabulary(corpus)) ?? heard
    }
    lastWord = word
    more = []
    return .answer(AskWording.spell(word))
  }

  private func who(_ subject: String, corpus: [String], lastTime: Bool) -> AskResult? {
    guard !corpus.isEmpty else { return nil }
    let found = AskMentions.find(corpus, subject)
    guard !found.isEmpty else { return nil }
    let name = AskMentions.displayName(corpus, found, subject)
    let (text, rest) = AskWording.mentions(name: name, found: found, keys: AskMentions.keyWords(subject), lastTime: lastTime)
    more = rest
    return .answer(text)
  }

  private func find(_ subject: String, corpus: [String]) -> AskResult {
    guard !corpus.isEmpty else { return .nothingRead }
    let found = AskSearch.find(corpus, subject)
    guard !found.isEmpty else {
      more = []
      return .answer(AskWording.nothingFound(subject))
    }
    let (text, rest) = AskWording.matches(subject: subject, found: found, keys: AskSearch.keyWords(subject))
    more = rest
    return .answer(text)
  }
}
