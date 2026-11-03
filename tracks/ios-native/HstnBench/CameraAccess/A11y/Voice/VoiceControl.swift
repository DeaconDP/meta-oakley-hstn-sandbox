/*
 * VoiceControl - runs the app by speaking: picks a listener, keeps it alive, acts on commands
 *
 * The UI binds to `status`, `reason`, `activeListener`, `lastCommand`, `isEnabled` and
 * `availableCommands`. Screens register what commands do with setScreen(_:handler:), calling the
 * same actions as Siri, Magic Tap and the actions rotor; what is the same on every screen (help,
 * stop, repeat, faster, slower) lives here.
 *
 * Which listener: VoiceListenerPolicy. Glasses during a STARTED session with the wearable mic
 * granted, otherwise the phone. reconcile() is the one place that applies the decision, and every
 * change of input calls it. A recording, the background, or a call pauses listening; the first two
 * also matter for privacy and for the audio session, which a recording must find free.
 *
 * Privacy: on-device recognition only. Transcripts are parsed and dropped. Only command names are
 * kept (`lastCommand`) or logged.
 *
 * Tests: `--ui-testing` and hosted unit tests make the shared instance inert: no permission prompt,
 * no mic. inject(transcript:) is the seam for driving commands; unit tests also build their own
 * instance with fakes through Environment.
 */

import AVFoundation
import MWDATCore
import Observation
import Speech
import UIKit
import os

@MainActor
@Observable
final class VoiceControl {
  static let shared = VoiceControl(environment: .live, preferences: .shared)

  enum Status: String, Sendable {
    case off
    case starting
    case listening
    case paused
    case unavailable
  }

  /// What everything else needs from the world, so tests can stand in for it.
  struct Environment {
    /// Never prompts and never opens a mic. Transcripts can still be injected.
    var isInert: Bool
    var makePhoneListener: @MainActor (_ localeIdentifier: String) -> (any SpeechListener)?
    var phoneLocale: @MainActor () -> String?
    var phoneMicPermission: @MainActor () -> VoicePermission
    var speechPermission: @MainActor () -> VoicePermission
    var requestPermissions: @MainActor () async -> Void
    var say: @MainActor (_ text: String, _ earcon: Earcon?, _ interrupt: Bool, _ onFinish: Announcer.Completion?) -> Void
    var playEarcon: @MainActor (Earcon) -> Void
    var isSpeaking: @MainActor () -> Bool
    var textBeingSpoken: @MainActor () -> String
    var stopSpeech: @MainActor () -> Void
    var repeatLast: @MainActor () -> Void
    var hasReadSentences: @MainActor () -> Bool
    /// True if VoiceOver's own speech, which can't be detected, could reach the active mic.
    var micHearsVoiceOver: @MainActor (_ listener: VoiceListenerKind?) -> Bool
    var followsVoiceOverRate: @MainActor () -> Bool
    var setIdleTimerDisabled: @MainActor (Bool) -> Void
    var glassesSpeechEnabled: @MainActor () -> Bool
    var now: @MainActor () -> Date
  }

  // MARK: State for the UI

  private(set) var status: Status = .off
  /// A sentence saying why, when paused or unavailable. nil otherwise.
  private(set) var reason: String?
  /// The mic in use right now.
  private(set) var activeListener: VoiceListenerKind?
  /// The last command understood. Commands only; heard speech is never kept.
  private(set) var lastCommand: VoiceCommand?
  private(set) var lastCommandAt: Date?
  /// The phone's permissions, which the setup step and settings show.
  private(set) var phoneMicPermission = VoicePermission.notDetermined
  private(set) var speechPermission = VoicePermission.notDetermined
  private(set) var screen: VoiceScreen?
  /// Glasses Speech could be used if the wearable mic were allowed (a Meta AI grant).
  private(set) var canRequestGlassesMicrophone = false

  var isEnabled: Bool { preferences.voiceControlEnabled }

  /// What can be said right now, for "help" and the UI.
  var availableCommands: [VoiceCommand] {
    guard let screen else { return [] }
    return VoiceCommandParser.availableCommands(context: context(on: screen))
  }

  /// For settings: "Voice control: listening".
  var statusText: String {
    switch status {
    case .off: "Voice control: off"
    case .starting: "Voice control: starting"
    case .listening: "Voice control: listening"
    case .paused: "Voice control: paused"
    case .unavailable: "Voice control: not available"
    }
  }

  // MARK: Private

  /// Set by a step for commands only it can answer. Tried before the screen's handler.
  @ObservationIgnored var stepHandler: (@MainActor (VoiceCommand) -> Bool)?

  @ObservationIgnored private let environment: Environment
  @ObservationIgnored private let preferences: A11yPreferences
  @ObservationIgnored private var handler: (@MainActor (VoiceCommand) -> Bool)?
  @ObservationIgnored private var listener: (any SpeechListener)?
  @ObservationIgnored private var listenerStartedAt: Date?
  @ObservationIgnored private var backoff = RestartBackoff()
  @ObservationIgnored private var restartTask: Task<Void, Never>?
  @ObservationIgnored private var inBackground = false
  @ObservationIgnored private var isRecording = false
  @ObservationIgnored private var interrupted = false
  @ObservationIgnored private var makeGlassesListener: (@MainActor () -> any SpeechListener)?
  @ObservationIgnored private var glassesMicGranted = false
  @ObservationIgnored private var glassesRequest: (@MainActor () async -> VoicePermission)?
  @ObservationIgnored private var glassesCoolOffUntil: Date?
  @ObservationIgnored private var cachedPhoneLocale: String??
  /// Play the "now listening" cue next time listening starts: not when a listener merely recovers
  /// or is swapped for the other one.
  @ObservationIgnored private var cueDue = true
  @ObservationIgnored private var permissionPromptInFlight = false
  /// Why-it-can't-listen lines already spoken, so they're said once per launch.
  @ObservationIgnored private var spokenReasons: Set<String> = []
  @ObservationIgnored private var hasBegun = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "VoiceControl")
  private static let glassesCoolOff: TimeInterval = 60
  /// After this many failed restarts in a row, say so. A blip stays quiet; an outage doesn't.
  private static let troubledAfter = 3
  private static let rateStep: Float = 0.05

  init(environment: Environment, preferences: A11yPreferences) {
    self.environment = environment
    self.preferences = preferences
  }

  // MARK: Lifecycle

  /// Starts following the app's lifecycle and audio interruptions, and starts listening if it can.
  /// Idempotent. A launch in a test does nothing but report it.
  func begin() {
    guard !hasBegun else { return }
    hasBegun = true
    if !environment.isInert { observeSystem() }
    refreshPermissions()
    reconcile()
  }

  private func observeSystem() {
    let center = NotificationCenter.default
    func observe(_ name: Notification.Name, object: Any? = nil, _ body: @escaping @MainActor (Notification) -> Void) {
      observers.append(
        center.addObserver(forName: name, object: object, queue: .main) { notification in
          nonisolated(unsafe) let notification = notification
          MainActor.assumeIsolated { body(notification) }
        })
    }
    observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.noteBackground(true) }
    observe(UIApplication.willEnterForegroundNotification) { [weak self] _ in self?.noteBackground(false) }
    let session = AVAudioSession.sharedInstance()
    observe(AVAudioSession.interruptionNotification, object: session) { [weak self] notification in
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      self?.noteInterruption(began: raw == AVAudioSession.InterruptionType.began.rawValue)
    }
    observe(AVAudioSession.mediaServicesWereResetNotification, object: session) { [weak self] _ in
      self?.restartListenerNow()
    }
  }

  func noteBackground(_ background: Bool) {
    inBackground = background
    if !background {
      // A call that ended while away may never report it, and Settings may have changed.
      interrupted = false
      cachedPhoneLocale = nil
      refreshPermissions()
    }
    reconcile()
  }

  func noteInterruption(began: Bool) {
    interrupted = began
    reconcile()
  }

  /// Before the recorder takes the session. Returns with the mic and session free.
  func recordingWillStart() {
    isRecording = true
    reconcile()
  }

  func recordingDidEnd() {
    isRecording = false
    reconcile()
  }

  // MARK: Settings

  func setEnabled(_ enabled: Bool) {
    guard enabled != preferences.voiceControlEnabled else { return }
    preferences.voiceControlEnabled = enabled
    if !enabled {
      environment.say(SpokenMessage.voiceControlTurnedOff, .disconnected, true, nil)
    }
    spokenReasons.removeAll()
    refreshPermissions()
    reconcile()
  }

  // MARK: Permissions

  private func refreshPermissions() {
    phoneMicPermission = environment.phoneMicPermission()
    speechPermission = environment.speechPermission()
  }

  /// The system dialogs, for the setup step's button (which has already explained them) or the
  /// prompt on the main screen. A denial is spoken by reconcile.
  func requestPermissions() async {
    guard !environment.isInert, !permissionPromptInFlight else { return }
    permissionPromptInFlight = true
    await environment.requestPermissions()
    permissionPromptInFlight = false
    refreshPermissions()
    reconcile()
  }

  /// Not asked during setup yet (setup was skipped, or this is an update): explain, then ask.
  private func promptForPermissions() {
    guard !permissionPromptInFlight else { return }
    permissionPromptInFlight = true
    environment.say(SpokenMessage.voiceControlExplanation, .attention, false) { [weak self] _ in
      guard let self else { return }
      self.permissionPromptInFlight = false
      Task { await self.requestPermissions() }
    }
  }

  // MARK: Screens and commands

  func setScreen(_ screen: VoiceScreen, handler: @escaping @MainActor (VoiceCommand) -> Bool) {
    self.screen = screen
    self.handler = handler
    reconcile()
  }

  /// A screen going away. Only if it is still current: the next screen may have appeared first.
  func clearScreen(where matches: (VoiceScreen) -> Bool) {
    guard let screen, matches(screen) else { return }
    self.screen = nil
    handler = nil
    stepHandler = nil
  }

  /// A finished utterance from a listener, or from a test. The seam for injecting transcripts.
  func inject(transcript: String) {
    guard let screen else { return }
    switch VoiceCommandParser.parse(transcript, context: context(on: screen)) {
    case .command(let command):
      accept(command, on: screen)
    case .notUnderstood:
      environment.playEarcon(.uncertain)
      // Queued: "reader, mumble" shouldn't cut off the book.
      environment.say(SpokenMessage.voiceNotUnderstood, nil, false, nil)
    case .ignored:
      break
    }
  }

  private func context(on screen: VoiceScreen) -> VoiceContext {
    VoiceContext(
      screen: screen, isSpeaking: environment.isSpeaking(), spokenText: environment.textBeingSpoken(),
      requiresWakeWord: environment.micHearsVoiceOver(activeListener), hasReadSentences: environment.hasReadSentences())
  }

  private func accept(_ command: VoiceCommand, on screen: VoiceScreen) {
    // Before anything else, so the 100 ms earcon budget doesn't depend on what the command does.
    environment.playEarcon(.heard)
    lastCommand = command
    lastCommandAt = environment.now()
    Self.logger.info("command \(command.rawValue, privacy: .public)")
    if stepHandler?(command) == true || handler?(command) == true { return }
    performCommon(command, on: screen)
  }

  private func performCommon(_ command: VoiceCommand, on screen: VoiceScreen) {
    switch command {
    case .help:
      environment.say(VoiceCommandParser.helpLine(context: context(on: screen)), nil, true, nil)
    case .stop:
      environment.stopSpeech()
    case .repeatLast:
      environment.repeatLast()
    case .faster:
      changeRate(by: Self.rateStep)
    case .slower:
      changeRate(by: -Self.rateStep)
    default:
      break
    }
  }

  private func changeRate(by delta: Float) {
    if environment.followsVoiceOverRate() {
      environment.say(SpokenMessage.voiceRateFollowsVoiceOver, nil, true, nil)
      return
    }
    let before = preferences.speechRate
    preferences.speechRate = before + delta
    if preferences.speechRate == before {
      environment.say(delta > 0 ? SpokenMessage.voiceFastest : SpokenMessage.voiceSlowest, nil, true, nil)
    } else {
      environment.say(delta > 0 ? SpokenMessage.voiceFaster : SpokenMessage.voiceSlower, nil, true, nil)
    }
  }

  // MARK: Glasses

  /// A device session reached STARTED. Checks the wearable mic quietly; never redirects to Meta AI
  /// on its own (requestGlassesMicrophone does, from a button).
  func attachGlasses(session: DeviceSession, wearables: WearablesInterface) {
    guard !environment.isInert, environment.glassesSpeechEnabled() else { return }
    attachGlasses(
      makeListener: { GlassesSpeechListener(session: session) },
      checkPermission: {
        let status = try? await wearables.checkPermissionStatus(.microphone)
        return status == .granted ? .granted : .notDetermined
      },
      requestPermission: {
        let status = try? await wearables.requestPermission(.microphone)
        return status == .granted ? .granted : .denied
      })
  }

  /// Separate from the DAT types, so tests can use a fake listener.
  func attachGlasses(
    makeListener: @escaping @MainActor () -> any SpeechListener,
    checkPermission: @escaping @MainActor () async -> VoicePermission,
    requestPermission: @escaping @MainActor () async -> VoicePermission
  ) {
    makeGlassesListener = makeListener
    glassesRequest = requestPermission
    glassesCoolOffUntil = nil
    Task { [weak self] in
      let status = await checkPermission()
      guard let self, self.makeGlassesListener != nil else { return }
      self.glassesMicGranted = status == .granted
      self.canRequestGlassesMicrophone = status != .granted
      self.reconcile()
    }
  }

  /// The session ended: back to the phone. Safe to call without a session.
  func detachGlasses() {
    guard makeGlassesListener != nil else { return }
    makeGlassesListener = nil
    glassesRequest = nil
    glassesMicGranted = false
    canRequestGlassesMicrophone = false
    reconcile()
  }

  /// For a settings button: says the app switch is coming, then asks through Meta AI.
  func requestGlassesMicrophone() {
    guard let request = glassesRequest else { return }
    environment.say(SpokenMessage.voiceGlassesMicNeedsMetaAI, .attention, true) { [weak self] _ in
      Task { [weak self] in
        let status = await request()
        guard let self else { return }
        self.glassesMicGranted = status == .granted
        self.canRequestGlassesMicrophone = status != .granted
        self.environment.say(
          status == .granted ? SpokenMessage.voiceGlassesMicAllowed : SpokenMessage.voiceGlassesMicNotAllowed,
          status == .granted ? .done : .attention, false, nil)
        self.reconcile()
      }
    }
  }

  // MARK: Applying the decision

  private var policyInputs: VoiceListenerPolicy.Inputs {
    VoiceListenerPolicy.Inputs(
      enabled: preferences.voiceControlEnabled, inBackground: inBackground, recording: isRecording, interrupted: interrupted,
      glassesAvailable: makeGlassesListener != nil, glassesMicGranted: glassesMicGranted,
      glassesCoolingOff: glassesCoolOffUntil.map { environment.now() < $0 } ?? false,
      phoneMic: phoneMicPermission, speechRecognition: speechPermission, onDeviceRecognizerAvailable: phoneLocale != nil)
  }

  private var phoneLocale: String? {
    if let cachedPhoneLocale { return cachedPhoneLocale }
    let locale = environment.phoneLocale()
    cachedPhoneLocale = .some(locale)
    return locale
  }

  /// The single place listening is started and stopped.
  private func reconcile() {
    if environment.isInert {
      status = preferences.voiceControlEnabled ? .unavailable : .off
      reason = preferences.voiceControlEnabled ? "Voice control doesn't listen during tests." : nil
      return
    }
    let decision = VoiceListenerPolicy.decide(policyInputs)
    switch decision {
    case .off:
      stopListener()
      enter(.off, reason: nil)
    case .paused(let pause):
      stopListener()
      enter(.paused, reason: pause.text)
    case .needsPermission:
      stopListener()
      enter(.unavailable, reason: "Waiting for permission to use the microphone and speech recognition.")
      // Setup has its own step that explains this first; otherwise ask once the app is up.
      if let screen {
        if case .setup = screen { return }
        promptForPermissions()
      }
    case .denied:
      stopListener()
      unavailable(SpokenMessage.voicePermissionDenied)
    case .noOnDeviceRecognition:
      stopListener()
      unavailable(SpokenMessage.voiceNoOnDeviceRecognition)
    case .glasses:
      startListener(.glasses)
    case .phone:
      startListener(.phone)
    }
    environment.setIdleTimerDisabled(decision == .glasses || decision == .phone)
  }

  private func enter(_ new: Status, reason newReason: String?) {
    if new == .off || new == .paused || new == .unavailable { cueDue = true }
    status = new
    reason = newReason
  }

  /// Says why it can't listen, once per launch for each reason. Never silence (ROADMAP).
  private func unavailable(_ line: String) {
    enter(.unavailable, reason: line)
    guard spokenReasons.insert(line).inserted else { return }
    environment.say(line, .attention, false, nil)
  }

  private func startListener(_ kind: VoiceListenerKind) {
    if let listener, listener.kind == kind { return }
    stopListener()
    let new: (any SpeechListener)?
    switch kind {
    case .glasses: new = makeGlassesListener?()
    case .phone: new = phoneLocale.flatMap { environment.makePhoneListener($0) }
    }
    guard let new else {
      unavailable(SpokenMessage.voiceNoOnDeviceRecognition)
      return
    }
    listener = new
    activeListener = kind
    if status != .listening { enter(.starting, reason: nil) }
    new.onEvent = { [weak self, weak new] event in
      guard let self, let new, self.listener === new else { return }
      self.handle(event, from: new)
    }
    new.start()
  }

  private func stopListener() {
    restartTask?.cancel()
    restartTask = nil
    listener?.onEvent = nil
    listener?.stop()
    listener = nil
    listenerStartedAt = nil
    activeListener = nil
  }

  private func restartListenerNow() {
    stopListener()
    reconcile()
  }

  private func handle(_ event: SpeechListenerEvent, from source: any SpeechListener) {
    switch event {
    case .started:
      listeningStarted()
    case .transcript(let text):
      inject(transcript: text)
    case .finished:
      scheduleRestart()
    case .failed(let failure, let transient):
      Self.logger.error("listener \(source.kind.rawValue, privacy: .public) failed: \(failure, privacy: .public)")
      if source.kind == .glasses {
        // Fall back to the phone straight away, and give the glasses another chance later.
        let coolOff = Self.glassesCoolOff
        glassesCoolOffUntil = environment.now().addingTimeInterval(coolOff)
        stopListener()
        reconcile()
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(coolOff))
          self?.reconcile()
        }
      } else if transient {
        scheduleRestart()
      } else {
        cachedPhoneLocale = .some(nil)
        stopListener()
        reconcile()
      }
    }
  }

  private func listeningStarted() {
    listenerStartedAt = environment.now()
    let wasCueDue = cueDue
    cueDue = false
    // "Trouble" stays spoken until listening has held for a while, so a listener that keeps
    // starting and failing doesn't repeat it on every cycle (scheduleRestart clears it).
    spokenReasons.formIntersection([SpokenMessage.voiceControlTroubled])
    enter(.listening, reason: nil)
    guard wasCueDue else { return }
    environment.playEarcon(.listening)
    guard !preferences.voiceControlIntroHeard else { return }
    let line = environment.micHearsVoiceOver(activeListener) ? SpokenMessage.voiceControlOnWakeWord : SpokenMessage.voiceControlOn
    environment.say(line, nil, false) { [weak self] finished in
      if finished { self?.preferences.voiceControlIntroHeard = true }
    }
  }

  /// A listener ended: start again after a pause that grows while it keeps failing. Task ends,
  /// errors and route changes the listener can't ride out all come through here.
  private func scheduleRestart() {
    if let startedAt = listenerStartedAt {
      backoff.noteRanFor(environment.now().timeIntervalSince(startedAt))
      if backoff.attempts == 0 { spokenReasons.remove(SpokenMessage.voiceControlTroubled) }
    }
    stopListener()
    let delay = backoff.next()
    if backoff.attempts >= Self.troubledAfter {
      unavailable(SpokenMessage.voiceControlTroubled)
    } else {
      enter(.starting, reason: nil)
    }
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.restartTask = nil
      self?.reconcile()
    }
  }
}

// MARK: - Live environment

extension VoiceControl.Environment {
  static let live = VoiceControl.Environment(
    isInert: LaunchOptions.isAutomatedTest,
    makePhoneListener: { PhoneSpeechListener(localeIdentifier: $0) },
    phoneLocale: {
      PhoneLocaleChoice.choose(deviceLocale: Locale.current.identifier) { identifier in
        SFSpeechRecognizer(locale: Locale(identifier: identifier))?.supportsOnDeviceRecognition == true
      }
    },
    phoneMicPermission: {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: .granted
      case .denied: .denied
      default: .notDetermined
      }
    },
    speechPermission: {
      switch SFSpeechRecognizer.authorizationStatus() {
      case .authorized: .granted
      case .denied, .restricted: .denied
      default: .notDetermined
      }
    },
    requestPermissions: {
      _ = await AVAudioApplication.requestRecordPermission()
      await VoiceSpeechAuthorization.request()
    },
    say: { text, earcon, interrupt, onFinish in
      Announcer.shared.announce(text, earcon: earcon, interrupt: interrupt, onFinish: onFinish)
    },
    playEarcon: { EarconPlayer.shared.play($0) },
    isSpeaking: { Announcer.shared.isSpeaking },
    textBeingSpoken: { Announcer.shared.textBeingSpoken() },
    stopSpeech: { Announcer.shared.stop() },
    repeatLast: { Announcer.shared.repeatLast() },
    hasReadSentences: { TextReader.shared.hasSentences },
    micHearsVoiceOver: { listener in
      guard UIAccessibility.isVoiceOverRunning else { return false }
      // The glasses mic is next to the glasses speaker; the phone mic is next to the phone speaker.
      return listener == .glasses || A11yAudioSession.outputDescription() == "phone speaker"
    },
    followsVoiceOverRate: { A11yPreferences.shared.useVoiceOverVoice && UIAccessibility.isVoiceOverRunning },
    setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 },
    glassesSpeechEnabled: { VoiceFeatureFlags.glassesSpeechEnabled() },
    now: { Date() }
  )
}

/// nonisolated: the callback arrives on a background queue, and a closure formed on the main actor
/// would trap there under Swift 6.
enum VoiceSpeechAuthorization {
  nonisolated static func request() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
    }
  }
}
