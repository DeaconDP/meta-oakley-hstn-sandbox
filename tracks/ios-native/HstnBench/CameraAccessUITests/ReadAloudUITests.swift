/*
 * ReadAloudUITests - "Read it aloud" end to end on the Mock Device Kit
 *
 * Feeds the mock a printed page (A11y/Read/Fixtures/read_page.mp4 as the camera feed, the same
 * page as read_page.png for the photo fallback; made by tracks/ios-native/tools/
 * make-read-fixtures.swift), starts the stream, presses Read, and checks that the reader found
 * the text, spoke it (the timing line only appears once the first word has started), and that
 * next / stop work. The timing line carries the same numbers that go to the log as
 * `metric=trigger_to_first_word`, `ocr` and `frame_age`, which bench.sh summarises.
 *
 * Kept apart from CameraAccessUITests so the photo benchmark test there stays exactly as it is.
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class ReadAloudUITests: XCTestCase {
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
    if app.state == .runningForeground {
      let endSession = app.buttons["end_session_button"]
      if endSession.exists, endSession.isEnabled { endSession.tap() }
    }
    if let pairedDeviceId {
      _ = await mockClient.unpairDevice(deviceId: pairedDeviceId)
      self.pairedDeviceId = nil
    }
    app.terminate()
    mockClient = nil
  }

  // MARK: - Test

  func testReadAloud() async throws {
    let connect = app.buttons["Connect my glasses"]
    XCTAssertTrue(connect.waitForExistence(timeout: 10), "Should start on the home screen")
    connect.tap()
    XCTAssertTrue(app.staticTexts["Waiting for an active device"].waitForExistence(timeout: 15))

    let paired = await mockClient.pairDevice()
    let deviceId = try XCTUnwrap(paired, "pairDevice should return a deviceId")
    pairedDeviceId = deviceId
    let feedSet = await mockClient.setCameraFeed(deviceId: deviceId, resourceName: "read_page", ext: "mp4")
    XCTAssertTrue(feedSet, "Mock should accept the printed-page feed")
    let photoSet = await mockClient.setCapturedImage(deviceId: deviceId, resourceName: "read_page", ext: "png")
    XCTAssertTrue(photoSet, "Mock should accept the printed-page photo")

    startSessionAndStream()

    let read = app.buttons["read_button"]
    XCTAssertTrue(read.waitForExistence(timeout: 10), "Read should sit next to Take photo")
    XCTAssertTrue(waitUntilEnabled(read), "Read should be enabled while streaming")
    read.tap()

    // A sentence on screen means OCR ran and reading started.
    let sentence = app.staticTexts["read_sentence"]
    XCTAssertTrue(sentence.waitForExistence(timeout: 20), "A sentence should be shown once reading starts")

    // The timing line appears when the synthesizer has started the first word.
    let timing = app.staticTexts["read_timing"]
    XCTAssertTrue(timing.waitForExistence(timeout: 15), "trigger_to_first_word should be measured")
    XCTAssertTrue(timing.label.hasPrefix("First word "), "Unexpected timing line: \(timing.label)")
    XCTAssertTrue(timing.label.contains("OCR "), "OCR time should be reported: \(timing.label)")
    XCTAssertTrue(timing.label.contains("frame "), "The stream frame should be used, not a photo: \(timing.label)")

    // Speech moves on by itself, so every check below first stops it and then compares the place
    // the status reports with the sentence shown: sentence N must be the page's Nth sentence.
    stopIfReading()
    let first = try assertShownSentenceMatchesPlace()

    // Next (or previous from the last one) moves one sentence, word for word.
    let step = first < Self.pageSentences.count ? "read_next_button" : "read_previous_button"
    app.buttons[step].tap()
    stopIfReading()
    let second = try assertShownSentenceMatchesPlace()
    XCTAssertNotEqual(first, second, "\(step) should change the sentence")
    XCTAssertTrue(app.buttons["read_repeat_button"].exists, "Repeat stays available after stopping")
  }

  /// The fixture page (tools/make-read-fixtures.swift), in reading order.
  private static let pageSentences = [
    "Reading test",
    "The quick brown fox jumps over the lazy dog.",
    "Printed text is read word for word, in order.",
    "This is the end of the test page.",
  ]

  private func stopIfReading() {
    let stop = app.buttons["read_stop_button"]
    if stop.waitForExistence(timeout: 1) { stop.tap() }
  }

  /// Reads "Stopped at sentence N of 4" (or "Finished, 4 sentences") and checks the shown
  /// sentence is the page's Nth. Returns N.
  @discardableResult
  private func assertShownSentenceMatchesPlace() throws -> Int {
    let status = app.staticTexts["read_status"]
    let count = Self.pageSentences.count
    XCTAssertTrue(
      waitForLabel(status) { $0.hasPrefix("Stopped at sentence ") || $0 == "Finished, \(count) sentences" },
      "Reading should stop with a place, got '\(status.label)'")
    let place: Int
    if status.label.hasPrefix("Finished") {
      place = count
    } else {
      let parts = status.label.replacingOccurrences(of: "Stopped at sentence ", with: "").split(separator: " ")
      place = try XCTUnwrap(parts.first.flatMap { Int($0) }, "No sentence number in '\(status.label)'")
      XCTAssertEqual(status.label, "Stopped at sentence \(place) of \(count)", "The page should have \(count) sentences")
    }
    XCTAssertTrue((1...count).contains(place))
    XCTAssertEqual(app.staticTexts["read_sentence"].label, Self.pageSentences[place - 1], "Sentence \(place) read out of order")
    return place
  }

  // MARK: - Helpers

  private func startSessionAndStream() {
    let startSession = app.buttons["start_session_button"]
    XCTAssertTrue(startSession.waitForExistence(timeout: 15), "Start Session should appear once a device is active")
    startSession.tap()

    let startPreview = app.buttons["start_preview_button"]
    XCTAssertTrue(startPreview.waitForExistence(timeout: 20), "Start Preview should appear once the session is started")
    startPreview.tap()

    // Camera is denied by default in the mock: confirm the redirect when asked.
    let allow = app.alerts.buttons["Continue"]
    if allow.waitForExistence(timeout: 10) { allow.tap() }
    // The first stream of a run asks for Local Network access (SpringBoard dialog).
    let springboardAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if springboardAllow.waitForExistence(timeout: 5) { springboardAllow.tap() }

    XCTAssertTrue(app.buttons["stop_preview_button"].waitForExistence(timeout: 20), "Preview should be streaming")
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
