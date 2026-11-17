/*
 * Conversation - "talk to me": a spoken back-and-forth about the page, with OpenAI Realtime
 *
 * Opened by voice ("talk", "let's talk", "I have a question") or the Talk button. While it runs,
 * Realtime owns the phone mic: VoiceControl's command listener is paused, and the model decides
 * when the user has finished a turn (semantic VAD). The user can talk over a reply; it stops
 * within one audio buffer and the model's history is cut to what was heard.
 *
 * It ends when:
 * - the user says goodbye (the model calls end_conversation after saying goodbye);
 * - the Talk button is pressed again, or the screen goes away;
 * - nobody speaks for RealtimeConfig.idleTimeout after a reply;
 * - the network or the key fails. Each failure is spoken in the app's own voice, then the command
 *   listener comes back, so the app is never left deaf.
 *
 * Needs an OpenAI key (the same one cloud reading uses: Keychain, then Secrets.xcconfig). Without
 * one, "talk" says how to add one instead of failing silently. Off under automated tests.
 */

import Foundation
import Observation
import os

@MainActor
@Observable
final class Conversation {
  static let shared = Conversation()

  enum Phase: Equatable {
    case idle
    case connecting
    case listening
    case replying
  }

  private(set) var phase: Phase = .idle
  /// The last thing each side said, for the screen (large print, VoiceOver).
  private(set) var userLine = ""
  private(set) var assistantLine = ""

  var isActive: Bool { phase != .idle }

  /// Pause or resume the command listener. Replaceable for tests.
  @ObservationIgnored var setCommandListenerPaused: (Bool) -> Void = { VoiceControl.shared.noteConversation($0) }
  /// Speak a line in the app's own voice.
  @ObservationIgnored var say: (String) -> Void = { Announcer.shared.say($0) }
  /// The page read last, as plain text, or nil.
  @ObservationIgnored var currentPageText: () -> String? = {
    let sentences = TextReader.shared.sentences.map(\.display)
    return sentences.isEmpty ? nil : sentences.joined(separator: " ")
  }
  /// Before the mic opens: stop a read and the app's own voice, so nothing talks over the model.
  @ObservationIgnored var quietOtherSpeech: () -> Void = {
    if TextReader.shared.isActive { TextReader.shared.stop() }
    Announcer.shared.stop()
  }

  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var urlSession: URLSession?
  @ObservationIgnored private var audio: RealtimeAudio?
  @ObservationIgnored private var playback = RealtimePlayback()
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private var endingAfterReply = false
  /// Bumped per conversation so late callbacks from an old socket are ignored.
  @ObservationIgnored private var generation = 0

  private nonisolated static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "Realtime")

  // MARK: - Start / stop

  /// The key, if conversation can run here.
  static func availableKey() -> String? {
    guard !LaunchOptions.isAutomatedTest else { return nil }
    return OpenAIKey.resolve(store: KeychainKeyStore(), infoDictionary: Bundle.main.infoDictionary)
  }

  func toggle() {
    isActive ? end(reason: "button") : start()
  }

  func start() {
    guard phase == .idle else { return }
    guard let key = Self.availableKey() else {
      say(SpokenMessage.conversationNeedsKey)
      return
    }
    guard let url = RealtimeConfig.url() else { return }

    generation += 1
    let current = generation
    phase = .connecting
    userLine = ""
    assistantLine = ""
    playback.reset()
    endingAfterReply = false
    // No "starting" line: the model's own greeting, a second or so later, says it's listening.
    quietOtherSpeech()
    setCommandListenerPaused(true)

    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    let socket = session.webSocketTask(with: request)
    urlSession = session
    self.socket = socket
    socket.resume()

    let page = currentPageText()
    send(RealtimeOutgoing.sessionUpdate(pageText: page))
    send(RealtimeOutgoing.greeting(hasPage: RealtimeOutgoing.trimmedPage(page) != nil))
    receive(on: socket, generation: current)

    let audio = RealtimeAudio()
    audio.onMicChunk = { [weak self] chunk in
      Task { @MainActor in self?.sendMic(chunk, generation: current) }
    }
    self.audio = audio
    Task {
      let started = await audio.start()
      guard current == generation else { return }
      if !started { fail(.network, spoken: SpokenMessage.conversationNoMic) }
    }
  }

  /// Ends now and speaks `line` in the app's voice (nil after the model's own goodbye).
  func end(reason: String, line: String? = SpokenMessage.conversationEnded) {
    guard phase != .idle else { return }
    Self.logger.info("conversation end: \(reason, privacy: .public)")
    generation += 1
    idleTask?.cancel()
    idleTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    audio?.flush()
    audio?.stop()
    audio = nil
    phase = .idle
    if let line { say(line) }
    // Give the session a moment to hand the mic back before commands listen again.
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      setCommandListenerPaused(false)
    }
  }

  // MARK: - Socket

  private func send(_ event: [String: Any]) {
    guard let socket, let text = RealtimeOutgoing.encode(event) else { return }
    socket.send(.string(text)) { error in
      if let error { Self.logger.error("send failed: \(error.localizedDescription)") }
    }
  }

  private func sendMic(_ chunk: Data, generation current: Int) {
    guard current == generation, phase != .connecting else { return }
    send(RealtimeOutgoing.appendAudio(chunk))
  }

  private func receive(on socket: URLSessionWebSocketTask, generation current: Int) {
    socket.receive { [weak self] result in
      Task { @MainActor in
        guard let self, current == self.generation else { return }
        switch result {
        case .success(.string(let text)):
          self.handle(RealtimeEvent.parse(text))
          self.receive(on: socket, generation: current)
        case .success:
          self.receive(on: socket, generation: current)
        case .failure(let error):
          Self.logger.error("socket closed: \(error.localizedDescription)")
          let mapped = Self.closeReason(socket)
          self.fail(mapped, spoken: mapped == .unauthorized ? SpokenMessage.conversationKeyRefused : SpokenMessage.conversationLost)
        }
      }
    }
  }

  /// A refused key shows up as an HTTP 401 on the upgrade, not as an error event.
  private static func closeReason(_ socket: URLSessionWebSocketTask) -> OpenAIError {
    if let response = socket.response as? HTTPURLResponse, response.statusCode >= 400 {
      return OpenAIError.from(status: response.statusCode)
    }
    return .network
  }

  // MARK: - Events

  private func handle(_ event: RealtimeEvent) {
    switch event {
    case .sessionReady:
      if phase == .connecting { phase = .listening }
    case .speechStarted:
      idleTask?.cancel()
      if phase == .replying { bargeIn() }
      phase = .listening
    case .speechStopped:
      break
    case .userTranscript(let text):
      if !text.isEmpty { userLine = text }
    case .audioDelta(let itemID, let pcm):
      if phase != .replying {
        phase = .replying
        assistantLine = ""
      }
      idleTask?.cancel()
      playback.queued(itemID: itemID, bytes: pcm.count)
      audio?.play(pcm)
    case .assistantTranscriptDelta(let delta):
      assistantLine += delta
    case .assistantTranscriptDone(let text):
      if !text.isEmpty { assistantLine = text }
    case .responseDone:
      afterReply()
    case .functionCall(let name, let callID):
      guard name == RealtimeConfig.endToolName else { return }
      send(RealtimeOutgoing.functionOutput(callID: callID))
      endingAfterReply = true
      afterReply()
    case .failed(let error):
      Self.logger.error("realtime error: \(error.logName, privacy: .public)")
      switch error {
      case .unauthorized: fail(error, spoken: SpokenMessage.conversationKeyRefused)
      case .rateLimited: fail(error, spoken: SpokenMessage.conversationOutOfCredit)
      default: break  // A bad event doesn't end the conversation; the socket closing does.
      }
    case .other:
      break
    }
  }

  /// The user spoke over the reply: stop it and tell the model how much was heard.
  private func bargeIn() {
    let unheard = audio?.flush() ?? 0
    if let itemID = playback.itemID {
      send(RealtimeOutgoing.truncate(itemID: itemID, audioEndMs: playback.heardMs(unplayedBytes: unheard)))
    }
    playback.reset()
  }

  /// Waits for the reply's audio to finish playing, then either ends (after goodbye) or starts
  /// the idle timer.
  private func afterReply() {
    let current = generation
    idleTask?.cancel()
    idleTask = Task { [weak self] in
      while let self, current == self.generation, (self.audio?.unplayedBytes ?? 0) > 0 {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let self, current == self.generation, !Task.isCancelled else { return }
      if self.endingAfterReply {
        self.end(reason: "goodbye", line: nil)
        return
      }
      self.phase = .listening
      try? await Task.sleep(for: .seconds(RealtimeConfig.idleTimeout))
      guard current == self.generation, !Task.isCancelled else { return }
      self.end(reason: "idle")
    }
  }

  private func fail(_ error: OpenAIError, spoken: String) {
    guard phase != .idle else { return }
    end(reason: "error_\(error.logName)", line: spoken)
  }
}
