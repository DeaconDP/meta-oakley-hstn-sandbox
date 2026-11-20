/*
 * MailTool - the mail reader: "what is this letter", then "read it all"
 *
 *   "what is this letter" / "read" ─► a picture from the ReadFrameSource (the phone's camera by
 *   default, the glasses when linked): the still photo, else the latest stream frame ─►
 *   TextRecognizer (Apple Vision, on the phone, shared with Read text) ─► FramingAdvisor (no text,
 *   dark, blurred, too small) ─► LetterReader (sender, recipient, kind, subject, amount due,
 *   deadline, references, scam signs; the money rule) ─► a second look at the amount ─►
 *   LetterSpeech summary, spoken.
 *
 * Port of the Android MailViewModel, phone first. "read it all" reads every paragraph sentence by
 * sentence through the Announcer; "back", "skip", "repeat", "start again" and "carry on reading"
 * act on sentences, and the global "stop" pauses (the Announcer cut ends the sentence unfinished).
 * Questions ("who's it from", "how much", "when is it due", "is it a scam") are answered from
 * the letter; asked before any letter, they look at one first. "next page" adds a page and the
 * summary updates; "how much" on an unsure amount takes a fresh look at the same page.
 *
 * The second look (iOS only): when the amount due reads as sure, the latest stream frame is read
 * too, and if it reads a different sure amount, no figure is said (LetterReader.crossChecked).
 * Android notes/mail-reader.md listed this as an idea; stream frames make it cheap here.
 *
 * Every failure is spoken with an earcon; the working tick plays while it looks. Nothing leaves
 * the phone: no cloud call on any path, even when Read text's natural voice is on.
 */

import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MailTool: SpeakUpTool {
  enum Phase: Equatable, Sendable {
    case idle
    /// Taking the picture and reading it.
    case looking
    /// A letter has been read; waiting for a question or "read it all".
    case ready
    case reading
    case paused
  }

  private enum Mode { case new, addPage, recheck, envelope }

  let toolID: ToolID = .mail

  private(set) var phase: Phase = .idle
  private(set) var letter: Letter?
  private(set) var summary = ""
  /// "Read it all": every sentence of the letter, safe for speech.
  private(set) var sentences: [String] = []
  private(set) var sentenceIndex = 0
  /// The last failure or guidance line, shown in large print.
  private(set) var notice: String?

  var currentSentence: String? {
    (phase == .reading || phase == .paused) && sentences.indices.contains(sentenceIndex) ? sentences[sentenceIndex] : nil
  }

  var helpLine: String {
    "Mail reader. Say: what is this letter, read it all, who is it from, how much, when is it due, "
      + "is it a scam, what's the reference, next page, new letter, repeat, or stop."
  }

  /// A stream frame older than this isn't used for the second look.
  static let maxFrameAge: TimeInterval = 1.0
  static let streamWait: Duration = .seconds(30)
  private static let tickOwner = "mail"

  @ObservationIgnored private weak var source: (any ReadFrameSource)?
  @ObservationIgnored private let recognize: @Sendable (UIImage) throws -> RecognizedFrame
  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared
  @ObservationIgnored private var scans: [LetterScan] = []
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Bumped by every new look, reading step and stop, so late callbacks do nothing.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var lastAnswer: String?

  /// `recognize` is Vision OCR (TextRecognizer, shared with Read text); tests can pass their own.
  init(recognize: @escaping @Sendable (UIImage) throws -> RecognizedFrame = { try TextRecognizer.recognize($0) }) {
    self.recognize = recognize
  }

  // MARK: SpeakUpTool

  func start(source: ReadFrameSource) {
    self.source = source
    _ = source.prepareStreamForReading()  // Starts the camera early; the first look waits for it.
    let how =
      source.cameraKind == .phone
      ? "Hold the phone flat over a letter or envelope, about 30 centimetres above it"
      : "Hold a letter or envelope in front of you, about an arm's length away"
    say("Mail reader. \(how), then say what is this letter.", earcon: .ready)
  }

  func stop() {
    generation += 1
    task?.cancel()
    task = nil
    earcons.stopWorkingTick(owner: Self.tickOwner)
    if phase == .reading || phase == .looking { announcer.stop() }
    switch phase {
    case .reading: phase = .paused
    case .looking: phase = letter == nil ? .idle : .ready
    default: break
    }
    source = nil
  }

  func handle(transcript: String) -> Bool {
    guard let command = MailGrammar.parse(transcript) else { return false }
    BenchClock.shared.note("mail voice command=\(command.rawValue)")
    perform(command)
    return true
  }

  func makePanel() -> AnyView { AnyView(MailPanel(tool: self)) }

  // MARK: Commands (voice and buttons)

  func perform(_ command: MailCommand) {
    switch command {
    case .summarise:
      if phase == .paused, letter != nil { resume() } else { look(.new) }
    case .newLetter: look(.new)
    case .envelope: look(.envelope)
    case .nextPage: look(letter == nil ? .new : .addPage)
    case .summary:
      if let letter { answer(LetterSpeech.summary(letter)) } else { look(.new) }
    case .readAll, .startAgain:
      if letter == nil { look(.new, then: .readAll) } else { startReading(from: 0) }
    case .howMuch:
      guard let letter else { return look(.new, then: command) }
      // An unsure amount: take a fresh look at the same page, never guess.
      if letter.amount.isUnsureOrConflict { look(.recheck, then: command) } else { answer(LetterSpeech.howMuch(letter)) }
    case .from, .forWhom, .whenDue, .isJunk, .scam, .kind, .date, .reference:
      guard let letter else { return look(.new, then: command) }
      answer(Self.answer(command, letter), earcon: command == .scam && !letter.scamSigns.isEmpty ? .attention : nil)
    case .back: back()
    case .skip: skip()
    case .repeatLast: repeatLast()
    case .resume: resume()
    }
  }

  /// Read it all, or pause and carry on: the panel's main reading button.
  func toggleReading() {
    switch phase {
    case .reading:
      generation += 1
      announcer.stop()
      phase = .paused
      earcons.play(.ready)
    case .paused: resume()
    default: perform(.readAll)
    }
  }

  static func answer(_ command: MailCommand, _ letter: Letter) -> String {
    switch command {
    case .from: LetterSpeech.from(letter)
    case .forWhom: LetterSpeech.forWhom(letter)
    case .howMuch: LetterSpeech.howMuch(letter)
    case .whenDue: LetterSpeech.whenDue(letter)
    case .isJunk: LetterSpeech.isJunk(letter)
    case .scam: LetterSpeech.scam(letter)
    case .kind: LetterSpeech.kind(letter)
    case .date: LetterSpeech.date(letter)
    case .reference: LetterSpeech.references(letter)
    default: LetterSpeech.summary(letter)
    }
  }

  // MARK: Looking at the letter

  private func look(_ mode: Mode, then: MailCommand? = nil) {
    if phase == .looking { return say("Still looking at the letter.") }
    guard source != nil else { return warn(SpokenMessage.readNoCamera) }
    generation += 1
    let myGeneration = generation
    task?.cancel()
    announcer.stop()
    phase = .looking
    notice = nil
    earcons.play(.working)
    earcons.startWorkingTick(owner: Self.tickOwner)
    announcer.say(mode == .addPage ? "Looking at the next page." : "Looking at the letter.", kind: .reply, interrupt: false)
    task = Task { [weak self] in await self?.run(mode, then: then, myGeneration) }
  }

  private func run(_ mode: Mode, then: MailCommand?, _ myGeneration: Int) async {
    let startedAt = BenchClock.uptimeNanoseconds()
    guard let source else { return fail(SpokenMessage.readNoCamera, earcon: .error, myGeneration) }
    guard await ensureStream(source, myGeneration) else { return }

    // The still photo first: letters have small print and money is at stake. The latest frame
    // if the photo fails.
    var image = await source.captureStillForReading()
    guard isCurrent(myGeneration) else { return }
    if image == nil { image = source.latestReadFrame?.image }
    guard let image else { return fail(SpokenMessage.readPhotoFailed, earcon: .error, myGeneration) }

    guard let recognized = await recognizeOffMain(image), isCurrent(myGeneration) else {
      if isCurrent(myGeneration) { fail(SpokenMessage.readFailed, earcon: .error, myGeneration) }
      return
    }
    BenchClock.shared.record("mail_ocr", ms: recognized.ocrMilliseconds, detail: "lines=\(recognized.page.lines.count)")
    let verdict = FramingAdvisor.assess(recognized.page, quality: recognized.quality)
    let camera = source.cameraKind
    if verdict.blocksReading {
      let guidance =
        SpokenMessage.readGuidance(verdict, verbosity: A11yPreferences.shared.verbosity, camera: camera) ?? SpokenMessage.readFailed
      return fail(guidance, earcon: .attention, myGeneration)
    }
    let scan = LetterScan(page: recognized.page)

    let newScans: [LetterScan]
    switch mode {
    case .new, .envelope:
      newScans = [scan]
    case .addPage:
      if let last = scans.last, MailPages.isSamePage(last, scan) {
        earcons.stopWorkingTick(owner: Self.tickOwner)
        phase = .ready
        notice = "That looks like the same page."
        return say("That looks like the same page. Turn it over or hold up the next one, then say next page.", earcon: .attention)
      }
      newScans = scans + [scan]
    case .recheck:
      newScans = Array(scans.dropLast()) + [scan]
    }

    var read = LetterReader.read(newScans)
    if case .sure = read.amount, let other = await secondLook(source, after: newScans, myGeneration) {
      read = LetterReader.crossChecked(read, with: other)
    }
    guard isCurrent(myGeneration) else { return }

    earcons.stopWorkingTick(owner: Self.tickOwner)
    scans = newScans
    letter = read
    summary = LetterSpeech.summary(read)
    sentences = []
    sentenceIndex = 0
    phase = .ready
    BenchClock.shared.record(
      "mail_trigger_to_summary", ms: Int((BenchClock.uptimeNanoseconds() &- startedAt) / 1_000_000),
      detail: "kind=\(read.kind.rawValue) envelope=\(read.isEnvelope) amount=\(Self.logName(read.amount)) pages=\(read.pages.count)")

    let cut = Self.cutOffHint(verdict, camera: camera)
    let text: String? =
      switch (mode, then) {
      case (.envelope, _): LetterSpeech.envelope(read)
      case (_, .readAll?): nil
      case (_, let command?): Self.answer(command, read)
      case (.addPage, nil): "Page \(newScans.count) added. " + summary
      default: summary
      }
    let earcon: Earcon = read.amount.isUnsureOrConflict ? .uncertain : .done
    if let text {
      say([text, cut].compactMap { $0 }.joined(separator: " "), earcon: earcon)
    } else if let cut {
      say(cut, earcon: .attention)
    }
    if then == .readAll { startReading(from: 0, interrupt: text == nil && cut == nil) }
  }

  /// The amount read on the latest stream frame instead of the photo, as a whole letter. nil when
  /// there's no fresh frame or it can't be read.
  private func secondLook(_ source: any ReadFrameSource, after scans: [LetterScan], _ myGeneration: Int) async -> Letter? {
    guard let frame = source.latestReadFrame,
      Double(BenchClock.uptimeNanoseconds() &- frame.arrivedAt) / 1_000_000_000 <= Self.maxFrameAge,
      let recognized = await recognizeOffMain(frame.image), isCurrent(myGeneration)
    else { return nil }
    let page = LetterScan(page: recognized.page)
    guard !page.lines.isEmpty else { return nil }
    return LetterReader.read(Array(scans.dropLast()) + [page])
  }

  private func recognizeOffMain(_ image: UIImage) async -> RecognizedFrame? {
    let recognize = recognize
    let result = await Task.detached(priority: .userInitiated) { () -> Result<RecognizedFrame, any Error> in
      Result { try recognize(image) }
    }.value
    if case .failure(let error) = result { BenchClock.shared.note("mail ocr failed: \(error.localizedDescription)") }
    return try? result.get()
  }

  /// Waits for a streaming camera, nudging it along. False (having said why) when it can't.
  private func ensureStream(_ source: any ReadFrameSource, _ myGeneration: Int) async -> Bool {
    let deadline = ContinuousClock.now + Self.streamWait
    var announced = false
    while isCurrent(myGeneration) {
      switch source.prepareStreamForReading() {
      case .ready:
        return true
      case .starting:
        if !announced {
          announced = true
          announcer.say(SpokenMessage.readStartingCamera, kind: .reply, interrupt: false)
        }
      case .blocked:
        // An alert or permission prompt is up and the camera screen says it.
        earcons.stopWorkingTick(owner: Self.tickOwner)
        phase = letter == nil ? .idle : .ready
        return false
      case .unavailable(let reason):
        fail(reason, earcon: .attention, myGeneration)
        return false
      }
      if ContinuousClock.now >= deadline {
        fail(SpokenMessage.readCameraTimedOut, earcon: .error, myGeneration)
        return false
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func fail(_ text: String, earcon: Earcon, _ myGeneration: Int) {
    guard isCurrent(myGeneration) else { return }
    earcons.stopWorkingTick(owner: Self.tickOwner)
    phase = letter == nil ? .idle : .ready
    notice = text
    say(text, earcon: earcon)
  }

  private func isCurrent(_ myGeneration: Int) -> Bool { myGeneration == generation && !Task.isCancelled }

  /// After the summary: which way to move when part of the letter was cut off.
  static func cutOffHint(_ verdict: FramingVerdict, camera: CameraKind) -> String? {
    guard case .cutOff(let edges) = verdict else { return nil }
    let sides = FramingEdge.allCases.filter(edges.contains).map { edge in
      switch edge {
      case .left: "left"
      case .right: "right"
      case .top: "top"
      case .bottom: "bottom"
      }
    }
    let move = camera == .phone ? "Raise the phone a little or move it towards that side" : "Hold the letter a little further away"
    return "Part of the letter is cut off at the \(sides.joined(separator: " and ")). \(move), then say read."
  }

  private static func logName(_ amount: AmountDue) -> String {
    switch amount {
    case .none: "none"
    case .sure: "sure"
    case .unsure: "unsure"
    case .conflict: "conflict"
    }
  }

  // MARK: Reading every word

  private func startReading(from start: Int, interrupt: Bool = true) {
    guard let letter else { return say("No letter yet. Say what is this letter.") }
    sentences = letter.readingParagraphs.flatMap(LetterSentences.split)
    guard !sentences.isEmpty else { return warn("I can't find any words to read in this letter.") }
    sentenceIndex = min(max(0, start), sentences.count - 1)
    phase = .reading
    speakCurrent(interrupt: interrupt)
  }

  private func speakCurrent(interrupt: Bool) {
    generation += 1
    let myGeneration = generation
    let index = sentenceIndex
    guard sentences.indices.contains(index) else { return }
    announcer.say(sentences[index], kind: .reply, interrupt: interrupt) { [weak self] finished in
      self?.sentenceEnded(index, finished: finished, myGeneration)
    }
  }

  private func sentenceEnded(_ index: Int, finished: Bool, _ myGeneration: Int) {
    guard myGeneration == generation, phase == .reading else { return }
    guard finished else {
      // Cut by "stop" or by something else speaking: pause here.
      phase = .paused
      return
    }
    if index + 1 < sentences.count {
      sentenceIndex = index + 1
      speakCurrent(interrupt: false)
    } else {
      finishedReading()
    }
  }

  private func finishedReading() {
    generation += 1
    phase = .ready
    sentenceIndex = 0
    say("That's the end of the letter. Say read it all to hear it again, or new letter.", earcon: .done, interrupt: false)
  }

  private func resume() {
    switch phase {
    case .paused: startReading(from: sentenceIndex)
    case .reading: return
    case .ready: say("Nothing is paused. Say read it all to hear the letter.")
    case .idle, .looking: perform(.summarise)
    }
  }

  private func back() {
    guard phase == .reading || phase == .paused else {
      return letter == nil ? say("No letter yet. Say what is this letter.") : startReading(from: 0)
    }
    if sentenceIndex == 0 { announcer.say("That's the start.", kind: .reply) }
    startReading(from: max(0, sentenceIndex - 1), interrupt: sentenceIndex != 0)
  }

  private func skip() {
    guard phase == .reading || phase == .paused else {
      return say(letter == nil ? "No letter yet. Say what is this letter." : "Nothing is being read. Say read it all.")
    }
    if sentenceIndex + 1 < sentences.count {
      startReading(from: sentenceIndex + 1)
    } else {
      announcer.stop()
      finishedReading()
    }
  }

  private func repeatLast() {
    if phase == .reading || phase == .paused { return startReading(from: sentenceIndex) }
    if let lastAnswer { return answer(lastAnswer) }
    if let letter { return answer(LetterSpeech.summary(letter)) }
    say("Nothing to repeat yet. Say what is this letter.")
  }

  // MARK: Speaking

  /// An answer. While reading, it cuts in, then reading carries on from the same sentence.
  private func answer(_ text: String, earcon: Earcon? = nil) {
    lastAnswer = text
    guard phase == .reading else { return say(text, earcon: earcon) }
    generation += 1
    let myGeneration = generation
    announcer.announce(text, earcon: earcon, kind: .reply, interrupt: true) { [weak self] finished in
      guard let self, finished, myGeneration == self.generation, self.phase == .reading else { return }
      self.speakCurrent(interrupt: false)
    }
  }

  private func say(_ text: String, earcon: Earcon? = nil, interrupt: Bool = true) {
    if phase == .reading {
      generation += 1
      phase = .paused
    }
    announcer.announce(text, earcon: earcon, kind: .reply, interrupt: interrupt)
  }

  private func warn(_ text: String) {
    notice = text
    say(text, earcon: .error)
  }
}

/// "next page" on the page already read: the same words again means the user hasn't turned it.
enum MailPages {
  /// Share of the shorter page's words that must also be on the other page to call it the same.
  static let sameShare = 0.7

  static func isSamePage(_ a: LetterScan, _ b: LetterScan) -> Bool {
    let wordsA = words(a)
    let wordsB = words(b)
    guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
    let shared = wordsA.intersection(wordsB).count
    return Double(shared) >= sameShare * Double(min(wordsA.count, wordsB.count))
  }

  private static func words(_ scan: LetterScan) -> Set<String> {
    Set(scan.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
  }
}
