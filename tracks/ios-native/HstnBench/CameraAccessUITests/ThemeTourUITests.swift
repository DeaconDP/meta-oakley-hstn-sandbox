/*
 * ThemeTourUITests - walks every screen and keeps a screenshot of each, to look at
 *
 * Light, dark, Increase Contrast's palette and the largest accessibility text size, on the Mock
 * Device Kit. Attachments are kept in the result bundle: `xcrun xcresulttool export attachments`.
 * It also proves the whole path can be walked in each of those: every tap below has to land.
 *
 * Launch flags, all only with --ui-testing: --dark-mode forces dark, --preview-listening shows "Listening" and the "Say ..."
 * hints (nothing listens in a UI test), --progress-seed=streak,pages gives the card real-looking
 * data, and --high-contrast draws the Increase Contrast palette.
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class ThemeTourUITests: XCTestCase {
  private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private var app = XCUIApplication()
  private var variant = ""
  private var pairedDeviceId: String?
  // swiftlint:disable:next implicitly_unwrapped_optional
  private var mockClient: MockDeviceTestClient!

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    addTeardownBlock { [portFilePath] in
      try? FileManager.default.removeItem(atPath: portFilePath)
    }
  }

  override func tearDown() async throws {
    // Only while the app is up: its test server goes with it, and a request to it would never end.
    if let pairedDeviceId, mockClient != nil, app.state == .runningForeground {
      _ = await mockClient.unpairDevice(deviceId: pairedDeviceId)
    }
    pairedDeviceId = nil
    app.terminate()
  }

  // MARK: - Tours

  func testTourLight() async throws {
    try await tour("light", extra: [])
  }

  func testTourDark() async throws {
    try await tour("dark", extra: ["--dark-mode"])
  }

  func testTourIncreaseContrastPalette() async throws {
    try await tour("contrast", extra: ["--high-contrast"])
  }

  func testTourLargestText() async throws {
    try await tour("ax", extra: Self.largestText)
  }

  func testTourDarkLargestText() async throws {
    try await tour("ax-dark", extra: ["--dark-mode"] + Self.largestText)
  }

  // MARK: - The walk

  private func tour(_ name: String, extra: [String]) async throws {
    variant = name

    launch(["--preview-listening", "--progress-seed=3,2"] + extra)
    XCTAssertTrue(app.buttons["connect_glasses_button"].waitForExistence(timeout: 15))
    shot("01-home", scrolled: true)
    app.terminate()

    launch(["--onboarding", "--preview-listening", "--progress-seed=3,2"] + extra)
    let client = MockDeviceTestClient(portFilePath: portFilePath)
    mockClient = client
    let reachable = await client.waitForServer(timeout: 10)
    XCTAssertTrue(reachable, "Test server should be running")

    tap("onboarding_guided_button", before: "02-welcome")
    tap("voice_turn_on_button", before: "03-voice")
    tap("onboarding_continue_button", before: "04-sounds", scrolled: true)
    tap("onboarding_heard_no_button", before: "05-speaker")
    shot("05b-speaker-fixes", scrolled: true)
    tap("onboarding_continue_button", before: nil)
    tap("onboarding_continue_button", before: "06-verbosity", scrolled: true)
    tap("onboarding_continue_button", before: "07-disclaimer", scrolled: true)
    tap("connect_glasses_button", before: "08-connect")

    // Setup finishes by connecting: the celebration is up for a few seconds.
    XCTAssertTrue(app.staticTexts["Waiting for an active device"].waitForExistence(timeout: 20))
    shot("09-setup-finished", settle: 0.8)
    try? await Task.sleep(for: .seconds(4))
    shot("10-camera-waiting", scrolled: true)

    tap("settings_button", before: nil)
    XCTAssertTrue(app.buttons["voice_control_toggle"].waitForExistence(timeout: 5))
    shot("11-settings", scrolled: true)
    scrollToTop()
    tap("settings_button", before: nil)

    let paired = await client.pairDevice()
    let deviceId = try XCTUnwrap(paired)
    pairedDeviceId = deviceId
    let feedSet = await client.setCameraFeed(deviceId: deviceId, resourceName: "read_page", ext: "mp4")
    XCTAssertTrue(feedSet)
    let photoSet = await client.setCapturedImage(deviceId: deviceId, resourceName: "read_page", ext: "png")
    XCTAssertTrue(photoSet)

    XCTAssertTrue(app.buttons["start_session_button"].waitForExistence(timeout: 15))
    tap("start_session_button", before: "12-camera-ready", scrolled: true)
    XCTAssertTrue(app.buttons["start_preview_button"].waitForExistence(timeout: 20))
    tap("start_preview_button", before: "13-session-started", scrolled: true)

    let allow = app.alerts.buttons["Continue"]
    if allow.waitForExistence(timeout: 10) { allow.tap() }
    let springboardAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if springboardAllow.waitForExistence(timeout: 5) { springboardAllow.tap() }
    XCTAssertTrue(app.buttons["stop_preview_button"].waitForExistence(timeout: 20))
    let read = app.buttons["read_button"]
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    shot("14-streaming", settle: 1.5, scrolled: true)

    scrollTo(read)
    read.tap()
    XCTAssertTrue(app.staticTexts["read_sentence"].waitForExistence(timeout: 25))
    // Straight away: this page takes seconds to read, and the celebration only lasts a few.
    attach("15-reading")

    // The seed has two pages today, so reading this one to its end reaches the goal.
    let status = app.staticTexts["read_status"]
    let deadline = Date().addingTimeInterval(90)
    while status.label != "Finished, 4 sentences", Date() < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(status.label, "Finished, 4 sentences")
    // Long enough for the card's spring, well inside its few seconds on screen.
    try? await Task.sleep(for: .milliseconds(500))
    attach("16-goal-reached")
    try? await Task.sleep(for: .seconds(5))
    scrollTo(status)
    shot("17-page-finished")

    let capture = app.buttons["capture_button"]
    scrollTo(capture)
    capture.tap()
    XCTAssertTrue(app.buttons["close_preview_button"].waitForExistence(timeout: 15))
    shot("18-capture-preview", settle: 1)
    app.buttons["close_preview_button"].tap()

    let record = app.buttons["record_button"]
    scrollTo(record)
    record.tap()
    XCTAssertTrue(app.staticTexts["recording_indicator"].waitForExistence(timeout: 10))
    shot("19-recording", settle: 1.2)
    record.tap()
    let close = app.buttons["close_preview_button"]
    XCTAssertTrue(close.waitForExistence(timeout: 15))
    close.tap()
    let end = app.buttons["end_session_button"]
    XCTAssertTrue(end.waitForExistence(timeout: 10))
    scrollTo(end)
    end.tap()
  }

  // MARK: - Helpers

  private func launch(_ arguments: [String]) {
    app.launchArguments = ["--ui-testing"] + arguments
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }

  /// Screenshot `before`, then the button, scrolling to it if needed.
  private func tap(_ id: String, before name: String?, scrolled: Bool = false) {
    let button = app.buttons[id]
    XCTAssertTrue(button.waitForExistence(timeout: 15), "\(id) should appear")
    if let name { shot(name, settle: 0.6, scrolled: scrolled) }
    scrollTo(button)
    button.tap()
  }

  private func scrollTo(_ element: XCUIElement) {
    var attempts = 0
    while !element.isHittable, attempts < 12 {
      app.swipeUp(velocity: .slow)
      attempts += 1
    }
    attempts = 0
    while !element.isHittable, attempts < 12 {
      app.swipeDown(velocity: .slow)
      attempts += 1
    }
  }

  private func scrollToTop() {
    for _ in 0..<6 { app.swipeDown(velocity: .fast) }
  }

  private func shot(_ name: String, settle: Double = 0.6, scrolled: Bool = false) {
    Thread.sleep(forTimeInterval: settle)
    attach(name)
    guard scrolled else { return }
    app.swipeUp(velocity: .slow)
    Thread.sleep(forTimeInterval: 0.5)
    attach(name + "-scrolled")
    app.swipeUp(velocity: .slow)
    Thread.sleep(forTimeInterval: 0.5)
    attach(name + "-scrolled2")
    scrollToTop()
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "\(variant)-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
