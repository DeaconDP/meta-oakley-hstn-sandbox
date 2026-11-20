/*
 * SpokenMessage+Import - what SpeakUp says when it reads a photo or PDF from another app, and
 * what Siri says when a tool is opened from a shortcut
 */

extension SpokenMessage {
  // MARK: Import

  static let importReadingPhoto = "Reading the photo."

  static let importNothingInPicture = "Nothing to read in this picture."

  static let importNothingInPDF = "Nothing to read in this PDF."

  static let importPageEmpty = "No text on this page."

  static let importPageFailed = "This page couldn't be read."

  static let importCouldNotOpen = "SpeakUp couldn't open this file."

  static let importLockedPDF = "This PDF has a password. Open it in Files first, then share it again."

  static let importNotSupported = "SpeakUp reads photos and PDFs. This file is neither."

  /// "PDF, 3 pages. Page 1." first, then "Page 2." for the rest. One page: "PDF, 1 page."
  static func importPDFPage(_ page: Int, of count: Int) -> String {
    guard page == 1 else { return "Page \(page)." }
    return count == 1 ? "PDF, 1 page." : "PDF, \(count) pages. Page 1."
  }

  // MARK: Import by voice

  /// Said before a picker opens by voice ("read a photo", "read a file", "import"). The pickers
  /// are the system's, so the line says how to get round them without the app's voice.
  static func importOpening(_ request: ImportPicker.Request) -> String {
    switch request {
    case .photo:
      "Opening your photos. Pick one and I'll read it. The picker works with VoiceOver or Voice Control."
    case .file:
      "Opening your files. Pick a PDF or a picture and I'll read it. The picker works with VoiceOver or Voice Control."
    case .choice:
      "Read a photo or PDF. Choose a photo, or choose a file, and I'll read it. The list works with VoiceOver or Voice Control."
    }
  }

  /// "Read what I shared" with nothing waiting: then the choice.
  static let importNothingShared = "Nothing shared is waiting."

  // MARK: Launch: open a tool

  /// Siri's line when a shortcut opens a tool ("Opening Mail reader.").
  static func launchOpening(_ tool: ToolID) -> String {
    "Opening \(tool.title)."
  }

  static let launchReadingImported = "Reading what you shared."
}
