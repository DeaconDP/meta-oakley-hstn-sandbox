/*
 * VoiceTests - the app's voice choice, the command parser, the listener rules, VoiceControl with
 * fake listeners, and GlassesSpeechListener against MockDeviceKit's Speech
 *
 * PhoneSpeechListener isn't here: it needs a real mic and recogniser (notes/a11y-device-test.md).
 */

import AVFoundation
@testable import CameraAccess
import Foundation
import MWDATCore
import MWDATMockDevice
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

private func voice(
  _ name: String, _ language: String = "en-GB", gender: VoiceDescriptor.Gender = .female, quality: Int = 1, id: String? = nil
) -> VoiceDescriptor {
  VoiceDescriptor(
    name: name, identifier: id ?? "com.apple.voice.compact.\(language).\(name)", language: language, gender: gender, quality: quality)
}

final class VoiceSelectionTests: XCTestCase {
  private let daniel = voice("Daniel", gender: .male)
  private let samantha = voice("Samantha", "en-US")

  func testStockPhoneFallsBackToDanielAndNeedsTheNotice() {
    let choice = VoiceSelection.choose(from: [daniel, samantha, voice("Tessa", "en-ZA")])
    XCTAssertEqual(choice?.voice.name, "Daniel")
    XCTAssertEqual(choice?.match, .britishOther)
    XCTAssertEqual(choice?.isBritishFemale, false)
  }

  func testBritishFemaleBeatsAMaleVoiceOfBetterQuality() {
    let choice = VoiceSelection.choose(from: [voice("Daniel", gender: .male, quality: 3), voice("Kate")])
    XCTAssertEqual(choice?.voice.name, "Kate")
    XCTAssertEqual(choice?.match, .britishFemale)
  }

  func testBestQualityThenPreferredName() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena"), voice("Kate", quality: 2)])?.voice.name, "Kate")
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Martha", quality: 2), voice("Serena", quality: 2)])?.voice.name, "Serena")
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Unknown"), voice("Stephanie")])?.voice.name, "Stephanie")
  }

  func testUnspecifiedGenderCountsAsFemaleOnlyByKnownName() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena", gender: .unspecified)])?.match, .britishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena (Premium)", gender: .unspecified)])?.match, .britishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Oliver", gender: .unspecified)])?.match, .britishOther)
    // A stated gender isn't second-guessed by name.
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Kate", gender: .male)])?.match, .britishOther)
  }

  func testNoveltyAndEloquenceVoicesDontCount() {
    let flo = voice("Flo", id: "com.apple.eloquence.en-GB.Flo")
    let albert = voice("Albert", "en-US", gender: .unspecified, id: "com.apple.speech.synthesis.voice.Albert")
    var novelty = voice("Zarvox")
    novelty.isNovelty = true
    XCTAssertEqual(VoiceSelection.choose(from: [flo, daniel])?.voice.name, "Daniel")
    XCTAssertNil(VoiceSelection.choose(from: [flo, albert, novelty]))
  }

  func testFallbackOrderWithNoBritishVoice() {
    let choice = VoiceSelection.choose(from: [samantha, voice("Tessa", "en-ZA"), voice("Rishi", "en-IN", gender: .male), voice("Moira", "en-IE")])
    XCTAssertEqual(choice?.voice.name, "Moira")
    XCTAssertEqual(choice?.match, .englishFemale)
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Rishi", "en-IN", gender: .male)])?.match, .englishOther)
    XCTAssertNil(VoiceSelection.choose(from: [voice("Anna", "de-DE")]))
  }

  func testLanguageSpellingsAreTolerated() {
    XCTAssertEqual(VoiceSelection.choose(from: [voice("Serena", "en_GB")])?.match, .britishFemale)
  }

  func testDisplayString() {
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Serena")), "Voice: Serena, British")
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Serena (Premium)")), "Voice: Serena, British")
    XCTAssertEqual(VoiceSelection.displayString(for: voice("Karen", "en-AU")), "Voice: Karen, Australian")
  }

  func testDownloadNoticeOnlyWhenNeeded() {
    let british = VoiceChoice(voice: voice("Serena"), match: .britishFemale)
    let fallback = VoiceChoice(voice: daniel, match: .britishOther)
    XCTAssertTrue(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertTrue(VoiceSelection.shouldOfferDownload(choice: nil, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: british, alreadyHeard: false, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: true, followsVoiceOver: false))
    XCTAssertFalse(VoiceSelection.shouldOfferDownload(choice: fallback, alreadyHeard: false, followsVoiceOver: true))
  }
}

@MainActor
final class VoicePreferenceMigrationTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "VoicePreferenceMigrationTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testOldStoredFalseGetsTheNewDefaultAndIsRemoved() {
    defaults.set(false, forKey: "a11y.useAppVoice")
    XCTAssertFalse(A11yPreferences(defaults: defaults).useVoiceOverVoice)
    XCTAssertNil(defaults.object(forKey: "a11y.useAppVoice"))
  }

  func testRealChoiceSurvives() {
    A11yPreferences(defaults: defaults).useVoiceOverVoice = true
    defaults.set(true, forKey: "a11y.useAppVoice")
    XCTAssertTrue(A11yPreferences(defaults: defaults).useVoiceOverVoice)
  }

  func testVoiceControlOffSwitchPersists() {
    A11yPreferences(defaults: defaults).voiceControlEnabled = false
    XCTAssertFalse(A11yPreferences(defaults: defaults).voiceControlEnabled)
  }

  func testOutputRouting() {
    typealias Output = CameraAccess.Announcer.Output
    let own = Output.ownVoice(prefersAssistiveTechnologySettings: false)
    // The default: the app's voice, VoiceOver or not, status or reply.
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: true, useVoiceOverVoice: false), own)
    XCTAssertEqual(Output.choose(kind: .reply, voiceOverRunning: true, useVoiceOverVoice: false), own)
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: false, useVoiceOverVoice: true), own)
    // Opted in, with VoiceOver running.
    XCTAssertEqual(Output.choose(kind: .status, voiceOverRunning: true, useVoiceOverVoice: true), .voiceOver)
    XCTAssertEqual(
      Output.choose(kind: .reply, voiceOverRunning: true, useVoiceOverVoice: true), .ownVoice(prefersAssistiveTechnologySettings: true))
  }
}

final class VoiceCommandParserTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera)

  private func parse(_ text: String, _ context: VoiceContext? = nil) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context ?? camera)
  }

  func testCameraCommands() {
    let expected: [(String, VoiceCommand)] = [
      ("read", .read), ("read this", .read), ("read aloud", .read), ("Read it aloud.", .read),
      ("stop", .stop), ("pause", .stop), ("quiet", .stop),
      ("repeat", .repeatLast), ("say that again", .repeatLast),
      ("status", .status), ("what's the status", .status),
      ("connect", .connect), ("start", .connect),
      ("take a photo", .takePhoto), ("Take a picture", .takePhoto),
      ("faster", .faster), ("slower", .slower), ("slow down", .slower),
      ("help", .help), ("what can I say", .help),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  func testFillerIsTolerated() {
    XCTAssertEqual(parse("please read this"), .command(.read))
    XCTAssertEqual(parse("Can you read this please"), .command(.read))
    XCTAssertEqual(parse("could you take a photo for me"), .command(.takePhoto))
    XCTAssertEqual(parse("um stop"), .command(.stop))
    XCTAssertEqual(parse("stop thank you"), .command(.stop))
  }

  func testConversationIsIgnoredInSilence() {
    XCTAssertEqual(parse("I'll read this book later"), .ignored(.unrecognized))
    XCTAssertEqual(parse("stop listening to him"), .ignored(.unrecognized))
    XCTAssertEqual(parse("did you take a photo of it"), .ignored(.unrecognized))
    XCTAssertEqual(parse(""), .ignored(.empty))
    XCTAssertEqual(parse("..."), .ignored(.empty))
  }

  func testWakeWordWhileSpeaking() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "The bus did not stop at the corner.")
    XCTAssertEqual(parse("stop", speaking), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader, stop", speaking), .command(.stop))
    XCTAssertEqual(parse("Hey reader stop", speaking), .command(.stop))
    XCTAssertEqual(parse("reader please stop now", speaking), .command(.stop))
  }

  func testTranscriptOverlappingTheBookIsDiscarded() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "She looked up. Reader, stop the car, he said.")
    XCTAssertEqual(parse("reader stop", speaking), .ignored(.overlapsSpeech))
    XCTAssertEqual(parse("reader stop the car", speaking), .ignored(.overlapsSpeech))
    // "stopped" isn't "stop": the user really said it.
    let other = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "The reader stopped and looked up.")
    XCTAssertEqual(parse("reader stop", other), .command(.stop))
  }

  func testIdleOverlapWithJustFinishedText() {
    let justSpoke = VoiceContext(screen: .camera, isSpeaking: false, spokenText: "Press stop to end.")
    XCTAssertEqual(parse("stop", justSpoke), .ignored(.overlapsSpeech))
    XCTAssertEqual(parse("read", justSpoke), .command(.read))
    // A recogniser slip in the middle still counts as hearing ourselves.
    let longer = VoiceContext(screen: .camera, spokenText: "Ready to take a photo.")
    XCTAssertEqual(parse("to take a photograph", longer), .ignored(.overlapsSpeech))
  }

  func testWakeWordNotUnderstood() {
    XCTAssertEqual(parse("reader, make me a sandwich"), .notUnderstood)
    XCTAssertEqual(parse("reader"), .notUnderstood)
  }

  func testRequiresWakeWordWhenIdle() {
    let context = VoiceContext(screen: .camera, requiresWakeWord: true)
    XCTAssertEqual(parse("read text", context), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader read text", context), .command(.read))
  }

  func testCommandsDependOnTheScreen() {
    let welcome = VoiceContext(screen: .setup(.welcome))
    XCTAssertEqual(parse("yes", welcome), .command(.yes))
    XCTAssertEqual(parse("skip", welcome), .command(.skip))
    XCTAssertEqual(parse("take a photo", welcome), .ignored(.unavailableHere))
    XCTAssertEqual(parse("reader take a photo", welcome), .notUnderstood)

    let speaker = VoiceContext(screen: .setup(.speakerTest))
    XCTAssertEqual(parse("test the speaker", speaker), .command(.testSpeaker))
    XCTAssertEqual(parse("no", speaker), .command(.no))
    XCTAssertEqual(parse("yes", speaker), .command(.yes))
    XCTAssertEqual(parse("back", speaker), .command(.back))
    XCTAssertEqual(parse("next", speaker), .command(.continueOn))

    XCTAssertEqual(parse("test the speaker", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("yes", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("read", VoiceContext(screen: .home)), .ignored(.unavailableHere))
    XCTAssertEqual(parse("connect", VoiceContext(screen: .home)), .command(.connect))

    XCTAssertEqual(parse("next", camera), .ignored(.unavailableHere))
    XCTAssertEqual(parse("next", VoiceContext(screen: .camera, hasReadSentences: true)), .command(.continueOn))
  }

  func testHelpListsOnlyWhatIsValidNow() {
    let cameraHelp = VoiceCommandParser.helpLine(context: camera)
    XCTAssertTrue(cameraHelp.contains("take a photo"))
    XCTAssertFalse(cameraHelp.contains("test the speaker"))
    let setupHelp = VoiceCommandParser.helpLine(context: VoiceContext(screen: .setup(.speakerTest)))
    XCTAssertTrue(setupHelp.contains("test the speaker"))
    XCTAssertFalse(setupHelp.contains("take a photo"))
    XCTAssertTrue(VoiceCommandParser.helpLine(context: VoiceContext(screen: .home, requiresWakeWord: true)).hasPrefix("Say reader first"))
  }

  func testEveryStepHasHelpStopAndAWayForward() {
    for step in OnboardingStep.allCases {
      let available = VoiceCommandParser.availableCommands(context: VoiceContext(screen: .setup(step)))
      XCTAssertTrue(available.contains(.help), step.rawValue)
      XCTAssertTrue(available.contains(.stop), step.rawValue)
      XCTAssertTrue(available.contains(.continueOn), step.rawValue)
    }
  }
}

final class VoiceListenerRuleTests: XCTestCase {
  private let allowed = VoiceListenerPolicy.Inputs(phoneMic: .granted, speechRecognition: .granted)

  func testPhoneIsUsedWithNoSession() {
    XCTAssertEqual(VoiceListenerPolicy.decide(allowed), .phone)
  }

  func testGlassesPreferredWhenSessionAndMicGranted() {
    var inputs = allowed
    inputs.glassesAvailable = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .phone, "no wearable mic grant yet")
    inputs.glassesMicGranted = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .glasses)
    inputs.glassesCoolingOff = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .phone, "falls back after a failure")
  }

  func testGlassesWorkWithPhonePermissionsDenied() {
    var inputs = VoiceListenerPolicy.Inputs(glassesAvailable: true, glassesMicGranted: true, phoneMic: .denied, speechRecognition: .denied)
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .glasses)
    inputs.glassesAvailable = false
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .denied)
  }

  func testPausesAndOffWin() {
    var inputs = allowed
    inputs.recording = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.recording))
    inputs = allowed
    inputs.inBackground = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.background))
    inputs = allowed
    inputs.interrupted = true
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .paused(.interrupted))
    inputs.enabled = false
    XCTAssertEqual(VoiceListenerPolicy.decide(inputs), .off)
  }

  func testPermissionsAndRecognizer() {
    XCTAssertEqual(VoiceListenerPolicy.decide(.init()), .needsPermission)
    XCTAssertEqual(VoiceListenerPolicy.decide(.init(phoneMic: .granted, speechRecognition: .notDetermined)), .needsPermission)
    XCTAssertEqual(VoiceListenerPolicy.decide(.init(phoneMic: .denied, speechRecognition: .notDetermined)), .denied)
    XCTAssertEqual(
      VoiceListenerPolicy.decide(.init(phoneMic: .granted, speechRecognition: .granted, onDeviceRecognizerAvailable: false)),
      .noOnDeviceRecognition)
  }

  func testLocaleChoice() {
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { _ in true }, "en-ZA")
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { $0 != "en-ZA" }, "en-GB")
    XCTAssertEqual(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { $0 == "en-US" }, "en-US")
    XCTAssertNil(PhoneLocaleChoice.choose(deviceLocale: "en_ZA") { _ in false })
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "en_ZA@rg=gbzzzz"), ["en-ZA", "en-GB", "en-US"])
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "en_GB"), ["en-GB", "en-US"])
    // The commands are English, so a German phone listens in English.
    XCTAssertEqual(PhoneLocaleChoice.candidates(deviceLocale: "de_DE"), ["en-GB", "en-US"])
  }

  func testBackoffDoublesCapsAndResets() {
    var backoff = RestartBackoff()
    XCTAssertEqual((0..<8).map { _ in backoff.next() }, [0.5, 1, 2, 4, 8, 16, 30, 30])
    backoff.noteRanFor(5)
    XCTAssertEqual(backoff.attempts, 8)
    backoff.noteRanFor(RestartBackoff.stableAfter)
    XCTAssertEqual(backoff.next(), 0.5)
  }

  func testRoutineRecognitionErrors() {
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kAFAssistantErrorDomain", code: 1110), .routine)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 301), .routine)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 201), .recognizerUnavailable)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kLSRErrorDomain", code: 300), .transient)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "kAFAssistantErrorDomain", code: 1101), .transient)
    XCTAssertEqual(SpeechRecognitionFailure.classify(domain: "other", code: 1110), .transient)
  }

  func testGlassesTranscriptFilter() {
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "stop", isFinal: false, confidence: 1))
    XCTAssertEqual(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: 0.9), "stop")
    XCTAssertEqual(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: -1), "stop", "-1 is no score")
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "stop", isFinal: true, confidence: 0.1))
    XCTAssertNil(GlassesTranscriptFilter.accepted(text: "", isFinal: true, confidence: -1))
  }

  func testGlassesSpeechFlag() throws {
    let suite = "VoiceFlag.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: true))
    XCTAssertFalse(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: false))
    defaults.set(true, forKey: VoiceFeatureFlags.glassesSpeechKey)
    XCTAssertTrue(VoiceFeatureFlags.glassesSpeechEnabled(defaults: defaults, isDebugBuild: false))
  }

  func testCommandsNeverOpenHFP() {
    for ducking in [false, true] {
      let listening = A11yAudioSession.sessionConfiguration(phoneMic: true, ducking: ducking)
      XCTAssertEqual(listening.category, .playAndRecord)
      XCTAssertTrue(listening.options.contains(.allowBluetoothA2DP))
      XCTAssertTrue(listening.options.contains(.defaultToSpeaker))
      XCTAssertFalse(listening.options.contains(.allowBluetoothHFP))
      XCTAssertEqual(listening.options.contains(.duckOthers), ducking)
      XCTAssertEqual(listening.options.contains(.mixWithOthers), !ducking)
    }
    // Without the phone mic, it's what it always was.
    let idle = A11yAudioSession.sessionConfiguration(phoneMic: false, ducking: false)
    XCTAssertEqual(idle.category, .playback)
    XCTAssertEqual(idle.mode, .spokenAudio)
    XCTAssertEqual(idle.options, .mixWithOthers)
    XCTAssertEqual(A11yAudioSession.sessionConfiguration(phoneMic: false, ducking: true).options, .duckOthers)
  }
}

// MARK: - VoiceControl with fakes

@MainActor
private final class FakeListener: SpeechListener {
  let kind: VoiceListenerKind
  var onEvent: (@MainActor (SpeechListenerEvent) -> Void)?
  var starts = 0
  var stops = 0

  init(kind: VoiceListenerKind) { self.kind = kind }

  func start() { starts += 1 }
  func stop() { stops += 1 }
}

@MainActor
private final class Harness {
  var earcons: [Earcon] = []
  var lines: [String] = []
  var finishLines = true
  var speaking = false
  var spokenText = ""
  var micHearsVoiceOver = false
  var phoneMic = VoicePermission.granted
  var speech = VoicePermission.granted
  var locale: String? = "en-ZA"
  var requested = 0
  var grantOnRequest = true
  var phoneListeners: [FakeListener] = []
  var stopSpeechCalls = 0
  var repeatCalls = 0
  var idleTimerDisabled = false
  var now = Date(timeIntervalSince1970: 1000)

  func environment() -> VoiceControl.Environment {
    VoiceControl.Environment(
      isInert: false,
      makePhoneListener: { [unowned self] _ in
        let listener = FakeListener(kind: .phone)
        phoneListeners.append(listener)
        return listener
      },
      phoneLocale: { [unowned self] in locale },
      phoneMicPermission: { [unowned self] in phoneMic },
      speechPermission: { [unowned self] in speech },
      requestPermissions: { [unowned self] in
        requested += 1
        let result: VoicePermission = grantOnRequest ? .granted : .denied
        phoneMic = result
        speech = result
      },
      say: { [unowned self] text, earcon, _, onFinish in
        lines.append(text)
        if let earcon { earcons.append(earcon) }
        onFinish?(finishLines)
      },
      playEarcon: { [unowned self] in earcons.append($0) },
      isSpeaking: { [unowned self] in speaking },
      textBeingSpoken: { [unowned self] in spokenText },
      stopSpeech: { [unowned self] in stopSpeechCalls += 1 },
      repeatLast: { [unowned self] in repeatCalls += 1 },
      hasReadSentences: { false },
      micHearsVoiceOver: { [unowned self] _ in micHearsVoiceOver },
      followsVoiceOverRate: { false },
      setIdleTimerDisabled: { [unowned self] in idleTimerDisabled = $0 },
      glassesSpeechEnabled: { true },
      now: { [unowned self] in now })
  }
}

@MainActor
final class VoiceControlTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()
  private var preferences: A11yPreferences!
  private var harness: Harness!
  private var control: VoiceControl!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "VoiceControlTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    preferences = A11yPreferences(defaults: defaults)
    harness = Harness()
    control = VoiceControl(environment: harness.environment(), preferences: preferences)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    control = nil
    harness = nil
    try await super.tearDown()
  }

  private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
  }

  private func beginListening() -> FakeListener {
    control.begin()
    control.setScreen(.camera) { _ in false }
    let listener = harness.phoneListeners.last!
    listener.onEvent?(.started)
    return listener
  }

  func testStartsListeningOnLaunchWithPermissions() {
    let listener = beginListening()
    XCTAssertEqual(listener.starts, 1)
    XCTAssertEqual(control.status, .listening)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertTrue(harness.idleTimerDisabled)
  }

  func testFirstListenCueAndIntroLineOnlyOnce() {
    _ = beginListening()
    XCTAssertEqual(harness.earcons, [.listening])
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceControlOn])
    XCTAssertTrue(preferences.voiceControlIntroHeard)

    let again = VoiceControl(environment: harness.environment(), preferences: preferences)
    harness.lines = []
    again.begin()
    again.setScreen(.camera) { _ in false }
    harness.phoneListeners.last?.onEvent?(.started)
    XCTAssertEqual(harness.lines, [])
  }

  func testIntroComesBackIfCutOff() {
    harness.finishLines = false
    _ = beginListening()
    XCTAssertFalse(preferences.voiceControlIntroHeard)
  }

  func testOffSwitch() {
    let listener = beginListening()
    control.setEnabled(false)
    XCTAssertEqual(control.status, .off)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertFalse(preferences.voiceControlEnabled)
    XCTAssertFalse(harness.idleTimerDisabled)
  }

  func testEarconComesBeforeTheActionAndCommandIsRemembered() {
    _ = beginListening()
    harness.earcons = []
    var earconsAtAction: [Earcon] = []
    control.setScreen(.camera) { [harness] _ in
      earconsAtAction = harness!.earcons
      return true
    }
    control.inject(transcript: "read this")
    XCTAssertEqual(earconsAtAction, [.heard])
    XCTAssertEqual(control.lastCommand, .read)
  }

  func testConversationGetsNoReaction() {
    _ = beginListening()
    harness.earcons = []
    harness.lines = []
    control.inject(transcript: "what time is the bus")
    XCTAssertEqual(harness.earcons, [])
    XCTAssertEqual(harness.lines, [])
    XCTAssertNil(control.lastCommand)
  }

  func testWakeWordNotUnderstoodSaysSoBriefly() {
    _ = beginListening()
    harness.earcons = []
    harness.lines = []
    control.inject(transcript: "reader do a backflip")
    XCTAssertEqual(harness.earcons, [.uncertain])
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceNotUnderstood])
  }

  func testWhileSpeakingOnlyTheWakeWordCounts() {
    _ = beginListening()
    harness.speaking = true
    harness.spokenText = "The train did not stop."
    control.inject(transcript: "stop")
    XCTAssertEqual(harness.stopSpeechCalls, 0)
    control.inject(transcript: "reader stop")
    XCTAssertEqual(harness.stopSpeechCalls, 1)
  }

  func testHelpSpeaksWhatIsValidHere() {
    _ = beginListening()
    harness.lines = []
    control.inject(transcript: "help")
    XCTAssertEqual(harness.lines.count, 1)
    XCTAssertTrue(harness.lines[0].contains("take a photo"))
    XCTAssertEqual(control.availableCommands.contains(.takePhoto), true)
  }

  func testFasterAndSlowerChangeTheRateWithinLimits() {
    _ = beginListening()
    let start = preferences.speechRate
    control.inject(transcript: "faster")
    XCTAssertGreaterThan(preferences.speechRate, start)
    preferences.speechRate = AVSpeechUtteranceMaximumSpeechRate
    harness.lines = []
    control.inject(transcript: "faster")
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceFastest])
  }

  func testYieldsToRecordingAndComesBackWithACue() {
    let listener = beginListening()
    harness.earcons = []
    control.recordingWillStart()
    XCTAssertEqual(listener.stops, 1, "must be off before the recorder takes the session")
    XCTAssertEqual(control.status, .paused)
    XCTAssertEqual(control.reason, VoicePauseReason.recording.text)
    XCTAssertNil(control.activeListener)

    control.recordingDidEnd()
    let resumed = harness.phoneListeners.last!
    XCTAssertFalse(resumed === listener)
    resumed.onEvent?(.started)
    XCTAssertEqual(control.status, .listening)
    XCTAssertEqual(harness.earcons, [.listening])
  }

  func testInterruptionPausesAndResumes() {
    let listener = beginListening()
    control.noteInterruption(began: true)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.status, .paused)
    control.noteInterruption(began: false)
    XCTAssertEqual(harness.phoneListeners.count, 2)
    XCTAssertEqual(control.status, .starting)
  }

  func testBackgroundStopsTheMic() {
    let listener = beginListening()
    control.noteBackground(true)
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.reason, VoicePauseReason.background.text)
    XCTAssertFalse(harness.idleTimerDisabled)
    control.noteBackground(false)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testFailureRestartsWithoutACueOrALine() async throws {
    let listener = beginListening()
    harness.earcons = []
    harness.lines = []
    listener.onEvent?(.failed(reason: "test", transient: true))
    XCTAssertEqual(listener.stops, 1)
    XCTAssertEqual(control.status, .starting)
    try await Task.sleep(for: .milliseconds(700))  // first backoff is 0.5 s
    XCTAssertEqual(harness.phoneListeners.count, 2)
    harness.phoneListeners.last?.onEvent?(.started)
    XCTAssertEqual(control.status, .listening)
    XCTAssertEqual(harness.earcons, [])
    XCTAssertEqual(harness.lines, [])
  }

  func testRepeatedFailureIsSpokenOnce() async throws {
    _ = beginListening()
    harness.lines = []
    for _ in 0..<3 {
      let current = harness.phoneListeners.last!
      current.onEvent?(.failed(reason: "test", transient: true))
      if control.status == .unavailable { break }
      try await Task.sleep(for: .seconds(control.status == .starting ? 2.2 : 0))
    }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceControlTroubled])
  }

  func testAFlappingListenerSpeaksTroubleOnlyOnce() async throws {
    _ = beginListening()
    harness.lines = []
    // Starts then fails at once, again and again; time doesn't pass, so it never counts as stable.
    for _ in 0..<4 {
      harness.phoneListeners.last?.onEvent?(.failed(reason: "test", transient: true))
      control.noteBackground(false)  // skips the backoff wait: reconcile starts a new listener
      harness.phoneListeners.last?.onEvent?(.started)
    }
    XCTAssertEqual(harness.lines.filter { $0 == SpokenMessage.voiceControlTroubled }.count, 1)
  }

  func testDeniedSpeaksWhyAndHowOncePerLaunch() {
    harness.phoneMic = .denied
    control.begin()
    control.setScreen(.camera) { _ in false }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(control.reason, SpokenMessage.voicePermissionDenied)
    XCTAssertEqual(harness.lines, [SpokenMessage.voicePermissionDenied])
    XCTAssertEqual(harness.requested, 0)
    control.setScreen(.home) { _ in false }
    XCTAssertEqual(harness.lines.count, 1)
    XCTAssertEqual(harness.phoneListeners.count, 0)
  }

  func testNoOnDeviceRecognizerSaysWhy() {
    harness.locale = nil
    control.begin()
    control.setScreen(.camera) { _ in false }
    XCTAssertEqual(control.status, .unavailable)
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceNoOnDeviceRecognition])
  }

  func testSetupDoesNotPromptByItself() {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    control.begin()
    control.setScreen(.setup(.welcome)) { _ in false }
    XCTAssertEqual(harness.requested, 0)
    XCTAssertEqual(harness.lines, [])
    XCTAssertEqual(control.status, .unavailable)
  }

  func testMainScreenExplainsThenAsksThenListens() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    control.begin()
    control.setScreen(.camera) { _ in false }
    await settle()
    XCTAssertEqual(harness.lines.first, SpokenMessage.voiceControlExplanation)
    XCTAssertEqual(harness.requested, 1)
    XCTAssertEqual(harness.phoneListeners.count, 1)
    XCTAssertEqual(harness.phoneListeners[0].starts, 1)
  }

  func testRefusedPromptSpeaksTheFixAndKeepsListeningOff() async {
    harness.phoneMic = .notDetermined
    harness.speech = .notDetermined
    harness.grantOnRequest = false
    control.begin()
    control.setScreen(.camera) { _ in false }
    await settle()
    XCTAssertEqual(harness.lines, [SpokenMessage.voiceControlExplanation, SpokenMessage.voicePermissionDenied])
    XCTAssertEqual(harness.phoneListeners.count, 0)
  }

  // MARK: Choosing and swapping listeners

  private func attachFakeGlasses(permission: VoicePermission = .granted) -> () -> FakeListener? {
    var made: FakeListener?
    control.attachGlasses(
      makeListener: {
        let listener = FakeListener(kind: .glasses)
        made = listener
        return listener
      },
      checkPermission: { permission },
      requestPermission: { .granted })
    return { made }
  }

  func testGlassesTakeOverWithASessionAndHandBackWhenItEnds() async {
    let phone = beginListening()
    let glasses = attachFakeGlasses()
    await settle()
    XCTAssertEqual(phone.stops, 1, "the phone mic is released")
    XCTAssertEqual(control.activeListener, .glasses)
    XCTAssertEqual(glasses()?.starts, 1)
    glasses()?.onEvent?(.started)
    XCTAssertEqual(control.status, .listening)

    control.detachGlasses()
    XCTAssertEqual(glasses()?.stops, 1)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testWithoutTheWearableMicThePhoneStaysAndAButtonIsOffered() async {
    let phone = beginListening()
    _ = attachFakeGlasses(permission: .notDetermined)
    await settle()
    XCTAssertEqual(phone.stops, 0)
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertTrue(control.canRequestGlassesMicrophone)
  }

  func testGlassesFailureFallsBackToThePhone() async {
    _ = beginListening()
    let glasses = attachFakeGlasses()
    await settle()
    glasses()?.onEvent?(.started)
    glasses()?.onEvent?(.failed(reason: "startFailed", transient: false))
    XCTAssertEqual(control.activeListener, .phone)
    XCTAssertEqual(harness.phoneListeners.count, 2)
  }

  func testTranscriptsFromAReplacedListenerAreIgnored() async {
    let phone = beginListening()
    let onEvent = phone.onEvent
    _ = attachFakeGlasses()
    await settle()
    onEvent?(.transcript("read"))
    XCTAssertNil(control.lastCommand)
  }

  func testSharedInstanceIsInertInTests() {
    XCTAssertTrue(LaunchOptions.isAutomatedTest)
    VoiceControl.shared.begin()
    XCTAssertNil(VoiceControl.shared.activeListener)
    XCTAssertNotEqual(VoiceControl.shared.status, .listening)
    XCTAssertEqual(AVAudioSession.sharedInstance().category == .record, false)
  }
}

// MARK: - The real GlassesSpeechListener against the mock

@MainActor
final class GlassesSpeechListenerMockTests: XCTestCase {
  private var mock: MockGlasses?
  private var selector: AutoDeviceSelector?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    glasses.powerOn()
    glasses.don()
    mock = glasses
    MockDeviceKit.shared.permissions.set(.microphone, .granted)
    try await Task.sleep(for: .seconds(1))
  }

  override func tearDown() async throws {
    await MockDeviceKit.shared.disable()
    mock = nil
    try await super.tearDown()
  }

  private func startedSession() async throws -> DeviceSession {
    // The selector only knows a device once its stream has reported one, as in CameraViewModel.
    let selector = AutoDeviceSelector(wearables: Wearables.shared)
    self.selector = selector
    for await device in selector.activeDeviceStream() where device != nil { break }
    let session = try Wearables.shared.createSession(deviceSelector: selector)
    try session.start()
    for _ in 0..<100 where session.state != .started {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(session.state, .started)
    return session
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  func testFinalTranscriptsGetThroughIncludingNoScore() async throws {
    let glasses = try XCTUnwrap(mock)
    let session = try await startedSession()
    defer { session.stop() }

    let listener = GlassesSpeechListener(session: session)
    var events: [SpeechListenerEvent] = []
    listener.onEvent = { events.append($0) }
    listener.start()
    let speech = glasses.services.speech
    try await waitUntil { speech.isListening }
    XCTAssertTrue(speech.isListening, "the mock should be listening")
    try await waitUntil { events.contains(.started) }
    XCTAssertTrue(events.contains(.started))

    speech.simulateTranscription(text: "partial stop", isFinal: false, confidence: 0.9)
    speech.simulateTranscription(text: "read this", isFinal: true, confidence: 0.9)
    try await waitUntil { events.contains(.transcript("read this")) }
    XCTAssertTrue(events.contains(.transcript("read this")))
    XCTAssertFalse(events.contains(.transcript("partial stop")))

    listener.stop()
    try await waitUntil { !speech.isListening }
    XCTAssertFalse(speech.isListening, "stop should end listening")
  }

  func testMockErrorIsReportedAsFailure() async throws {
    let glasses = try XCTUnwrap(mock)
    let session = try await startedSession()
    defer { session.stop() }

    let listener = GlassesSpeechListener(session: session)
    var events: [SpeechListenerEvent] = []
    listener.onEvent = { events.append($0) }
    listener.start()
    let speech = glasses.services.speech
    try await waitUntil { speech.isListening }
    speech.simulateError(errorCode: 1, message: "test")
    try await waitUntil {
      events.contains { if case .failed = $0 { true } else { false } }
    }
    XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
  }
}
