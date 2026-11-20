/*
 * PhoneCameraTests - V0 "Glasses optional": which camera reads (CameraSourcePolicy and
 * CameraSourceRouter), the voice phrases for switching and the torch, the phone camera's spoken
 * pitfalls, and the Simulator's no-camera path end to end through TextReader.
 *
 * The Simulator has no camera, so the router tests use a fake phone camera and a fake glasses
 * source; PhoneFrameSource itself is tested only where it can be: no camera.
 */

import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Fakes

@MainActor
private final class FakePhoneCamera: PhoneCamera {
  var problem: PhoneCameraProblem?
  var isRunning = false
  var hasTorch = true
  var isTorchOn = false
  var readiness: ReadStreamReadiness = .starting
  var prepareCalls = 0
  var stopCalls = 0

  var cameraKind: CameraKind { .phone }
  var latestReadFrame: ReadFrame? { nil }

  func prepareStreamForReading() -> ReadStreamReadiness {
    prepareCalls += 1
    return readiness
  }

  func captureStillForReading() async -> UIImage? { nil }

  func stopReadingStream() { stopCalls += 1 }

  func setTorch(_ on: Bool) -> TorchResult {
    guard hasTorch else { return .noTorch }
    isTorchOn = on
    return on ? .on : .off
  }
}

@MainActor
private final class FakeGlasses: ReadFrameSource {
  var readiness: ReadStreamReadiness = .ready
  var prepareCalls = 0
  var stopCalls = 0

  var latestReadFrame: ReadFrame? { nil }

  func prepareStreamForReading() -> ReadStreamReadiness {
    prepareCalls += 1
    return readiness
  }

  func captureStillForReading() async -> UIImage? { nil }

  func stopReadingStream() { stopCalls += 1 }
}

// MARK: - Policy

final class CameraSourcePolicyTests: XCTestCase {
  func testPhoneAndGlassesChoicesAreFixed() {
    for registered in [false, true] {
      for connected in [false, true] {
        for waitOver in [false, true] {
          XCTAssertEqual(
            CameraSourcePolicy.resolve(.phone, registered: registered, glassesConnected: connected, glassesWaitOver: waitOver), .phone)
          XCTAssertEqual(
            CameraSourcePolicy.resolve(.glasses, registered: registered, glassesConnected: connected, glassesWaitOver: waitOver), .glasses)
        }
      }
    }
  }

  func testAutoIsThePhoneUntilGlassesAreLinked() {
    XCTAssertEqual(CameraSourcePolicy.resolve(.auto, registered: false, glassesConnected: false, glassesWaitOver: false), .phone)
    XCTAssertEqual(CameraSourcePolicy.resolve(.auto, registered: false, glassesConnected: true, glassesWaitOver: true), .phone)
  }

  func testAutoWithLinkedGlassesWaitsThenFallsBack() {
    // Still waiting: give the glasses the benefit of the doubt.
    XCTAssertEqual(CameraSourcePolicy.resolve(.auto, registered: true, glassesConnected: false, glassesWaitOver: false), .glasses)
    XCTAssertEqual(CameraSourcePolicy.resolve(.auto, registered: true, glassesConnected: true, glassesWaitOver: true), .glasses)
    XCTAssertEqual(CameraSourcePolicy.resolve(.auto, registered: true, glassesConnected: false, glassesWaitOver: true), .phone)
    XCTAssertTrue(CameraSourcePolicy.isFallback(.auto, registered: true, glassesConnected: false, glassesWaitOver: true))
    XCTAssertFalse(CameraSourcePolicy.isFallback(.auto, registered: false, glassesConnected: false, glassesWaitOver: true))
    XCTAssertFalse(CameraSourcePolicy.isFallback(.phone, registered: true, glassesConnected: false, glassesWaitOver: true))
  }

  func testCameraScreenNeedsNoRegistrationUnlessGlassesAreAskedFor() {
    XCTAssertTrue(CameraSourcePolicy.showsCameraScreen(.auto, registered: false))
    XCTAssertTrue(CameraSourcePolicy.showsCameraScreen(.phone, registered: false))
    XCTAssertFalse(CameraSourcePolicy.showsCameraScreen(.glasses, registered: false))
    for preference in CameraSourcePreference.allCases {
      XCTAssertTrue(CameraSourcePolicy.showsCameraScreen(preference, registered: true))
    }
  }

  @MainActor
  func testSettingDefaultsToAutoAndPersists() {
    let suite = "PhoneCameraTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(A11yPreferences(defaults: defaults).cameraSource, .auto)
    A11yPreferences(defaults: defaults).cameraSource = .phone
    XCTAssertEqual(A11yPreferences(defaults: defaults).cameraSource, .phone)
  }
}

// MARK: - Router

@MainActor
final class CameraSourceRouterTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var preferences: A11yPreferences!
  private var phone: FakePhoneCamera!
  private var glasses: FakeGlasses!
  private var spoken: [String] = []
  private var readerBusy = false

  override func setUp() async throws {
    suite = "CameraSourceRouterTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    preferences = A11yPreferences(defaults: defaults)
    phone = FakePhoneCamera()
    glasses = FakeGlasses()
    spoken = []
    readerBusy = false
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeRouter(_ preference: CameraSourcePreference = .auto, registered: Bool = false) -> CameraSourceRouter {
    preferences.cameraSource = preference
    let router = CameraSourceRouter(
      preferences: preferences, phone: phone, say: { [weak self] text, _ in self?.spoken.append(text) },
      isReaderBusy: { [weak self] in self?.readerBusy ?? false }, preferenceOverride: preference)
    router.glasses = glasses
    router.registered = registered
    return router
  }

  func testUnregisteredAutoReadsWithThePhone() {
    let router = makeRouter()
    XCTAssertEqual(router.active, .phone)
    XCTAssertEqual(router.cameraKind, .phone)
    XCTAssertEqual(router.prepareStreamForReading(), .starting)
    XCTAssertEqual(phone.prepareCalls, 1)
    XCTAssertEqual(glasses.prepareCalls, 0)
    XCTAssertTrue(spoken.isEmpty, "No glasses, nothing to fall back from")
  }

  func testLinkedGlassesThatDontComeFallBackOnceAndComeBack() {
    let router = makeRouter(registered: true)
    XCTAssertEqual(router.active, .glasses)
    router.glassesWaitEnded()
    router.glassesWaitEnded()
    XCTAssertEqual(router.active, .phone)
    XCTAssertEqual(spoken, [SpokenMessage.glassesFallbackToPhone], "Said once")

    router.glassesConnected = true
    XCTAssertEqual(router.active, .glasses)
    XCTAssertEqual(spoken.last, SpokenMessage.glassesBackFromFallback)
    XCTAssertEqual(phone.stopCalls, 1, "The phone camera stops when the glasses take over")
  }

  func testGlassesArrivingMidReadDontSwitchMidSentence() {
    let router = makeRouter(registered: true)
    router.glassesWaitEnded()
    readerBusy = true
    router.glassesConnected = true
    XCTAssertEqual(spoken, [SpokenMessage.glassesFallbackToPhone])
    XCTAssertEqual(router.active, .phone)
    // The next read uses them.
    XCTAssertEqual(router.prepareStreamForReading(), .ready)
    XCTAssertEqual(router.active, .glasses)
    XCTAssertEqual(glasses.prepareCalls, 1)
    XCTAssertEqual(spoken.last, SpokenMessage.glassesBackFromFallback)
  }

  func testReadingBeforeTheWaitEndsDoesntWaitForAbsentGlasses() {
    let router = makeRouter(registered: true)
    XCTAssertEqual(router.prepareStreamForReading(), .starting)
    XCTAssertEqual(phone.prepareCalls, 1)
    XCTAssertEqual(glasses.prepareCalls, 0)
    XCTAssertEqual(spoken, [SpokenMessage.glassesFallbackToPhone])
  }

  func testConnectedGlassesReadInAuto() {
    let router = makeRouter(registered: true)
    router.glassesConnected = true
    router.glassesWaitEnded()
    XCTAssertEqual(router.prepareStreamForReading(), .ready)
    XCTAssertEqual(glasses.prepareCalls, 1)
    XCTAssertTrue(spoken.isEmpty)
  }

  func testSwitchingByVoiceSaysSoStopsTheOtherCameraAndPersists() {
    let router = makeRouter(registered: true)
    router.glassesConnected = true
    XCTAssertEqual(router.choose(.phone), SpokenMessage.cameraSwitched(to: .phone))
    XCTAssertEqual(router.active, .phone)
    XCTAssertEqual(glasses.stopCalls, 1)
    XCTAssertEqual(A11yPreferences(defaults: defaults).cameraSource, .phone)
    XCTAssertEqual(router.choose(.phone), SpokenMessage.cameraAlreadyInUse(.phone))

    XCTAssertEqual(router.choose(.glasses), SpokenMessage.cameraSwitched(to: .glasses))
    XCTAssertEqual(router.active, .glasses)
    XCTAssertEqual(phone.stopCalls, 1)
    XCTAssertEqual(router.choose(.auto), SpokenMessage.cameraAutomatic)
  }

  func testUseTheGlassesWithoutLinkedGlassesSaysHowToConnect() {
    let router = makeRouter()
    XCTAssertEqual(router.choose(.glasses), SpokenMessage.glassesNeedConnecting)
    XCTAssertFalse(CameraSourcePolicy.showsCameraScreen(router.preference, registered: false), "The connect screen follows")
  }

  func testLinkedButAbsentGlassesChosenSaysToCheckBluetooth() {
    let router = makeRouter(.phone, registered: true)
    XCTAssertEqual(router.choose(.glasses), SpokenMessage.glassesNotAroundYet)
  }

  func testTorchIsThePhones() {
    let router = makeRouter()
    XCTAssertEqual(router.setTorch(true), .on)
    XCTAssertTrue(phone.isTorchOn)
    XCTAssertEqual(spoken.last, SpokenMessage.torchOn)
    XCTAssertEqual(router.setTorch(false), .off)
    XCTAssertEqual(spoken.last, SpokenMessage.torchOff)

    phone.hasTorch = false
    XCTAssertEqual(router.setTorch(true), .noTorch)
    XCTAssertEqual(spoken.last, SpokenMessage.torchUnavailable)

    let glassesRouter = makeRouter(.glasses, registered: true)
    XCTAssertEqual(glassesRouter.setTorch(true), .glassesInUse)
    XCTAssertEqual(spoken.last, SpokenMessage.torchGlasses)
  }

  func testWhichCamera() {
    let router = makeRouter()
    XCTAssertEqual(router.whichCameraLine, "You're using the phone camera, chosen automatically.")
    let linked = makeRouter(.phone, registered: true)
    XCTAssertEqual(linked.whichCameraLine, "You're using the phone camera. Say use the glasses to switch.")
    let onGlasses = makeRouter(.glasses, registered: true)
    XCTAssertEqual(onGlasses.whichCameraLine, "You're using the glasses camera. Say use the phone to switch.")
  }

  func testPhoneStatusLine() {
    let router = makeRouter()
    XCTAssertEqual(router.phoneStatusLine, SpokenMessage.phoneReady)
    phone.isRunning = true
    XCTAssertEqual(router.phoneStatusLine, SpokenMessage.phoneCameraOn)
    phone.problem = .permissionDenied
    XCTAssertEqual(router.phoneStatusLine, SpokenMessage.phoneCameraPermissionDenied)
    XCTAssertNil(makeRouter(.glasses, registered: true).phoneStatusLine, "The glasses have their own line")
  }

  func testCoachSituationForThePhone() {
    XCTAssertEqual(CoachSituation.forPhone(problem: nil, hasReadSentences: false), .readyWithPhone)
    XCTAssertEqual(CoachSituation.forPhone(problem: nil, hasReadSentences: true), .afterReading)
    XCTAssertEqual(CoachSituation.forPhone(problem: .permissionDenied, hasReadSentences: false), .phoneCameraBlocked)
    XCTAssertNil(CoachSituation.forPhone(problem: .interrupted, hasReadSentences: false))
  }
}

// MARK: - Voice phrases

final class CameraVoiceCommandTests: XCTestCase {
  private let camera = VoiceContext(screen: .camera)

  private func parse(_ text: String, _ context: VoiceContext? = nil) -> VoiceParseResult {
    VoiceCommandParser.parse(text, context: context ?? camera)
  }

  func testCameraScreenPhrases() {
    let expected: [(String, VoiceCommand)] = [
      ("use the phone", .usePhone), ("Use the phone camera.", .usePhone), ("use my iPhone", .usePhone),
      ("switch to the phone", .usePhone), ("please use the phone", .usePhone),
      ("use the glasses", .useGlasses), ("use the glasses camera", .useGlasses), ("switch to the glasses", .useGlasses),
      ("which camera", .whichCamera), ("which camera am I using", .whichCamera),
      ("torch on", .torchOn), ("turn on the torch", .torchOn), ("flashlight on", .torchOn), ("torch on please", .torchOn),
      ("torch off", .torchOff), ("turn the torch off", .torchOff),
    ]
    for (text, command) in expected {
      XCTAssertEqual(parse(text), .command(command), text)
    }
  }

  /// The new phrases don't take over the old ones.
  func testNoConflictsWithExistingCommands() {
    XCTAssertEqual(parse("connect glasses"), .command(.connect))
    XCTAssertEqual(parse("disconnect the glasses"), .command(.disconnect))
    XCTAssertEqual(parse("glasses display on"), .command(.glassesDisplayOn))
    XCTAssertEqual(parse("display off"), .command(.glassesDisplayOff))
    XCTAssertEqual(parse("not now", VoiceContext(screen: .welcome)), .command(.no))
    // Every command's own phrase means that command wherever it is offered.
    for command in VoiceCommand.allCases {
      for screen in [VoiceScreen.welcome, .home, .camera] {
        let context = VoiceContext(screen: screen, hasReadSentences: true, awaitingAnswer: true)
        guard VoiceCommandParser.availableCommands(context: context).contains(command) else { continue }
        XCTAssertEqual(VoiceCommandParser.parse(command.phrase, context: context), .command(command), "\(command.phrase) on \(screen)")
      }
    }
  }

  func testFirstScreenAndHomeTakeThePhone() {
    let welcome = VoiceContext(screen: .welcome)
    XCTAssertEqual(parse("phone", welcome), .command(.usePhone))
    XCTAssertEqual(parse("use my iPhone's camera", welcome), .command(.usePhone))
    XCTAssertEqual(parse("use the glasses", welcome), .command(.useGlasses))
    XCTAssertEqual(parse("use the phone", VoiceContext(screen: .home)), .command(.usePhone))
    // The torch belongs to the camera screen.
    XCTAssertEqual(parse("torch on", welcome), .ignored(.unavailableHere))
  }

  func testWakeWordStillNeededWhileSpeaking() {
    let speaking = VoiceContext(screen: .camera, isSpeaking: true, spokenText: "Grilled fish with lemon.")
    XCTAssertEqual(parse("torch on", speaking), .ignored(.needsWakeWord))
    XCTAssertEqual(parse("reader, torch on", speaking), .command(.torchOn))
  }

  func testHelpOffersTheCameraCommands() {
    let help = VoiceCommandParser.helpLine(context: camera)
    XCTAssertTrue(help.contains("which camera"), help)
    XCTAssertTrue(help.contains("use the phone"), help)
    XCTAssertTrue(help.contains("torch on"), help)
    XCTAssertTrue(VoiceCommandParser.helpLine(context: VoiceContext(screen: .welcome)).contains("use the phone"))
  }
}

// MARK: - Pitfall wording

final class PhoneCameraWordingTests: XCTestCase {
  private let problems: [PhoneCameraProblem] = [
    .permissionDenied, .permissionRestricted, .noCamera, .setupFailed, .interrupted, .stoppedWithError,
  ]

  func testEveryProblemSaysWhatHappenedAndEndsAsASentence() {
    for problem in problems {
      let line = problem.spokenLine
      XCTAssertTrue(line.hasSuffix("."), line)
      XCTAssertLessThan(line.split(separator: " ").count, 30, line)
      XCTAssertFalse(line.lowercased().contains("something went wrong"), line)
      XCTAssertFalse(problem.title.isEmpty)
    }
  }

  func testPermissionDeniedSaysHowToFixItInSettings() {
    let line = PhoneCameraProblem.permissionDenied.spokenLine
    for word in ["Settings", "SpeakUp", "Camera"] {
      XCTAssertTrue(line.contains(word), "\(word) missing: \(line)")
    }
    XCTAssertTrue(PhoneCameraProblem.permissionDenied.opensSettings)
    XCTAssertFalse(PhoneCameraProblem.noCamera.opensSettings)
  }

  func testNoCameraIsSaidPlainly() {
    XCTAssertTrue(PhoneCameraProblem.noCamera.spokenLine.hasPrefix("No camera available"))
  }

  func testPhoneGuidanceSuggestsTheTorchAndThePhonesDistance() {
    for verbosity in Verbosity.allCases {
      let dark = SpokenMessage.readGuidance(.tooDark, verbosity: verbosity, camera: .phone) ?? ""
      XCTAssertTrue(dark.contains("torch on"), dark)
      let cut = SpokenMessage.readGuidance(.cutOff([.right]), verbosity: verbosity, camera: .phone) ?? ""
      XCTAssertTrue(cut.contains("phone") && cut.contains("right"), cut)
      XCTAssertFalse(cut.contains("head"), cut)
    }
    let none = SpokenMessage.readGuidance(.noText, verbosity: .normal, camera: .phone) ?? ""
    XCTAssertTrue(none.contains("30 centimetres"), none)
    XCTAssertNil(SpokenMessage.readGuidance(.good, verbosity: .normal, camera: .phone))
  }

  func testGlassesGuidanceIsUnchanged() {
    XCTAssertEqual(
      SpokenMessage.readGuidance(.noText, verbosity: .normal),
      "No text found. Hold the page about an arm's length away, a little to your right.")
    XCTAssertEqual(SpokenMessage.readGuidance(.tooDark, verbosity: .short, camera: .glasses), "Too dark.")
  }
}

// MARK: - No camera (the Simulator)

@MainActor
final class PhoneFrameSourceTests: XCTestCase {
  func testNoCameraFailsGracefully() {
    let source = PhoneFrameSource(findDevice: { nil })
    XCTAssertEqual(source.prepareStreamForReading(), .unavailable(SpokenMessage.phoneCameraUnavailable))
    XCTAssertEqual(source.problem, .noCamera)
    XCTAssertFalse(source.isRunning)
    XCTAssertNil(source.latestReadFrame)
    XCTAssertFalse(source.hasTorch)
    XCTAssertEqual(source.setTorch(true), .noTorch)
    // Asking again doesn't change the answer, and never asks for permission.
    XCTAssertEqual(source.prepareStreamForReading(), .unavailable(SpokenMessage.phoneCameraUnavailable))
  }

  #if targetEnvironment(simulator)
  /// The real default: the Simulator has no back camera.
  func testTheSimulatorHasNoCamera() {
    let source = PhoneFrameSource()
    XCTAssertEqual(source.prepareStreamForReading(), .unavailable(SpokenMessage.phoneCameraUnavailable))
  }
  #endif

  /// Read on a device with no camera: the reader says so, with the attention earcon, instead of
  /// waiting for a stream.
  func testReaderSaysNoCameraAvailable() async throws {
    let suite = "PhoneFrameSourceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let router = CameraSourceRouter(
      preferences: A11yPreferences(defaults: defaults), phone: PhoneFrameSource(findDevice: { nil }), say: { _, _ in },
      isReaderBusy: { false }, preferenceOverride: .phone)
    let reader = TextReader.shared
    let previous = reader.source
    reader.source = router
    defer {
      reader.stop()
      reader.source = previous
    }
    reader.read()
    let deadline = Date().addingTimeInterval(3)
    while reader.phase != .guided, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(reader.phase, .guided)
    XCTAssertEqual(reader.notice, SpokenMessage.phoneCameraUnavailable)
  }
}
