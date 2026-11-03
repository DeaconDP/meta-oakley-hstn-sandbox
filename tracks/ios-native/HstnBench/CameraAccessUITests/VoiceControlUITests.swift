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

  func testUITestLaunchDoesNotListenOrPrompt() {
    launch([])
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "unavailable")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "No permission dialog in a UI test")
  }

  func testConnectByVoiceReachesTheCameraScreen() {
    launch([])
    XCTAssertTrue(app.buttons["Connect my glasses"].waitForExistence(timeout: 15))
    say("please connect my glasses")
    waitForLastCommand("connect")
    XCTAssertTrue(app.staticTexts["Waiting for an active device"].waitForExistence(timeout: 20), "Should reach the camera screen")
  }

  func testConversationDoesNothing() {
    launch([])
    XCTAssertTrue(app.buttons["Connect my glasses"].waitForExistence(timeout: 15))
    say("I will connect with him tomorrow")
    XCTAssertEqual(app.staticTexts["voice_test_last_command"].label, "none")
    XCTAssertTrue(app.buttons["Connect my glasses"].exists)
  }

  func testGuidedSetupByVoice() {
    launch(["--onboarding"])
    // Each step speaks as it appears, and while the app speaks only "reader, ..." counts.
    waitForStep("welcome")
    say("reader, yes")
    waitForStep("voiceControl")
    // Doesn't prompt under --ui-testing: it moves on.
    say("reader, yes")
    waitForStep("sounds")
    say("reader, back")
    waitForStep("voiceControl")
    say("reader, skip")
    waitForStep("sounds")
    say("reader, next")
    waitForStep("speakerTest")
    say("reader, test the speaker")
    waitForLastCommand("testSpeaker")
    say("reader, no")
    XCTAssertTrue(app.staticTexts["Things to check"].waitForExistence(timeout: 10), "\"no\" should show the fixes")
    say("reader, continue")
    waitForStep("verbosity")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.exists, "No permission dialog in a UI test")
  }

  /// Not with --voice-inject's field: the audit should see what users see.
  func testVoiceControlStepPassesAudit() throws {
    app.launchArguments = ["--ui-testing", "--onboarding"]
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    let guided = app.buttons["onboarding_guided_button"]
    XCTAssertTrue(guided.waitForExistence(timeout: 15))
    guided.tap()
    XCTAssertTrue(app.buttons["voice_turn_on_button"].waitForExistence(timeout: 10))
    try app.performAccessibilityAudit { issue in
      issue.element?.identifier == "debug_menu_button"
    }
  }

  func testSettingsShowsVoiceAndHasTheSwitches() {
    launch([])
    let connect = app.buttons["Connect my glasses"]
    XCTAssertTrue(connect.waitForExistence(timeout: 15))
    connect.tap()
    let settings = app.buttons["settings_button"]
    XCTAssertTrue(settings.waitForExistence(timeout: 20))
    settings.tap()
    let toggle = app.buttons["voice_control_toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["use_voiceover_voice_toggle"].exists)
    XCTAssertTrue(app.staticTexts["voice_name_label"].label.hasPrefix("Voice: "))
    XCTAssertEqual(toggle.label, "Turn voice control off")
    toggle.tap()
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "off")
    toggle.tap()  // Leave the default for the next test.
    XCTAssertEqual(app.staticTexts["voice_test_status"].label, "unavailable")
  }
}
