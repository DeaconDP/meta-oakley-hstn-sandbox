/*
 * StoreScreenshotsUITests - screenshots of the App Store build (SpeakUp, no glasses) for
 * design/screens: the tools home and one open tool.
 *
 * Opt-in: the SpeakUp app must be installed on the Simulator first, and the run needs
 * TEST_RUNNER_SPEAKUP_SCREENSHOTS=1. Otherwise it is skipped. The images are attachments in the
 * result bundle (xcresulttool export attachments).
 */

import XCTest

@MainActor
final class StoreScreenshotsUITests: XCTestCase {
  func testToolsHomeAndAnOpenTool() throws {
    guard ProcessInfo.processInfo.environment["SPEAKUP_SCREENSHOTS"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_SPEAKUP_SCREENSHOTS=1 with the SpeakUp app installed.")
    }
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.deaco.speakup")
    app.launchArguments = ["--ui-testing"]
    app.launch()
    let title = app.staticTexts["tools_home_title"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 1.5)
    // Seven tools don't fit under the status card: bring the Tools heading near the top first.
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
    XCTAssertTrue(app.buttons["tool_open_reminders"].waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 1.5)
    attach(app, "ios-tools-home")

    let mail = app.buttons["tool_open_mail"]
    XCTAssertTrue(mail.waitForExistence(timeout: 5))
    mail.tap()
    XCTAssertTrue(app.staticTexts["tool_title"].waitForExistence(timeout: 10))
    Thread.sleep(forTimeInterval: 2)
    attach(app, "ios-tool-open")
    app.terminate()
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
