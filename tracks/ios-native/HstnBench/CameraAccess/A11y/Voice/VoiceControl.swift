/*
 * VoiceControl - runs the app by speaking: picks a listener, keeps it alive, acts on commands
 *
 * The UI binds to `status`, `reason`, `activeListener`, `lastCommand`, `isEnabled` and
 * `availableCommands`. Screens register what commands do with setScreen(_:handler:), calling the
 * same actions as Siri, Magic Tap and the actions rotor; what is the same on every screen (help,
 * stop, repeat, faster, slower, goodbye, and the spoken settings except disconnect) lives here.
 *
 * Prompts: an alert, sheet or question that wants a spoken answer calls showPrompt(_:accepts:...)
 * and dismissPrompt(_:) when it goes. A blocking prompt takes every command and the screen
 * underneath gets none (so "yes" on the Meta AI sheet can't also connect from the first screen); a
 * non-blocking one (a notice, an offer) only adds its answers. The newest prompt wins.
 *
 * Goodbye: stops listening until the app comes back to the front, the user reads (Siri, a button),
 * or voice control is switched on again, and lets the screen sleep. Not a setting: it isn't saved.
 *
 * Which listener: VoiceListenerPolicy. Glasses during a STARTED session with the wearable mic
 * granted, otherwise the phone. reconcile() is the one place that applies the decision, and every
 * change of input calls it. The background or a call pauses listening; the background also
 * matters for privacy.
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
    /// The system microphone dialog. VoiceControl says one line before it.
    var requestMicPermission: @MainActor () async -> Void
    /// The system speech recognition dialog. VoiceControl says one line before it.
    var requestSpeechPermission: @MainActor () async -> Void
    var say: @MainActor (_ text: String, _ earcon: Earcon?, _ interrupt: Bool, _ onFinish: Announcer.Completion?) -> Void
    var playEarcon: @MainActor (Earcon) -> Void
    var isSpeaking: @MainActor () -> Bool
    var textBeingSpoken: @MainActor () -> String
    var stopSpeech: @MainActor () -> Void
    var repeatLast: @MainActor () -> Void
    var hasReadSentences: @MainActor () -> Bool
    /// A page is being fetched or read (TextReader.isActive).
    var isReading: @MainActor () -> Bool
    /// True if VoiceOver's own speech, which can't be detected, could reach the active mic.
    var micHearsVoiceOver: @MainActor (_ listener: VoiceListenerKind?) -> Bool
    var followsVoiceOverRate: @MainActor () -> Bool
    var setIdleTimerDisabled: @MainActor (Bool) -> Void
    var glassesSpeechEnabled: @MainActor () -> Bool
    /// An OpenAI key is set, so "natural voice on" can take effect.
    var hasCloudKey: @MainActor () -> Bool
    /// The service refused the key this session (CloudReading.keyRefused).
    var cloudKeyRefused: @MainActor () -> Bool
    var now: @MainActor () -> Date
  }

  /// Something on screen waiting for a spoken answer. See the file comment.
  enum PromptID: String, Sendable {
    case registrationRequest
    case cameraPermission
    case cameraError
    case wearablesError
    case confirm
    case glassesMicOffer
    case voiceDownload
  }

  private struct Prompt {
    let id: PromptID
    let commands: [VoiceCommand]
    let blocking: Bool
    let handler: @MainActor (VoiceCommand) -> Bool
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
  /// The phone's permissions, which the voice indicator and settings show.
  private(set) var phoneMicPermission = VoicePermission.notDetermined
  private(set) var speechPermission = VoicePermission.notDetermined
  private(set) var screen: VoiceScreen?
  /// Glasses Speech could be used if the wearable mic were allowed (a Meta AI grant).
  private(set) var canRequestGlassesMicrophone = false
  /// "Goodbye" was said: not listening until wake().
  private(set) var isAsleep = false
  /// The prompts waiting for an answer, newest last.
  private var prompts: [Prompt] = []

  /// The blocking prompt that takes commands right now, if any.
  var activePrompt: PromptID? { prompts.last(where: \.blocking)?.id }

  var isEnabled: Bool { preferences.voiceControlEnabled }

  /// What can be said right now, for "help" and the UI.
  var availableCommands: [VoiceCommand] {
    guard let screen else { return [] }
    return VoiceCommandParser.availableCommands(context: context(on: screen))
  }

  /// Bare commands aren't safe right now, so prompts should say "reader, ..." (see VoiceCommand).
  var needsWakeWord: Bool { environment.micHearsVoiceOver(activeListener) }

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

  @ObservationIgnored private let environment: Environment
  @ObservationIgnored private let preferences: A11yPreferences
  @ObservationIgnored private var handler: (@MainActor (VoiceCommand) -> Bool)?
  @ObservationIgnored private var canUpdate: (@MainActor () -> Bool)?
  /// Run once the permission dialogs are done with (or weren't needed).
  @ObservationIgnored private var afterPermissions: [@MainActor () -> Void] = []
  @ObservationIgnored private var glassesOfferTask: Task<Void, Never>?
  @ObservationIgnored private var listener: (any SpeechListener)?
  @ObservationIgnored private var listenerStartedAt: Date?
  @ObservationIgnored private var backoff = RestartBackoff()
  @ObservationIgnored private var restartTask: Task<Void, Never>?
  @ObservationIgnored private var inBackground = false
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
      // Back in front after "goodbye" (Siri's "SpeakUp read" brings it here): listen again.
      isAsleep = false
      refreshPermissions()
    }
    reconcile()
  }

  // MARK: Goodbye

  /// "Goodbye": the screen has already stopped reading and ended the camera. Stops listening, lets
  /// the screen sleep, and says how to come back.
  func goToSleep() {
    // A question left open would block commands, or act on a "yes" heard much later.
    dismissPrompt(.confirm)
    environment.say(SpokenMessage.voiceGoodbye, .disconnected, true, nil)
    isAsleep = true
    reconcile()
  }

  /// Listening again after goodbye: a read (button, Siri), or voice control switched on.
  func wake() {
    guard isAsleep else { return }
    isAsleep = false
    reconcile()
  }

  func noteInterruption(began: Bool) {
    interrupted = began
    reconcile()
  }

  // MARK: Settings

  func setEnabled(_ enabled: Bool) {
    guard enabled != preferences.voiceControlEnabled else { return }
    preferences.voiceControlEnabled = enabled
    if enabled { isAsleep = false }
    if !enabled {
      environment.say(SpokenMessage.voiceControlTurnedOff, .disconnected, true, nil)
    }
    spokenReasons.removeAll()
    refreshPermissions()
    reconcile()
    // Nothing will ask now, so whatever waited for the dialogs goes ahead.
    if !enabled { runAfterPermissions() }
  }

  // MARK: Permissions

  private func refreshPermissions() {
    phoneMicPermission = environment.phoneMicPermission()
    speechPermission = environment.speechPermission()
  }

  /// The system dialogs, for the voice indicator's Allow button or after the spoken explanation
  /// (promptForPermissions). A denial is spoken by reconcile.
  func requestPermissions() async {
    guard !environment.isInert, !permissionPromptInFlight else { return }
    permissionPromptInFlight = true
    // One line before each dialog, heard to the end first, so VoiceOver users know what's up.
    // Either one refused means no phone listening (VoiceListenerPolicy), so no point in the other.
    if environment.speechPermission() != .denied, environment.phoneMicPermission() == .notDetermined {
      await sayAndWait(SpokenMessage.voiceDialogOnScreen)
      await environment.requestMicPermission()
    }
    // A refused microphone means no phone listening; the speech dialog would be pointless.
    if environment.phoneMicPermission() != .denied, environment.speechPermission() == .notDetermined {
      await sayAndWait(SpokenMessage.voiceDialogOnScreen)
      await environment.requestSpeechPermission()
    }
    permissionPromptInFlight = false
    refreshPermissions()
    reconcile()
    runAfterPermissions()
  }

  /// Runs `body` once the microphone and speech dialogs are out of the way: at once if they were
  /// answered before (or can't be shown), otherwise after them. The first screen says "Say
  /// connect" here, so it is only offered once listening can work.
  func whenPermissionsSettled(_ body: @escaping @MainActor () -> Void) {
    let pending = Self.permissionsPending(mic: environment.phoneMicPermission(), speech: environment.speechPermission())
    guard !environment.isInert, preferences.voiceControlEnabled, pending else { return body() }
    afterPermissions.append(body)
  }

  /// Dialogs still to come, by the listening policy's rule: either one refused (or restricted) is
  /// settled, since listening can't happen and nothing more will be asked.
  static func permissionsPending(mic: VoicePermission, speech: VoicePermission) -> Bool {
    guard mic != .denied, speech != .denied else { return false }
    return mic == .notDetermined || speech == .notDetermined
  }

  private func runAfterPermissions() {
    let waiting = afterPermissions
    afterPermissions = []
    for body in waiting { body() }
  }

  private func sayAndWait(_ text: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      environment.say(text, .attention, false) { _ in continuation.resume() }
    }
  }

  /// Not asked yet: one spoken sentence on why, then the dialogs. Queued, so it follows whatever the
  /// screen is saying (the first screen's welcome line).
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

  /// `canUpdate`: an update is waiting, so "update" is offered (the camera screen).
  func setScreen(
    _ screen: VoiceScreen, canUpdate: (@MainActor () -> Bool)? = nil, handler: @escaping @MainActor (VoiceCommand) -> Bool
  ) {
    // A yes/no question belongs to the screen that asked it.
    if self.screen != screen { dismissPrompt(.confirm) }
    self.screen = screen
    self.handler = handler
    self.canUpdate = canUpdate
    reconcile()
  }

  /// A screen going away. Only if it is still current: the next screen may have appeared first.
  func clearScreen(where matches: (VoiceScreen) -> Bool) {
    guard let screen, matches(screen) else { return }
    self.screen = nil
    handler = nil
    canUpdate = nil
    dismissPrompt(.confirm)
  }

  // MARK: Prompts

  /// Something on screen wants a spoken answer. Replaces a prompt with the same id. `handler`
  /// returns false to pass one of its answers on to the screen, then the common handling.
  func showPrompt(
    _ id: PromptID, accepts commands: [VoiceCommand], blocking: Bool = true,
    handler: @escaping @MainActor (VoiceCommand) -> Bool
  ) {
    prompts.removeAll { $0.id == id }
    prompts.append(Prompt(id: id, commands: commands, blocking: blocking, handler: handler))
  }

  /// The prompt went away (answered by voice, by a button, or by itself). Safe to call twice.
  func dismissPrompt(_ id: PromptID) {
    prompts.removeAll { $0.id == id }
  }

  func isShowingPrompt(_ id: PromptID) -> Bool {
    prompts.contains { $0.id == id }
  }

  /// How long a yes/no question stays open. After that it lapses silently: a "yeah" minutes later
  /// must not disconnect anything.
  @ObservationIgnored var confirmTimeout: Duration = .seconds(15)
  @ObservationIgnored private var confirmToken = 0

  /// A yes/no question ("Disconnect your glasses? Say yes or no."). Blocking until answered, until
  /// confirmTimeout, goodbye or a screen change.
  func confirm(_ question: String, onYes: @escaping @MainActor () -> Void, onNo: @escaping @MainActor () -> Void) {
    confirmToken += 1
    let token = confirmToken
    let timeout = confirmTimeout
    Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, self.confirmToken == token else { return }
      self.dismissPrompt(.confirm)
    }
    // Only yes and no: "OK" could mean either.
    showPrompt(.confirm, accepts: [.yes, .no]) { [weak self] command in
      switch command {
      case .yes:
        self?.dismissPrompt(.confirm)
        onYes()
      case .no:
        self?.dismissPrompt(.confirm)
        onNo()
      default:
        return false
      }
      return true
    }
    environment.say(question, .attention, true, nil)
  }

  /// A finished utterance from a listener, or from a test. The seam for injecting transcripts.
  func inject(transcript: String) {
    guard let screen else { return }
    switch VoiceCommandParser.parse(transcript, context: context(on: screen)) {
    case .command(let command):
      accept(command, on: screen)
    case .notUnderstood where activePrompt == .confirm:
      environment.say(SpokenMessage.voiceSayYesOrNo, nil, true, nil)
    case .notUnderstood:
      environment.playEarcon(.uncertain)
      // Queued: "reader, mumble" shouldn't cut off the book.
      environment.say(SpokenMessage.voiceNotUnderstood, nil, false, nil)
    case .ignored(.unavailableHere) where activePrompt == .confirm:
      // A real command, held back by the question: say what's needed instead of nothing.
      environment.say(SpokenMessage.voiceSayYesOrNo, nil, true, nil)
    case .ignored:
      break
    }
  }

  private func context(on screen: VoiceScreen) -> VoiceContext {
    let blocking = prompts.last(where: \.blocking)
    let extra = prompts.filter { !$0.blocking }.flatMap(\.commands)
    return VoiceContext(
      screen: screen, isSpeaking: environment.isSpeaking(), spokenText: environment.textBeingSpoken(),
      requiresWakeWord: environment.micHearsVoiceOver(activeListener), hasReadSentences: environment.hasReadSentences(),
      canUpdate: canUpdate?() ?? false, promptCommands: blocking?.commands, extraCommands: extra)
  }

  private func accept(_ command: VoiceCommand, on screen: VoiceScreen) {
    // Before anything else, so the 100 ms earcon budget doesn't depend on what the command does.
    environment.playEarcon(.heard)
    lastCommand = command
    lastCommandAt = environment.now()
    Self.logger.info("command \(command.rawValue, privacy: .public)")
    if command == .goodbye {
      // The screen stops reading and ends the camera; the rest is the same everywhere.
      _ = handler?(command)
      return goToSleep()
    }
    if let blocking = prompts.last(where: \.blocking) {
      // The screen underneath gets nothing while a prompt is up, unless the prompt passes one of
      // its own answers on (its handler returns false).
      if blocking.commands.contains(command) {
        if blocking.handler(command) { return }
        if handler?(command) == true { return }
      }
      return performCommon(command, on: screen)
    }
    for prompt in prompts.reversed() where prompt.commands.contains(command) {
      if prompt.handler(command) { return }
    }
    if handler?(command) == true { return }
    performCommon(command, on: screen)
  }

  private func performCommon(_ command: VoiceCommand, on screen: VoiceScreen) {
    switch command {
    case .help:
      environment.say(VoiceCommandParser.helpLine(context: context(on: screen)), nil, true, nil)
    case .settings:
      environment.say(VoiceCommandParser.settingsLine(context: context(on: screen)), nil, true, nil)
    case .stop:
      environment.stopSpeech()
    case .repeatLast:
      environment.repeatLast()
    case .faster:
      changeRate(by: Self.rateStep)
    case .slower:
      changeRate(by: -Self.rateStep)
    case .naturalVoiceOn, .naturalVoiceOff, .tipsOn, .tipsOff, .shorter, .moreDetail, .replaySetup:
      environment.say(SpokenSettings.apply(
          command, preferences: preferences, hasCloudKey: environment.hasCloudKey(), keyRefused: environment.cloudKeyRefused()), nil, true, nil)
    case .glassesMic:
      listenThroughGlasses()
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
      if status != .granted { self.offerGlassesMicrophoneOnce() }
    }
  }

  /// The session ended: back to the phone. Safe to call without a session.
  func detachGlasses() {
    guard makeGlassesListener != nil else { return }
    makeGlassesListener = nil
    glassesRequest = nil
    glassesMicGranted = false
    canRequestGlassesMicrophone = false
    glassesOfferTask?.cancel()
    glassesOfferTask = nil
    dismissPrompt(.glassesMicOffer)
    reconcile()
  }

  /// How long the first-session question waits for a quiet moment, and how long it stays open.
  static let glassesOfferQuietWait: Duration = .seconds(90)
  static let glassesOfferOpenFor: Duration = .seconds(30)

  /// The first camera session ever, with the glasses mic not yet allowed: asks once, in the first
  /// quiet moment (never over a page being read). Non-blocking, so "read" still works meanwhile.
  private func offerGlassesMicrophoneOnce() {
    guard !preferences.glassesMicOffered, glassesOfferTask == nil, preferences.voiceControlEnabled, !isAsleep else { return }
    glassesOfferTask = Task { [weak self] in
      let clock = ContinuousClock()
      let deadline = clock.now + Self.glassesOfferQuietWait
      var quiet = false
      while !Task.isCancelled, clock.now < deadline {
        guard let self else { return }
        if !self.environment.isSpeaking(), !self.environment.isReading() {
          quiet = true
          break
        }
        try? await Task.sleep(for: .milliseconds(300))
      }
      // No quiet moment this session: ask next time rather than over the reading.
      guard quiet, let self, !Task.isCancelled, self.canRequestGlassesMicrophone, !self.preferences.glassesMicOffered else {
        return
      }
      self.preferences.glassesMicOffered = true
      self.showPrompt(.glassesMicOffer, accepts: [.yes, .no], blocking: false) { [weak self] command in
        guard let self else { return false }
        self.dismissPrompt(.glassesMicOffer)
        if command == .yes {
          self.requestGlassesMicrophone()
        } else {
          self.environment.say(SpokenMessage.voiceGlassesMicDeclined, nil, true, nil)
        }
        return true
      }
      self.environment.say(SpokenMessage.voiceGlassesMicOffer, .attention, false, nil)
      try? await Task.sleep(for: Self.glassesOfferOpenFor)
      self.dismissPrompt(.glassesMicOffer)
    }
  }

  /// "Listen through glasses": asks Meta AI for the mic, or says why it can't right now.
  private func listenThroughGlasses() {
    if activeListener == .glasses || glassesMicGranted {
      environment.say(SpokenMessage.voiceGlassesMicAlready, nil, true, nil)
    } else if canRequestGlassesMicrophone {
      requestGlassesMicrophone()
    } else {
      environment.say(SpokenMessage.voiceGlassesMicNeedsCamera, nil, true, nil)
    }
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
      enabled: preferences.voiceControlEnabled, asleep: isAsleep, inBackground: inBackground, interrupted: interrupted,
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
      // Asked once a screen is up, the first screen included: that is where "say connect" is
      // first offered.
      if screen != nil { promptForPermissions() }
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
    requestMicPermission: { _ = await AVAudioApplication.requestRecordPermission() },
    requestSpeechPermission: { await VoiceSpeechAuthorization.request() },
    say: { text, earcon, interrupt, onFinish in
      Announcer.shared.announce(text, earcon: earcon, interrupt: interrupt, onFinish: onFinish)
    },
    playEarcon: { EarconPlayer.shared.play($0) },
    isSpeaking: { Announcer.shared.isSpeaking },
    textBeingSpoken: { Announcer.shared.textBeingSpoken() },
    stopSpeech: { Announcer.shared.stop() },
    repeatLast: { Announcer.shared.repeatLast() },
    hasReadSentences: { TextReader.shared.hasSentences },
    isReading: { TextReader.shared.isActive },
    micHearsVoiceOver: { listener in
      guard UIAccessibility.isVoiceOverRunning else { return false }
      // The glasses mic is next to the glasses speaker; the phone mic is next to the phone speaker.
      return listener == .glasses || A11yAudioSession.outputDescription() == "phone speaker"
    },
    followsVoiceOverRate: { A11yPreferences.shared.useVoiceOverVoice && UIAccessibility.isVoiceOverRunning },
    setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 },
    glassesSpeechEnabled: { VoiceFeatureFlags.glassesSpeechEnabled() },
    hasCloudKey: { CloudReading.shared.hasKey },
    cloudKeyRefused: { CloudReading.shared.keyRefused },
    now: { Date() }
  )
}

// MARK: - Spoken settings

/// What "natural voice on", "tips off", "shorter", "replay setup"... change, and the line that says
/// the new state back. Pure apart from the preferences it is given, so it is unit tested.
/// "Listen through glasses" and "disconnect" need the session and the registration, so they live
/// with VoiceControl and WearablesViewModel.
@MainActor
enum SpokenSettings {
  static func apply(_ command: VoiceCommand, preferences: A11yPreferences, hasCloudKey: Bool, keyRefused: Bool = false) -> String {
    switch command {
    case .naturalVoiceOn:
      // On is only "on" when it can be heard: say why when it can't.
      preferences.useNaturalVoice = true
      if !hasCloudKey { return SpokenMessage.readNaturalVoiceOnNoKey }
      return keyRefused ? SpokenMessage.readNaturalVoiceOnKeyRefused : SpokenMessage.readNaturalVoiceOn
    case .naturalVoiceOff:
      preferences.useNaturalVoice = false
      return SpokenMessage.readNaturalVoiceOff
    case .tipsOn:
      preferences.voiceTipsEnabled = true
      return SpokenMessage.voiceTipsOn
    case .tipsOff:
      preferences.voiceTipsEnabled = false
      return SpokenMessage.voiceTipsOff
    case .shorter:
      guard let shorter = preferences.verbosity.shorter else { return SpokenMessage.verbosityShortest }
      preferences.verbosity = shorter
      return SpokenMessage.verbosity(shorter)
    case .moreDetail:
      guard let longer = preferences.verbosity.longer else { return SpokenMessage.verbosityLongest }
      preferences.verbosity = longer
      return SpokenMessage.verbosity(longer)
    case .replaySetup:
      preferences.resetOnboarding()
      return SpokenMessage.replayingSetup
    default:
      return VoiceCommandParser.helpLine(context: VoiceContext(screen: .camera))
    }
  }
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
