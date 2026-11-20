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
 * "Deal with this letter" (roadmap V1): after the summary, a letter with a sure deadline still to
 * come gets "Do you want a reminder before the deadline?" and "remind me three days before / on
 * Friday / the day before" (LetterReminders, through Reminders.shared; every result is spoken as
 * it is, including "reminders aren't available"). Each letter read is kept in the letters log on
 * the phone (LettersStore: the summary fields and the masked text, never the photo), reachable by
 * "my letters", "read the letter from ...", "delete that letter", "forget all letters" (asks
 * first), and the panel's My letters button. "explain this letter" gives a plain-English
 * explanation from rules on the phone (LetterExplainer); "explain online" and "explain in
 * Polish" ask OpenAI with the letter's text only (LetterExplainOnline), only with a key set, and
 * say that it's AI.
 *
 * Every failure is spoken with an earcon; the working tick plays while it looks. Nothing leaves
 * the phone unless the user asks for an AI explanation: no other cloud call on any path, even
 * when Read text's natural voice is on.
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

  /// The letter as kept in the letters log (nil for an envelope).
  private(set) var record: LetterRecord?
  /// A letter picked from the log ("read the letter from ..."). Questions, reminders and
  /// explanations are about it until the next look.
  private(set) var savedFocus: LetterRecord?
  /// The letters log is open in the panel.
  var showingLetters = false
  /// The reminder choices just offered, for the panel's buttons. Empty when nothing is offered.
  private(set) var reminderOffers: [LetterReminderChoice] = []
  /// The last explanation, shown in large print.
  private(set) var explanation: String?
  private(set) var explanationIsAI = false
  private(set) var isExplainingOnline = false
  /// What a "yes" or "no" would answer.
  private(set) var pendingQuestion: PendingQuestion = .none

  enum PendingQuestion: Equatable, Sendable {
    case none
    case reminder
    case forgetAll
  }

  /// The letter questions are about: one picked from the log, else the one just read.
  var activeRecord: LetterRecord? { savedFocus ?? record }

  var currentSentence: String? {
    (phase == .reading || phase == .paused) && sentences.indices.contains(sentenceIndex) ? sentences[sentenceIndex] : nil
  }

  var helpLine: String {
    "Mail reader. Say: what is this letter, read it all, who is it from, how much, when is it due, "
      + "is it a scam, explain this letter, remind me three days before, my letters, next page, new letter, repeat, or stop."
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
  /// Where the letter's text goes for "Ask about the text". Only the masked text (safeText).
  @ObservationIgnored var recentText: RecentText = .shared
  /// Counts letters, so a new letter is a new passage and an added page replaces its letter's.
  @ObservationIgnored private var letterNumber = 0
  @ObservationIgnored let letters: LettersStore
  @ObservationIgnored private let reminders: @MainActor () -> any ReminderScheduling
  @ObservationIgnored private let online: @MainActor () -> (any LetterExplainOnline)?
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored var calendar: Calendar = .current
  /// The log id of the letter being read, kept while pages are added.
  @ObservationIgnored private var currentLetterID: String?
  @ObservationIgnored private(set) var reminderTask: Task<Void, Never>?
  @ObservationIgnored private(set) var explainTask: Task<Void, Never>?
  private static let explainTickOwner = "mail-explain"

  /// - Parameters:
  ///   - recognize: Vision OCR (TextRecognizer, shared with Read text); tests can pass their own.
  ///   - letters: the letters log on the phone.
  ///   - reminders: asked each time, so the reminders feature can replace Reminders.shared at launch.
  ///   - online: the AI explainer, asked each time: OpenAI when a key is set, nil otherwise or under test.
  ///   - now: the clock, for reminder days; tests pass a fixed one.
  init(
    recognize: @escaping @Sendable (UIImage) throws -> RecognizedFrame = { try TextRecognizer.recognize($0) },
    letters: LettersStore = .shared,
    reminders: @escaping @MainActor () -> any ReminderScheduling = { Reminders.shared },
    online: @escaping @MainActor () -> (any LetterExplainOnline)? = { OpenAILetterExplainer.configured() },
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.recognize = recognize
    self.letters = letters
    self.reminders = reminders
    self.online = online
    self.now = now
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
    cancelOnlineExplanation()
    pendingQuestion = .none
    if phase == .reading || phase == .looking { announcer.stop() }
    switch phase {
    case .reading: phase = .paused
    case .looking: phase = letter == nil ? .idle : .ready
    default: break
    }
    source = nil
  }

  /// The global "stop": an AI explanation on its way is dropped (speech is already cut).
  func pauseForStop() {
    cancelOnlineExplanation()
  }

  func handle(transcript: String) -> Bool {
    if let command = LetterGrammar.parse(transcript), perform(letter: command) {
      BenchClock.shared.note("mail letter command")
      return true
    }
    guard let command = MailGrammar.parse(transcript) else { return false }
    BenchClock.shared.note("mail voice command=\(command.rawValue)")
    perform(command)
    return true
  }

  func makePanel() -> AnyView { AnyView(MailPanel(tool: self)) }

  // MARK: Commands (voice and buttons)

  func perform(_ command: MailCommand) {
    pendingQuestion = .none
    if let saved = savedFocus, Self.savedAnswers.contains(command) {
      return answer(LettersSpeech.answer(command, saved), earcon: command == .scam && !saved.signs.isEmpty ? .attention : nil)
    }
    switch command {
    case .summarise:
      if phase == .paused, letter != nil { resume() } else { look(.new) }
    case .newLetter: look(.new)
    case .envelope: look(.envelope)
    case .nextPage: look(letter == nil ? .new : .addPage)
    case .summary:
      if let letter { answer(LetterSpeech.summary(letter)) } else { look(.new) }
    case .readAll, .startAgain:
      if letter == nil && savedFocus == nil { look(.new, then: .readAll) } else { startReading(from: 0) }
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

  /// Questions a saved letter can answer without a new picture.
  private static let savedAnswers: Set<MailCommand> = [.from, .forWhom, .howMuch, .whenDue, .scam, .kind, .date, .reference, .summary]

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
        SpokenMessage.readGuidance(verdict, verbosity: A11yPreferences.shared.effectiveVerbosity, camera: camera) ?? SpokenMessage.readFailed
      return fail(guidance, earcon: .attention, myGeneration)
    }
    let scan = LetterScan(page: recognized.page)

    let newScans: [LetterScan]
    switch mode {
    case .new, .envelope:
      letterNumber += 1
      currentLetterID = nil
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
    recentText.append(read.safeText, source: .mail, key: "letter-\(letterNumber)")
    summary = LetterSpeech.summary(read)
    sentences = []
    sentenceIndex = 0
    phase = .ready
    savedFocus = nil
    explanation = nil
    explanationIsAI = false
    showingLetters = false
    reminderOffers = []
    let keep = keepInLog(read)
    BenchClock.shared.record(
      "mail_trigger_to_summary", ms: Int((BenchClock.uptimeNanoseconds() &- startedAt) / 1_000_000),
      detail: "kind=\(read.kind.rawValue) envelope=\(read.isEnvelope) amount=\(Self.logName(read.amount)) pages=\(read.pages.count)")

    let cut = Self.cutOffHint(verdict, camera: camera)
    var text: String? =
      switch (mode, then) {
      case (.envelope, _): LetterSpeech.envelope(read)
      case (_, .readAll?): nil
      case (_, let command?): Self.answer(command, read)
      case (.addPage, nil): "Page \(newScans.count) added. " + summary
      default: summary
      }
    // After the summary: whether it was kept, and the reminder offer.
    if then == nil, mode == .new || mode == .addPage, let current = text {
      text = ([current] + keep).joined(separator: " ")
      if let record, let offer = offerLine(for: record) {
        text = (text ?? "") + " " + offer
      }
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
    let paragraphs: [String]
    if let savedFocus {
      paragraphs = savedFocus.paragraphs.map { LetterSpeech.forReading($0, unsureMoney: []) }
    } else if let letter {
      paragraphs = letter.readingParagraphs
    } else {
      return say("No letter yet. Say what is this letter.", earcon: .attention)
    }
    sentences = paragraphs.flatMap(LetterSentences.split)
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
    recentText.setCurrent(sentences[index], source: .mail)
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
    recentText.setCurrent(nil, source: .mail)
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
      return letter == nil && savedFocus == nil ? say("No letter yet. Say what is this letter.") : startReading(from: 0)
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
    if let savedFocus { return answer(savedFocus.summary) }
    if let letter { return answer(LetterSpeech.summary(letter)) }
    say("Nothing to repeat yet. Say what is this letter.")
  }

  // MARK: Deal with this letter

  /// Saves the letter to the log. Returns what to add after the summary: a failure, or (once
  /// ever) that letters are kept on the phone.
  private func keepInLog(_ read: Letter) -> [String] {
    guard !read.isEnvelope else {
      record = nil
      return []
    }
    let id = currentLetterID ?? LetterRecord.stableID(for: read)
    currentLetterID = id
    let kept = LetterRecord(letter: read, id: id, summary: summary, savedAt: now())
    guard letters.save(kept) else {
      record = kept
      return ["I couldn't save it to your letters."]
    }
    record = letters.record(id: id) ?? kept
    guard !letters.hasToldAboutSaving else { return [] }
    letters.hasToldAboutSaving = true
    return ["I've kept it in your letters on this phone. Say my letters to hear them."]
  }

  private var planner: LetterReminderPlanner { LetterReminderPlanner(now: now(), calendar: calendar) }

  /// "Do you want a reminder before the deadline? ..." for a letter with a sure date still to come.
  private func offerLine(for record: LetterRecord) -> String? {
    let planner = self.planner
    guard let line = planner.offerLine(due: record.dueDay, kind: record.deadlineKind) else { return nil }
    reminderOffers = planner.offers(due: record.dueDay)
    pendingQuestion = .reminder
    return line
  }

  /// The letter commands, by voice or from the panel. False for a "yes" or "no" nothing asked for.
  @discardableResult
  func perform(letter command: LetterVoiceCommand) -> Bool {
    let pending = pendingQuestion
    switch command {
    case .yes:
      switch pending {
      case .reminder: remind(.suggested)
      case .forgetAll: forgetAllConfirmed()
      case .none: return false
      }
    case .no:
      switch pending {
      case .reminder: declineReminder()
      case .forgetAll: keepLetters()
      case .none: return false
      }
    case .remind(let choice): remind(choice)
    case .cancelReminder:
      if pending == .reminder { declineReminder() } else { cancelReminder() }
    case .explain(let mode):
      pendingQuestion = .none
      explain(mode)
    case .unknownLanguage(let said):
      pendingQuestion = .none
      say("I don't know the language \(said). Say explain in, then the language, like explain in Polish.", earcon: .attention)
    case .myLetters:
      pendingQuestion = .none
      listLetters()
    case .readSaved(let name):
      pendingQuestion = .none
      openSaved(named: name)
    case .deleteThat:
      pendingQuestion = .none
      deleteActive()
    case .forgetAll: askForgetAll()
    case .export:
      pendingQuestion = .none
      exportHint()
    }
    return true
  }

  func remind(_ choice: LetterReminderChoice) {
    pendingQuestion = .none
    guard let target = activeRecord else {
      return say("No letter yet. Say what is this letter, then ask for a reminder.", earcon: .attention)
    }
    let planner = self.planner
    let plan = planner.plan(choice, due: target.dueDay)
    guard case .remind(let fireDate, let day, _) = plan, let due = target.dueDay,
      let request = planner.request(for: target, fireDate: fireDate)
    else {
      let line = planner.line(for: plan, kind: target.deadlineKind) ?? "I can't set a reminder for this letter."
      notice = line
      return say(line, earcon: .attention)
    }
    reminderOffers = []
    let scheduler = reminders()
    reminderTask?.cancel()
    reminderTask = Task { [weak self] in
      let result = await scheduler.schedule(request)
      guard let self, !Task.isCancelled else { return }
      BenchClock.shared.note("mail reminder result=\(result)")
      if result == .scheduled { self.noteReminder(fireDate, for: target.id) }
      let line = planner.line(for: result, day: day, choice: choice, due: due, kind: target.deadlineKind)
      self.notice = line
      self.say(line, earcon: result == .scheduled ? .done : .attention)
    }
  }

  private func noteReminder(_ date: Date?, for id: String) {
    letters.setReminder(date, for: id)
    if record?.id == id { record?.reminderAt = date }
    if savedFocus?.id == id { savedFocus?.reminderAt = date }
  }

  private func declineReminder() {
    pendingQuestion = .none
    reminderOffers = []
    say("OK, no reminder.", earcon: .ready)
  }

  private func cancelReminder() {
    pendingQuestion = .none
    guard let target = activeRecord else { return say("No letter yet. Say what is this letter.", earcon: .attention) }
    guard target.reminderAt != nil else { return say("There's no reminder set for this letter.", earcon: .attention) }
    reminders().cancel(id: target.id)
    noteReminder(nil, for: target.id)
    say("Reminder cancelled.", earcon: .done)
  }

  // MARK: Explaining

  func explain(_ mode: ExplainMode) {
    guard let target = activeRecord else {
      if letter?.isEnvelope == true { return say("I can only see the envelope. Open it and say read, then ask again.", earcon: .attention) }
      return say("No letter yet. Say what is this letter, then explain.", earcon: .attention)
    }
    switch mode {
    case .onDevice:
      let text = LetterExplainer.explain(target, offerOnline: online() != nil)
      explanation = text
      explanationIsAI = false
      answer(text, earcon: .done)
    case .online:
      explainOnline(target, language: nil)
    case .language(let name):
      guard let language = name ?? LetterLanguages.phoneLanguage() else {
        return say("Your phone is set to English. Say explain in, then the language, like explain in Polish.", earcon: .attention)
      }
      explainOnline(target, language: language == "English" ? nil : language)
    }
  }

  nonisolated static let needsKey =
    "An AI explanation needs an OpenAI key in Settings. Nothing was sent. Say explain this letter for the explanation on the phone."

  private func explainOnline(_ target: LetterRecord, language: String?) {
    guard let client = online() else {
      notice = Self.needsKey
      return say(Self.needsKey, earcon: .attention)
    }
    if isExplainingOnline { return say("Still asking online.", earcon: .working) }
    isExplainingOnline = true
    earcons.startWorkingTick(owner: Self.explainTickOwner)
    let inLanguage = language.map { " in \($0)" } ?? ""
    say("Asking online for an AI explanation\(inLanguage). Only the letter's text is sent, not the photo.", earcon: .working)
    let text = target.text
    explainTask = Task { [weak self] in
      let result = await client.explain(text: text, language: language)
      guard let self, !Task.isCancelled else { return }
      self.earcons.stopWorkingTick(owner: Self.explainTickOwner)
      self.isExplainingOnline = false
      BenchClock.shared.note("mail explain online done")
      switch result {
      case .explanation(let explained):
        self.explanation = explained
        self.explanationIsAI = true
        self.answer(Self.aiLine(explained), earcon: .done)
      case .failed(let reason):
        let line = Self.onlineFailure(reason)
        self.notice = line
        self.say(line, earcon: .error)
      }
    }
  }

  /// The AI's words, said to be AI (EU AI Act Article 50), with the advice to check.
  nonisolated static func aiLine(_ explained: String) -> String {
    "AI explanation: \(explained) This was written by AI from the letter's text, so check anything important."
  }

  nonisolated static func onlineFailure(_ reason: String) -> String {
    let why =
      switch reason {
      case "network": "I couldn't reach the internet."
      case "unauthorized", "no_key": "The OpenAI key wasn't accepted. Check it in Settings."
      case "rate_limited": "OpenAI is busy or the key has run out of credit."
      default: "Something went wrong asking online."
      }
    return "\(why) Say explain this letter for the explanation on the phone."
  }

  private func cancelOnlineExplanation() {
    explainTask?.cancel()
    explainTask = nil
    if isExplainingOnline {
      earcons.stopWorkingTick(owner: Self.explainTickOwner)
      isExplainingOnline = false
    }
  }

  // MARK: The letters log

  func listLetters() {
    showingLetters = true
    _ = letters.load()
    say(LettersSpeech.list(letters.letters, calendar: calendar), earcon: .ready)
  }

  func openSaved(named name: String) {
    let matches = letters.find(sender: name)
    guard let first = matches.first else {
      let line = "I can't find a saved letter from \(name). Say my letters to hear them all."
      notice = line
      return say(line, earcon: .attention)
    }
    open(first, matches: matches.count)
  }

  /// A letter from the log, picked by voice or on screen.
  func open(_ saved: LetterRecord, matches: Int = 1) {
    pendingQuestion = .none
    if phase == .reading { generation += 1 }
    if phase == .reading || phase == .paused { phase = letter == nil ? .idle : .ready }
    savedFocus = saved
    sentences = []
    sentenceIndex = 0
    explanation = nil
    reminderOffers = []
    showingLetters = false
    answer(LettersSpeech.opened(saved, matches: matches, calendar: calendar), earcon: .done)
  }

  /// Back to the letter just read, from one picked in the log.
  func closeSaved() {
    savedFocus = nil
    sentences = []
    sentenceIndex = 0
    explanation = nil
    if phase == .reading || phase == .paused {
      generation += 1
      announcer.stop()
      phase = letter == nil ? .idle : .ready
    }
  }

  func deleteActive() {
    guard let target = activeRecord else {
      return say("There's no letter to delete. Say my letters to hear the ones you have.", earcon: .attention)
    }
    delete(target)
  }

  func delete(_ target: LetterRecord) {
    guard letters.record(id: target.id) != nil else {
      return say("That letter isn't in your letters.", earcon: .attention)
    }
    guard letters.delete(id: target.id) else {
      notice = "I couldn't delete that letter."
      return say("I couldn't delete that letter.", earcon: .error)
    }
    var line = "Deleted \(target.spokenName(calendar: calendar))"
    if target.reminderAt != nil {
      reminders().cancel(id: target.id)
      line += ", and its reminder"
    }
    if savedFocus?.id == target.id { closeSaved() }
    if record?.id == target.id { record = nil }
    say(line + ".", earcon: .done)
  }

  func askForgetAll() {
    _ = letters.load()
    let count = letters.letters.count
    guard count > 0 else {
      pendingQuestion = .none
      return say("You have no saved letters.", earcon: .attention)
    }
    pendingQuestion = .forgetAll
    let what = count == 1 ? "your one saved letter" : "all \(count) saved letters"
    say(
      "Forget \(what)? This deletes them from this phone and can't be undone. Say yes to forget them, or no to keep them.",
      earcon: .attention)
  }

  func forgetAllConfirmed() {
    pendingQuestion = .none
    let withReminders = letters.letters.filter { $0.reminderAt != nil }.map(\.id)
    guard letters.deleteAll() else {
      notice = "I couldn't delete your letters."
      return say("I couldn't delete your letters.", earcon: .error)
    }
    let scheduler = reminders()
    withReminders.forEach { scheduler.cancel(id: $0) }
    record = nil
    if savedFocus != nil { closeSaved() }
    say("Done. I've forgotten all your letters." + (withReminders.isEmpty ? "" : " Their reminders are cancelled too."), earcon: .done)
  }

  func keepLetters() {
    pendingQuestion = .none
    say("OK, I kept your letters.", earcon: .ready)
  }

  private func exportHint() {
    showingLetters = true
    guard !letters.letters.isEmpty else { return say("You have no saved letters to export.", earcon: .attention) }
    say(
      "To export your letters, tap Export as text or Export as CSV under My letters, then choose where to send them. "
        + "Nothing leaves the phone until you choose.",
      earcon: .ready)
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
