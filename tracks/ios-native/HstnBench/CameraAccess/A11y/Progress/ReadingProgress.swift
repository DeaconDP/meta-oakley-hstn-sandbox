/*
 * ReadingProgress - a day streak and pages read today, from real reading only
 *
 * `ReadingProgress` is pure: a value, a day in, a value out. A streak counts calendar days in a row
 * with at least one finished page. Days are the user's local calendar days, compared by date rather
 * than by elapsed time, so daylight saving and travel can't break or extend one.
 *
 * Missing a day ends the current count and takes nothing else: the best streak and all totals stay,
 * and nothing in the app mentions it. There are no penalties and no reminders. A clock moved back
 * doesn't lose anything either.
 *
 * Milestones are rare on purpose: a streak of 3, 7, 14, 30, 50, 100 or 365 days, or today's goal,
 * and at most one per finished page. They are spoken once, queued behind the end of the reading.
 */

import Foundation
import Observation

/// A calendar day. Compared by its date, so its length in hours doesn't matter.
struct ReadingDay: Codable, Equatable, Sendable {
  var year: Int
  var month: Int
  var day: Int

  init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  init(_ date: Date, calendar: Calendar = .current) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
  }

  /// Whole days from this one to `other`. Negative if `other` is earlier.
  func days(until other: ReadingDay) -> Int {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    func noon(_ day: ReadingDay) -> Date? {
      utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }
    guard let from = noon(self), let to = noon(other) else { return 0 }
    return utc.dateComponents([.day], from: from, to: to).day ?? 0
  }
}

enum ReadingMilestone: Equatable, Sendable {
  case streak(Int)
  case dailyGoal(Int)

  var spokenLine: String {
    switch self {
    case .streak(let days): "That's a \(Self.spelled(days))-day streak."
    case .dailyGoal(let pages): "That's your \(Self.spelled(pages)) pages for today."
    }
  }

  private static func spelled(_ number: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = Locale(identifier: "en")
    return formatter.string(from: NSNumber(value: number)) ?? String(number)
  }
}

struct ReadingProgress: Codable, Equatable, Sendable {
  static let dailyGoal = 3
  static let streakMilestones: Set<Int> = [3, 7, 14, 30, 50, 100, 365]

  private(set) var streak = 0
  private(set) var bestStreak = 0
  private(set) var totalPages = 0
  private(set) var lastDay: ReadingDay?
  private(set) var pagesOnLastDay = 0

  init() {}

  /// For the screenshot launch flag only.
  init(streak: Int, pagesToday: Int, today: ReadingDay) {
    self.streak = streak
    bestStreak = streak
    totalPages = pagesToday
    lastDay = pagesToday > 0 || streak > 0 ? today : nil
    pagesOnLastDay = pagesToday
  }

  /// The streak as it stands on `today`: alive if the last page was today or yesterday. A last
  /// page dated in the future (the clock moved back) keeps it, rather than punish a clock change.
  func currentStreak(on today: ReadingDay) -> Int {
    guard let lastDay else { return 0 }
    return lastDay.days(until: today) <= 1 ? streak : 0
  }

  func pagesRead(on today: ReadingDay) -> Int {
    lastDay == today ? pagesOnLastDay : 0
  }

  /// 0 to 1, towards today's goal. Stays full once reached.
  func goalFraction(on today: ReadingDay) -> Double {
    min(1, Double(pagesRead(on: today)) / Double(Self.dailyGoal))
  }

  /// A page was read to its end on `today`. Returns the milestone to speak, if this reached one.
  @discardableResult
  mutating func recordPage(on today: ReadingDay) -> ReadingMilestone? {
    totalPages += 1

    let gap = lastDay?.days(until: today)
    let firstPageToday: Bool
    switch gap {
    case nil:
      streak = 1
      pagesOnLastDay = 0
      firstPageToday = true
    case .some(0):
      firstPageToday = false
    case .some(1):
      streak += 1
      pagesOnLastDay = 0
      firstPageToday = true
    case .some(let days) where days > 1:
      streak = 1
      pagesOnLastDay = 0
      firstPageToday = true
    default:
      // The clock went backwards. Count the page on the day it says now; keep the streak as it is.
      pagesOnLastDay = 0
      firstPageToday = false
    }
    lastDay = today
    pagesOnLastDay += 1
    bestStreak = max(bestStreak, streak)

    if firstPageToday, Self.streakMilestones.contains(streak) { return .streak(streak) }
    if pagesOnLastDay == Self.dailyGoal { return .dailyGoal(Self.dailyGoal) }
    return nil
  }

  /// What the progress card shows and VoiceOver reads for it, in one sentence each.
  func summary(on today: ReadingDay) -> ReadingSummary {
    ReadingSummary(streak: currentStreak(on: today), bestStreak: bestStreak, pagesToday: pagesRead(on: today), fraction: goalFraction(on: today))
  }
}

struct ReadingSummary: Equatable, Sendable {
  let streak: Int
  let bestStreak: Int
  let pagesToday: Int
  let fraction: Double

  var goalReached: Bool { pagesToday >= ReadingProgress.dailyGoal }

  /// No zero, no "lost": with no streak running it says how one starts.
  var streakText: String {
    streak > 0 ? "\(streak)-day streak" : "Read a page to start a streak"
  }

  var countText: String {
    "\(pagesToday) of \(ReadingProgress.dailyGoal) pages today"
  }

  var pagesText: String {
    goalReached ? "\(countText). Goal reached!" : countText
  }

  /// Only once it says something the streak line doesn't.
  var bestText: String? {
    bestStreak > max(streak, 1) ? "Best: \(bestStreak) days" : nil
  }

  var spokenValue: String {
    [pagesText + ".", streakText + ".", bestText.map { $0 + "." }].compactMap { $0 }.joined(separator: " ")
  }
}

/// ReadingProgress, saved. Tests build their own with their own defaults and clock.
@MainActor
@Observable
final class ReadingProgressStore {
  static let shared = ReadingProgressStore(defaults: makeDefaults())

  private static let key = "a11y.readingProgress"

  private(set) var progress: ReadingProgress
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let calendar: Calendar

  init(defaults: UserDefaults, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.calendar = calendar
    self.now = now
    progress = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ReadingProgress.self, from: $0) } ?? ReadingProgress()
    if let seed = LaunchOptions.progressSeed {
      progress = ReadingProgress(streak: seed.streak, pagesToday: seed.pages, today: ReadingDay(now(), calendar: calendar))
    }
  }

  var today: ReadingDay { ReadingDay(now(), calendar: calendar) }

  var summary: ReadingSummary { progress.summary(on: today) }

  /// A page was read to its end. Saved at once, so a crash or a killed app doesn't lose it.
  @discardableResult
  func recordPage() -> ReadingMilestone? {
    let milestone = progress.recordPage(on: today)
    if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.key) }
    return milestone
  }

  /// Automated runs must not read or change a person's real progress, or each other's.
  private static func makeDefaults() -> UserDefaults {
    guard LaunchOptions.isAutomatedTest else { return .standard }
    let name = "hstn.readingProgress.test"
    let suite = UserDefaults(suiteName: name) ?? .standard
    suite.removePersistentDomain(forName: name)
    return suite
  }
}
