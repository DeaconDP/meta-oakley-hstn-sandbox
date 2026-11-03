/*
 * TextReader - "Read it aloud (word for word)": trigger, frame, OCR, framing check, then the
 * text sentence by sentence, with next / previous / repeat / stop
 *
 * Flow for one trigger (Read button, VoiceOver "Read text", Siri "Read this with HSTN Reader"):
 * 1. At once: cut whatever the app is saying, play the "working" earcon (inside the 100 ms
 *    budget) and start the working tick, so the wait is never silent.
 * 2. Make sure the stream is up; if not, take the next step (start session / preview) and wait.
 * 3. Take the latest decoded stream frame (CameraViewModel keeps it). No capturePhoto in the
 *    common case: it costs ~0.4 s on the mock and ~3.9 s measured elsewhere, while the stream
 *    frame is already there (ROADMAP phase 2, "New metric"). capturePhoto is the fallback, said
 *    out loud, when there is no frame from the last second or the text is too small in it.
 * 4. OCR on device (TextRecognizer), framing check (ReadFraming). A poor frame gets spoken
 *    guidance instead of reading; a cut-off frame gets guidance, then what is visible is read.
 * 5. Sentences go to the Announcer as replies, clause by clause, one sentence after another.
 *
 * Metrics (BenchClock, picked up by bench.sh): `trigger_to_first_word` from the trigger to the
 * synthesizer starting the first line of the response, whatever that line is (detail `first=`
 * says whether it was text, guidance or a fallback notice); `ocr` for Vision alone; `frame_age`
 * for how old the stream frame was when OCR got it.
 */

import Foundation
import Observation
import UIKit

/// A decoded stream frame and when it arrived (BenchClock uptime).
struct ReadFrame {
  var image: UIImage
  var arrivedAt: UInt64
}

enum ReadStreamReadiness: Equatable {
  case ready
  /// A start is in flight (or was just requested); keep waiting.
  case starting
  /// An error or a prompt is up; the camera screen is already saying it.
  case blocked
  /// Can't start from here; the reason is the spoken status line.
  case unavailable(String)
}

/// What the reader needs from the camera screen. CameraViewModel implements it.
@MainActor
protocol ReadFrameSource: AnyObject {
  var latestReadFrame: ReadFrame? { get }
  /// Returns at once. May start a session or the preview as a side effect.
  func prepareStreamForReading() -> ReadStreamReadiness
  /// An in-stream photo for reading only: no preview sheet, no photo reply. nil on failure.
  func captureStillForReading() async -> UIImage?
}

/// Shown under the sentence and used by the UI test; the same numbers go to the log.
struct ReadTiming: Equatable {
  var firstWordMs: Int
  var ocrMs: Int?
  var frameAgeMs: Int?
  var source: String

  var summary: String {
    var parts = ["First word \(firstWordMs) ms"]
    if let ocrMs { parts.append("OCR \(ocrMs) ms") }
    if let frameAgeMs { parts.append("frame \(frameAgeMs) ms old") }
    if source == "photo" { parts.append("from a photo") }
    return parts.joined(separator: ", ")
  }
}

@MainActor
@Observable
final class TextReader {
  static let shared = TextReader()

  enum Phase: Equatable {
    case idle
    /// Getting the camera going and a frame.
    case preparing
    /// OCR and the framing check.
    case recognizing
    case reading
    /// Spoke guidance instead of reading.
    case guided
    case finished
    case stopped
  }

  private(set) var phase: Phase = .idle
  private(set) var sentences: [RenderedSentence] = []
  private(set) var index = 0
  /// The last guidance or failure line, shown in large print.
  private(set) var notice: String?
  private(set) var lastTiming: ReadTiming?

  /// Set by the camera screen while it is up.
  @ObservationIgnored weak var source: (any ReadFrameSource)?

  /// A stream frame older than this isn't "the latest frame" any more. [est]
  static let maxFrameAge: TimeInterval = 1.0
  /// How long to wait for a fresh frame before falling back to a photo.
  static let frameWait: Duration = .milliseconds(1500)
  /// How long a Read trigger waits for the session and stream to come up.
  static let streamWait: Duration = .seconds(30)

  private static let tickOwner = "read"

  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared
  @ObservationIgnored private let clock = BenchClock.shared
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Bumped by every trigger, navigation and stop, so late callbacks from older speech or an
  /// older OCR run do nothing.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingFirstWord: PendingFirstWord?
  /// This page has counted towards today's progress, so hearing its end again doesn't count twice.
  @ObservationIgnored private var pageCounted = false

  private struct PendingFirstWord {
    var generation: Int
    var triggerAt: UInt64
    var ocrMs: Int?
    var frameAgeMs: Int?
    var source = "frame"
  }

  // MARK: State for the UI

  var hasSentences: Bool { !sentences.isEmpty }
  var isBusy: Bool { phase == .preparing || phase == .recognizing }
  var isActive: Bool { isBusy || phase == .reading }
  var currentSentence: RenderedSentence? { sentences.indices.contains(index) ? sentences[index] : nil }

  var statusText: String {
    switch phase {
    case .idle: "Ready to read"
    case .preparing: "Getting a picture"
    case .recognizing: "Finding text"
    case .reading: "Reading sentence \(index + 1) of \(sentences.count)"
    case .guided: notice ?? "No text read"
    case .finished: "Finished, \(sentences.count) \(sentences.count == 1 ? "sentence" : "sentences")"
    case .stopped: hasSentences ? "Stopped at sentence \(index + 1) of \(sentences.count)" : "Stopped"
    }
  }

  // MARK: Trigger

  /// Read what the glasses see. Interrupts any reading in progress.
  func read() {
    let triggerAt = BenchClock.uptimeNanoseconds()
    generation += 1
    let myGeneration = generation
    task?.cancel()
    announcer.stop()
    earcons.play(.working)
    earcons.startWorkingTick(owner: Self.tickOwner)
    pendingFirstWord = PendingFirstWord(generation: myGeneration, triggerAt: triggerAt)
    sentences = []
    index = 0
    notice = nil
    pageCounted = false
    phase = .preparing
    task = Task { await run(myGeneration) }
  }

  // MARK: Navigation

  func next() {
    guard hasSentences else { return speakNothingToNavigate() }
    if index + 1 < sentences.count {
      startSpeaking(at: index + 1)
    } else {
      generation += 1
      phase = .finished
      announcer.say(SpokenMessage.readLastSentence, kind: .reply)
    }
  }

  /// Back one sentence; on the first one, reads it again.
  func previous() {
    guard hasSentences else { return speakNothingToNavigate() }
    startSpeaking(at: max(0, index - 1))
  }

  func repeatSentence() {
    guard hasSentences else { return speakNothingToNavigate() }
    startSpeaking(at: index)
  }

  /// Stops speech and any recognition in flight. Keeps the sentences for previous/repeat.
  func stop() {
    generation += 1
    task?.cancel()
    task = nil
    pendingFirstWord = nil
    earcons.stopWorkingTick(owner: Self.tickOwner)
    announcer.stop()
    earcons.play(.ready)
    if phase != .idle { phase = .stopped }
  }

  private func speakNothingToNavigate() {
    announcer.say(SpokenMessage.readNothingToNavigate, kind: .reply)
  }

  // MARK: Pipeline

  private func run(_ myGeneration: Int) async {
    guard let source else {
      return finish(guidance: SpokenMessage.readNoCamera, earcon: .error, myGeneration)
    }
    guard await ensureStream(source, myGeneration) else { return }

    // The frame: the latest stream frame, or a photo when there's no recent one.
    var image: UIImage
    var fromPhoto = false
    if let frame = await recentFrame(source, myGeneration) {
      let ageMs = Int((BenchClock.uptimeNanoseconds() - frame.arrivedAt) / 1_000_000)
      clock.record("frame_age", ms: ageMs, detail: "size=\(Self.pixelSize(frame.image))")
      pendingFirstWord?.frameAgeMs = ageMs
      image = frame.image
    } else {
      guard isCurrent(myGeneration) else { return }
      speakInterim(SpokenMessage.readTakingPhotoNoFrame, first: "photo_notice", myGeneration)
      guard let photo = await source.captureStillForReading(), isCurrent(myGeneration) else {
        return finish(guidance: SpokenMessage.readPhotoFailed, earcon: .error, myGeneration)
      }
      image = photo
      fromPhoto = true
    }

    phase = .recognizing
    guard var recognized = await recognize(image, myGeneration) else { return }
    var verdict = FramingAdvisor.assess(recognized.page, quality: recognized.quality)

    // Small print in a stream frame: one try with the higher-resolution in-stream photo.
    if verdict == .tooSmall, !fromPhoto {
      speakInterim(SpokenMessage.readTakingPhotoSmallText, first: "photo_notice", myGeneration)
      phase = .preparing
      if let photo = await source.captureStillForReading(), isCurrent(myGeneration) {
        phase = .recognizing
        guard let again = await recognize(photo, myGeneration) else { return }
        recognized = again
        verdict = FramingAdvisor.assess(again.page, quality: again.quality)
        fromPhoto = true
      } else if !isCurrent(myGeneration) {
        return
      }
    }
    if fromPhoto { pendingFirstWord?.source = "photo" }
    clock.note("read verdict=\(verdict.logName) lines=\(recognized.page.lines.count) source=\(fromPhoto ? "photo" : "frame")")
    respond(to: recognized.page, verdict: verdict, myGeneration)
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
          speakInterim(SpokenMessage.readStartingCamera, first: "starting_camera", myGeneration)
        }
      case .blocked:
        // An alert or permission prompt is up and the camera screen says it; just stop waiting.
        endQuietly(myGeneration)
        return false
      case .unavailable(let reason):
        finish(guidance: reason, earcon: .attention, myGeneration)
        return false
      }
      if ContinuousClock.now >= deadline {
        finish(guidance: SpokenMessage.readCameraTimedOut, earcon: .error, myGeneration)
        return false
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func recentFrame(_ source: any ReadFrameSource, _ myGeneration: Int) async -> ReadFrame? {
    let deadline = ContinuousClock.now + Self.frameWait
    while isCurrent(myGeneration) {
      if let frame = source.latestReadFrame, Self.age(of: frame) <= Self.maxFrameAge { return frame }
      if ContinuousClock.now >= deadline { return nil }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }

  private func recognize(_ image: UIImage, _ myGeneration: Int) async -> RecognizedFrame? {
    let result = await Task.detached(priority: .userInitiated) { () -> Result<RecognizedFrame, any Error> in
      Result { try TextRecognizer.recognize(image) }
    }.value
    guard isCurrent(myGeneration) else { return nil }
    switch result {
    case .success(let recognized):
      clock.record(
        "ocr", ms: recognized.ocrMilliseconds,
        detail: "size=\(Int(recognized.page.imageSize.width))x\(Int(recognized.page.imageSize.height)) lines=\(recognized.page.lines.count)")
      pendingFirstWord?.ocrMs = recognized.ocrMilliseconds
      return recognized
    case .failure(let error):
      clock.note("read ocr failed: \(error.localizedDescription)")
      finish(guidance: SpokenMessage.readFailed, earcon: .error, myGeneration)
      return nil
    }
  }

  private func respond(to page: ReadPage, verdict: FramingVerdict, _ myGeneration: Int) {
    let preferences = A11yPreferences.shared
    let blocks = ReadingOrder.blocks(page.lines)
    let rendered = SentenceSplitter.sentences(blocks: blocks)
      .map { ReadSpeech.render($0, verbosity: preferences.verbosity, earconsEnabled: preferences.earconsEnabled) }
      .filter { !$0.chunks.isEmpty }

    let effective = rendered.isEmpty && !verdict.blocksReading ? FramingVerdict.noText : verdict
    let guidance = SpokenMessage.readGuidance(effective, verbosity: preferences.verbosity)
    if effective.blocksReading {
      return finish(guidance: guidance ?? SpokenMessage.readFailed, earcon: .attention, myGeneration)
    }

    earcons.stopWorkingTick(owner: Self.tickOwner)
    sentences = rendered
    notice = guidance
    if let guidance {
      // Cut off: say where and which way to turn, then read what is visible.
      announcer.announce(
        guidance, earcon: .attention, kind: .reply, interrupt: false,
        onStart: firstWordHandler(myGeneration, first: "guidance"))
    }
    speak(at: 0, interrupt: false, myGeneration)
  }

  // MARK: Speaking

  private func startSpeaking(at newIndex: Int) {
    generation += 1
    task?.cancel()
    pendingFirstWord = nil
    earcons.stopWorkingTick(owner: Self.tickOwner)
    speak(at: newIndex, interrupt: true, generation)
  }

  /// Queues sentence `at` chunk by chunk; when its last chunk finishes, the next sentence follows.
  private func speak(at sentenceIndex: Int, interrupt: Bool, _ myGeneration: Int) {
    guard sentences.indices.contains(sentenceIndex) else { return }
    index = sentenceIndex
    phase = .reading
    let chunks = sentences[sentenceIndex].chunks
    for (chunkIndex, chunk) in chunks.enumerated() {
      let isLast = chunkIndex == chunks.count - 1
      var onFinish: Announcer.Completion?
      if isLast {
        onFinish = { [weak self] finished in
          self?.sentenceEnded(sentenceIndex, finished: finished, myGeneration)
        }
      }
      let onStart = chunkIndex == 0 ? firstWordHandler(myGeneration, first: "text") : nil
      let cut = interrupt && chunkIndex == 0
      if chunk.flagged {
        announcer.announce(chunk.text, earcon: .uncertain, kind: .reply, interrupt: cut, onFinish: onFinish, onStart: onStart)
      } else {
        announcer.say(chunk.text, kind: .reply, interrupt: cut, onFinish: onFinish, onStart: onStart)
      }
    }
  }

  private func sentenceEnded(_ sentenceIndex: Int, finished: Bool, _ myGeneration: Int) {
    guard isCurrent(myGeneration) else { return }
    guard finished else {
      // Cut by something else (a photo, a status line, VoiceOver's stop).
      if phase == .reading { phase = .stopped }
      return
    }
    if sentenceIndex + 1 < sentences.count {
      speak(at: sentenceIndex + 1, interrupt: false, myGeneration)
    } else {
      phase = .finished
      announcer.announce(
        SpokenMessage.readEnd(verbosity: A11yPreferences.shared.verbosity), earcon: .done, kind: .reply, interrupt: false)
      recordFinishedPage()
    }
  }

  /// The page was read to its end, the only thing that counts as reading it. A milestone queues
  /// behind the end line, so it can't cut into the reading, and any new trigger cancels it.
  private func recordFinishedPage() {
    guard !pageCounted else { return }
    pageCounted = true
    let store = ReadingProgressStore.shared
    let milestone = store.recordPage()
    Celebrations.shared.pageRead(summary: store.summary, milestone: milestone)
    if let milestone {
      announcer.say(milestone.spokenLine, kind: .reply, interrupt: false)
    }
  }

  /// A progress line while work continues ("Taking a photo to read."). The tick keeps going.
  private func speakInterim(_ text: String, first: String, _ myGeneration: Int) {
    announcer.say(text, kind: .reply, interrupt: false, onStart: firstWordHandler(myGeneration, first: first))
  }

  /// The final line of a read that didn't produce text: guidance or a failure, never silence.
  private func finish(guidance text: String, earcon: Earcon, _ myGeneration: Int) {
    guard isCurrent(myGeneration) else { return }
    earcons.stopWorkingTick(owner: Self.tickOwner)
    notice = text
    sentences = []
    phase = .guided
    announcer.announce(text, earcon: earcon, kind: .reply, interrupt: false, onStart: firstWordHandler(myGeneration, first: "guidance"))
  }

  /// Something else on screen is speaking for this failure (an alert); stop the tick and wait.
  private func endQuietly(_ myGeneration: Int) {
    guard isCurrent(myGeneration) else { return }
    earcons.stopWorkingTick(owner: Self.tickOwner)
    pendingFirstWord = nil
    phase = .idle
  }

  // MARK: Metric

  private func firstWordHandler(_ myGeneration: Int, first: String) -> Announcer.StartHandler {
    { [weak self] startedAt in self?.firstWordSpoken(at: startedAt, generation: myGeneration, first: first) }
  }

  private func firstWordSpoken(at startedAt: UInt64, generation spokenGeneration: Int, first: String) {
    guard let pending = pendingFirstWord, pending.generation == spokenGeneration else { return }
    pendingFirstWord = nil
    let ms = Int((startedAt &- pending.triggerAt) / 1_000_000)
    clock.record(
      "trigger_to_first_word", ms: ms,
      detail: "first=\(first) source=\(pending.source) route=\(Announcer.shared.currentOutputDescription().replacingOccurrences(of: " ", with: "_"))")
    lastTiming = ReadTiming(firstWordMs: ms, ocrMs: pending.ocrMs, frameAgeMs: pending.frameAgeMs, source: pending.source)
  }

  // MARK: Helpers

  private func isCurrent(_ myGeneration: Int) -> Bool {
    myGeneration == generation && !Task.isCancelled
  }

  private static func age(of frame: ReadFrame) -> TimeInterval {
    Double(BenchClock.uptimeNanoseconds() &- frame.arrivedAt) / 1_000_000_000
  }

  private static func pixelSize(_ image: UIImage) -> String {
    "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))"
  }
}
