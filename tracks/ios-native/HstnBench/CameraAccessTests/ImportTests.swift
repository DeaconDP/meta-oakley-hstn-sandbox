/*
 * ImportTests - V4 "Reach": reading photos and PDFs from other apps, and the open-tool intents
 *
 * PDFs are made here with UIGraphicsPDFRenderer: text drawn as text has a text layer (read
 * exactly, no OCR); text drawn into a bitmap first and then placed as an image has none (OCR).
 * The inbox runs in a temporary folder. Nothing here opens a picker. ImportReadingTests reads
 * through a fresh TextReader, so it speaks; each test stops it.
 */

import PDFKit
import UIKit
import XCTest

@testable import CameraAccess

// MARK: - Fixtures

private enum Fixture {
  static let pageSize = CGSize(width: 612, height: 792)

  static func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
    [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black]
  }

  /// One page per string, drawn as real text.
  static func textPDF(_ pages: [String]) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
      for text in pages {
        context.beginPage()
        (text as NSString).draw(
          in: CGRect(x: 72, y: 72, width: pageSize.width - 144, height: pageSize.height - 144),
          withAttributes: attributes(18))
      }
    }
  }

  /// A white picture with black text on it.
  static func picture(_ text: String, size: CGSize = CGSize(width: 1200, height: 900), fontSize: CGFloat = 64) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      (text as NSString).draw(
        in: CGRect(x: 60, y: 60, width: size.width - 120, height: size.height - 120), withAttributes: attributes(fontSize))
    }
  }

  /// One page per string, each a picture of the text: a scan, with no text layer.
  static func scannedPDF(_ pages: [String]) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
      for text in pages {
        context.beginPage()
        picture(text, size: CGSize(width: 1224, height: 1584), fontSize: 72)
          .draw(in: CGRect(origin: .zero, size: pageSize))
      }
    }
  }

  static func blankPNG() -> Data {
    picture("").pngData()!
  }
}

private func temporaryInbox() -> ImportInbox {
  ImportInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)"))
}

private func words(_ page: ImportedPages.PageText) -> String {
  ImportedPages.plainText(page.page).lowercased()
}

// MARK: - PDF text layer vs OCR

final class ImportPDFTests: XCTestCase {
  func testPageCount() throws {
    let pdf = try ImportedPDF(data: Fixture.textPDF(["One.", "Two.", "Three."]))
    XCTAssertEqual(pdf.pageCount, 3)
  }

  func testATextLayerIsReadExactlyWithoutOCR() throws {
    let pdf = try ImportedPDF(data: Fixture.textPDF(["Take two tablets daily with water.", "Second page here."]))
    let first = try pdf.text(ofPage: 0)
    XCTAssertEqual(first.source, .textLayer)
    XCTAssertTrue(words(first).contains("take two tablets daily with water."), words(first))
    // Text-layer words are exact: never flagged as uncertain.
    XCTAssertTrue(first.page.lines.flatMap(\.words).allSatisfy { $0.confidence == 1 })
    XCTAssertEqual(ImportedPages.sentences(first.page).count, 1)

    let second = try pdf.text(ofPage: 1)
    XCTAssertEqual(second.source, .textLayer)
    XCTAssertTrue(words(second).contains("second page here"))
  }

  func testTextLayerLinesAreTopDownInReadingOrder() throws {
    let pdf = try ImportedPDF(data: Fixture.textPDF(["Heading\nFirst line of the body.\nSecond line of the body."]))
    let page = try pdf.text(ofPage: 0)
    let text = ImportedPages.plainText(page.page)
    let heading = try XCTUnwrap(text.range(of: "Heading"))
    let second = try XCTUnwrap(text.range(of: "Second line"))
    XCTAssertLessThan(heading.lowerBound, second.lowerBound)
  }

  func testAScannedPageHasNoTextLayerAndIsRecognized() throws {
    let data = Fixture.scannedPDF(["Gas bill due Friday"])
    let document = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertFalse(ImportedPages.hasTextLayer(try XCTUnwrap(document.page(at: 0))))

    let page = try ImportedPDF(data: data).text(ofPage: 0)
    XCTAssertEqual(page.source, .recognized)
    XCTAssertTrue(words(page).contains("bill"), words(page))
    XCTAssertTrue(words(page).contains("friday"), words(page))
  }

  func testABlankPageIsEmpty() throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: Fixture.pageSize)).pdfData { $0.beginPage() }
    let page = try ImportedPDF(data: data).text(ofPage: 0)
    XCTAssertEqual(page.source, .recognized)
    XCTAssertTrue(page.isEmpty)
  }

  func testNotAPDFIsRefused() {
    XCTAssertThrowsError(try ImportedPDF(data: Data("hello".utf8))) { error in
      XCTAssertEqual(error as? ImportedPages.ImportError, .unreadablePDF)
    }
  }

  func testRenderedPageIsCappedAtMaxPixelSize() throws {
    let document = try XCTUnwrap(PDFDocument(data: Fixture.textPDF(["Hello."])))
    let image = ImportedPages.render(try XCTUnwrap(document.page(at: 0)), maxPixelSize: 800)
    XCTAssertEqual(max(image.size.width, image.size.height), 800, accuracy: 1)
  }

  func testFallbackLinesKeepRowsAndSkipBlankOnes() {
    let lines = ImportedPages.fallbackLines("Title\n\nA longer line of body text.", width: 500)
    XCTAssertEqual(lines.map(\.text), ["Title", "A longer line of body text."])
    XCTAssertLessThan(lines[0].box.width, lines[1].box.width)
  }
}

// MARK: - Photos

final class ImportPhotoTests: XCTestCase {
  func testAPhotoIsRecognized() throws {
    let data = try XCTUnwrap(Fixture.picture("Library card number").pngData())
    let page = try ImportedPages.recognizeImage(data: data)
    XCTAssertEqual(page.source, .recognized)
    XCTAssertTrue(words(page).contains("library"), words(page))
  }

  func testTextOnATransparentBackgroundIsRead() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let size = CGSize(width: 1200, height: 900)
    let clear = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      ("Parking permit expires" as NSString).draw(
        in: CGRect(x: 60, y: 60, width: 1080, height: 780), withAttributes: Fixture.attributes(64))
    }
    let page = try ImportedPages.recognizeImage(data: try XCTUnwrap(clear.pngData()))
    XCTAssertTrue(words(page).contains("permit"), words(page))
  }

  func testABlankPictureHasNothingToRead() throws {
    let page = try ImportedPages.recognizeImage(data: Fixture.blankPNG())
    XCTAssertTrue(page.isEmpty)
    XCTAssertTrue(ImportedPages.sentences(page.page).isEmpty)
  }

  func testNotAnImageIsRefused() {
    XCTAssertThrowsError(try ImportedPages.recognizeImage(data: Data("not an image".utf8)))
  }

  func testBigPhotosAreScaledDown() throws {
    let data = try XCTUnwrap(Fixture.picture("Big", size: CGSize(width: 4000, height: 3000)).pngData())
    let image = try XCTUnwrap(ImportedPages.downscaledImage(data: data, maxPixelSize: 1000))
    XCTAssertEqual(image.size.width, 1000, accuracy: 1)
    XCTAssertEqual(image.size.height, 750, accuracy: 1)
  }

  func testSpokenLines() {
    XCTAssertEqual(SpokenMessage.importReadingPhoto, "Reading the photo.")
    XCTAssertEqual(SpokenMessage.importNothingInPicture, "Nothing to read in this picture.")
    XCTAssertEqual(SpokenMessage.importPDFPage(1, of: 3), "PDF, 3 pages. Page 1.")
    XCTAssertEqual(SpokenMessage.importPDFPage(2, of: 3), "Page 2.")
    XCTAssertEqual(SpokenMessage.importPDFPage(1, of: 1), "PDF, 1 page.")
  }
}

// MARK: - Pending queue

final class ImportInboxTests: XCTestCase {
  private var inbox: ImportInbox!

  override func setUp() {
    super.setUp()
    inbox = temporaryInbox()
  }

  override func tearDown() {
    inbox.removeAll()
    super.tearDown()
  }

  func testEmptyInboxHasNothingPending() {
    XCTAssertFalse(inbox.hasPending)
    XCTAssertEqual(inbox.pending(), [])
  }

  func testItemsComeBackOldestFirstWithTheirKind() throws {
    let now = Date()
    try inbox.add(data: Data("b".utf8), fileExtension: "pdf", now: now)
    try inbox.add(data: Data("a".utf8), fileExtension: "PNG", now: now.addingTimeInterval(-60))
    let pending = inbox.pending(now: now)
    XCTAssertEqual(pending.map(\.kind), [.image, .pdf])
    XCTAssertTrue(inbox.hasPending)
    XCTAssertEqual(pending[0].url.pathExtension, "png")
  }

  func testRemoveTakesAnItemOut() throws {
    let item = try inbox.add(data: Data("x".utf8), fileExtension: "jpg")
    inbox.remove(item)
    XCTAssertFalse(inbox.hasPending)
  }

  func testOldItemsAreDroppedUnread() throws {
    let now = Date()
    let old = try inbox.add(data: Data("x".utf8), fileExtension: "pdf", now: now.addingTimeInterval(-ImportInbox.maxAge - 60))
    try inbox.add(data: Data("y".utf8), fileExtension: "pdf", now: now)
    XCTAssertEqual(inbox.pending(now: now).count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
  }

  func testOnlyPhotosAndPDFsGoIn() {
    XCTAssertThrowsError(try inbox.add(data: Data("x".utf8), fileExtension: "txt")) { error in
      XCTAssertEqual(error as? ImportInbox.InboxError, .notAPhotoOrPDF)
    }
    XCTAssertFalse(inbox.hasPending)
  }

  func testCopyingAFileKeepsTheOriginal() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).pdf")
    try Fixture.textPDF(["Hi."]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let item = try inbox.add(copying: source)
    XCTAssertEqual(item.kind, .pdf)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: item.url), try Data(contentsOf: source))
  }

  func testKindsFromExtensions() {
    XCTAssertEqual(ImportInbox.Kind(fileExtension: "pdf"), .pdf)
    XCTAssertEqual(ImportInbox.Kind(fileExtension: "HEIC"), .image)
    XCTAssertEqual(ImportInbox.Kind(fileExtension: "jpeg"), .image)
    XCTAssertEqual(ImportInbox.Kind(fileExtension: "png"), .image)
    XCTAssertNil(ImportInbox.Kind(fileExtension: "docx"))
    XCTAssertNil(ImportInbox.Kind(fileExtension: ""))
  }

  func testFileNamesSortByTimeAndParseBack() throws {
    let early = Date(timeIntervalSince1970: 9)
    let late = Date(timeIntervalSince1970: 1_800_000_000.5)
    let a = ImportInbox.fileName(addedAt: early, fileExtension: "PDF", random: "aaaaaaaa")
    let b = ImportInbox.fileName(addedAt: late, fileExtension: "png", random: "00000000")
    XCTAssertEqual(a, "000000000009000-aaaaaaaa.pdf")
    XCTAssertLessThan(a, b)
    let item = try XCTUnwrap(ImportInbox.item(at: URL(fileURLWithPath: "/tmp/\(b)")))
    XCTAssertEqual(item.kind, .image)
    XCTAssertEqual(item.addedAt.timeIntervalSince1970, 1_800_000_000.5, accuracy: 0.001)
    XCTAssertNil(ImportInbox.item(at: URL(fileURLWithPath: "/tmp/notes.pdf")))
    XCTAssertNil(ImportInbox.item(at: URL(fileURLWithPath: "/tmp/000000000009000-aaaaaaaa.txt")))
  }
}

// MARK: - URLs and arrivals

@MainActor
final class ImportURLTests: XCTestCase {
  private var saved: ImportInbox!

  override func setUp() async throws {
    try await super.setUp()
    saved = ImportedReading.inbox
    ImportedReading.inbox = temporaryInbox()
  }

  override func tearDown() async throws {
    ImportedReading.inbox.removeAll()
    ImportedReading.inbox = saved
    try await super.tearDown()
  }

  func testReadImportedURLs() {
    for text in [
      "speakup://read-imported", "SPEAKUP://Read-Imported", "speakup:///read-imported", "speakup://import",
      "speakup://readimported",
    ] {
      XCTAssertTrue(ImportURL.isReadImported(URL(string: text)!), text)
    }
    for text in ["speakup://handsfree", "hstnbench://read-imported", "https://example.com/read-imported", "speakup://read"] {
      XCTAssertFalse(ImportURL.isReadImported(URL(string: text)!), text)
    }
    XCTAssertTrue(ImportURL.isReadImported(ImportURL.readImported))
  }

  func testReadImportedLinkParksTheAction() {
    let router = LaunchActionRouter()
    XCTAssertTrue(ImportedReading.handle(URL(string: "speakup://read-imported")!, router: router))
    XCTAssertEqual(router.consume(), .readImported)
  }

  func testOtherLinksAreLeftAlone() {
    let router = LaunchActionRouter()
    XCTAssertFalse(ImportedReading.handle(URL(string: "speakup://handsfree")!, router: router))
    XCTAssertFalse(ImportedReading.handle(URL(string: "hstnbench://callback?x=1")!, router: router))
    XCTAssertNil(router.pending)
  }

  func testAnOpenedPDFGoesInTheInboxAndIsRead() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("opened-\(UUID().uuidString).pdf")
    try Fixture.textPDF(["Hello."]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let router = LaunchActionRouter()
    XCTAssertTrue(ImportedReading.handle(source, router: router))
    XCTAssertEqual(router.consume(), .readImported)
    XCTAssertTrue(ImportedReading.hasPending)
    XCTAssertEqual(ImportedReading.inbox.pending().map(\.kind), [.pdf])
  }

  func testComingToTheFrontAsksForWaitingItems() throws {
    let router = LaunchActionRouter()
    ImportedReading.appBecameActive(router: router)
    XCTAssertNil(router.pending)
    try ImportedReading.inbox.add(data: Fixture.blankPNG(), fileExtension: "png")
    ImportedReading.appBecameActive(router: router)
    XCTAssertEqual(router.consume(), .readImported)
  }
}

// MARK: - Reading through TextReader

/// Imports are read by TextReader.read(pages:source:), so they behave like a camera read.
@MainActor
final class ImportReadingTests: XCTestCase {
  private var reader: TextReader!
  private var store: RecentText!

  override func setUp() async throws {
    reader = TextReader()
    store = RecentText(defaults: nil)
    reader.recentText = store
  }

  override func tearDown() async throws {
    reader.stop()
    Announcer.shared.stop()
    reader = nil
  }

  private func waitFor(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
  }

  private var displayed: [String] { reader.sentences.map(\.display) }

  func testAPDFIsReadAsSentencesWithPageHeadingsAndPublishedForAsk() async throws {
    let pdf = Fixture.textPDF(["The bus leaves at nine.", "Bring a coat. It may rain."])
    ImportedReading.read([.init(kind: .pdf, data: pdf)], reader: reader)
    XCTAssertTrue(reader.isActive)
    try await waitFor { displayed.count >= 5 }
    XCTAssertEqual(displayed.first, "PDF, 2 pages. Page 1.")
    XCTAssertTrue(displayed.contains("Page 2."), "\(displayed)")
    XCTAssertTrue(displayed.joined(separator: " ").lowercased().contains("bus leaves at nine"), "\(displayed)")
    XCTAssertTrue(displayed.joined(separator: " ").lowercased().contains("may rain"), "\(displayed)")
    let ask = try XCTUnwrap(store.snapshot(source: .read))
    XCTAssertEqual(ask.title, "A PDF")
    XCTAssertEqual(ask.passages.count, 2, "one passage per page")
    XCTAssertFalse(ask.fullText.contains("Page 2."), "headings aren't page text")
  }

  func testNextPreviousRepeatAndStopMoveThroughImportedText() async throws {
    ImportedReading.read([.init(kind: .pdf, data: Fixture.textPDF(["One cat sat. Two dogs ran. Three birds flew."]))], reader: reader)
    try await waitFor { displayed.count >= 4 }
    XCTAssertEqual(reader.index, 0)
    reader.next()
    XCTAssertEqual(reader.index, 1)
    XCTAssertEqual(reader.phase, .reading)
    reader.next()
    XCTAssertEqual(reader.index, 2)
    reader.previous()
    XCTAssertEqual(reader.index, 1)
    reader.repeatSentence()
    XCTAssertEqual(reader.index, 1)
    XCTAssertEqual(store.snapshot(source: .read)?.current, TextReader.spokenText(reader.sentences[1]))
    reader.stop()
    XCTAssertEqual(reader.phase, .stopped)
    XCTAssertTrue(reader.hasSentences, "stop keeps the text for repeat")
    XCTAssertEqual(reader.statusText, "Stopped at sentence 2 of \(reader.sentences.count)")
    reader.repeatSentence()
    XCTAssertEqual(reader.phase, .reading)
    XCTAssertEqual(reader.index, 1)
  }

  func testAPhotoSaysItsIntroThenItsText() async throws {
    let photo = try XCTUnwrap(Fixture.picture("Fresh bread daily").pngData())
    ImportedReading.read([.init(kind: .image, data: photo)], reader: reader)
    try await waitFor { reader.hasSentences }
    XCTAssertTrue(displayed.joined(separator: " ").lowercased().contains("fresh bread"), "\(displayed)")
    XCTAssertFalse(displayed.contains(SpokenMessage.importReadingPhoto), "the intro is said, not kept as a sentence")
    XCTAssertEqual(store.snapshot(source: .read)?.title, "A photo")
  }

  func testABlankPictureEndsOnItsNotice() async throws {
    ImportedReading.read([.init(kind: .image, data: Fixture.blankPNG())], reader: reader)
    try await waitFor { reader.hasSentences }
    XCTAssertEqual(displayed, [SpokenMessage.importNothingInPicture])
    XCTAssertNil(store.snapshot(source: .read), "nothing to ask about")
    try await waitFor(20) { reader.phase == .guided }
    XCTAssertEqual(reader.phase, .guided, "no \"End of text\" after a notice")
    XCTAssertEqual(reader.notice, SpokenMessage.importNothingInPicture)
  }

  func testAFileThatIsntAPDFSaysSo() async throws {
    ImportedReading.read([.init(kind: .pdf, data: Data("not a pdf".utf8))], reader: reader)
    try await waitFor { reader.hasSentences }
    XCTAssertEqual(displayed, [SpokenMessage.importCouldNotOpen])
  }

  func testNoPagesAtAllEndsWithTheNothingLine() async throws {
    reader.read(pages: [], source: ReadTextSource(title: "A PDF", nothingLine: SpokenMessage.importNothingInPDF))
    try await waitFor { reader.phase == .guided }
    XCTAssertEqual(reader.notice, SpokenMessage.importNothingInPDF)
  }

  func testACameraReadCutsAnImport() async throws {
    ImportedReading.read([.init(kind: .pdf, data: Fixture.textPDF(["A long page of text to read."]))], reader: reader)
    try await waitFor { reader.hasSentences }
    reader.read()  // No camera here: it says so.
    XCTAssertFalse(reader.hasSentences)
    try await waitFor { reader.phase == .guided }
    XCTAssertEqual(reader.notice, SpokenMessage.readNoCamera)
  }

  func testReadPendingEmptiesTheInbox() async throws {
    let saved = ImportedReading.inbox
    ImportedReading.inbox = temporaryInbox()
    defer {
      ImportedReading.inbox.removeAll()
      ImportedReading.inbox = saved
    }
    try ImportedReading.inbox.add(data: Fixture.textPDF(["Hello there."]), fileExtension: "pdf")
    ImportedReading.readPending(reader: reader)
    XCTAssertFalse(ImportedReading.hasPending)
    try await waitFor { reader.hasSentences }
    XCTAssertEqual(displayed.first, "PDF, 1 page.")
  }
}

// MARK: - Intents

@MainActor
final class OpenToolIntentTests: XCTestCase {
  func testEveryToolParksItsLaunchAction() {
    for tool in ToolID.allCases {
      let router = LaunchActionRouter()
      let line = OpenToolLaunch.park(tool, on: router)
      let action = router.consume()
      XCTAssertEqual(action, LaunchAction.open(tool), tool.rawValue)
      XCTAssertEqual(action?.tool, tool == .read ? nil : tool)
      XCTAssertFalse(line.isEmpty)
    }
    XCTAssertEqual(OpenToolLaunch.park(.mail, on: LaunchActionRouter()), "Opening Mail reader.")
    XCTAssertEqual(OpenToolLaunch.park(.read, on: LaunchActionRouter()), SpokenMessage.launchReading)
  }

  func testOneIntentPerToolMapsToItsTool() {
    XCTAssertEqual(OpenMailIntent.tool, .mail)
    XCTAssertEqual(OpenLabelsIntent.tool, .labels)
    XCTAssertEqual(OpenLightIntent.tool, .light)
    XCTAssertEqual(OpenWatchIntent.tool, .watch)
    XCTAssertEqual(OpenAskIntent.tool, .ask)
    XCTAssertEqual(OpenRemindersIntent.tool, .reminders)
    XCTAssertEqual(LaunchAction.open(OpenMailIntent.tool), .openMail)
    XCTAssertEqual(LaunchAction.open(OpenLabelsIntent.tool), .openLabels)
    XCTAssertEqual(LaunchAction.open(OpenLightIntent.tool), .openLight)
    XCTAssertEqual(LaunchAction.open(OpenWatchIntent.tool), .openWatch)
    XCTAssertEqual(LaunchAction.open(OpenAskIntent.tool), .openAsk)
    XCTAssertEqual(LaunchAction.open(OpenRemindersIntent.tool), .openReminders)
  }

  func testOpenToolIntentCarriesItsParameter() {
    XCTAssertEqual(OpenToolIntent(tool: .labels).tool, .labels)
  }

  func testEveryIntentThatOpensAToolOpensTheApp() {
    XCTAssertTrue(OpenToolIntent.openAppWhenRun)
    XCTAssertTrue(OpenMailIntent.openAppWhenRun)
    XCTAssertTrue(OpenLabelsIntent.openAppWhenRun)
    XCTAssertTrue(OpenLightIntent.openAppWhenRun)
    XCTAssertTrue(OpenWatchIntent.openAppWhenRun)
    XCTAssertTrue(OpenAskIntent.openAppWhenRun)
    XCTAssertTrue(OpenRemindersIntent.openAppWhenRun)
    XCTAssertTrue(ReadImportedIntent.openAppWhenRun)
  }

  func testEveryToolHasADisplayName() {
    XCTAssertEqual(Set(ToolID.caseDisplayRepresentations.keys), Set(ToolID.allCases))
  }

  func testAppShortcutsStayWithinApplesLimit() {
    XCTAssertLessThanOrEqual(LaunchShortcuts.appShortcuts.count, 10)
  }
}
