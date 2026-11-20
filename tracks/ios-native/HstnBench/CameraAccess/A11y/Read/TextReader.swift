/*
 * TextReader - "Read it aloud (word for word)": trigger, picture, text, then the text sentence by
 * sentence, with next / previous / repeat / stop
 *
 * Two paths, chosen per trigger:
 * - Cloud (CloudReading.isEnabled: an OpenAI key is set, "Use natural voice" is on, not under
 *   test). The page photo is sent to OpenAI to be transcribed, and the text is read with OpenAI's
 *   conversational voice. The photo and the text leave the phone for OpenAI.
 * - On the phone (no key, the user chose the phone voice, unit and UI tests, or any cloud error).
 *   Apple Vision OCR and the app's own voice; nothing leaves the phone.
 *
 * Flow for one trigger (Read button, VoiceOver "Read text", Siri "Read this with SpeakUp"):
 * 1. At once: cut whatever the app is saying, play the "working" earcon (inside the 100 ms
 *    budget) and start the working tick, so the wait is never silent.
 * 2. Make sure the stream is up; if not, take the next step (start session / preview) and wait.
 * 3. On the phone: take the latest decoded stream frame (CameraViewModel keeps it). No
 *    capturePhoto in the common case: it costs ~0.4 s on the mock and ~3.9 s measured elsewhere,
 *    while the stream frame is already there (ROADMAP phase 2, "New metric"). capturePhoto is the
 *    fallback, said out loud, when there is no frame from the last second or the text is too
 *    small in it.
 *    Cloud: always the full-resolution in-stream photo ("a photo of each page"), falling back to
 *    the latest frame if the photo fails.
 * 4. On the phone: OCR (TextRecognizer), framing check (ReadFraming). A poor frame gets spoken
 *    guidance instead of reading; a cut-off frame gets guidance, then what is visible is read.
 *    Cloud: the transcription streams in (OpenAIClient) and is split into sentences as it arrives
 *    (StreamingSentenceSplitter). A `SPEAKUP_NOTE:` reply is the model's guidance and is spoken
 *    like ours. On any cloud error: one short line, then the on-phone path for the same picture.
 * 5. On the phone: sentences go to the Announcer as replies, clause by clause, one after another.
 *    Cloud: the first sentence goes to the voice as soon as it is complete; while a sentence plays,
 *    the next one's audio is fetched (CloudSpeechClip), so there are no gaps. If the voice fails:
 *    one short line, then the rest is read with the phone's voice.
 *
 * The camera is the phone's or the glasses' (CameraSourceRouter, V0 "Glasses optional"); the
 * pipeline is the same, only the guidance wording follows `ReadFrameSource.cameraKind`.
 *
 * Text recognised elsewhere (an imported photo or PDF, notes/reach-ios.md) comes in through
 * `read(pages:source:)`: no camera, no cloud, but the same sentences, navigation, stop, end line
 * and RecentText as a camera read. Pages may arrive while earlier ones are spoken.
 *
 * Metrics (BenchClock, picked up by bench.sh): `trigger_to_first_word` from the trigger to the
 * first line of the response being heard, whatever that line is (detail `first=` says whether it
 * was text, guidance or a fallback notice; `source=` is frame, photo, cloud or cloud_fallback);
 * `ocr` for Vision alone; `frame_age` for how old the stream frame was when OCR got it;
 * `cloud_first_text` from the photo being ready to the first transcribed text arriving.
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

/// What the reader needs from a camera. CameraViewModel (glasses) and PhoneFrameSource implement
/// it; CameraSourceRouter picks between them and is what the camera screen hands the reader.
@MainActor
protocol ReadFrameSource: AnyObject {
  var latestReadFrame: ReadFrame? { get }
  /// Returns at once. May start a session or the preview as a side effect.
  func prepareStreamForReading() -> ReadStreamReadiness
  /// An in-stream photo for reading only: no preview sheet, no photo reply. nil on failure.
  func captureStillForReading() async -> UIImage?
  /// Which camera this is, so guidance fits it ("turn your head" or "move the phone").
  var cameraKind: CameraKind { get }
  /// Another camera took over: stop streaming (the session may stay).
  func stopReadingStream()
}

extension ReadFrameSource {
  var cameraKind: CameraKind { .glasses }
  func stopReadingStream() {}
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
    if source == "cloud" { parts.append("natural voice") }
    if source == "cloud_fallback" { parts.append("read on the phone") }
    return parts.joined(separator: ", ")
  }
}

/// One page of text recognised somewhere other than the camera, for `TextReader.read(pages:source:)`.
struct ReadTextPage: Sendable {
  /// Said first, as a sentence of its own ("PDF, 3 pages. Page 1.").
  var heading: String?
  /// The page's text. nil when it couldn't be read.
  var page: ReadPage?
  /// Said, with the attention earcon, when the page has no readable text ("No text on this page.").
  var emptyLine: String?
}

/// Where the text given to `TextReader.read(pages:source:)` came from.
struct ReadTextSource: Sendable {
  /// For Ask ("A photo", "A PDF").
  var title: String
  /// Said at once while the first page is still being recognised ("Reading the photo.").
  var intro: String?
  /// Said when no page gives anything to say.
  var nothingLine = SpokenMessage.readFailed
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
  /// Where each page goes for "Ask about the text": the words as spoken, never the image.
  @ObservationIgnored var recentText: RecentText = .shared

  // Cloud reading. `generation` changes with every navigation, but the transcription keeps
  // streaming across next/previous, so it checks `readID` (bumped by read() and stop()) instead.
  @ObservationIgnored private var readID = 0
  /// Non-nil while the current sentences are spoken with the cloud voice.
  @ObservationIgnored private var cloudClient: OpenAIClient?
  /// Each sentence's cloud audio, fetched once: the next one ahead of time, kept for repeats.
  @ObservationIgnored private var clips: [Int: CloudSpeechClip] = [:]
  /// The cloud transcription is still streaming, so more sentences may come.
  @ObservationIgnored private var isTranscribing = false
  /// Reading reached the last sentence so far while more were still coming.
  @ObservationIgnored private var waitingForMore = false
  /// Waits for the Announcer to go quiet, then starts the cloud voice.
  @ObservationIgnored private var speechTask: Task<Void, Never>?
  /// Pages given to read(pages:source:) all had no text: end on the last notice, not "End of text".
  @ObservationIgnored private var pagesHadNoText = false

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
    let (myGeneration, myRead) = beginRead(source: "frame")
    phase = .preparing
    task = Task { await run(myGeneration, read: myRead) }
  }

  /// Reads text that was already recognised (an imported photo or PDF), skipping the camera and
  /// the cloud. From there on it is a camera read: next, previous, repeat, stop, the end line and
  /// RecentText. Pages may still be arriving while the first ones are spoken. Interrupts any
  /// reading in progress.
  func read(pages: AsyncStream<ReadTextPage>, source: ReadTextSource) {
    let (myGeneration, myRead) = beginRead(source: "import")
    phase = .recognizing
    if let intro = source.intro { speakInterim(intro, first: "intro", myGeneration) }
    task = Task { await runPages(pages, source: source, myGeneration, read: myRead) }
  }

  func read(pages: [ReadTextPage], source: ReadTextSource) {
    read(
      pages: AsyncStream { continuation in
        for page in pages { continuation.yield(page) }
        continuation.finish()
      }, source: source)
  }

  /// Cuts what is going on and starts a new read: working earcon and tick, nothing read yet.
  private func beginRead(source: String) -> (generation: Int, read: Int) {
    let triggerAt = BenchClock.uptimeNanoseconds()
    generation += 1
    task?.cancel()
    announcer.stop()
    readID += 1
    resetCloud()
    pagesHadNoText = false
    earcons.play(.working)
    earcons.startWorkingTick(owner: Self.tickOwner)
    pendingFirstWord = PendingFirstWord(generation: generation, triggerAt: triggerAt, source: source)
    sentences = []
    index = 0
    notice = nil
    return (generation, readID)
  }

  // MARK: Navigation

  func next() {
    guard hasSentences else { return speakNothingToNavigate() }
    if index + 1 < sentences.count {
      startSpeaking(at: index + 1)
    } else if isTranscribing {
      // More text is still arriving: wait for the next sentence instead of saying "last".
      generation += 1
      speechTask?.cancel()
      announcer.stop()
      waitingForMore = true
      phase = .reading
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
    readID += 1
    task?.cancel()
    task = nil
    isTranscribing = false
    waitingForMore = false
    speechTask?.cancel()
    speechTask = nil
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

  private func run(_ myGeneration: Int, read myRead: Int) async {
    guard let source else {
      return finish(guidance: SpokenMessage.readNoCamera, earcon: .error, myGeneration)
    }
    guard await ensureStream(source, myGeneration) else { return }

    if let client = CloudReading.shared.client() {
      return await runCloud(source, client: client, myGeneration, read: myRead)
    }

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
    await recognizeAndRespond(image, fromPhoto: fromPhoto, source: source, myGeneration)
  }

  /// On-phone OCR and the framing check for `image`, then the response. Also the cloud fallback.
  private func recognizeAndRespond(
    _ image: UIImage, fromPhoto initialFromPhoto: Bool, source: any ReadFrameSource, _ myGeneration: Int
  ) async {
    var fromPhoto = initialFromPhoto
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
    if fromPhoto, pendingFirstWord?.source == "frame" { pendingFirstWord?.source = "photo" }
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
      .map { ReadSpeech.render($0, verbosity: preferences.effectiveVerbosity, earconsEnabled: preferences.earconsEnabled) }
      .filter { !$0.chunks.isEmpty }

    let effective = rendered.isEmpty && !verdict.blocksReading ? FramingVerdict.noText : verdict
    let guidance = SpokenMessage.readGuidance(effective, verbosity: preferences.effectiveVerbosity, camera: cameraKind)
    if effective.blocksReading {
      return finish(guidance: guidance ?? SpokenMessage.readFailed, earcon: .attention, myGeneration)
    }

    earcons.stopWorkingTick(owner: Self.tickOwner)
    sentences = rendered
    notice = guidance
    publishPage()
    if let guidance {
      // Cut off: say where and which way to turn, then read what is visible.
      announcer.announce(
        guidance, earcon: .attention, kind: .reply, interrupt: false,
        onStart: firstWordHandler(myGeneration, first: "guidance"))
    }
    speak(at: 0, interrupt: false, myGeneration)
  }

  // MARK: Text from elsewhere

  private func runPages(
    _ pages: AsyncStream<ReadTextPage>, source: ReadTextSource, _ myGeneration: Int, read myRead: Int
  ) async {
    let preferences = A11yPreferences.shared
    // Like a cloud transcription: sentences arrive while earlier ones are spoken.
    isTranscribing = true
    var pageNumber = 0
    var hadText = false
    for await page in pages {
      guard isCurrentRead(myRead) else { return }
      pageNumber += 1
      let words = page.page.map { SentenceSplitter.sentences(blocks: ReadingOrder.blocks($0.lines)) } ?? []
      let rendered = words
        .map { ReadSpeech.render($0, verbosity: preferences.effectiveVerbosity, earconsEnabled: preferences.earconsEnabled) }
        .filter { !$0.chunks.isEmpty }
      if let heading = page.heading { addSentence(Self.noticeSentence(heading)) }
      guard !rendered.isEmpty else {
        if let line = page.emptyLine { addSentence(Self.noticeSentence(line, earcon: .attention)) }
        continue
      }
      hadText = true
      // One passage per page, as spoken: withheld numbers stay withheld.
      recentText.append(
        rendered.map(Self.spokenText).joined(separator: " "), source: .read, key: "read-\(myRead)-\(pageNumber)")
      recentText.setTitle(source.title, source: .read)
      for sentence in rendered { addSentence(sentence) }
    }
    guard isCurrentRead(myRead) else { return }
    isTranscribing = false
    clock.note("read pages=\(pageNumber) sentences=\(sentences.count) text=\(hadText)")
    guard !sentences.isEmpty else {
      return finish(guidance: source.nothingLine, earcon: .attention, generation)
    }
    pagesHadNoText = !hadText
    guard waitingForMore else { return }
    // The voice was waiting at the last sentence: that was all of it.
    waitingForMore = false
    readFinished()
  }

  /// A line that isn't page text (a page heading, "No text on this page."), as a sentence.
  private static func noticeSentence(_ line: String, earcon: Earcon? = nil) -> RenderedSentence {
    RenderedSentence(
      display: line, chunks: [SpokenChunk(text: line, flagged: false)], uncertainWords: 0, withheld: nil, isNotice: true,
      earcon: earcon)
  }

  // MARK: Speaking

  private func startSpeaking(at newIndex: Int) {
    generation += 1
    // A cloud transcription still streaming keeps going: navigation only changes what is spoken.
    if !isTranscribing { task?.cancel() }
    waitingForMore = false
    speechTask?.cancel()
    pendingFirstWord = nil
    earcons.stopWorkingTick(owner: Self.tickOwner)
    speak(at: newIndex, interrupt: true, generation)
  }

  /// Queues sentence `at` chunk by chunk; when its last chunk finishes, the next sentence follows.
  private func speak(at sentenceIndex: Int, interrupt: Bool, _ myGeneration: Int) {
    guard sentences.indices.contains(sentenceIndex) else { return }
    index = sentenceIndex
    phase = .reading
    let sentence = sentences[sentenceIndex]
    recentText.setCurrent(sentence.isNotice ? nil : Self.spokenText(sentence), source: .read)
    if let cloudClient {
      return speakCloud(at: sentenceIndex, interrupt: interrupt, client: cloudClient, myGeneration)
    }
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
      if chunkIndex == 0, let earcon = sentences[sentenceIndex].earcon {
        announcer.announce(chunk.text, earcon: earcon, kind: .reply, interrupt: cut, onFinish: onFinish, onStart: onStart)
      } else if chunk.flagged {
        announcer.announce(chunk.text, earcon: .uncertain, kind: .reply, interrupt: cut, onFinish: onFinish, onStart: onStart)
      } else {
        announcer.say(chunk.text, kind: .reply, interrupt: cut, onFinish: onFinish, onStart: onStart)
      }
    }
  }

  private func sentenceEnded(_ sentenceIndex: Int, finished: Bool, _ myGeneration: Int) {
    guard isCurrent(myGeneration) else { return }
    guard finished else {
      // Cut by something else (a status line, VoiceOver's stop).
      if phase == .reading { phase = .stopped }
      return
    }
    if sentenceIndex + 1 < sentences.count {
      speak(at: sentenceIndex + 1, interrupt: false, myGeneration)
    } else if isTranscribing {
      // The voice caught up with the transcription; addCloudSentence carries on.
      waitingForMore = true
    } else {
      readFinished()
    }
  }

  /// The last sentence was spoken: "End of text", or, when no imported page had text, end on its
  /// notice as guidance.
  private func readFinished() {
    recentText.setCurrent(nil, source: .read)
    if pagesHadNoText {
      notice = sentences.last?.display
      phase = .guided
      return
    }
    phase = .finished
    announcer.announce(
      SpokenMessage.readEnd(verbosity: A11yPreferences.shared.effectiveVerbosity), earcon: .done, kind: .reply, interrupt: false)
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

  // MARK: Cloud

  /// Photo, streamed transcription, sentences to the cloud voice as they complete.
  private func runCloud(_ source: any ReadFrameSource, client: OpenAIClient, _ myGeneration: Int, read myRead: Int) async {
    pendingFirstWord?.source = "cloud"
    // A photo per page, as asked; the latest stream frame if the photo fails.
    let photo = await source.captureStillForReading()
    guard isCurrent(myGeneration) else { return }
    let image: UIImage
    let fromPhoto: Bool
    if let photo {
      image = photo
      fromPhoto = true
    } else {
      clock.note("read cloud photo failed, using the stream frame")
      var frame = source.latestReadFrame
      if frame == nil { frame = await recentFrame(source, myGeneration) }
      guard let frame, isCurrent(myGeneration) else {
        return finish(guidance: SpokenMessage.readPhotoFailed, earcon: .error, myGeneration)
      }
      image = frame.image
      fromPhoto = false
    }

    phase = .recognizing
    let photoReadyAt = BenchClock.uptimeNanoseconds()
    let jpeg = await Task.detached(priority: .userInitiated) { CloudImage.jpeg(image) }.value
    guard isCurrent(myGeneration) else { return }
    guard let jpeg else {
      return await readOnPhoneInstead(image, fromPhoto: fromPhoto, source: source, reason: "jpeg")
    }

    cloudClient = client
    isTranscribing = true
    var splitter = StreamingSentenceSplitter()
    var heardFirstText = false
    do {
      for try await delta in client.transcriptionDeltas(jpeg: jpeg) {
        guard isCurrentRead(myRead) else { return }
        if !heardFirstText {
          heardFirstText = true
          clock.record(
            "cloud_first_text", ms: Self.milliseconds(since: photoReadyAt),
            detail: "size=\(Self.pixelSize(image)) source=\(fromPhoto ? "photo" : "frame")")
        }
        for sentence in splitter.append(delta) { addCloudSentence(sentence) }
      }
      guard isCurrentRead(myRead) else { return }
      for sentence in splitter.finish() { addCloudSentence(sentence) }
    } catch {
      guard isCurrentRead(myRead), !(error is CancellationError) else { return }
      let reason = (error as? OpenAIError)?.logName ?? "unknown"
      return await readOnPhoneInstead(image, fromPhoto: fromPhoto, source: source, reason: reason)
    }
    isTranscribing = false
    transcriptionFinished(note: splitter.note)
  }

  /// A sentence from the stream: the first one starts the voice at once; later ones continue a
  /// voice that caught up, or have their audio fetched ahead while the one before plays.
  private func addCloudSentence(_ text: String) {
    let preferences = A11yPreferences.shared
    let rendered = CloudSentence.rendered(text, verbosity: preferences.effectiveVerbosity, earconsEnabled: preferences.earconsEnabled)
    guard !rendered.chunks.isEmpty else { return }
    if sentences.isEmpty { clock.note("read verdict=cloud") }
    addSentence(rendered)
    publishPage()
  }

  /// A sentence that arrived while reading (cloud stream, imported pages): the first one starts
  /// the voice at once; later ones continue a voice that caught up, or have their cloud audio
  /// fetched ahead while the one before plays.
  private func addSentence(_ rendered: RenderedSentence) {
    sentences.append(rendered)
    let newIndex = sentences.count - 1
    if newIndex == 0 {
      earcons.stopWorkingTick(owner: Self.tickOwner)
      speak(at: 0, interrupt: false, generation)
    } else if waitingForMore {
      waitingForMore = false
      speak(at: newIndex, interrupt: false, generation)
    } else if newIndex == index + 1, phase == .reading, let cloudClient {
      _ = clip(at: newIndex, client: cloudClient)
    }
  }

  private func transcriptionFinished(note: String?) {
    let preferences = A11yPreferences.shared
    if sentences.isEmpty {
      // The model's own hint (SPEAKUP_NOTE), or ours when it sent nothing readable.
      clock.note("read cloud no_text note=\(note != nil)")
      let guidance =
        note ?? SpokenMessage.readGuidance(.noText, verbosity: preferences.effectiveVerbosity, camera: cameraKind) ?? SpokenMessage.readFailed
      return finish(guidance: guidance, earcon: .attention, generation)
    }
    clock.note("read cloud sentences=\(sentences.count)")
    guard waitingForMore else { return }
    // The voice was waiting at the last sentence: that was all of it.
    waitingForMore = false
    readFinished()
  }

  /// Any transcription error: one short line, then the on-phone path for the same picture. If the
  /// stream broke part way, the phone reads the page from the start.
  private func readOnPhoneInstead(_ image: UIImage, fromPhoto: Bool, source: any ReadFrameSource, reason: String) async {
    clock.note("read cloud failed reason=\(reason), reading on the phone")
    if !sentences.isEmpty {
      generation += 1
      announcer.stop()
      sentences = []
      index = 0
      pendingFirstWord = nil
    }
    resetCloud()
    let myGeneration = generation
    pendingFirstWord?.source = "cloud_fallback"
    earcons.startWorkingTick(owner: Self.tickOwner)
    speakInterim(SpokenMessage.readCloudFallback, first: "cloud_fallback", myGeneration)
    await recognizeAndRespond(image, fromPhoto: fromPhoto, source: source, myGeneration)
  }

  /// Plays sentence `at` with the cloud voice once the Announcer is quiet (a progress line may
  /// still be playing), fetching the next sentence's audio meanwhile.
  private func speakCloud(at sentenceIndex: Int, interrupt: Bool, client: OpenAIClient, _ myGeneration: Int) {
    let current = clip(at: sentenceIndex, client: client)
    if sentenceIndex + 1 < sentences.count { _ = clip(at: sentenceIndex + 1, client: client) }
    if interrupt { announcer.stop() }  // Also stops the cloud voice.
    let onStart = firstWordHandler(myGeneration, first: "text")
    speechTask?.cancel()
    speechTask = Task { [weak self] in
      guard let self else { return }
      while self.announcer.isSpeaking, self.generation == myGeneration, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(30))
      }
      guard self.generation == myGeneration, !Task.isCancelled else { return }
      CloudVoicePlayer.shared.play(current, onStart: onStart) { [weak self] end in
        self?.cloudSentenceEnded(sentenceIndex, end: end, myGeneration)
      }
    }
  }

  private func cloudSentenceEnded(_ sentenceIndex: Int, end: CloudVoicePlayer.End, _ myGeneration: Int) {
    guard myGeneration == generation else { return }
    switch end {
    case .finished: sentenceEnded(sentenceIndex, finished: true, myGeneration)
    case .cancelled: sentenceEnded(sentenceIndex, finished: false, myGeneration)
    case .failed: cloudVoiceFailed(at: sentenceIndex, myGeneration)
    }
  }

  /// The cloud voice failed on a sentence: one short line, then the phone's voice from there on
  /// (the transcription, if still streaming, carries on).
  private func cloudVoiceFailed(at sentenceIndex: Int, _ myGeneration: Int) {
    clock.note("read cloud voice failed at sentence \(sentenceIndex + 1), using the phone voice")
    cloudClient = nil
    for clip in clips.values { clip.cancel() }
    clips = [:]
    pendingFirstWord?.source = "cloud_fallback"
    announcer.say(
      SpokenMessage.readCloudFallback, kind: .reply, interrupt: false,
      onStart: firstWordHandler(myGeneration, first: "cloud_fallback"))
    speak(at: sentenceIndex, interrupt: false, myGeneration)
  }

  /// The sentence's cloud audio: kept from before, or fetched now. A failed fetch is retried.
  private func clip(at sentenceIndex: Int, client: OpenAIClient) -> CloudSpeechClip {
    if let clip = clips[sentenceIndex], clip.failure == nil { return clip }
    let clip = CloudSpeechClip(text: CloudSentence.speechText(sentences[sentenceIndex]), client: client)
    clips[sentenceIndex] = clip
    return clip
  }

  private func resetCloud() {
    speechTask?.cancel()
    speechTask = nil
    for clip in clips.values { clip.cancel() }
    clips = [:]
    cloudClient = nil
    isTranscribing = false
    waitingForMore = false
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

  // MARK: Ask about the text

  /// The page read so far, as one passage per read (a cloud page grows as it streams in).
  private func publishPage() {
    let text = sentences.filter { !$0.isNotice }.map(Self.spokenText).joined(separator: " ")
    recentText.append(text, source: .read, key: "read-\(readID)")
  }

  /// A sentence as it is spoken: withheld numbers stay withheld.
  static func spokenText(_ sentence: RenderedSentence) -> String {
    sentence.chunks.map(\.text).joined(separator: " ")
  }

  // MARK: Helpers

  /// The camera being read from, for guidance wording.
  private var cameraKind: CameraKind { source?.cameraKind ?? .glasses }

  private func isCurrent(_ myGeneration: Int) -> Bool {
    myGeneration == generation && !Task.isCancelled
  }

  /// For the cloud transcription, which outlives navigation (see `readID`).
  private func isCurrentRead(_ myRead: Int) -> Bool {
    myRead == readID && !Task.isCancelled
  }

  private static func milliseconds(since start: UInt64) -> Int {
    Int((BenchClock.uptimeNanoseconds() &- start) / 1_000_000)
  }

  private static func age(of frame: ReadFrame) -> TimeInterval {
    Double(BenchClock.uptimeNanoseconds() &- frame.arrivedAt) / 1_000_000_000
  }

  private static func pixelSize(_ image: UIImage) -> String {
    "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))"
  }
}
