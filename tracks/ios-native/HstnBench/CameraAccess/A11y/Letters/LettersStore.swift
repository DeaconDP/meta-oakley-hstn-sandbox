/*
 * LettersStore - the letters log, kept on the phone
 *
 * Every letter the mail reader has dealt with: its summary fields and its text, never the photo
 * (LetterRecord). One JSON file in Application Support/Letters, written atomically with
 * NSFileProtectionComplete (unreadable while the phone is locked) and excluded from iCloud and
 * computer backups, folder and file both. Nothing here sends anything anywhere; export happens
 * only when the user taps an export button (LettersExport, ShareLink).
 *
 * If the file exists but can't be read (the phone is locked, or the file is damaged), saving is
 * refused rather than overwriting the log with only the new letter. Newest first.
 */

import Foundation
import Observation

@MainActor
@Observable
final class LettersStore {
  static let shared = LettersStore()

  /// Newest first.
  private(set) var letters: [LetterRecord] = []

  @ObservationIgnored let directory: URL?
  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private var loaded = false
  private static let toldKey = "letters.toldAboutSaving"

  /// `directory` nil keeps the log in memory only (previews). Tests pass a temporary folder.
  init(directory: URL? = LettersStore.defaultDirectory(), defaults: UserDefaults? = .standard) {
    self.directory = directory
    self.defaults = defaults
    _ = load()
  }

  nonisolated static func defaultDirectory() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Letters", isDirectory: true)
  }

  var fileURL: URL? { directory?.appendingPathComponent("letters.json") }

  /// Whether the user has been told once that letters are kept on the phone.
  var hasToldAboutSaving: Bool {
    get { defaults?.bool(forKey: Self.toldKey) ?? true }
    set { defaults?.set(newValue, forKey: Self.toldKey) }
  }

  // MARK: Reading

  /// Reads the file. False when it exists but couldn't be read.
  @discardableResult
  func load() -> Bool {
    guard let url = fileURL else {
      loaded = true
      return true
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      letters = []
      loaded = true
      return true
    }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      letters = try decoder.decode([LetterRecord].self, from: data).sorted { $0.savedAt > $1.savedAt }
      loaded = true
      return true
    } catch {
      BenchClock.shared.note("letters load failed: \(error.localizedDescription)")
      loaded = false
      return false
    }
  }

  func record(id: String) -> LetterRecord? { letters.first { $0.id == id } }

  /// Letters whose sender matches what was said, best first: "Northgate" finds "Northgate Energy".
  func find(sender query: String) -> [LetterRecord] {
    let wanted = Self.words(query)
    guard !wanted.isEmpty else { return [] }
    let scored = letters.compactMap { record -> (LetterRecord, Int)? in
      let have = Self.words([record.sender, record.title].compactMap { $0 }.joined(separator: " "))
      let hits = wanted.filter { word in have.contains { $0 == word || ($0.hasPrefix(word) && word.count >= 3) } }.count
      return hits == wanted.count ? (record, hits) : nil
    }
    return scored.map(\.0)
  }

  private static let ignored: Set<String> = ["the", "a", "an", "my", "of", "from", "letter", "ltd", "limited", "plc"]

  private static func words(_ text: String) -> [String] {
    VoiceCommandParser.normalize(text).filter { !ignored.contains($0) }
  }

  // MARK: Writing

  /// Adds the letter, or replaces the one with the same id. False (log unchanged) on failure.
  @discardableResult
  func save(_ record: LetterRecord) -> Bool {
    guard loaded || load() else { return false }
    var next = letters.filter { $0.id != record.id }
    var record = record
    if let old = letters.first(where: { $0.id == record.id }), record.reminderAt == nil { record.reminderAt = old.reminderAt }
    next.insert(record, at: 0)
    next.sort { $0.savedAt > $1.savedAt }
    return write(next)
  }

  @discardableResult
  func setReminder(_ date: Date?, for id: String) -> Bool {
    guard var record = record(id: id) else { return false }
    record.reminderAt = date
    return write(letters.map { $0.id == id ? record : $0 })
  }

  @discardableResult
  func delete(id: String) -> Bool {
    guard loaded || load() else { return false }
    guard letters.contains(where: { $0.id == id }) else { return false }
    return write(letters.filter { $0.id != id })
  }

  /// Forgets every letter: the file is removed.
  @discardableResult
  func deleteAll() -> Bool {
    if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        BenchClock.shared.note("letters delete all failed: \(error.localizedDescription)")
        return false
      }
    }
    letters = []
    loaded = true
    return true
  }

  private func write(_ records: [LetterRecord]) -> Bool {
    guard let url = fileURL, let directory else {
      letters = records
      return true
    }
    do {
      try Self.prepare(directory)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(records).write(to: url, options: [.atomic, .completeFileProtection])
      try Self.excludeFromBackup(url)
      letters = records
      return true
    } catch {
      BenchClock.shared.note("letters save failed: \(error.localizedDescription)")
      return false
    }
  }

  private static func prepare(_ directory: URL) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: directory.path) {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
    }
    try excludeFromBackup(directory)
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
