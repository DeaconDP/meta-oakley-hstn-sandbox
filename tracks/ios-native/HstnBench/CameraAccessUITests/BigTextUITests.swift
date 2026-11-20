/*
 * BigTextUITests - the big-text mirror end to end on the Mock Device Kit (notes/phone-reading-ios.md)
 *
 * Reads the printed fixture page as ReadAloudUITests does, opens Big text from the reading card,
 * checks it shows the sentence being read with its controls, moves on with Next, changes the
 * contrast, and closes. Screenshots are attached to the result; with
 * TEST_RUNNER_SPEAKUP_SHOT_DIR=<dir> they are also written there as PNGs (for design/screens).
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class BigTextUITests: XCTestCase {
  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private let app = XCUIApplication()
  // swiftlint:disable implicitly_unwrapped_optional
  private var mockClient: MockDeviceTestClient!
  // swiftlint:enable implicitly_unwrapped_optional
  private var pairedDeviceId: String?

  override func setUp() async throws {
    continueAfterFailure = false
    addTeardownBlock { [portFilePath] in
      try? FileManager.default.removeItem(atPath: portFilePath)
    }
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    mockClient = MockDeviceTestClient(portFilePath: portFilePath)
    let serverReachable = await mockClient.waitForServer(timeout: 10)
    XCTAssertTrue(serverReachable, "Test server should be running")
  }

  override func tearDown() async throws {
    if let pairedDeviceId {
      _ = await mockClient.unpairDevice(deviceId: pairedDeviceId)
      self.pairedDeviceId = nil
    }
    app.terminate()
    mockClient = nil
  }

  func testBigTextFollowsTheReading() async throws {
    try await connectAndPairPrintedPage()
    app.buttons["read_button"].tap()
    let allow = app.alerts.buttons["Continue"]
    if allow.waitForExistence(timeout: 15) { allow.tap() }
    let springboardAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if springboardAllow.waitForExistence(timeout: 5) { springboardAllow.tap() }
    XCTAssertTrue(app.staticTexts["read_sentence"].waitForExistence(timeout: 25), "Reading should start")

    let bigText = app.buttons["read_big_text_button"]
    XCTAssertTrue(bigText.waitForExistence(timeout: 5), "The reading card offers Big text")
    reveal(bigText)
    bigText.tap()

    let sentence = app.staticTexts["big_text_sentence"]
    XCTAssertTrue(sentence.waitForExistence(timeout: 5), "The mirror shows the sentence")
    XCTAssertFalse(sentence.label.isEmpty)
    for id in ["big_text_close_button", "big_text_previous_button", "big_text_pause_button", "big_text_next_button",
      "big_text_smaller_button", "big_text_contrast_button", "big_text_larger_button"]
    {
      XCTAssertTrue(app.buttons[id].exists, "\(id) should be on the mirror")
    }
    // Mid-sentence, while a word is highlighted.
    try await Task.sleep(for: .milliseconds(600))
    save("big-text-yellow-reading")

    // Pause, then Next moves one sentence and the mirror follows.
    let pause = app.buttons["big_text_pause_button"]
    if pause.label == "Pause" { pause.tap() }
    let place = app.staticTexts["big_text_place"]
    XCTAssertTrue(waitForLabel(place) { $0.hasPrefix("Stopped at sentence ") || $0.hasPrefix("Finished") }, "got \(place.label)")
    let before = sentence.label
    let next = app.buttons["big_text_next_button"]
    next.tap()
    XCTAssertTrue(waitForLabel(sentence) { $0 != before } || before == "This is the end of the test page.", "Next should move on")
    try await Task.sleep(for: .milliseconds(500))
    save("big-text-yellow-next")

    let contrast = app.buttons["big_text_contrast_button"]
    contrast.tap()
    XCTAssertTrue(contrast.label.contains("Dark on light"), contrast.label)
    save("big-text-dark-on-light")
    contrast.tap()
    save("big-text-light-on-dark")
    contrast.tap()

    app.buttons["big_text_close_button"].tap()
    XCTAssertTrue(waitForLabel(app.staticTexts["read_status"], timeout: 5) { !$0.isEmpty }, "Back on the reading card")
    XCTAssertFalse(sentence.exists, "The mirror closed")
  }

  // MARK: - Helpers

  private func save(_ name: String) {
    let shot = app.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let dir = ProcessInfo.processInfo.environment["SPEAKUP_SHOT_DIR"], !dir.isEmpty {
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
  }

  private func connectAndPairPrintedPage() async throws {
    let connect = app.buttons["Connect my glasses"]
    XCTAssertTrue(connect.waitForExistence(timeout: 10), "Should start on the home screen")
    connect.tap()
    let title = app.staticTexts["status_title"]
    XCTAssertTrue(waitForLabel(title, timeout: 15) { $0 == "Put on your glasses" }, "Should wait for glasses")
    let paired = await mockClient.pairDevice()
    let deviceId = try XCTUnwrap(paired, "pairDevice should return a deviceId")
    pairedDeviceId = deviceId
    let feedSet = await mockClient.setCameraFeed(deviceId: deviceId, resourceName: "read_page", ext: "mp4")
    XCTAssertTrue(feedSet)
    let photoSet = await mockClient.setCapturedImage(deviceId: deviceId, resourceName: "read_page", ext: "png")
    XCTAssertTrue(photoSet)
    XCTAssertTrue(waitForLabel(title, timeout: 15) { $0 == "Ready to read" }, "Should be ready once the glasses are active")
  }

  private func reveal(_ element: XCUIElement) {
    var attempts = 0
    while !element.isHittable, attempts < 8 {
      app.swipeUp(velocity: .slow)
      attempts += 1
    }
  }

  private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 10, _ matches: @escaping (String) -> Bool) -> Bool {
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement, element.exists else { return false }
      return matches(element.label)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
