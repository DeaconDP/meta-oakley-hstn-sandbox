/*
 * Announcer - every sentence the app speaks to the user goes through here
 *
 * Two outputs, one voice at a time (notes/a11y-perception-stack.md, "TTS"):
 * - Short status lines go to VoiceOver as announcements when it is running and the user hasn't
 *   picked the app's own voice. VoiceOver then speaks them in the user's voice and rate.
 * - Everything else (replies, and status without VoiceOver) uses this class's AVSpeechSynthesizer.
 *   With VoiceOver running it takes VoiceOver's voice and rate via
 *   prefersAssistiveTechnologySettings; otherwise the rate from A11yPreferences.
 * Replies never go through VoiceOver announcements: those can't be stopped or streamed, and the
 * phone may be in a pocket with VoiceOver focused elsewhere.
 *
 * Lines play strictly in call order from one queue: an earcon lead-in, then the line, then the
 * next line only once this one has finished (synthesizer callback, or VoiceOver's
 * announcement-did-finish notification). `interrupt: true` drops everything queued or playing.
 *
 * The synthesizer shares A11yAudioSession with the earcons (separate from TtsReply's), so speech
 * ducks other audio and the session is released once nothing is speaking.
 */

import AVFoundation
import Observation
import UIKit

enum AnnouncementKind: Sendable {
  /// Short state lines ("Connected", "Ready"). May go through VoiceOver.
  case status
  /// Answers and descriptions. Always the app's own synthesizer, so stop() can cut them.
  case reply
}

@MainActor
@Observable
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = Announcer()

  /// Called once per line: `true` when it was spoken to the end, `false` when it was cut by an
  /// interrupt or stop(), dropped (empty text), or the engine reported a cancel.
  typealias Completion = @MainActor (_ finished: Bool) -> Void

  /// Where a line is spoken. Pure, so the routing rule is unit-testable.
  enum Output: Equatable, Sendable {
    case voiceOver
    case ownVoice(prefersAssistiveTechnologySettings: Bool)

    static func choose(kind: AnnouncementKind, voiceOverRunning: Bool, useAppVoice: Bool) -> Output {
      if voiceOverRunning, !useAppVoice {
        return kind == .status ? .voiceOver : .ownVoice(prefersAssistiveTechnologySettings: true)
      }
      return .ownVoice(prefersAssistiveTechnologySettings: false)
    }
  }

  /// True while anything is queued, waiting on an earcon, or being spoken, by the app's voice or
  /// by VoiceOver.
  private(set) var isSpeaking = false

  /// The last text passed to say() or announce(), for a "repeat" command.
  private(set) var lastSpoken: String?

  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private let audio = A11yAudioSession.shared
  @ObservationIgnored private let preferences = A11yPreferences.shared
  // Looked up once; the lookup is slow enough to delay the first word.
  @ObservationIgnored private lazy var voice: AVSpeechSynthesisVoice? = {
    let language = AVSpeechSynthesisVoice.currentLanguageCode()
    // The app's strings are English, so a non-English system language still gets an English voice.
    return AVSpeechSynthesisVoice(language: language.hasPrefix("en") ? language : "en-US")
  }()

  private struct Line {
    let text: String
    let kind: AnnouncementKind
    let earcon: Earcon?
    /// VoiceOver only: cut VoiceOver's current speech instead of queueing behind it.
    let interruptVoiceOver: Bool
    let onFinish: Completion?
  }

  @ObservationIgnored private var queue: [Line] = []
  @ObservationIgnored private var current: Line?
  @ObservationIgnored private var runner: Task<Void, Never>?
  /// Bumped by every interrupt, so a cancelled runner never touches the state of its successor.
  @ObservationIgnored private var generation = 0
  /// Resumed when the line now playing ends. Single-shot; see finishCurrent(_:).
  @ObservationIgnored private var waiter: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var waiterToken = 0
  @ObservationIgnored private var currentUtteranceTag: Int?
  @ObservationIgnored private var currentAnnouncement: String?
  @ObservationIgnored private var nextTag = 0
  /// Whether this class holds A11yAudioSession's speech hold (balanced begin/end).
  @ObservationIgnored private var holdsSession = false

  private override init() {
    super.init()
    synthesizer.delegate = self
    NotificationCenter.default.addObserver(
      forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let text = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
      let success = notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool ?? true
      MainActor.assumeIsolated { self?.announcementFinished(text: text, success: success) }
    }
  }

  // MARK: Speaking

  /// Speaks `text`. `interrupt: true` cuts whatever the app is saying or has queued (and, for
  /// VoiceOver announcements, VoiceOver's current speech). `interrupt: false` waits until every
  /// line before it, including a pending announce() earcon, has finished.
  func say(_ text: String, kind: AnnouncementKind = .status, interrupt: Bool = true, onFinish: Completion? = nil) {
    enqueue(Line(text: text, kind: kind, earcon: nil, interruptVoiceOver: interrupt, onFinish: onFinish), interrupt: interrupt)
  }

  /// Plays `earcon`, then speaks `text` once the tone has finished, so they don't overlap. Queues
  /// like say(): with `interrupt: false` the earcon too waits for the lines before it.
  /// With earcons off (or `earcon` nil) this is just say().
  func announce(
    _ text: String, earcon: Earcon?, kind: AnnouncementKind = .status, interrupt: Bool = true, onFinish: Completion? = nil
  ) {
    enqueue(Line(text: text, kind: kind, earcon: earcon, interruptVoiceOver: interrupt, onFinish: onFinish), interrupt: interrupt)
  }

  /// Barge-in: stops the app's own voice immediately and drops everything queued, calling their
  /// completions with `false`. Doesn't stop the working tick (EarconPlayer owns it) or a
  /// VoiceOver announcement already handed over (the user stops those with VoiceOver's
  /// two-finger tap).
  func stop() {
    cancelAll()
    releaseSessionIfIdle()
  }

  /// Speaks the last text again, interrupting.
  func repeatLast() {
    guard let lastSpoken else { return }
    say(lastSpoken, kind: .reply)
  }

  /// Where speech will be heard: "glasses", "headphones" or "phone speaker".
  func currentOutputDescription() -> String {
    A11yAudioSession.outputDescription()
  }

  /// Upper bound on waiting for VoiceOver's did-finish notification, which isn't guaranteed (for
  /// example if VoiceOver is turned off mid-line). Generous: it only stops the queue from sticking.
  nonisolated static func voiceOverTimeout(for text: String) -> TimeInterval {
    let words = text.split(whereSeparator: \.isWhitespace).count
    return min(30, 2 + Double(words) * 0.5)
  }

  // MARK: Queue

  private func enqueue(_ line: Line, interrupt: Bool) {
    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      line.onFinish?(false)
      return
    }
    if interrupt { cancelAll() }
    lastSpoken = text
    queue.append(Line(text: text, kind: line.kind, earcon: line.earcon, interruptVoiceOver: line.interruptVoiceOver, onFinish: line.onFinish))
    if runner == nil {
      let myGeneration = generation
      runner = Task { await runQueue(generation: myGeneration) }
    }
    updateIsSpeaking()
  }

  private func runQueue(generation myGeneration: Int) async {
    while generation == myGeneration, !queue.isEmpty {
      let line = queue.removeFirst()
      current = line
      let finished = await play(line)
      guard generation == myGeneration else { return }  // cancelAll() already completed `line`
      current = nil
      line.onFinish?(finished)
    }
    guard generation == myGeneration else { return }
    runner = nil
    releaseSessionIfIdle()
  }

  /// Plays one line and returns once it has ended. `false` if it was cut.
  private func play(_ line: Line) async -> Bool {
    let myGeneration = generation
    if let earcon = line.earcon, preferences.earconsEnabled {
      EarconPlayer.shared.play(earcon)
      try? await Task.sleep(for: .seconds(earcon.duration + 0.06))
      guard generation == myGeneration else { return false }
    }
    let output = Output.choose(
      kind: line.kind, voiceOverRunning: UIAccessibility.isVoiceOverRunning, useAppVoice: preferences.useAppVoice)
    switch output {
    case .voiceOver:
      // The app's own voice is idle here (the queue is serial), so nothing talks over this.
      let announcement = NSAttributedString(
        string: line.text,
        attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: !line.interruptVoiceOver)])
      currentAnnouncement = line.text
      return await waitForEnd(timeout: Self.voiceOverTimeout(for: line.text)) {
        UIAccessibility.post(notification: .announcement, argument: announcement)
      }
    case .ownVoice(let prefersAssistive):
      if !holdsSession {
        holdsSession = true
        await runOnAudioQueue { $0.beginSpeech() }
        guard generation == myGeneration else { return false }
      }
      let utterance = TaggedUtterance(string: line.text)
      nextTag += 1
      utterance.tag = nextTag
      if prefersAssistive {
        // VoiceOver's voice, rate and pitch override the utterance's own.
        utterance.prefersAssistiveTechnologySettings = true
      } else {
        utterance.voice = voice
        utterance.rate = preferences.speechRate
      }
      currentUtteranceTag = utterance.tag
      return await waitForEnd(timeout: nil) { synthesizer.speak(utterance) }
    }
  }

  /// Runs `start`, then suspends until finishCurrent(_:) or the timeout (which counts as finished:
  /// VoiceOver most likely spoke it and just didn't report).
  private func waitForEnd(timeout: TimeInterval?, start: () -> Void) async -> Bool {
    waiterToken += 1
    let token = waiterToken
    if let timeout {
      Task {
        try? await Task.sleep(for: .seconds(timeout))
        if waiterToken == token { finishCurrent(true) }
      }
    }
    return await withCheckedContinuation { continuation in
      waiter = continuation
      start()
    }
  }

  private func finishCurrent(_ finished: Bool) {
    currentUtteranceTag = nil
    currentAnnouncement = nil
    waiterToken += 1
    let pending = waiter
    waiter = nil
    pending?.resume(returning: finished)
  }

  /// Drops the queue and the line now playing, completing each with `false`.
  private func cancelAll() {
    generation += 1
    runner?.cancel()
    runner = nil
    let dropped = (current.map { [$0] } ?? []) + queue
    current = nil
    queue.removeAll()
    if currentUtteranceTag != nil || synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    finishCurrent(false)
    updateIsSpeaking()
    for line in dropped { line.onFinish?(false) }
  }

  /// Hands the speech hold back once nothing is queued, so the session can idle out and ducked
  /// audio returns.
  private func releaseSessionIfIdle() {
    updateIsSpeaking()
    guard holdsSession, runner == nil else { return }
    holdsSession = false
    let audio = audio
    audio.queue.async { audio.endSpeech() }
  }

  private func updateIsSpeaking() {
    let speaking = runner != nil || current != nil || !queue.isEmpty
    if speaking != isSpeaking { isSpeaking = speaking }
  }

  private func runOnAudioQueue(_ work: @escaping @Sendable (A11yAudioSession) -> Void) async {
    let audio = audio
    await withCheckedContinuation { continuation in
      audio.queue.async {
        work(audio)
        continuation.resume()
      }
    }
  }

  private func utteranceEnded(tag: Int, finished: Bool) {
    guard tag == currentUtteranceTag else { return }
    finishCurrent(finished)
  }

  private func announcementFinished(text: String?, success: Bool) {
    guard let currentAnnouncement, text == nil || text == currentAnnouncement else { return }
    finishCurrent(success)
  }

  // MARK: AVSpeechSynthesizerDelegate

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let tag = (utterance as? TaggedUtterance)?.tag else { return }
    Task { @MainActor in self.utteranceEnded(tag: tag, finished: true) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    guard let tag = (utterance as? TaggedUtterance)?.tag else { return }
    Task { @MainActor in self.utteranceEnded(tag: tag, finished: false) }
  }
}

/// Carries an id through the delegate callbacks. Matching on the object's address instead could
/// confuse a late callback for a cancelled utterance with a new one allocated at the same address.
private final class TaggedUtterance: AVSpeechUtterance {
  var tag = 0
}
