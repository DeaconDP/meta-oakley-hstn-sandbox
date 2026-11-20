/*
 * VoiceControlUITests - driving the real screens with injected transcripts
 *
 * `--voice-inject` adds a field that hands text to VoiceControl.inject(transcript:), since a UI test
 * has no mic. `--ui-testing` guarantees nothing prompts or opens the mic, which these also check.
 */

import XCTest

@MainActor
final class VoiceControlUITests: XCTestCase {
  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private var app = XCUIApplication()

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    addTeardownBlock { [portFilePath] in
      try? FileManager.default.removeItem(atPath: portFilePath)
    }
  }

  override func tearDown() async throws {
    app.terminate()
  }

  private func launch(_ extra: [String]) {
    app.launchArguments = ["--ui-testing", "--voice-inject"] + extra
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }

  private func say(_ text: String) {
    let field = app.textFields["voice_test_transcript"]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "The transcript field should exist")
    field.tap()
    field.typeText(text + "\n")
  }

  private func waitForLastCommand(_ raw: String) {
    let label = app.staticTexts["voice_test_last_command"]
    let matched = expectation(for: NSPredicate(format: "label == %@", raw), evaluatedWith: label)
    wait(for: [matched], timeout: 10)
  }

  private func waitForStep(_ step: String) {
    XCTAssertTrue(app.descendants(matching: .any)["onboarding_\(step)"].waitForExistence(timeout: 10), "Expected step \(step)")
  }

  /// The toolbox is the default: the mic is off until the mic button is tapped.
  func testUITestLaunchDoesNotListenOrPrompt() {
    launch([])
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "off")
    XCTAssertTrue(app.buttons["push_to_talk_button"].waitForExistence(timeout: 10))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "No permission dialog in a UI test")
  }

  /// Hands-free wants to listen, but a UI test never opens the mic. No mic button: it's always on.
  func testHandsFreeLaunchWantsToListenButDoesNotInATest() {
    launch(["--hands-free"])
    XCTAssertTrue(app.switches["hands_free_toggle"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "unavailable")
    XCTAssertFalse(app.buttons["push_to_talk_button"].exists)
  }

  func testHandsFreeOffByVoiceShowsTheMicButton() {
    launch(["--hands-free"])
    XCTAssertTrue(app.switches["hands_free_toggle"].waitForExistence(timeout: 10))
    // Hands-free speaks its opening line at launch, and while the app speaks only "reader, ..." counts.
    say("reader, touch mode")
    waitForLastCommand("handsFreeOff")
    XCTAssertTrue(app.buttons["push_to_talk_button"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "off")
  }

  func testConnectByVoiceReachesTheCameraScreen() {
    launch([])
    XCTAssertTrue(app.buttons["Connect my glasses"].waitForExistence(timeout: 15))
    say("please connect my glasses")
    waitForLastCommand("connect")
    XCTAssertTrue(app.staticTexts["Put on your glasses"].waitForExistence(timeout: 20), "Should reach the camera screen")
  }

  func testConversationDoesNothing() {
    launch([])
    XCTAssertTrue(app.buttons["Connect my glasses"].waitForExistence(timeout: 15))
    say("I will connect with him tomorrow")
    XCTAssertEqual(app.staticTexts["voice_test_last_command"].label, "none")
    XCTAssertTrue(app.buttons["Connect my glasses"].exists)
  }

  /// Setup is one screen: "connect" there goes straight to the main screen.
  func testSetupByVoiceGoesStraightToTheMainScreen() {
    launch(["--onboarding"])
    // The screen speaks as it appears, and while the app speaks only "reader, ..." counts.
    waitForStep("welcome")
    say("reader, repeat")
    waitForLastCommand("repeatLast")
    say("reader, connect")
    waitForLastCommand("connect")
    XCTAssertTrue(app.staticTexts["Put on your glasses"].waitForExistence(timeout: 20), "Should reach the main screen")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.exists, "No permission dialog in a UI test")
  }

  func testNotNowByVoiceGoesToTheHomeScreen() {
    launch(["--onboarding"])
    waitForStep("welcome")
    say("reader, not now")
    waitForLastCommand("no")
    XCTAssertTrue(app.buttons["Connect my glasses"].waitForExistence(timeout: 10), "Should land on the home screen")
  }

  func testSettingsShowsVoiceAndHasTheSwitches() {
    launch([])
    let connect = app.buttons["Connect my glasses"]
    XCTAssertTrue(connect.waitForExistence(timeout: 15))
    connect.tap()
    let settings = app.buttons["settings_button"]
    XCTAssertTrue(settings.waitForExistence(timeout: 20))
    settings.tap()
    let toggle = app.switches["hands_free_toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["use_voiceover_voice_toggle"].exists)
    XCTAssertTrue(app.buttons["glasses_display_toggle"].exists)
    XCTAssertTrue(app.staticTexts["voice_name_label"].label.hasPrefix("Voice: "))
    XCTAssertEqual(toggle.value as? String, "0", "the toolbox is the default")
    // The switch itself sits at the trailing edge; the label beside it doesn't flip it.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "unavailable", "hands-free wants the mic; tests never open it")
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "off")
  }
}
