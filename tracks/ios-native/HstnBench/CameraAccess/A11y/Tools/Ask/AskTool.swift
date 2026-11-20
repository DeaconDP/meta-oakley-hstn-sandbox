/*
 * AskTool - "Ask about the text": questions about what was just read, answered aloud
 *
 * "What does recondite mean?", "spell it", "who is Holmes?", "recap", "what did it say about the
 * stick?", then "next". On the phone first (AskAnswerer: the bundled WordNet dictionary and the text
 * heard so far from RecentText); open questions go online only when the user has set an OpenAI
 * key, only when one is asked, and only as text (AskOnline). The camera isn't used.
 *
 * The integrator can also answer a question while another tool is open: AskGrammar.isQuestion(_:)
 * spots one, and ask(_:offerCarryOn:) answers it (offerCarryOn when a reader was paused for it).
 * Ported from Android's tools/ask/ and tools/core/AskAboutText.kt; notes/watch-and-ask-ios.md.
 */

import Observation
import SwiftUI

@MainActor
@Observable
final class AskTool: SpeakUpTool {
  let toolID: ToolID = .ask

  private(set) var lastQuestion: String?
  private(set) var lastAnswer: String?
  private(set) var isAnswering = false
  /// "Text from Read text, 120 words." or nil when nothing has been read.
  private(set) var sourceSummary: String?
  /// "More" / "next" would give something now.
  private(set) var offersMore = false
  /// "No" would undo a "Did you mean".
  private(set) var offersNo = false
  private(set) var answersOnline = false

  /// Which tool's text to ask about first (else the latest text from any tool).
  @ObservationIgnored var preferredSource: ToolID?

  @ObservationIgnored let answerer: AskAnswerer
  @ObservationIgnored private let recentText: RecentText
  @ObservationIgnored private let loader: AskDictionaryLoader
  @ObservationIgnored private var answerTask: Task<Void, Never>?
  @ObservationIgnored private let announcer = Announcer.shared

  /// - Parameters:
  ///   - recentText: where tools publish what they read.
  ///   - loader: loads the bundled dictionary once, lazily.
  ///   - online: the cloud answerer for open questions, asked each time; the default is OpenAI when
  ///     the user has set a key, and nil otherwise or under test.
  init(
    recentText: RecentText = .shared, loader: AskDictionaryLoader = .shared,
    online: (@MainActor () -> (any AskOnline)?)? = nil
  ) {
    self.recentText = recentText
    self.loader = loader
    let onlineProvider: @MainActor () -> (any AskOnline)? = online ?? { OpenAIAskOnline.configured() }
    answerer = AskAnswerer(
      dictionary: { await loader.dictionary() }, previousSession: { recentText.previousSession }, online: onlineProvider)
  }

  private var snapshot: RecentText.Snapshot? { recentText.forQuestion(source: preferredSource) }

  // MARK: SpeakUpTool

  func start(source: ReadFrameSource) {
    loader.warmUp()
    answersOnline = answerer.hasOnline
    refreshSummary()
    let lead = snapshot == nil ? "Nothing has been read yet, but I can still define words. " : ""
    announcer.announce(lead + AskWording.start, earcon: .ready, kind: .reply)
  }

  func stop() {
    answerTask?.cancel()
    answerTask = nil
    isAnswering = false
  }

  /// The app's global "stop": the answer being worked out is dropped.
  func pauseForStop() { stop() }

  func handle(transcript: String) -> Bool {
    guard answerer.classify(transcript) != nil else { return false }
    ask(transcript)
    return true
  }

  var helpLine: String { AskWording.help }

  func makePanel() -> AnyView { AnyView(AskPanel(tool: self)) }

  // MARK: Asking

  /// Answers `question` aloud. Anything that isn't a recognised question is treated as an open
  /// question (on the phone that's an honest "I can't answer that one").
  /// - Parameter offerCarryOn: a reader was paused for this question; the first answer says how to go on.
  func ask(_ question: String, offerCarryOn: Bool = false) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    answerTask?.cancel()
    lastQuestion = trimmed
    isAnswering = true
    let snapshot = snapshot
    answerTask = Task { [weak self] in
      guard let self else { return }
      let result = await self.answerer.answer(trimmed, snapshot: snapshot, offerCarryOn: offerCarryOn) { note in
        self.announcer.announce(note, earcon: .working, kind: .reply)
      }
      guard !Task.isCancelled else { return }
      self.isAnswering = false
      self.speak(result)
      self.offersMore = self.answerer.followUps.allowed(.more)
      self.offersNo = self.answerer.followUps.allowed(.no)
      self.refreshSummary()
    }
  }

  func more() { ask("more") }
  func spellIt() { ask("spell it") }
  func noTheWordISaid() { ask("no, the one I said") }
  func recap() { ask("recap") }

  private func speak(_ result: AskResult) {
    let text: String
    var earcon: Earcon?
    switch result {
    case .answer(let answer): text = answer
    case .notInText:
      text = AskWording.notInText
      earcon = .uncertain
    case .nothingRead:
      text = AskWording.nothingRead
      earcon = .uncertain
    case .failed:
      text = AskWording.failed
      earcon = .error
    }
    lastAnswer = text
    announcer.announce(text, earcon: earcon, kind: .reply)
  }

  private func refreshSummary() {
    guard let snapshot else {
      sourceSummary = nil
      return
    }
    let words = AskReadText.sentences(snapshot).reduce(0) { $0 + AskWords.of($1).count }
    sourceSummary = "Asking about text from \(snapshot.source.title), \(words) \(words == 1 ? "word" : "words")."
  }
}
