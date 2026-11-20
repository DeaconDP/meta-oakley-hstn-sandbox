/*
 * ImportedReading - reads pages that arrive from outside the camera (share sheet, Photos, Files)
 *
 * Contract with the main screen: whoever receives an image or PDF puts it in the ImportInbox and
 * requests LaunchAction.readImported; the main screen calls readPending() when it can. The in-app
 * ImportButton calls readPending() itself, since the app is already in front.
 *
 * Ways in (notes/reach-ios.md):
 * - ImportButton: Photos picker or Files picker, inside the app.
 * - "Open in SpeakUp" / "Copy to SpeakUp" from Files and other apps (CFBundleDocumentTypes): the
 *   file URL arrives at onOpenURL (ImportLaunchHandling).
 * - The "SpeakUp Share" extension: iOS doesn't let a share extension open its app, so it leaves
 *   the file in the App Group inbox and says "Open SpeakUp to hear it". When the app comes to the
 *   front with something waiting, it is read.
 * - speakup://read-imported reads whatever is waiting (Shortcuts, tests).
 *
 * Reading: the text is recognised here, on the phone only (TextRecognizer, PDF text layers), and
 * handed to TextReader.read(pages:source:). So an import is a Read text read like any other: next,
 * previous, repeat, stop and Magic Tap work on it, and Ask can answer about it. Never the cloud.
 *
 * A PDF: "PDF, 3 pages. Page 1.", page 1, "Page 2.", page 2... The next page is recognised while
 * the current one is spoken. A photo: "Reading the photo." while OCR runs, then the text.
 */

import Foundation

@MainActor
enum ImportedReading {
  /// Where items wait. Tests swap it for a temporary folder.
  static var inbox = ImportInbox.shared

  /// True when something is waiting to be read.
  static var hasPending: Bool { inbox.hasPending }

  /// One waiting item's bytes. `data` is nil when the file couldn't be loaded.
  struct Job: Sendable {
    var kind: ImportInbox.Kind
    var data: Data?
  }

  /// Reads whatever is waiting, then clears it. Does nothing when nothing is waiting.
  static func readPending(reader: TextReader = .shared) {
    let items = inbox.pending()
    guard !items.isEmpty else { return }
    var jobs: [Job] = []
    for item in items {
      // Taken out of the inbox now: a stopped read isn't repeated at the next launch.
      let data = try? Data(contentsOf: item.url)
      inbox.remove(item)
      jobs.append(Job(kind: item.kind, data: data))
    }
    read(jobs, reader: reader)
  }

  /// Recognises `jobs` in order, off the main actor, and hands the pages to `reader` as they come.
  static func read(_ jobs: [Job], reader: TextReader = .shared) {
    guard let first = jobs.first else { return }
    let source = ReadTextSource(
      title: first.kind == .pdf ? "A PDF" : "A photo",
      intro: first.kind == .image ? SpokenMessage.importReadingPhoto : nil,
      nothingLine: first.kind == .pdf ? SpokenMessage.importNothingInPDF : SpokenMessage.importNothingInPicture)
    let pages = AsyncStream<ReadTextPage> { continuation in
      let work = Task.detached(priority: .userInitiated) {
        for (index, job) in jobs.enumerated() {
          guard !Task.isCancelled else { break }
          for await page in Self.pages(of: job, isFirst: index == 0) {
            guard !Task.isCancelled else { break }
            continuation.yield(page)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in work.cancel() }
    }
    reader.read(pages: pages, source: source)
  }

  /// The pages of one item. Blocking work; call from a background task.
  nonisolated static func pages(of job: Job, isFirst: Bool) -> AsyncStream<ReadTextPage> {
    AsyncStream { continuation in
      switch job.kind {
      case .image: continuation.yield(photoPage(job.data, isFirst: isFirst))
      case .pdf: pdfPages(job.data, into: continuation)
      }
      continuation.finish()
    }
  }

  nonisolated static func photoPage(_ data: Data?, isFirst: Bool) -> ReadTextPage {
    // The first photo's "Reading the photo." is said at once, while OCR runs (the read's intro).
    let heading = isFirst ? nil : SpokenMessage.importReadingPhoto
    guard let data, let text = try? ImportedPages.recognizeImage(data: data) else {
      BenchClock.shared.note("import photo unreadable")
      return ReadTextPage(heading: heading, page: nil, emptyLine: SpokenMessage.importCouldNotOpen)
    }
    BenchClock.shared.note(text.isEmpty ? "import photo empty" : "import photo lines=\(text.page.lines.count)")
    return ReadTextPage(heading: heading, page: text.page, emptyLine: SpokenMessage.importNothingInPicture)
  }

  nonisolated static func pdfPages(_ data: Data?, into continuation: AsyncStream<ReadTextPage>.Continuation) {
    let pdf: ImportedPDF
    do {
      guard let data else { throw ImportedPages.ImportError.unreadablePDF }
      pdf = try ImportedPDF(data: data)
    } catch let error as ImportedPages.ImportError where error == .lockedPDF {
      continuation.yield(ReadTextPage(emptyLine: SpokenMessage.importLockedPDF))
      return
    } catch {
      continuation.yield(ReadTextPage(emptyLine: SpokenMessage.importCouldNotOpen))
      return
    }
    guard pdf.pageCount > 0 else {
      continuation.yield(ReadTextPage(emptyLine: SpokenMessage.importNothingInPDF))
      return
    }
    BenchClock.shared.note("import pdf pages=\(pdf.pageCount)")
    var anyText = false
    for index in 0..<pdf.pageCount {
      guard !Task.isCancelled else { return }
      let heading = SpokenMessage.importPDFPage(index + 1, of: pdf.pageCount)
      switch Result(catching: { try pdf.text(ofPage: index) }) {
      case .success(let text) where !ImportedPages.sentences(text.page).isEmpty:
        anyText = true
        BenchClock.shared.note(
          "import pdf page=\(index + 1) source=\(text.source == .textLayer ? "text_layer" : "ocr") lines=\(text.page.lines.count)")
        continuation.yield(ReadTextPage(heading: heading, page: text.page))
      case .success:
        BenchClock.shared.note("import pdf page=\(index + 1) empty")
        continuation.yield(ReadTextPage(heading: heading, page: nil, emptyLine: SpokenMessage.importPageEmpty))
      case .failure:
        continuation.yield(ReadTextPage(heading: heading, page: nil, emptyLine: SpokenMessage.importPageFailed))
      }
    }
    if !anyText, pdf.pageCount > 1 { continuation.yield(ReadTextPage(emptyLine: SpokenMessage.importNothingInPDF)) }
  }

  // MARK: Arrivals

  /// A URL handed to the app. A file (Open in / Copy to) goes into the inbox and is read; a
  /// speakup://read-imported link reads what is waiting. Returns false for any other URL, which
  /// belongs to someone else (hands-free, Meta AI's callback).
  @discardableResult
  static func handle(_ url: URL, router: LaunchActionRouter = .shared) -> Bool {
    if url.isFileURL {
      if addFile(url) { router.request(.readImported) }
      return true
    }
    guard ImportURL.isReadImported(url) else { return false }
    router.request(.readImported)
    return true
  }

  /// Copies a picked or opened file into the inbox. Says why when it can't. True when added.
  @discardableResult
  static func addFile(_ url: URL) -> Bool {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      try inbox.add(copying: url)
    } catch {
      BenchClock.shared.note("import refused ext=\(url.pathExtension)")
      let line = error as? ImportInbox.InboxError == .notAPhotoOrPDF
        ? SpokenMessage.importNotSupported : SpokenMessage.importCouldNotOpen
      Announcer.shared.say(line, kind: .reply)
      return false
    }
    // "Copy to" leaves a copy in Documents/Inbox; it is in our inbox now, so don't keep it twice.
    if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
    return true
  }

  /// The app came to the front: if the share extension left something, ask for it to be read.
  static func appBecameActive(router: LaunchActionRouter = .shared) {
    // A read in progress isn't cut; what is waiting is read the next time the app comes forward.
    guard !TextReader.shared.isActive, hasPending else { return }
    router.request(.readImported)
  }
}

/// speakup://read-imported (also read-import, readimported, import).
enum ImportURL {
  static let scheme = "speakup"
  static let readImported = URL(string: "speakup://read-imported")!

  static func isReadImported(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == scheme else { return false }
    let target = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return ["read-imported", "read-import", "readimported", "import"].contains(target)
  }
}
