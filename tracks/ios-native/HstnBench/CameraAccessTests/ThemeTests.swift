/*
 * ThemeTests - the palette's contrast, the reading progress store and the voice indicator
 *
 * Contrast is computed, never eyeballed: every pair the screens use, in every variant. The progress
 * tests cover the cases that would otherwise only show up on a real calendar: midnight, missed days,
 * month and year ends, daylight saving, and a clock moved backwards.
 */

@testable import CameraAccess
import Foundation
import SwiftUI
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class ThemePaletteTests: XCTestCase {
  private func assertContrast(
    _ a: ThemeRGB, _ b: ThemeRGB, atLeast minimum: Double, _ what: String, in palette: ThemePalette,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let ratio = a.contrast(with: b)
    XCTAssertGreaterThanOrEqual(ratio, minimum, "\(palette.name) \(what): \(String(format: "%.2f", ratio)):1", file: file, line: line)
  }

  func testKnownRatios() {
    XCTAssertEqual(ThemeRGB(0x000000).contrast(with: ThemeRGB(0xFFFFFF)), 21, accuracy: 0.001)
    XCTAssertEqual(ThemeRGB(0xFFFFFF).contrast(with: ThemeRGB(0xFFFFFF)), 1, accuracy: 0.001)
    // White on a bright green: why the bright faces carry dark text.
    XCTAssertLessThan(ThemeRGB(0xFFFFFF).contrast(with: ThemePalette.light.green.face), 3)
  }

  func testTextMeetsItsMinimumInEveryVariant() {
    for palette in ThemePalette.all {
      let minimum = palette.textMinimum
      for background in [palette.page, palette.surface] {
        assertContrast(palette.ink, background, atLeast: minimum, "ink", in: palette)
        assertContrast(palette.inkSoft, background, atLeast: minimum, "soft ink", in: palette)
      }
      assertContrast(palette.lockedText, palette.lockedFace, atLeast: minimum, "locked text", in: palette)
      for tone in Tone.allCases {
        let colors = palette.colors(for: tone)
        assertContrast(colors.onFace, colors.face, atLeast: minimum, "text on \(tone)", in: palette)
      }
    }
  }

  func testBoundariesReachThreeToOneInEveryVariant() {
    for palette in ThemePalette.all {
      for background in [palette.page, palette.surface] {
        assertContrast(palette.stroke, background, atLeast: 3, "card outline", in: palette)
        assertContrast(palette.lockedStroke, background, atLeast: 3, "locked outline", in: palette)
        for tone in Tone.allCases where tone != .neutral {
          assertContrast(palette.colors(for: tone).lip, background, atLeast: 3, "\(tone) lip", in: palette)
        }
      }
      assertContrast(palette.fill, palette.track, atLeast: 3, "progress fill on its track", in: palette)
      assertContrast(palette.fill, palette.surface, atLeast: 3, "progress fill on its card", in: palette)
    }
  }

  func testDynamicColoursFollowDarkModeAndIncreaseContrast() {
    let cases: [(UIUserInterfaceStyle, UIAccessibilityContrast, ThemePalette)] = [
      (.light, .normal, .light), (.dark, .normal, .dark), (.light, .high, .lightHighContrast), (.dark, .high, .darkHighContrast),
    ]
    for (style, contrast, expected) in cases {
      let traits = UITraitCollection { traits in
        traits.userInterfaceStyle = style
        traits.accessibilityContrast = contrast
      }
      XCTAssertEqual(ThemePalette.variant(for: traits).name, expected.name)
      let resolved = UIColor(Theme.page).resolvedColor(with: traits)
      var red: CGFloat = 0
      resolved.getRed(&red, green: nil, blue: nil, alpha: nil)
      XCTAssertEqual(red, expected.page.red, accuracy: 0.01, expected.name)
    }
  }
}

final class ReadingProgressTests: XCTestCase {
  private let monday = ReadingDay(year: 2026, month: 11, day: 2)
  private func day(_ offset: Int, from start: ReadingDay? = nil) -> ReadingDay {
    let base = start ?? monday
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let date = utc.date(from: DateComponents(year: base.year, month: base.month, day: base.day + offset, hour: 12)) ?? Date()
    return ReadingDay(date, calendar: utc)
  }

  func testStartsEmpty() {
    let progress = ReadingProgress()
    XCTAssertEqual(progress.currentStreak(on: monday), 0)
    XCTAssertEqual(progress.pagesRead(on: monday), 0)
    XCTAssertEqual(progress.goalFraction(on: monday), 0)
  }

  func testPagesOnOneDayCountOnceForTheStreak() {
    var progress = ReadingProgress()
    progress.recordPage(on: monday)
    progress.recordPage(on: monday)
    XCTAssertEqual(progress.currentStreak(on: monday), 1)
    XCTAssertEqual(progress.pagesRead(on: monday), 2)
    XCTAssertEqual(progress.totalPages, 2)
  }

  func testConsecutiveDaysExtendAndPagesResetAtMidnight() {
    var progress = ReadingProgress()
    progress.recordPage(on: monday)
    progress.recordPage(on: monday)
    XCTAssertEqual(progress.pagesRead(on: day(1)), 0, "A new day starts at zero pages")
    XCTAssertEqual(progress.currentStreak(on: day(1)), 1, "Yesterday's streak is still alive today")
    progress.recordPage(on: day(1))
    XCTAssertEqual(progress.currentStreak(on: day(1)), 2)
    XCTAssertEqual(progress.pagesRead(on: day(1)), 1)
  }

  func testMissedDayEndsTheCountButKeepsEverythingElse() {
    var progress = ReadingProgress()
    for offset in 0..<4 { progress.recordPage(on: day(offset)) }
    XCTAssertEqual(progress.currentStreak(on: day(5)), 0, "Two days on, there's no current streak")
    progress.recordPage(on: day(9))
    XCTAssertEqual(progress.currentStreak(on: day(9)), 1)
    XCTAssertEqual(progress.bestStreak, 4)
    XCTAssertEqual(progress.totalPages, 5)
  }

  func testNothingInTheCopyPunishesAMissedDay() {
    var progress = ReadingProgress()
    for offset in 0..<4 { progress.recordPage(on: day(offset)) }
    let summary = progress.summary(on: day(30))
    XCTAssertEqual(summary.streakText, "Read a page to start a streak")
    XCTAssertEqual(summary.bestText, "Best: 4 days")
    let copy = summary.spokenValue.lowercased()
    for word in ["lost", "missed", "broke", "failed", "0-day", "again"] {
      XCTAssertFalse(copy.contains(word), "Guilt copy: \(word) in \(copy)")
    }
  }

  func testMonthAndYearBoundaries() {
    var progress = ReadingProgress()
    progress.recordPage(on: ReadingDay(year: 2026, month: 12, day: 31))
    progress.recordPage(on: ReadingDay(year: 2027, month: 1, day: 1))
    XCTAssertEqual(progress.currentStreak(on: ReadingDay(year: 2027, month: 1, day: 1)), 2)
    var leap = ReadingProgress()
    leap.recordPage(on: ReadingDay(year: 2028, month: 2, day: 28))
    leap.recordPage(on: ReadingDay(year: 2028, month: 2, day: 29))
    leap.recordPage(on: ReadingDay(year: 2028, month: 3, day: 1))
    XCTAssertEqual(leap.currentStreak(on: ReadingDay(year: 2028, month: 3, day: 1)), 3)
  }

  func testDaylightSavingDayIsStillOneDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    // Clocks went back on 1 November 2026, so that day has 25 hours: more than 24 hours can pass
    // inside one day, and it still counts as one.
    let early = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 5)))
    let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 55)))
    XCTAssertGreaterThan(late.timeIntervalSince(early), 24 * 3600)
    XCTAssertEqual(ReadingDay(early, calendar: calendar), ReadingDay(late, calendar: calendar))
    let next = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 5)))
    XCTAssertEqual(ReadingDay(late, calendar: calendar).days(until: ReadingDay(next, calendar: calendar)), 1)
  }

  func testClockMovedBackLosesNothing() {
    var progress = ReadingProgress()
    for offset in 0..<3 { progress.recordPage(on: day(offset)) }
    XCTAssertEqual(progress.currentStreak(on: day(-5)), 3, "A clock moved back doesn't end the streak")
    XCTAssertNil(progress.recordPage(on: day(-5)))
    XCTAssertEqual(progress.streak, 3)
    XCTAssertEqual(progress.totalPages, 4)
  }

  func testMilestonesAreRare() {
    var progress = ReadingProgress()
    var spoken: [ReadingMilestone] = []
    for offset in 0..<8 {
      if let milestone = progress.recordPage(on: day(offset)) { spoken.append(milestone) }
    }
    XCTAssertEqual(spoken, [.streak(3), .streak(7)])
    XCTAssertEqual(ReadingMilestone.streak(3).spokenLine, "That's a three-day streak.")
  }

  func testGoalIsSpokenOnceADayAndOnlyAtTheGoal() {
    var progress = ReadingProgress()
    XCTAssertNil(progress.recordPage(on: monday))
    XCTAssertNil(progress.recordPage(on: monday))
    XCTAssertEqual(progress.recordPage(on: monday), .dailyGoal(ReadingProgress.dailyGoal))
    XCTAssertNil(progress.recordPage(on: monday), "Past the goal: nothing more")
    XCTAssertEqual(progress.goalFraction(on: monday), 1, "Stays full past the goal")
    XCTAssertEqual(ReadingMilestone.dailyGoal(3).spokenLine, "That's your three pages for today.")
  }

  func testAtMostOneMilestonePerPage() {
    var progress = ReadingProgress()
    progress.recordPage(on: day(0))
    progress.recordPage(on: day(1))
    XCTAssertEqual(progress.recordPage(on: day(2)), .streak(3), "The third day's first page")
    XCTAssertNil(progress.recordPage(on: day(2)))
    XCTAssertEqual(progress.recordPage(on: day(2)), .dailyGoal(3))
  }

  func testSummaryWords() {
    var progress = ReadingProgress()
    XCTAssertEqual(progress.summary(on: monday).spokenValue, "0 of 3 pages today. Read a page to start a streak.")
    progress.recordPage(on: monday)
    XCTAssertEqual(progress.summary(on: monday).spokenValue, "1 of 3 pages today. 1-day streak.")
    progress.recordPage(on: monday)
    progress.recordPage(on: monday)
    XCTAssertEqual(progress.summary(on: monday).pagesText, "3 of 3 pages today. Goal reached!")
  }
}

@MainActor
final class ReadingProgressStoreTests: XCTestCase {
  private var suiteName = ""
  private var defaults = UserDefaults()

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ReadingProgressStoreTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testPersistsAcrossLaunches() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ReadingProgressStore(defaults: defaults, now: { now })
    store.recordPage()
    store.recordPage()
    let reopened = ReadingProgressStore(defaults: defaults, now: { now })
    XCTAssertEqual(reopened.summary.pagesToday, 2)
    XCTAssertEqual(reopened.summary.streak, 1)
  }

  func testFollowsTheClock() {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = ReadingProgressStore(defaults: defaults, now: { now })
    store.recordPage()
    now = now.addingTimeInterval(24 * 3600)
    XCTAssertEqual(store.summary.pagesToday, 0)
    XCTAssertEqual(store.summary.streak, 1)
    now = now.addingTimeInterval(24 * 3600)
    XCTAssertEqual(store.summary.streak, 0)
  }

  func testCorruptSaveStartsFresh() {
    defaults.set(Data([1, 2, 3]), forKey: "a11y.readingProgress")
    XCTAssertEqual(ReadingProgressStore(defaults: defaults).summary.pagesToday, 0)
  }
}

@MainActor
final class VoiceIndicatorModelTests: XCTestCase {
  private func model(
    _ status: VoiceControl.Status, reason: String? = nil, listener: VoiceListenerKind? = .phone,
    mic: VoicePermission = .granted, speech: VoicePermission = .granted, speaking: Bool = false, heard: VoiceCommand? = nil,
    inSetup: Bool = false, canPrompt: Bool = true
  ) -> VoiceIndicatorModel {
    VoiceIndicatorModel.make(
      status: status, reason: reason, listener: listener, micPermission: mic, speechPermission: speech, isSpeaking: speaking,
      heard: heard, inSetup: inSetup, canPrompt: canPrompt)
  }

  func testListeningSaysSoInWords() {
    XCTAssertEqual(model(.listening).title, "Listening")
    XCTAssertEqual(model(.listening).mood, .listening)
    XCTAssertEqual(model(.listening, listener: .glasses).title, "Listening through your glasses")
    XCTAssertNil(model(.listening).fix)
  }

  func testWhileTheAppTalksItExplainsTheWakeWord() {
    XCTAssertTrue(model(.listening, speaking: true).detail?.contains("reader") == true)
    XCTAssertTrue(model(.listening, speaking: false).detail?.contains("help") == true)
  }

  func testAHeardCommandIsShownByItsPhrase() {
    XCTAssertTrue(model(.listening, heard: .read).title.contains("read"))
    XCTAssertEqual(model(.listening, heard: .read).mood, .happy)
  }

  func testUnavailableShowsTheReasonAndAFix() {
    let denied = model(.unavailable, reason: SpokenMessage.voicePermissionDenied, mic: .denied)
    XCTAssertEqual(denied.detail, SpokenMessage.voicePermissionDenied)
    XCTAssertEqual(denied.fix, .openSettings)
    XCTAssertEqual(denied.mood, .confused)
    XCTAssertFalse(denied.isCompact, "A long reason scrolls with the page instead of pinning")
    let noDictation = model(.unavailable, reason: SpokenMessage.voiceNoOnDeviceRecognition)
    XCTAssertEqual(noDictation.fix, .openSettings)
    let notAsked = model(.unavailable, reason: "Waiting", mic: .notDetermined)
    XCTAssertEqual(notAsked.fix, .askPermission)
  }

  func testOffOffersTurningItBackOn() {
    XCTAssertEqual(model(.off).fix, .turnOn)
  }

  func testSetupAndTestsDontOfferAFixTheStepAlreadyGives() {
    XCTAssertNil(model(.unavailable, reason: "Waiting", mic: .notDetermined, inSetup: true).fix)
    XCTAssertNil(model(.off, inSetup: true).fix)
    XCTAssertNil(model(.unavailable, reason: "Waiting", mic: .notDetermined, canPrompt: false).fix)
  }

  func testPausedGivesTheReason() {
    let paused = model(.paused, reason: "A recording is running.")
    XCTAssertEqual(paused.title, "Listening paused")
    XCTAssertEqual(paused.spokenLabel, "Listening paused. A recording is running.")
  }

  func testSetupStepFractions() {
    XCTAssertEqual(OnboardingStep.welcome.progressFraction, 0)
    XCTAssertEqual(OnboardingStep.connect.progressFraction, 1)
  }
}
