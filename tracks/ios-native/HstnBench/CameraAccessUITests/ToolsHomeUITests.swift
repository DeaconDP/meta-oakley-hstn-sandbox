/*
 * ToolsHomeUITests - the tools home with the iPhone's camera (notes/tools-home-ios.md): every tool
 * opens from its row and closes back to the list, by touch and by voice.
 *
 * Launched with --phone-camera, so the main screen comes up without glasses. The Simulator has no
 * camera, so the tools say so; these check the screens, not what the tools find.
 */

import XCTest

@MainActor
final class ToolsHomeUITests: XCTestCase {
  private let portFilePath = NSTemporaryDirectory() + "mwdat_test_server_port_\(UUID().uuidString).txt"
  private var app = XCUIApplication()

  private static let titles: [(id: String, title: String)] = [
    ("read", "Read text"), ("mail", "Mail reader"), ("labels", "Labels and barcodes"), ("watch", "Watch for text"),
    ("ask", "Ask about the text"), ("light", "Light and colour"), ("reminders", "Reminders"),
  ]

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

  private func launch(_ extra: [String] = []) {
    app.launchArguments = ["--ui-testing", "--phone-camera"] + extra
    app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(app.staticTexts["tools_home_title"].waitForExistence(timeout: 20), "The tools home should show")
  }

  private func row(_ id: String) -> XCUIElement {
    app.buttons[id == "read" ? "read_button" : "tool_open_\(id)"]
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

  func testEveryToolOpensFromTheHomeAndCloses() {
    launch()
    for (id, title) in Self.titles {
      let tile = row(id)
      XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(title) should be on the tools home")
      reveal(tile)
      tile.tap()
      let header = app.staticTexts["tool_title"]
      XCTAssertTrue(header.waitForExistence(timeout: 10), "\(title) should open")
      XCTAssertEqual(header.label, title)
      XCTAssertFalse(app.staticTexts["tools_home_title"].exists, "the list gives way to the tool")
      let close = app.buttons["tool_close_button"]
      XCTAssertTrue(close.exists, "\(title) needs a Close")
      reveal(close)
      close.tap()
      XCTAssertTrue(app.staticTexts["tools_home_title"].waitForExistence(timeout: 10), "Close goes back to the tools")
      XCTAssertFalse(app.buttons["tool_close_button"].exists)
    }
  }

  /// "Read a photo or PDF" sits under the tools, as one named button that offers the two pickers.
  func testImportButtonIsOnTheHomeAndOffersBothPickers() {
    launch()
    let importButton = app.buttons["importButton"]
    XCTAssertTrue(importButton.waitForExistence(timeout: 10), "The import button should be on the tools home")
    XCTAssertEqual(importButton.label, "Read a photo or PDF")
    XCTAssertGreaterThan(importButton.frame.minY, row("reminders").frame.maxY, "it comes after the seven tools")
    reveal(importButton)
    importButton.tap()
    XCTAssertTrue(app.buttons["Choose a photo"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Choose a file"].exists)
    // iOS 27 shows the choices without a Cancel row; a tap outside dismisses them.
    let cancel = app.buttons["Cancel"]
    if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
    let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Choose a photo"])
    wait(for: [gone], timeout: 5)
    XCTAssertTrue(app.staticTexts["tools_home_title"].exists)
  }

  func testToolsOpenAndCloseByVoice() {
    launch(["--voice-inject"])
    let field = app.textFields["voice_test_transcript"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    func say(_ text: String) {
      field.tap()
      field.typeText(text + "\n")
    }
    // The app speaks as screens and tools open, and then only "reader, ..." counts.
    say("reader, open mail reader")
    let header = app.staticTexts["tool_title"]
    XCTAssertTrue(header.waitForExistence(timeout: 10))
    XCTAssertEqual(header.label, "Mail reader")
    say("reader, what colour is this")
    XCTAssertTrue(app.staticTexts["tool_title"].waitForExistence(timeout: 10))
    let switched = NSPredicate(format: "label == %@", "Light and colour")
    wait(for: [expectation(for: switched, evaluatedWith: app.staticTexts["tool_title"])], timeout: 10)
    say("reader, close")
    XCTAssertTrue(app.staticTexts["tools_home_title"].waitForExistence(timeout: 10))
    say("reader, tell me when you see 42")
    let watching = NSPredicate(format: "label == %@", "Watch for text")
    wait(for: [expectation(for: watching, evaluatedWith: app.staticTexts["tool_title"])], timeout: 10)
    say("reader, main menu")
    XCTAssertTrue(app.staticTexts["tools_home_title"].waitForExistence(timeout: 10))
  }

  /// J2: "switch to <tool>" moves between tools; "import" from inside a tool goes back to the
  /// tools home and offers the two pickers; "read a photo" opens the Photos picker.
  func testSwitchToAndImportByVoice() {
    launch(["--voice-inject"])
    let field = app.textFields["voice_test_transcript"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    func say(_ text: String) {
      field.tap()
      field.typeText(text + "\n")
    }
    say("reader, switch to labels")
    let labels = NSPredicate(format: "label == %@", "Labels and barcodes")
    wait(for: [expectation(for: labels, evaluatedWith: app.staticTexts["tool_title"])], timeout: 10)
    say("reader, switch to read text")
    let readText = NSPredicate(format: "label == %@", "Read text")
    wait(for: [expectation(for: readText, evaluatedWith: app.staticTexts["tool_title"])], timeout: 10)
    say("reader, import")
    XCTAssertTrue(app.staticTexts["tools_home_title"].waitForExistence(timeout: 10), "the tool closes for the import")
    XCTAssertTrue(app.buttons["Choose a photo"].waitForExistence(timeout: 20), "the choice opens after the spoken line")
    XCTAssertTrue(app.buttons["Choose a file"].exists)
    let cancel = app.buttons["Cancel"]
    if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
    let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Choose a photo"])
    wait(for: [gone], timeout: 5)
    say("reader, read a photo")
    // The Photos picker runs out of process; its sheet still shows in the app's tree.
    let picker = app.descendants(matching: .any).matching(
      NSPredicate(format: "label IN %@ OR identifier IN %@", ["Photos", "Collections", "Albums", "Search"], ["PhotosPicker"]))
      .firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 20), "the Photos picker should open: \(app.debugDescription)")
  }

  /// "Remind me ..." from the tools home opens Reminders, confirms, and lists it; "undo" takes it off.
  /// UI tests use notifications that never ask (ReminderStore.live), so no permission prompt.
  func testReminderByVoiceFromTheHome() {
    launch(["--voice-inject"])
    let field = app.textFields["voice_test_transcript"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    func say(_ text: String) {
      field.tap()
      field.typeText(text + "\n")
    }
    say("reader, remind me in 20 minutes to take the bins out")
    let opened = NSPredicate(format: "label == %@", "Reminders")
    wait(for: [expectation(for: opened, evaluatedWith: app.staticTexts["tool_title"])], timeout: 10)
    let confirm = app.staticTexts["reminders_last_line"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    let confirmed = NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Reminder at ", "take the bins out. Say undo to cancel.")
    wait(for: [expectation(for: confirmed, evaluatedWith: confirm)], timeout: 10)
    XCTAssertTrue(
      app.buttons["Cancel reminder: take the bins out"].waitForExistence(timeout: 5), "it's listed under Coming up, with Cancel")
    say("reader, undo")
    let undone = NSPredicate(format: "label BEGINSWITH %@", "Undone.")
    wait(for: [expectation(for: undone, evaluatedWith: confirm)], timeout: 10)
    XCTAssertTrue(app.staticTexts["reminders_none"].waitForExistence(timeout: 5))
  }
}
