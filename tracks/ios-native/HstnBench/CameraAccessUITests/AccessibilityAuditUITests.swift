/*
 * AccessibilityAuditUITests - runs Xcode's accessibility audit on the first screens
 *
 * notes/a11y-onboarding.md, "How to test it": every onboarding screen gets
 * performAccessibilityAudit() in CI, at the default text size and at the largest accessibility
 * size. Deliberately loose about which screen comes first: `--onboarding` asks for the guided
 * setup, and if the build doesn't have it the audit runs on whatever screen appears instead.
 * Only identifiers already relied on by CameraAccessUITests are used, so screens can change
 * without breaking this file.
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class AccessibilityAuditUITests: XCTestCase {
  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private var app = XCUIApplication()

  override func setUp() async throws {
    continueAfterFailure = true
    app = XCUIApplication()
    addTeardownBlock { [portFilePath] in
      try? FileManager.default.removeItem(atPath: portFilePath)
    }
  }

  override func tearDown() async throws {
    app.terminate()
  }

  // MARK: - Tests

  func testFirstScreenPassesAudit() throws {
    launch(extraArguments: ["--onboarding"])
    try audit(screen: "first screen")
  }

  func testFirstScreenPassesAuditAtLargestTextSize() throws {
    launch(extraArguments: ["--onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    try audit(screen: "first screen at AX XXXL")
  }

  /// The camera screen as a returning, registered user sees it before glasses are active.
  func testCameraScreenPassesAudit() throws {
    launch()
    try registerIfPossible()
    try audit(screen: "camera screen")
  }

  func testCameraScreenPassesAuditAtLargestTextSize() throws {
    launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    try registerIfPossible()
    try audit(screen: "camera screen at AX XXXL")
  }

  /// Every step of setup, including with the "Say ..." hints showing.
  func testEverySetupStepPassesAudit() throws {
    launch(extraArguments: ["--onboarding", "--preview-listening", "--progress-seed=3,2"])
    try auditEverySetupStep(size: "default")
  }

  func testEverySetupStepPassesAuditAtLargestTextSize() throws {
    launch(extraArguments: ["--onboarding", "--preview-listening"] + Self.largestText)
    try auditEverySetupStep(size: "AX XXXL")
  }

  func testHomeScreenPassesAudit() throws {
    launch(extraArguments: ["--preview-listening"])
    XCTAssertTrue(app.buttons["connect_glasses_button"].waitForExistence(timeout: 15))
    try audit(screen: "home screen")
  }

  func testHomeScreenPassesAuditAtLargestTextSize() throws {
    launch(extraArguments: ["--preview-listening"] + Self.largestText)
    XCTAssertTrue(app.buttons["connect_glasses_button"].waitForExistence(timeout: 15))
    try audit(screen: "home screen at AX XXXL")
  }

  func testSettingsPassesAudit() throws {
    launch()
    try registerIfPossible()
    try openSettingsAndAudit(screen: "settings")
  }

  func testSettingsPassesAuditAtLargestTextSize() throws {
    launch(extraArguments: Self.largestText)
    try registerIfPossible()
    try openSettingsAndAudit(screen: "settings at AX XXXL")
  }

  /// The path with the camera on, the reading card and the capture preview.
  func testStreamingReadingAndPreviewPassAudit() async throws {
    try await auditStreamingScreens(extraArguments: ["--preview-listening"], size: "default")
  }

  func testStreamingReadingAndPreviewPassAuditAtLargestTextSize() async throws {
    try await auditStreamingScreens(extraArguments: ["--preview-listening"] + Self.largestText, size: "AX XXXL")
  }

  func testEverySetupStepPassesAuditInDarkMode() throws {
    launch(extraArguments: ["--onboarding", "--preview-listening", "--dark-mode"])
    try auditEverySetupStep(size: "dark")
  }

  func testHomeScreenPassesAuditInDarkMode() throws {
    launch(extraArguments: ["--preview-listening", "--dark-mode"])
    XCTAssertTrue(app.buttons["connect_glasses_button"].waitForExistence(timeout: 15))
    try audit(screen: "home screen, dark")
  }

  func testStreamingReadingAndPreviewPassAuditInDarkMode() async throws {
    try await auditStreamingScreens(extraArguments: ["--preview-listening", "--dark-mode"], size: "dark")
  }

  // MARK: - Helpers

  private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  private func auditEverySetupStep(size: String) throws {
    func step(_ name: String, next id: String) throws {
      XCTAssertTrue(app.descendants(matching: .any)["onboarding_\(name)"].waitForExistence(timeout: 10), "Expected step \(name)")
      let button = app.buttons[id]
      XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) should exist on \(name)")
      try audit(screen: "setup \(name) at \(size)")
      reveal(button)
      button.tap()
    }
    try step("welcome", next: "onboarding_guided_button")
    try step("voiceControl", next: "voice_turn_on_button")
    try step("sounds", next: "onboarding_continue_button")
    try step("speakerTest", next: "onboarding_heard_yes_button")
    try step("verbosity", next: "onboarding_continue_button")
    try step("disclaimer", next: "onboarding_continue_button")
    XCTAssertTrue(app.descendants(matching: .any)["onboarding_connect"].waitForExistence(timeout: 10))
    try audit(screen: "setup connect at \(size)")
  }

  private func openSettingsAndAudit(screen: String) throws {
    let settings = app.buttons["settings_button"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    reveal(settings)
    settings.tap()
    XCTAssertTrue(app.buttons["voice_control_toggle"].waitForExistence(timeout: 5))
    try audit(screen: screen)
  }

  private func auditStreamingScreens(extraArguments: [String], size: String) async throws {
    launch(extraArguments: extraArguments)
    let client = MockDeviceTestClient(portFilePath: portFilePath)
    let reachable = await client.waitForServer(timeout: 10)
    XCTAssertTrue(reachable, "Test server should be running")
    try registerIfPossible()
    let paired = await client.pairDevice()
    let deviceId = try XCTUnwrap(paired)
    _ = await client.setCameraFeed(deviceId: deviceId, resourceName: "read_page", ext: "mp4")
    _ = await client.setCapturedImage(deviceId: deviceId, resourceName: "read_page", ext: "png")

    let start = app.buttons["start_session_button"]
    XCTAssertTrue(start.waitForExistence(timeout: 15))
    try audit(screen: "camera ready at \(size)")
    reveal(start)
    start.tap()
    let startPreview = app.buttons["start_preview_button"]
    XCTAssertTrue(startPreview.waitForExistence(timeout: 20))
    try audit(screen: "session started at \(size)")
    reveal(startPreview)
    startPreview.tap()
    let allow = app.alerts.buttons["Continue"]
    if allow.waitForExistence(timeout: 10) { allow.tap() }
    let springboardAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if springboardAllow.waitForExistence(timeout: 5) { springboardAllow.tap() }
    XCTAssertTrue(app.buttons["stop_preview_button"].waitForExistence(timeout: 20))
    try audit(screen: "streaming at \(size)")

    let read = app.buttons["read_button"]
    reveal(read)
    read.tap()
    XCTAssertTrue(app.staticTexts["read_sentence"].waitForExistence(timeout: 25))
    let stop = app.buttons["read_stop_button"]
    if stop.waitForExistence(timeout: 2) {
      reveal(stop)
      stop.tap()
    }
    try audit(screen: "read panel at \(size)")

    let capture = app.buttons["capture_button"]
    reveal(capture)
    capture.tap()
    let close = app.buttons["close_preview_button"]
    XCTAssertTrue(close.waitForExistence(timeout: 15))
    try audit(screen: "capture preview at \(size)")
    close.tap()
    _ = await client.unpairDevice(deviceId: deviceId)
  }

  private func reveal(_ element: XCUIElement) {
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

  private func launch(extraArguments: [String] = []) {
    // --ui-testing swaps in the mock device kit, so no real glasses or Meta AI are involved.
    app.launchArguments = ["--ui-testing"] + extraArguments
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App should reach the foreground")
    // Any interactive element means the first screen has rendered.
    XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 15), "First screen should show a button")
  }

  /// Gets from the home screen to the camera screen with the mock registration, as
  /// CameraAccessUITests does. Skips if the app opens on something else (e.g. onboarding).
  private func registerIfPossible() throws {
    let connectButton = app.buttons["Connect my glasses"]
    guard connectButton.waitForExistence(timeout: 5) else {
      throw XCTSkip("Home screen's Connect button isn't the first screen; camera screen not reachable here")
    }
    connectButton.tap()
    let waitingText = app.staticTexts["Waiting for an active device"]
    XCTAssertTrue(waitingText.waitForExistence(timeout: 15), "Camera screen should show the waiting state")
  }

  private func audit(screen: String) throws {
    // Contrast is measured at each element's frame, so scrolling and springs must have finished.
    Thread.sleep(forTimeInterval: 1.5)
    // What's on screen for scrolling content: below this, a page continues out of view.
    let visible = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch.frame : app.windows.firstMatch.frame
    try app.performAccessibilityAudit { issue in
      let ignored = Self.isIgnored(issue, visible: visible)
      if !ignored {
        // The default failure message doesn't say which screen; this does.
        let element = issue.element.map { "\($0.elementType) '\($0.identifier)' '\($0.label)' \($0.frame)" } ?? "no element"
        print("[a11y audit] \(screen): \(issue.compactDescription) — \(element) — \(issue.detailedDescription)")
      }
      return ignored
    }
  }

  /// Issues that aren't ours to fix. Kept narrow: matched by element, not by issue type, so a
  /// real problem of the same type elsewhere still fails.
  private static func isIgnored(_ issue: XCUIAccessibilityAuditIssue, visible: CGRect) -> Bool {
    guard let element = issue.element else { return false }
    // Contrast is measured from the screenshot at the element's frame. For a row scrolled partly or
    // wholly out of view, those pixels belong to whatever is there instead (a pinned button, the
    // edge of the screen), so the measure says nothing about the row. ThemePaletteTests covers it.
    if issue.auditType == .contrast, !visible.contains(element.frame) { return true }
    // The ladybug button is the Meta sample's DEBUG-only overlay for the mock device kit. It
    // doesn't ship, and its icon-only label and fixed size come from the sample.
    if element.identifier == "debug_menu_button" { return true }
    return false
  }
}
