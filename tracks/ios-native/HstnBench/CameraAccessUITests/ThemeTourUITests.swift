/*
 * ThemeTourUITests - walks every screen and keeps a screenshot of each, to look at
 *
 * Light, dark, Increase Contrast's palette and the largest accessibility text size, on the Mock
 * Device Kit. Attachments are kept in the result bundle: `xcrun xcresulttool export attachments`.
 * It also proves the whole path can be walked in each of those: every tap below has to land.
 *
 * Launch flags, all only with --ui-testing: --dark-mode forces dark and --light-mode light (the app is
 * dark-first otherwise), --preview-listening shows "Listening" and the "Say ..."
 * hints (nothing listens in a UI test), and --high-contrast draws the Increase Contrast palette.
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
    try await tour("light", extra: ["--light-mode"])
  }

  func testTourDark() async throws {
    try await tour("dark", extra: ["--dark-mode"])
  }

  func testTourIncreaseContrastPalette() async throws {
    try await tour("contrast", extra: ["--light-mode", "--high-contrast"])
  }

  func testTourLargestText() async throws {
    try await tour("ax", extra: ["--light-mode"] + Self.largestText)
  }

  func testTourDarkLargestText() async throws {
    try await tour("ax-dark", extra: ["--dark-mode"] + Self.largestText)
  }

  // MARK: - The walk

  private func tour(_ name: String, extra: [String]) async throws {
    variant = name

    launch(["--preview-listening"] + extra)
    XCTAssertTrue(app.buttons["connect_glasses_button"].waitForExistence(timeout: 15))
    shot("01-home", scrolled: true)
    app.terminate()

    launch(["--onboarding", "--preview-listening"] + extra)
    let client = MockDeviceTestClient(portFilePath: portFilePath)
    mockClient = client
    let reachable = await client.waitForServer(timeout: 10)
    XCTAssertTrue(reachable, "Test server should be running")

    // The one first-run screen. Connecting finishes setup and goes straight to the main screen.
    XCTAssertTrue(app.descendants(matching: .any)["onboarding_welcome"].waitForExistence(timeout: 15))
    tap("connect_glasses_button", before: "02-welcome", scrolled: true)

    XCTAssertTrue(app.staticTexts["Put on your glasses"].waitForExistence(timeout: 20))
    shot("03-waiting-for-glasses", settle: 0.8, scrolled: true)

    tap("settings_button", before: nil)
    XCTAssertTrue(app.buttons["voice_control_toggle"].waitForExistence(timeout: 5))
    // Not `scrolled:`: its swipes back to the top would pull the sheet down.
    shot("04-settings")
    app.swipeUp(velocity: .slow)
    shot("04-settings-scrolled", settle: 0.5)
    app.swipeUp(velocity: .slow)
    shot("04-settings-scrolled2", settle: 0.5)
    // Settings is a sheet over the main screen: Done closes it.
    tap("settings_done_button", before: nil)

    let paired = await client.pairDevice()
    let deviceId = try XCTUnwrap(paired)
    pairedDeviceId = deviceId
    let feedSet = await client.setCameraFeed(deviceId: deviceId, resourceName: "read_page", ext: "mp4")
    XCTAssertTrue(feedSet)
    let photoSet = await client.setCapturedImage(deviceId: deviceId, resourceName: "read_page", ext: "png")
    XCTAssertTrue(photoSet)

    XCTAssertTrue(app.staticTexts["Ready to read"].waitForExistence(timeout: 15))
    shot("05-ready-to-read", settle: 1, scrolled: true)

    // One tap: the camera starts itself, then the page is read.
    let read = app.buttons["read_button"]
    scrollTo(read)
    read.tap()
    let allow = app.alerts.buttons["Continue"]
    if allow.waitForExistence(timeout: 15) { allow.tap() }
    let springboardAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if springboardAllow.waitForExistence(timeout: 5) { springboardAllow.tap() }
    // The card is worth seeing even when the read falls back to guidance, so the shot comes first.
    let sentenceShown = app.staticTexts["read_sentence"].waitForExistence(timeout: 25)
    attach("06-reading")
    XCTAssertTrue(sentenceShown)

    let status = app.staticTexts["read_status"]
    let deadline = Date().addingTimeInterval(90)
    while status.label != "Finished, 4 sentences", Date() < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(status.label, "Finished, 4 sentences")
    scrollTo(status)
    shot("07-page-finished")
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
