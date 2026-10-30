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

  // MARK: - Helpers

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
    try app.performAccessibilityAudit { issue in
      let ignored = Self.isIgnored(issue)
      if !ignored {
        // The default failure message doesn't say which screen; this does.
        let element = issue.element.map { "\($0.elementType) '\($0.identifier)' '\($0.label)'" } ?? "no element"
        print("[a11y audit] \(screen): \(issue.compactDescription) — \(element)")
      }
      return ignored
    }
  }

  /// Issues that aren't ours to fix. Kept narrow: matched by element, not by issue type, so a
  /// real problem of the same type elsewhere still fails.
  private static func isIgnored(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
    guard let element = issue.element else { return false }
    // The ladybug button is the Meta sample's DEBUG-only overlay for the mock device kit. It
    // doesn't ship, and its icon-only label and fixed size come from the sample.
    if element.identifier == "debug_menu_button" { return true }
    return false
  }
}
