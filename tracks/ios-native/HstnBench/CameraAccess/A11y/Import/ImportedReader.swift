/*
 * ImportedReader - speaks imported photos and PDFs: "Reading the photo." / "PDF, 3 pages. Page 1."
 *
 * Uses the camera reader's building blocks unchanged: ReadingOrder and SentenceSplitter for the
 * order and the sentences, ReadSpeech.render for the spoken form (uncertain words, withheld doses
 * and amounts), Announcer for the voice and EarconPlayer for the tones. TextReader itself has no
 * way to be handed a page (its only trigger is the camera), so this reader speaks the sentences
 * the same way it does, one after another, and stops when anything cuts in (a new read, Stop,
 * VoiceOver's stop). Next / previous / repeat by voice go to TextReader and don't reach this
 * text yet (notes/reach-ios.md > "Open").
 *
 * Every page's text goes to RecentText under Read text, so Ask can answer about it.
 * Always on the phone: imports are never sent to the cloud reader.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ImportedReader {
  static let shared = ImportedReader()

  struct Job: Sendable {
    var kind: ImportInbox.Kind
    /// nil when the file couldn't be loaded.
    var data: Data?
  }

  enum Phase: Equatable {
    case idle
    case working
    case reading
    case finished
    case stopped
  }

  private(set) var phase: Phase = .idle
  /// What is being read, for the screen ("PDF, page 2 of 3").
  private(set) var statusText = ""

  var isActive: Bool { phase == .working || phase == .reading }

  private static let tickOwner = "import"

  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var queue: [Job] = []
  /// Bumped by every new run and by stop(), so an old run never clears a newer one's task.
  @ObservationIgnored private var runID = 0

  /// Reads `jobs` one after another. If a read is already going, they wait their turn.
  func read(_ jobs: [Job]) {
    guard !jobs.isEmpty else { return }
    queue.append(contentsOf: jobs)
    guard task == nil else { return }
    if TextReader.shared.isActive { TextReader.shared.stop() }
    runID += 1
    let myRun = runID
    task = Task { [weak self] in
      await self?.drain(myRun)
    }
  }

  func stop() {
    runID += 1
    queue.removeAll()
    task?.cancel()
    task = nil
    earcons.stopWorkingTick(owner: Self.tickOwner)
    announcer.stop()
    RecentText.shared.setCurrent(nil, source: .read)
    if isActive { phase = .stopped }
  }

  // MARK: Running

  private func drain(_ myRun: Int) async {
    while runID == myRun, !queue.isEmpty, !Task.isCancelled {
      let job = queue.removeFirst()
      let completed: Bool
      switch job.kind {
      case .image: completed = await readImage(job.data)
      case .pdf: completed = await readPDF(job.data)
      }
      if !completed {
        // Cut by something else: drop the rest too, the user wants quiet.
        queue.removeAll()
        if phase != .idle { phase = .stopped }
        break
      }
    }
    guard runID == myRun else { return }
    RecentText.shared.setCurrent(nil, source: .read)
    earcons.stopWorkingTick(owner: Self.tickOwner)
    task = nil
  }

  /// False when it was cut short.
  private func readImage(_ data: Data?) async -> Bool {
    phase = .working
    statusText = "Reading the photo"
    startWorking()
    // OCR runs while the first line is spoken.
    let recognition = Task.detached(priority: .userInitiated) { () -> Result<ImportedPages.PageText, any Error> in
      guard let data else { return .failure(ImportedPages.ImportError.unreadableImage) }
      return Result { try ImportedPages.recognizeImage(data: data) }
    }
    guard await say(SpokenMessage.importReadingPhoto, interrupt: true) else {
      recognition.cancel()
      return false
    }
    let result = await recognition.value
    guard !Task.isCancelled else { return false }
    switch result {
    case .failure:
      return await fail(SpokenMessage.importCouldNotOpen)
    case .success(let text) where text.isEmpty || ImportedPages.sentences(text.page).isEmpty:
      BenchClock.shared.note("import photo empty")
      return await fail(SpokenMessage.importNothingInPicture, earcon: .attention)
    case .success(let text):
      BenchClock.shared.note("import photo lines=\(text.page.lines.count)")
      publish(text.page, key: "import-photo-\(UUID().uuidString)", title: "A photo")
      guard await speak(text.page) else { return false }
      return await finished()
    }
  }

  private func readPDF(_ data: Data?) async -> Bool {
    phase = .working
    statusText = "Opening the PDF"
    startWorking()
    let opened: Result<ImportedPDF, any Error> = await Task.detached(priority: .userInitiated) {
      Result { () throws -> ImportedPDF in
        guard let data else { throw ImportedPages.ImportError.unreadablePDF }
        return try ImportedPDF(data: data)
      }
    }.value
    guard !Task.isCancelled else { return false }
    let pdf: ImportedPDF
    switch opened {
    case .success(let document): pdf = document
    case .failure(let error as ImportedPages.ImportError) where error == .lockedPDF:
      return await fail(SpokenMessage.importLockedPDF)
    case .failure: return await fail(SpokenMessage.importCouldNotOpen)
    }
    guard pdf.pageCount > 0 else { return await fail(SpokenMessage.importNothingInPDF, earcon: .attention) }
    BenchClock.shared.note("import pdf pages=\(pdf.pageCount)")

    let documentKey = UUID().uuidString
    var next = Self.pageTask(pdf, 0)
    var anyText = false
    for index in 0..<pdf.pageCount {
      let current = next
      if index + 1 < pdf.pageCount { next = Self.pageTask(pdf, index + 1) }
      let heading = SpokenMessage.importPDFPage(index + 1, of: pdf.pageCount)
      statusText = "PDF, page \(index + 1) of \(pdf.pageCount)"
      guard await say(heading, interrupt: index == 0) else { current.cancel(); next.cancel(); return false }
      let result = await current.value
      guard !Task.isCancelled else { next.cancel(); return false }
      switch result {
      case .success(let text) where !ImportedPages.sentences(text.page).isEmpty:
        anyText = true
        BenchClock.shared.note(
          "import pdf page=\(index + 1) source=\(text.source == .textLayer ? "text_layer" : "ocr") lines=\(text.page.lines.count)")
        publish(text.page, key: "import-pdf-\(documentKey)-\(index + 1)", title: "A PDF")
        guard await speak(text.page) else { next.cancel(); return false }
      case .success:
        BenchClock.shared.note("import pdf page=\(index + 1) empty")
        stopWorking()
        guard await say(SpokenMessage.importPageEmpty) else { next.cancel(); return false }
      case .failure:
        stopWorking()
        guard await say(SpokenMessage.importPageFailed) else { next.cancel(); return false }
      }
      if index + 1 < pdf.pageCount { startWorking() }
    }
    if !anyText, pdf.pageCount > 1 {
      return await fail(SpokenMessage.importNothingInPDF, earcon: .attention)
    }
    return await finished()
  }

  private static func pageTask(_ pdf: ImportedPDF, _ index: Int) -> Task<Result<ImportedPages.PageText, any Error>, Never> {
    Task.detached(priority: .userInitiated) { Result { try pdf.text(ofPage: index) } }
  }

  // MARK: Speaking

  /// Speaks the page sentence by sentence. False when cut short.
  private func speak(_ page: ReadPage) async -> Bool {
    stopWorking()
    phase = .reading
    let preferences = A11yPreferences.shared
    let rendered = ImportedPages.sentences(page)
      .map { ReadSpeech.render($0, verbosity: preferences.verbosity, earconsEnabled: preferences.earconsEnabled) }
      .filter { !$0.chunks.isEmpty }
    for sentence in rendered {
      RecentText.shared.setCurrent(sentence.display, source: .read)
      var finished = true
      for (index, chunk) in sentence.chunks.enumerated() {
        let isLast = index == sentence.chunks.count - 1
        if isLast {
          finished = await say(chunk.text, earcon: chunk.flagged ? .uncertain : nil)
        } else if chunk.flagged {
          announcer.announce(chunk.text, earcon: .uncertain, kind: .reply, interrupt: false)
        } else {
          announcer.say(chunk.text, kind: .reply, interrupt: false)
        }
      }
      guard finished, !Task.isCancelled else { return false }
    }
    return true
  }

  private func finished() async -> Bool {
    stopWorking()
    phase = .finished
    statusText = ""
    return await say(SpokenMessage.readEnd(verbosity: A11yPreferences.shared.verbosity), earcon: .done)
  }

  /// A failure line. The queue carries on with the next item.
  private func fail(_ line: String, earcon: Earcon = .error) async -> Bool {
    stopWorking()
    phase = .finished
    statusText = line
    return await say(line, earcon: earcon)
  }

  /// Queues a line and waits for it. True when it was spoken to the end.
  private func say(_ text: String, earcon: Earcon? = nil, interrupt: Bool = false) async -> Bool {
    await withCheckedContinuation { continuation in
      let done: Announcer.Completion = { finished in
        if !finished { BenchClock.shared.note("import line cut: \(text.prefix(40))") }
        continuation.resume(returning: finished)
      }
      if let earcon {
        announcer.announce(text, earcon: earcon, kind: .reply, interrupt: interrupt, onFinish: done)
      } else {
        announcer.say(text, kind: .reply, interrupt: interrupt, onFinish: done)
      }
    }
  }

  private func publish(_ page: ReadPage, key: String, title: String) {
    RecentText.shared.append(ImportedPages.plainText(page), source: .read, key: key)
    RecentText.shared.setTitle(title, source: .read)
  }

  private func startWorking() {
    earcons.play(.working)
    earcons.startWorkingTick(owner: Self.tickOwner)
  }

  private func stopWorking() {
    earcons.stopWorkingTick(owner: Self.tickOwner)
  }
}
