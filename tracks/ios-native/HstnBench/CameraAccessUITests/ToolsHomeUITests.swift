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
    ("ask", "Ask about the text"), ("light", "Light and colour"),
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
}
