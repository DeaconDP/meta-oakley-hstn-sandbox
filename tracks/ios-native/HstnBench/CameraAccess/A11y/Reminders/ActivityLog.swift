/*
 * ActivityLog - "What was I doing?": a short list of recent steps (a tool opened, a tool closed),
 * kept in memory for this session only
 *
 * ToolHub notes each open and close. Nothing is written to disk and no camera frame or read text
 * is kept: only the step's name and when.
 */

import Foundation

@MainActor
final class ActivityLog {
  static let shared = ActivityLog()

  struct Entry: Equatable, Sendable {
    var text: String
    var tool: ToolID?
    var at: Date
  }

  private(set) var entries: [Entry] = []
  static let limit = 30
  var now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// "Opened Mail reader". `tool` is the tool it was about, if any.
  func note(_ text: String, tool: ToolID?) {
    entries.append(Entry(text: text, tool: tool, at: now()))
    if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
  }

  func clear() { entries.removeAll() }

  /// The answer to "what was I doing?": the tool open now, then the last few steps before it,
  /// leaving out Reminders itself.
  func whatWasIDoing(openTool: ToolID?) -> String {
    var steps = entries.filter { $0.tool != .reminders }
    var lead = ""
    if let openTool, openTool != .reminders {
      lead = "You're in \(openTool.title) now. "
      if let last = steps.last, last.tool == openTool, last.text.hasPrefix("Opened") { steps.removeLast() }
    }
    let recent = steps.suffix(3).reversed()
    guard let first = recent.first else {
      return lead.isEmpty ? "Nothing yet. You haven't used a tool since SpeakUp opened." : lead + "Nothing before that this time."
    }
    var line = lead + "\(Self.ago(first.at, now: now()).capitalizedFirst), you \(first.text.lowercasedFirstWord)."
    let earlier = recent.dropFirst().map { $0.text.lowercasedFirstWord }
    if !earlier.isEmpty { line += " Before that, you \(earlier.joined(separator: ", then before that, "))." }
    return line
  }

  /// "just now", "a minute ago", "5 minutes ago", "an hour ago", "2 hours ago".
  static func ago(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    switch minutes {
    case ..<1: return "just now"
    case 1: return "a minute ago"
    case 2..<60: return "\(minutes) minutes ago"
    case 60..<120: return "an hour ago"
    default: return "\(minutes / 60) hours ago"
    }
  }
}

extension String {
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
  /// "Opened Mail reader" is "opened Mail reader".
  fileprivate var lowercasedFirstWord: String { prefix(1).lowercased() + dropFirst() }
}
