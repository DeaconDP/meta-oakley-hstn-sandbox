/*
 * RecentText - the text each tool has read out recently, for "Ask about the text"
 *
 * A question like "what does ephemeral mean?" or "who's Mr. Bennet?" is about what the user just
 * heard. Tools publish that text here as they read it:
 *
 *   RecentText.shared.append(pageText, source: .read)            // a page, a letter, a label
 *   RecentText.shared.setCurrent(sentence, source: .read)        // the sentence being read now
 *   RecentText.shared.setCurrent(nil, source: .read)             // finished or stopped
 *
 * Ask uses `forQuestion(source:)`: that tool's text if it has any, else whichever tool published
 * last. When a tool tracks its current sentence, only the text up to and including it counts, so
 * names, searches and "did you mean" never draw on what hasn't been heard yet (AskReadText).
 *
 * Only text, never images. Memory only, bounded: past `maxCharacters` per tool the oldest passages
 * go first. The one thing kept on the phone across launches is the last ~3,000 characters heard
 * (whole sentences), for "what happened last time?"; it never leaves the phone. Thread-safe, so a
 * tool can publish from any thread. Ported from Android's tools/core/RecentText.kt and
 * tools/ask/AskMemory.kt.
 */

import Foundation

final class RecentText: @unchecked Sendable {
  static let shared = RecentText()

  /// What one tool has read. `passages` oldest first; `current` is the sentence being read now.
  struct Snapshot: Equatable, Sendable {
    var source: ToolID
    var passages: [String]
    var current: String?
    var title: String?
    var updatedAt: Date

    /// All passages joined, oldest first.
    var fullText: String { passages.joined(separator: "\n\n") }
  }

  static let defaultMaxCharacters = 40_000
  /// Kept across launches for "what happened last time".
  static let tailKey = "ask_recent_text_tail"
  static let tailCharacters = 3_000

  private struct Entry {
    var passages: [(key: String, text: String)] = []
    var current: String?
    var title: String?
    var updatedAt = Date.distantPast
  }

  private let lock = NSLock()
  private var entries: [ToolID: Entry] = [:]
  private let maxCharacters: Int
  private let clock: @Sendable () -> Date
  private let defaults: UserDefaults?
  /// What the last app session heard, read once before this session writes over it.
  let previousSession: String?

  /// - Parameter defaults: where the tail for "last time" is kept; nil keeps nothing (tests).
  init(
    maxCharacters: Int = RecentText.defaultMaxCharacters, defaults: UserDefaults? = .standard,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.maxCharacters = maxCharacters
    self.clock = clock
    self.defaults = defaults
    previousSession = defaults?.string(forKey: Self.tailKey)
  }

  /// Adds a passage (a page, a letter). Publishing the same `key` again replaces that passage (a
  /// page re-read after a correction) instead of adding a copy. The key defaults to the text.
  func append(_ text: String, source: ToolID, key: String? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let key = key ?? trimmed
    let snapshot: Snapshot? = lock.withLock {
      var entry = entries[source] ?? Entry()
      if let index = entry.passages.firstIndex(where: { $0.key == key }) {
        entry.passages[index] = (key, trimmed)
      } else {
        entry.passages.append((key, trimmed))
      }
      while entry.passages.count > 1, entry.passages.reduce(0, { $0 + $1.text.count }) > maxCharacters {
        entry.passages.removeFirst()
      }
      entry.updatedAt = clock()
      entries[source] = entry
      return makeSnapshot(source, entry)
    }
    saveTail(snapshot)
  }

  /// The sentence being read now; nil when nothing is being read.
  func setCurrent(_ sentence: String?, source: ToolID) {
    let snapshot: Snapshot? = lock.withLock {
      var entry = entries[source] ?? Entry()
      entry.current = sentence
      entry.updatedAt = clock()
      entries[source] = entry
      return makeSnapshot(source, entry)
    }
    saveTail(snapshot)
  }

  /// Optional context ("Letter from ...").
  func setTitle(_ title: String?, source: ToolID) {
    lock.withLock {
      var entry = entries[source] ?? Entry()
      entry.title = title
      entries[source] = entry
    }
  }

  /// Forget what `source` read (a new letter replaces the old one, say).
  func clear(source: ToolID) {
    _ = lock.withLock { entries.removeValue(forKey: source) }
  }

  func snapshot(source: ToolID) -> Snapshot? {
    lock.withLock { entries[source].flatMap { makeSnapshot(source, $0) } }
  }

  /// The tool that published most recently, or nil if nothing has been read.
  func latest() -> Snapshot? {
    lock.withLock {
      entries.compactMap { makeSnapshot($0.key, $0.value) }.max { $0.updatedAt < $1.updatedAt }
    }
  }

  /// `source`'s text if it has any, else the most recent text from any tool.
  func forQuestion(source: ToolID?) -> Snapshot? {
    if let source, let own = snapshot(source: source) { return own }
    return latest()
  }

  private func makeSnapshot(_ source: ToolID, _ entry: Entry) -> Snapshot? {
    guard !entry.passages.isEmpty || entry.current != nil else { return nil }
    return Snapshot(
      source: source, passages: entry.passages.map(\.text), current: entry.current, title: entry.title,
      updatedAt: entry.updatedAt)
  }

  private func saveTail(_ snapshot: Snapshot?) {
    guard let defaults, let tail = AskReadText.tail(snapshot, maxCharacters: Self.tailCharacters) else { return }
    defaults.set(tail, forKey: Self.tailKey)
  }
}
