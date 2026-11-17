/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATMockDeviceTestClient
import XCTest

@MainActor
final class CameraAccessUITests: XCTestCase {
  private static let portFilePrefix = "mwdat_test_server_port_"
  private static let portFileSuffix = ".txt"
  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private let app = XCUIApplication()
  // swiftlint:disable implicitly_unwrapped_optional
  private var mockClient: MockDeviceTestClient!
  private var pairedDeviceId: String!
  // swiftlint:enable implicitly_unwrapped_optional

  /// The iOS Local Network permission is a one-shot, per-install grant: once
  /// answered it persists across app relaunches, so the system dialog only
  /// appears on the first stream in the whole run. Tracked here so later tests
  /// skip the (otherwise wasted) wait for a prompt that will never reappear.
  private static var didAllowLocalNetwork = false

  private static let noGlassesTitle = "Put on your glasses"

  override func setUp() async throws {
    continueAfterFailure = false
    removeStalePortFiles()
    addTeardownBlock { [portFilePath] in
      try? FileManager.default.removeItem(atPath: portFilePath)
    }

    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()

    // Initialize the client *after* launch so the server has time to write the port file.
    mockClient = MockDeviceTestClient(portFilePath: portFilePath)
    let serverReachable = await mockClient.waitForServer(timeout: 10)
    XCTAssertTrue(serverReachable, "Test server should be running")
  }

  override func tearDown() async throws {
    if app.state == .runningForeground {
      dismissErrorAlertIfNeeded()
      let stop = app.buttons["read_stop_button"]
      if stop.exists, stop.isHittable { stop.tap() }
    }
    if pairedDeviceId != nil {
      _ = await mockClient.unpairDevice(deviceId: pairedDeviceId)
      pairedDeviceId = nil
    }
    app.terminate()
    mockClient = nil
  }

  // MARK: - Helpers

  private func dismissErrorAlertIfNeeded() {
    let alertOK = app.alerts.buttons["OK"]
    if alertOK.exists, alertOK.isHittable {
      alertOK.tap()
    }
  }

  private func removeStalePortFiles() {
    let fileManager = FileManager.default
    let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    guard let fileURLs = try? fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else {
      return
    }

    for fileURL in fileURLs {
      let filename = fileURL.lastPathComponent
      if filename.hasPrefix(Self.portFilePrefix), filename.hasSuffix(Self.portFileSuffix) {
        try? fileManager.removeItem(at: fileURL)
      }
    }
  }

  private var statusTitle: XCUIElement { app.staticTexts["status_title"] }

  /// Taps "Connect my glasses" to trigger registration via the fake handler, then
  /// waits for the main screen to show that no glasses are active yet.
  private func registerViaUI() {
    let connectButton = app.buttons["Connect my glasses"]
    XCTAssertTrue(connectButton.waitForExistence(timeout: 10), "Should start on HomeScreenView")
    connectButton.tap()
    waitForInactiveDevice()
  }

  /// Registers, then pairs a mock device with default camera resources.
  private func pairDeviceWithCameraResources() async {
    registerViaUI()

    let deviceId = await mockClient.pairDevice()
    XCTAssertNotNil(deviceId, "pairDevice should return a deviceId")
    pairedDeviceId = deviceId

    _ = await mockClient.setCameraFeed(deviceId: pairedDeviceId, resourceName: "plant", ext: "mp4")
    _ = await mockClient.setCapturedImage(deviceId: pairedDeviceId, resourceName: "plant", ext: "png")
  }

  /// Waits for the main screen to show active glasses: the status is no longer "Put on your
  /// glasses". Returns the Read button.
  @discardableResult
  private func waitForActiveDevice(timeout: TimeInterval = 15) -> XCUIElement {
    XCTAssertTrue(
      waitForLabel(statusTitle, timeout: timeout) { $0 != Self.noGlassesTitle },
      "The status should leave '\(Self.noGlassesTitle)' once a device is active, got '\(statusTitle.label)'")
    let read = app.buttons["read_button"]
    XCTAssertTrue(read.exists, "Read text should be on the main screen")
    return read
  }

  /// Waits for the main screen to show that no glasses are active.
  private func waitForInactiveDevice(timeout: TimeInterval = 15) {
    XCTAssertTrue(
      waitForLabel(statusTitle, timeout: timeout) { $0 == Self.noGlassesTitle },
      "The status should say '\(Self.noGlassesTitle)', got '\(statusTitle.label)'")
  }

  /// Taps Read with nothing running and waits until the reader has had a frame: one tap starts the
  /// session and the stream. The plant feed has no text, so the read ends in guidance.
  private func readFromCold(timeout: TimeInterval = 30) {
    waitForActiveDevice().tap()

    confirmCameraPermission()

    // Streaming runs over Wi-Fi (the high link level), so the first stream triggers
    // the iOS system Local Network permission dialog. It blocks the stream until
    // answered, so allow it before waiting for the reader.
    allowLocalNetworkPermissionIfNeeded()

    let status = app.staticTexts["read_status"]
    XCTAssertTrue(
      waitForLabel(status, timeout: timeout) { !["Getting a picture", "Finding text", "Ready to read"].contains($0) },
      "The reader should get a frame and finish, got '\(status.label)'")
  }

  /// Allows the iOS system Local Network permission dialog on the first stream.
  /// The dialog is presented by SpringBoard, not the app, so it is tapped through
  /// the springboard element rather than `app.alerts`. Best-effort: once granted
  /// the dialog never reappears, so later calls return without waiting.
  private func allowLocalNetworkPermissionIfNeeded() {
    guard !Self.didAllowLocalNetwork else { return }
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow"]
    if allow.waitForExistence(timeout: 10) {
      allow.tap()
      Self.didAllowLocalNetwork = true
    }
  }

  /// Camera is denied by default in the mock, so the first read surfaces the
  /// permission-redirect confirm alert. Tap "Continue" so the request proceeds
  /// (the mock then grants and persists it, and the read carries on by itself).
  private func confirmCameraPermission() {
    let allow = app.alerts.buttons["Continue"]
    XCTAssertTrue(allow.waitForExistence(timeout: 15), "Camera permission confirm should appear on the first read")
    allow.tap()
  }

  private func waitForLabel(_ element: XCUIElement, timeout: TimeInterval = 10, _ matches: @escaping (String) -> Bool) -> Bool {
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement, element.exists else { return false }
      return matches(element.label)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  // MARK: - Device Pairing & Navigation Tests

  /// Verifies that launching without pairing a device shows the home screen.
  func testLaunchWithoutDeviceShowsHomeScreen() async {
    let connectButton = app.buttons["Connect my glasses"]
    XCTAssertTrue(
      connectButton.waitForExistence(timeout: 10),
      "HomeScreenView should show 'Connect my glasses' when no device is paired"
    )
  }

  /// Verifies that registering and pairing a device shows the main screen, ready to read.
  func testRegisterAndPairShowsReadyToRead() async {
    await pairDeviceWithCameraResources()
    waitForActiveDevice()
    XCTAssertEqual(statusTitle.label, "Ready to read")
  }

  /// The main screen has one action and no camera steps: none of the old session, preview,
  /// photo, video or mic controls may come back.
  func testMainScreenHasOnlyReadAndSettings() async {
    await pairDeviceWithCameraResources()
    let read = waitForActiveDevice()

    for id in ["start_session_button", "end_session_button", "start_preview_button", "stop_preview_button",
      "capture_button", "record_button", "mic_toggle", "status_button"]
    {
      XCTAssertFalse(app.buttons[id].exists, "\(id) should be gone")
    }
    XCTAssertTrue(read.isHittable, "Read text should be hittable")
    XCTAssertTrue(read.isEnabled, "Read text is always enabled; the reader says why it can't read")
    XCTAssertTrue(app.buttons["settings_button"].exists)
  }

  /// Verifies that the device state query reflects the correct number of paired devices.
  func testDeviceStateReflectsPairedDevices() async {
    // Initially no devices paired
    let state0 = await mockClient.getDeviceState()
    XCTAssertNotNil(state0, "getDeviceState should return a response")
    XCTAssertEqual(state0?["pairedDeviceCount"] as? Int, 0, "Should have 0 paired devices initially")

    // Register and pair a device
    await pairDeviceWithCameraResources()

    let state1 = await mockClient.getDeviceState()
    XCTAssertNotNil(state1, "getDeviceState should return a response after pairing")
    XCTAssertEqual(state1?["pairedDeviceCount"] as? Int, 1, "Should have 1 paired device")

    // Unpair
    _ = await mockClient.unpairDevice(deviceId: pairedDeviceId)
    pairedDeviceId = nil

    let state2 = await mockClient.getDeviceState()
    XCTAssertNotNil(state2, "getDeviceState should return a response after unpairing")
    XCTAssertEqual(state2?["pairedDeviceCount"] as? Int, 0, "Should have 0 paired devices after unpairing")
  }

  // MARK: - Device Activity Tests

  /// Verifies that doff is wear-only and keeps the device active — the transport
  /// and stream stay up across a doff/don, so the device never drops to the
  /// waiting state.
  func testDoffKeepsDeviceActive() async {
    await pairDeviceWithCameraResources()
    waitForActiveDevice()

    // Doff the device → device stays active (doff no longer tears down the link).
    _ = await mockClient.doff(deviceId: pairedDeviceId)
    XCTAssertNotEqual(statusTitle.label, Self.noGlassesTitle, "Doff should not deactivate the device")
    waitForActiveDevice()

    // Don the device → device remains active.
    _ = await mockClient.don(deviceId: pairedDeviceId)
    waitForActiveDevice()
  }

  /// Verifies that powering off makes the device inactive and powering on
  /// with don reactivates it.
  func testPowerCycleAffectsDeviceActivity() async {
    await pairDeviceWithCameraResources()
    waitForActiveDevice()

    // Power off → device becomes inactive
    let powerOffResult = await mockClient.powerOff(deviceId: pairedDeviceId)
    XCTAssertTrue(powerOffResult, "Power off should succeed")
    waitForInactiveDevice()

    // Power on + don → device becomes active again
    let powerOnResult = await mockClient.powerOn(deviceId: pairedDeviceId)
    XCTAssertTrue(powerOnResult, "Power on should succeed")
    let donResult = await mockClient.don(deviceId: pairedDeviceId)
    XCTAssertTrue(donResult, "Don should succeed")
    waitForActiveDevice()
  }

  // MARK: - Reading starts the camera

  /// One tap on Read with nothing running: the session and stream start by themselves, the camera
  /// permission prompt is the only stop, and the read carries on after it. The plant feed has no
  /// text, so the reader finishes with guidance, not silence.
  func testReadStartsTheCameraByItself() async {
    await pairDeviceWithCameraResources()
    readFromCold()
    XCTAssertFalse(app.alerts.firstMatch.exists, "Reading should not end in an error alert")
  }

  /// Folding the glasses while the camera is on ends it; the device stays active and the screen
  /// says the glasses are folded.
  func testFoldWhileReadingEndsTheCamera() async {
    await pairDeviceWithCameraResources()
    readFromCold()

    let foldResult = await mockClient.fold(deviceId: pairedDeviceId)
    XCTAssertTrue(foldResult, "Fold command should succeed")

    // The session-ended error surfaces an alert — dismiss it so the view hierarchy settles.
    let alertOK = app.alerts.buttons["OK"]
    if alertOK.waitForExistence(timeout: 15) { alertOK.tap() }

    waitForActiveDevice()
    XCTAssertTrue(
      waitForLabel(statusTitle, timeout: 15) { $0 == "Glasses folded" || $0 == "Ready to read" },
      "After a fold the status should say so, got '\(statusTitle.label)'")
  }
}
