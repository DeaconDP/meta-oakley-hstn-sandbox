/*
 * ImportInbox - photos and PDFs waiting to be read, as plain files in one folder
 *
 * Compiled into the app (both targets) and into the "SpeakUp Share" extension, so it uses
 * Foundation only. The share extension can't open the app (iOS only lets Today and iMessage
 * extensions do that), so it drops the file here and says "Open SpeakUp to hear it". The app
 * looks here when it comes to the front and reads what is waiting (ImportedReading).
 *
 * The folder is in the App Group container when the app has the group (the SpeakUp target and
 * its extension), else in the app's own Application Support (the Beta target, tests).
 * One file per item, named `<milliseconds>-<random>.<ext>`, so the name sorts oldest first and
 * no index file can get out of step with the files. Items are deleted once read, and anything
 * older than `maxAge` is dropped unread: a shared page is not kept on the phone for long.
 */

import Foundation
import UniformTypeIdentifiers

struct ImportInbox: Sendable {
  static let appGroupID = "group.com.deaco.speakup"
  static let folderName = "ImportInbox"
  /// Unread items older than this are deleted.
  static let maxAge: TimeInterval = 7 * 24 * 60 * 60

  enum Kind: String, Sendable, Equatable {
    case image
    case pdf

    /// From a file name extension ("pdf", "PNG", "heic"); nil for anything else.
    init?(fileExtension: String) {
      guard let type = UTType(filenameExtension: fileExtension.lowercased()) else { return nil }
      self.init(type: type)
    }

    init?(type: UTType) {
      if type.conforms(to: .pdf) {
        self = .pdf
      } else if type.conforms(to: .image) {
        self = .image
      } else {
        return nil
      }
    }
  }

  struct Item: Equatable, Sendable {
    var url: URL
    var kind: Kind
    var addedAt: Date
  }

  enum InboxError: Error, Equatable {
    case notAPhotoOrPDF
  }

  let directory: URL

  init(directory: URL) {
    self.directory = directory
  }

  /// The App Group folder when the group is available, else the app's own.
  static var shared: ImportInbox {
    let fileManager = FileManager.default
    if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
      return ImportInbox(directory: group.appendingPathComponent(folderName, isDirectory: true))
    }
    let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return ImportInbox(directory: support.appendingPathComponent(folderName, isDirectory: true))
  }

  // MARK: Adding

  /// Saves `data` as a new item. `fileExtension` keeps the format ("png", "heic", "pdf").
  @discardableResult
  func add(data: Data, fileExtension: String, now: Date = Date()) throws -> Item {
    guard let kind = Kind(fileExtension: fileExtension) else { throw InboxError.notAPhotoOrPDF }
    let url = try newURL(fileExtension: fileExtension, now: now)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return Item(url: url, kind: kind, addedAt: now)
  }

  /// Copies the file at `source` in as a new item. The original is left alone.
  @discardableResult
  func add(copying source: URL, now: Date = Date()) throws -> Item {
    let fileExtension = source.pathExtension
    guard let kind = Kind(fileExtension: fileExtension) else { throw InboxError.notAPhotoOrPDF }
    let url = try newURL(fileExtension: fileExtension, now: now)
    try FileManager.default.copyItem(at: source, to: url)
    return Item(url: url, kind: kind, addedAt: now)
  }

  // MARK: Reading

  /// Items waiting, oldest first. Drops (and deletes) anything older than `maxAge`.
  func pending(now: Date = Date()) -> [Item] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var items: [Item] = []
    for name in names.sorted() {
      let url = directory.appendingPathComponent(name)
      guard let item = Self.item(at: url) else { continue }
      if now.timeIntervalSince(item.addedAt) > Self.maxAge {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      items.append(item)
    }
    return items
  }

  var hasPending: Bool { !pending().isEmpty }

  func remove(_ item: Item) {
    try? FileManager.default.removeItem(at: item.url)
  }

  func removeAll() {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Names

  /// `<ms since 1970, 15 digits>-<8 random hex>.<ext>`
  static func fileName(addedAt: Date, fileExtension: String, random: String = Self.randomTag()) -> String {
    let milliseconds = max(0, Int64((addedAt.timeIntervalSince1970 * 1000).rounded()))
    let stamp = String(milliseconds)
    let padded = String(repeating: "0", count: max(0, 15 - stamp.count)) + stamp
    return "\(padded)-\(random).\(fileExtension.lowercased())"
  }

  /// The item a file in the inbox stands for; nil for files that don't follow the naming.
  static func item(at url: URL) -> Item? {
    let name = url.deletingPathExtension().lastPathComponent
    guard let kind = Kind(fileExtension: url.pathExtension),
      let stamp = name.split(separator: "-").first, stamp.count == 15,
      let milliseconds = Int64(stamp)
    else { return nil }
    return Item(url: url, kind: kind, addedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
  }

  static func randomTag() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
  }

  private func newURL(fileExtension: String, now: Date) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(Self.fileName(addedAt: now, fileExtension: fileExtension))
  }
}
