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
 * Reading is ImportedReader: on the phone only (TextRecognizer, PDF text layers, the app's voice).
 */

import Foundation

@MainActor
enum ImportedReading {
  /// Where items wait. Tests swap it for a temporary folder.
  static var inbox = ImportInbox.shared

  /// True when something is waiting to be read.
  static var hasPending: Bool { inbox.hasPending }

  /// Reads whatever is waiting, then clears it. Does nothing when nothing is waiting.
  static func readPending() {
    let items = inbox.pending()
    guard !items.isEmpty else { return }
    var jobs: [ImportedReader.Job] = []
    for item in items {
      // Taken out of the inbox now: a stopped read isn't repeated at the next launch.
      let data = try? Data(contentsOf: item.url)
      inbox.remove(item)
      jobs.append(ImportedReader.Job(kind: item.kind, data: data))
    }
    ImportedReader.shared.read(jobs)
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
    guard !ImportedReader.shared.isActive, hasPending else { return }
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
