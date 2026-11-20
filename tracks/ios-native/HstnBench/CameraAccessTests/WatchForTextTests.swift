/*
 * WatchForTextTests - Watch for text's pure parts, ported from Android's JVM tests
 *
 * WatchMatchingTest: target parsing and number words; numbers exact (42 is not 421, 142, 4.2 or
 * 42A, but is "No. 42"), words loose, codes, several words side by side, the position of a match
 * inside a wide line, the tallest sighting winning, near misses, tokenising decimals.
 * WatchTrackerTest: one frame never enough, two of four announce once, appear / gone / reappear,
 * gone timing, a brief dropout, ageing out, near-miss agreement and throttling, "where is it",
 * sides and the camera offset, close / far, the view-issue watcher, the pace watcher.
 * WatchGrammarTest: stop and carry on, what and where, new targets, ticks, other commands left
 * alone, and the openers that carry the free target ("find Boots", "tell me when you see 42").
 * Plus the iOS additions: the phone's centred camera, the covered / dark check and the wording.
 */

import CoreGraphics
@testable import CameraAccess
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class WatchForTextTests: XCTestCase {
  private func t(_ raw: String) -> WatchTarget { WatchTarget.parse(raw)! }

  private func found(_ target: String, _ line: String) -> Bool {
    WatchTextMatcher.findInLine(t(target), line) != nil
  }

  // MARK: Target parsing

  func testTargetsAreParsedIntoNumbersCodesAndWords() {
    XCTAssertEqual(t("42").tokens, [WatchTargetToken(text: "42", kind: .number)])
    XCTAssertEqual(t("forty two").display, "42")
    XCTAssertEqual(t("four two").display, "42")
    XCTAssertEqual(t("one oh one").display, "101")
    XCTAssertEqual(t("one hundred and one").display, "101")
    XCTAssertEqual(t("the 73 bus").display, "73")
    XCTAssertEqual(t("bus number 73").display, "73")
    XCTAssertEqual(t("number 42").display, "42")
    XCTAssertEqual(t("platform three").display, "platform 3")
    XCTAssertEqual(t("gate twelve").display, "gate 12")
    XCTAssertEqual(t("room 12 b").display, "room 12B")
    XCTAssertEqual(t("12b").tokens.first?.kind, .code)
    XCTAssertEqual(t("one way").display, "one way")
    XCTAssertEqual(t("Boots").display, "boots")
    XCTAssertEqual(t("the exit").display, "exit")
    XCTAssertEqual(t("Sainsbury's").display, "sainsburys")
    XCTAssertTrue(t("42").isSingleNumber)
    XCTAssertFalse(t("platform 3").isSingleNumber)
    XCTAssertNil(WatchTarget.parse("the"))
    XCTAssertNil(WatchTarget.parse("  "))
  }

  func testNumberWords() {
    XCTAssertEqual(WatchNumberWords.parse(["seven"]), "7")
    XCTAssertEqual(WatchNumberWords.parse(["fifteen"]), "15")
    XCTAssertEqual(WatchNumberWords.parse(["ninety"]), "90")
    XCTAssertEqual(WatchNumberWords.parse(["two", "hundred", "fifty"]), "250")
    XCTAssertNil(WatchNumberWords.parse(["forty", "way"]))
    XCTAssertNil(WatchNumberWords.parse(["one", "way"]))
  }

  // MARK: Numbers are exact

  func testFortyTwoMatchesOnlyFortyTwo() {
    for line in ["42", "42 Victoria Station", "via Town Centre 42 Victoria", "No. 42", "No.42", "Bus 42,", "(42)", "No42"] {
      XCTAssertTrue(found("42", line), line)
    }
    XCTAssertFalse(found("42", "4O"), "O read for a zero: that's 40")
    XCTAssertTrue(found("40", "4O"))
    XCTAssertTrue(found("11", "1l"))
    for line in ["421", "142", "4.2", "42.5", "4,2", "42A", "Route 421 Airport", "4 2", "24", "10:42"] {
      XCTAssertFalse(found("42", line), line)
    }
  }

  func testLeadingZerosDontMatter() {
    XCTAssertTrue(found("4", "Gate 04"))
    XCTAssertTrue(found("gate 4", "GATE 04"))
  }

  func testCodesAreExactIgnoringCaseAndSlips() {
    XCTAssertTrue(found("12b", "Room 12B"))
    XCTAssertTrue(found("12b", "ROOM 12 B"))
    XCTAssertTrue(found("12b", "I2B"))
    XCTAssertFalse(found("12b", "12C"))
    XCTAssertFalse(found("12b", "112B"))
    XCTAssertFalse(found("12b", "12"))
  }

  // MARK: Words are loose

  func testWordsMatchLoosely() {
    XCTAssertTrue(found("exit", "EXIT"))
    XCTAssertTrue(found("exit", "Exit."))
    XCTAssertTrue(found("exit", "<- exit ->"))
    XCTAssertTrue(found("boots", "Boots"))
    XCTAssertTrue(found("boots", "BOOTS PHARMACY"))
    XCTAssertTrue(found("boots", "Bots"), "a missing letter")
    XCTAssertTrue(found("boots", "B00TS"), "zeros read for O")
    XCTAssertTrue(found("boots", "BO OTS"), "split by OCR")
    XCTAssertTrue(found("sainsburys", "SAINSBURY'S"))
    XCTAssertTrue(found("sainsburys", "SAINSBURYS"))
    XCTAssertTrue(found("pharmacy", "PHARMCY"), "8 letters: 2 edits allowed")
    XCTAssertTrue(found("toilets", "Toilets"))
    XCTAssertTrue(found("toilets", "Tollets"))

    XCTAssertFalse(found("boots", "Boston"))
    XCTAssertFalse(found("boots", "Bootstrap"))
    XCTAssertFalse(found("exit", "exiting"), "3 letters more")
    XCTAssertFalse(found("bus", "bun"), "3 letters: exact only")
    XCTAssertFalse(found("boots", ""))
  }

  // MARK: Several words

  func testMultiWordTargetsMatchSideBySide() {
    XCTAssertTrue(found("platform 3", "Platform 3"))
    XCTAssertTrue(found("platform 3", "To Platform 3 and 4"))
    XCTAssertTrue(found("platform 3", "PLATFORM3"))
    XCTAssertTrue(found("platform 3", "PLATF0RM 3"))
    XCTAssertTrue(found("right exit", "Right exit"))
    XCTAssertTrue(found("way out", "WAY OUT ->"))

    for line in ["Platform 13", "Platform 31", "Platform 4", "3 Platform", "Platform", "PLATFORM31"] {
      XCTAssertFalse(found("platform 3", line), line)
    }
    XCTAssertFalse(found("way out", "way in out"))
  }

  // MARK: Finding it in a frame

  private func page(_ lines: WatchLine...) -> WatchPage {
    WatchPage(lines: lines, imageSize: CGSize(width: 1000, height: 2000))
  }

  private func line(_ text: String, _ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat) -> WatchLine {
    WatchLine(text: text, box: CGRect(x: left, y: top, width: right - left, height: bottom - top))
  }

  func testPositionIsTheMatchedPartOfTheLine() throws {
    // "42" at the start of a wide line: placed left of the line's centre.
    let spot = try XCTUnwrap(WatchTextMatcher.find(t("42"), in: page(line("42 VICTORIA", 100, 100, 900, 200))).hit)
    XCTAssertLessThan(spot.x, 0.25)
    XCTAssertEqual(spot.text, "42")
    XCTAssertEqual(spot.heightFraction, 0.05, accuracy: 0.001)

    let right = try XCTUnwrap(WatchTextMatcher.find(t("42"), in: page(line("42", 800, 500, 900, 600))).hit)
    XCTAssertEqual(right.x, 0.85, accuracy: 0.01)
    XCTAssertEqual(WatchPosition.side(x: right.x), .right)
  }

  func testTheTallestSightingWins() {
    let match = WatchTextMatcher.find(t("exit"), in: page(line("exit", 100, 100, 200, 130), line("EXIT", 600, 400, 900, 600)))
    XCTAssertEqual(match.hit?.heightFraction ?? 0, 0.1, accuracy: 0.001)
  }

  func testNearMissesAreSwapsAndOneDigitOffForLongNumbers() {
    XCTAssertTrue(WatchTextMatcher.isNearMiss(target: "42", seen: "24"))
    XCTAssertFalse(WatchTextMatcher.isNearMiss(target: "42", seen: "43"), "2 digits: swaps only")
    XCTAssertFalse(WatchTextMatcher.isNearMiss(target: "42", seen: "421"))
    XCTAssertFalse(WatchTextMatcher.isNearMiss(target: "42", seen: "42"))
    XCTAssertTrue(WatchTextMatcher.isNearMiss(target: "123", seen: "132"))
    XCTAssertTrue(WatchTextMatcher.isNearMiss(target: "123", seen: "124"))
    XCTAssertFalse(WatchTextMatcher.isNearMiss(target: "123", seen: "456"))

    let near = WatchTextMatcher.find(t("42"), in: page(line("24 Town Centre", 0, 0, 500, 100)))
    XCTAssertNil(near.hit)
    XCTAssertEqual(near.nearMiss, "24")
    // A hit beats a near miss on another line.
    let both = WatchTextMatcher.find(t("42"), in: page(line("24", 0, 0, 100, 100), line("42", 0, 300, 100, 400)))
    XCTAssertNotNil(both.hit)
    XCTAssertNil(both.nearMiss)
    // Words have no near misses.
    XCTAssertNil(WatchTextMatcher.find(t("toilets"), in: page(line("tablets", 0, 0, 100, 100))).nearMiss)
    XCTAssertEqual(WatchTextMatcher.find(t("42"), in: page(line("421", 0, 0, 100, 100))), .none)
  }

  func testTokensSeparateDecimalsFromNumbers() {
    let tokens = WatchTextMatcher.tokens("No. 42 at 4.2 km, 10:30")
    XCTAssertEqual(tokens.map(\.text), ["no", "42", "at", "4.2", "km", "10:30"])
    XCTAssertEqual(tokens.map(\.kind), [.word, .number, .word, .decimal, .word, .decimal])
  }

  // MARK: The sighting tracker

  private let seen = WatchFrameMatch(hit: WatchSpot(text: "42", x: 0.85, heightFraction: 0.05), nearMiss: nil)
  private let nothing = WatchFrameMatch.none

  private func near(_ text: String) -> WatchFrameMatch { WatchFrameMatch(hit: nil, nearMiss: text) }

  /// Feeds `frames` `gap` ms apart (2 fps by default) from `start`; every event with its time.
  private func run(
    _ tracker: inout WatchSightingTracker, _ frames: [WatchFrameMatch], start: Int64 = 0, gap: Int64 = 500
  ) -> [(Int64, WatchEvent)] {
    var out: [(Int64, WatchEvent)] = []
    for (index, frame) in frames.enumerated() {
      let at = start + Int64(index) * gap
      out += tracker.onFrame(nowMs: at, match: frame).map { (at, $0) }
    }
    return out
  }

  func testOneFrameIsNeverEnough() {
    var tracker = WatchSightingTracker()
    XCTAssertTrue(run(&tracker, [nothing, seen, nothing, nothing, nothing, seen, nothing, nothing, nothing, nothing]).isEmpty)
  }

  func testTwoOfTheLastFourAnnounceOnce() {
    var tracker = WatchSightingTracker()
    let events = run(&tracker, [nothing, seen, nothing, seen, seen, seen, seen, seen])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.0, 1500)
    XCTAssertEqual(events.first?.1, .appeared(seen.hit!))
    XCTAssertTrue(tracker.inView)
  }

  func testAppearGoneReappear() {
    var tracker = WatchSightingTracker(goneAfterMs: 4_000)
    let events = run(&tracker, [seen, seen] + Array(repeating: nothing, count: 12) + [seen, seen, seen]).map(\.1)
    XCTAssertEqual(events, [.appeared(seen.hit!), .gone, .appeared(seen.hit!)])
  }

  func testGoneComesAfterTheDelayNotOnTheFirstMissedFrame() {
    var tracker = WatchSightingTracker(goneAfterMs: 4_000)
    let events = run(&tracker, [seen, seen] + Array(repeating: nothing, count: 12))
    let gone = events.filter { $0.1 == .gone }
    XCTAssertEqual(gone.count, 1)
    // Last seen at 500 ms; gone at the first frame 4 s later.
    XCTAssertEqual(gone.first?.0, 4_500)
  }

  func testABriefDropoutDoesntSayGone() {
    var tracker = WatchSightingTracker(goneAfterMs: 4_000)
    XCTAssertEqual(run(&tracker, [seen, seen, nothing, nothing, nothing, seen, nothing, nothing, seen, seen]).count, 1)
  }

  func testAfterGoneASingleFrameDoesntCountAsBack() {
    var tracker = WatchSightingTracker(goneAfterMs: 2_000)
    // Slow OCR: 2 s between frames, so old hits would still be in the window.
    let events = run(&tracker, [seen, seen, nothing, nothing, seen, nothing], gap: 2_000).map(\.1)
    XCTAssertEqual(events, [.appeared(seen.hit!), .gone])
  }

  func testOldFramesAgeOut() {
    var tracker = WatchSightingTracker(maxAgeMs: 8_000)
    // Two hits 10 s apart (very slow OCR, or a gap) are not two of the last four.
    XCTAssertTrue(run(&tracker, [seen, seen], gap: 10_000).isEmpty)
  }

  func testNearMissesAgreeTwiceAndAreThrottled() {
    var tracker = WatchSightingTracker(nearMissGapMs: 20_000, sameNearMissGapMs: 60_000)
    XCTAssertTrue(run(&tracker, [near("24"), nothing, nothing, nothing]).isEmpty, "once: not said")
    let first = run(&tracker, Array(repeating: near("24"), count: 30), start: 10_000)
    XCTAssertEqual(first.map(\.1), [.nearMiss("24")], "twice: said once, then quiet for 20 s")
    let other = run(&tracker, Array(repeating: near("43"), count: 50), start: 25_000)
    XCTAssertEqual(other.count, 1)
    XCTAssertGreaterThanOrEqual(other[0].0, 10_500 + 20_000)
    XCTAssertTrue(run(&tracker, Array(repeating: near("24"), count: 20), start: 55_000).isEmpty, "the same within 60 s")
  }

  func testNoNearMissWhileTheTargetIsInView() {
    var tracker = WatchSightingTracker()
    _ = run(&tracker, [seen, seen])
    XCTAssertTrue(run(&tracker, [near("24"), near("24"), near("24")], start: 1_000).isEmpty)
  }

  func testWhereIsIt() {
    var tracker = WatchSightingTracker(goneAfterMs: 4_000)
    XCTAssertEqual(tracker.whereIs(nowMs: 0), .notSeen)
    _ = tracker.onFrame(nowMs: 0, match: seen)
    XCTAssertEqual(tracker.whereIs(nowMs: 100), .notSeen, "a single unconfirmed frame isn't a sighting")
    _ = tracker.onFrame(nowMs: 500, match: seen)
    XCTAssertEqual(tracker.whereIs(nowMs: 600), .inView(seen.hit!))
    _ = run(&tracker, Array(repeating: nothing, count: 10), start: 1_000)
    XCTAssertEqual(tracker.whereIs(nowMs: 10_500), .lastSeen(seen.hit!, agoMs: 10_000))
    tracker.reset()
    XCTAssertEqual(tracker.whereIs(nowMs: 11_000), .notSeen)
  }

  func testSidesAllowForTheGlassesCameraOnTheLeft() {
    XCTAssertEqual(WatchPosition.side(x: 0.1), .left)
    XCTAssertEqual(WatchPosition.side(x: 0.35), .left)
    XCTAssertEqual(WatchPosition.side(x: 0.5), .ahead)
    // The picture's centre-right is still straight ahead of the wearer.
    XCTAssertEqual(WatchPosition.side(x: 0.66), .ahead)
    XCTAssertEqual(WatchPosition.side(x: 0.72), .right)
    XCTAssertEqual(WatchPosition.side(x: 0.95), .right)
  }

  func testThePhoneCameraIsCentred() {
    let centre = WatchPosition.centreX(for: .phone)
    XCTAssertEqual(WatchPosition.side(x: 0.5, centre: centre), .ahead)
    XCTAssertEqual(WatchPosition.side(x: 0.68, centre: centre), .right)
    XCTAssertEqual(WatchPosition.side(x: 0.68, centre: WatchPosition.centreX(for: .glasses)), .ahead)
    XCTAssertEqual(WatchPosition.side(x: 0.32, centre: centre), .left)
  }

  func testCloseAndFarFromTextHeight() {
    XCTAssertEqual(WatchPosition.nearness(heightFraction: 0.2), .close)
    XCTAssertEqual(WatchPosition.nearness(heightFraction: 0.01), .far)
    XCTAssertNil(WatchPosition.nearness(heightFraction: 0.05))
  }

  func testViewProblemsAreSaidOnceThenRepeatedThenCleared() {
    var watch = WatchViewIssueWatch(confirmFrames: 2, repeatMs: 45_000)
    XCTAssertNil(watch.onFrame(nowMs: 0, issue: .covered))
    XCTAssertEqual(watch.onFrame(nowMs: 500, issue: .covered), .started(.covered))
    XCTAssertNil(watch.onFrame(nowMs: 1_000, issue: .covered))
    XCTAssertNil(watch.onFrame(nowMs: 1_500, issue: .tooDark))
    XCTAssertEqual(watch.onFrame(nowMs: 46_000, issue: .tooDark), .stillThere(.tooDark))
    XCTAssertNil(watch.onFrame(nowMs: 46_500, issue: nil))
    XCTAssertEqual(watch.onFrame(nowMs: 47_000, issue: nil), .cleared)
    XCTAssertNil(watch.onFrame(nowMs: 47_500, issue: nil))
    // A single dark frame (a passing shadow) says nothing.
    XCTAssertNil(watch.onFrame(nowMs: 48_000, issue: .tooDark))
    XCTAssertNil(watch.onFrame(nowMs: 48_500, issue: nil))
  }

  func testPaceWarnsOnceWhenOcrCantKeepUp() {
    var pace = WatchPaceWatch(slowMs: 3_000, samples: 4)
    var now: Int64 = 0
    for _ in 0..<10 {
      now += 500
      XCTAssertNil(pace.onFrameDone(nowMs: now))
    }
    var warnings: [Int] = []
    for _ in 0..<10 {
      now += 4_000
      if let seconds = pace.onFrameDone(nowMs: now) { warnings.append(seconds) }
    }
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue((3...4).contains(warnings[0]))
    // Recovers, then slows again: warned again.
    for _ in 0..<10 {
      now += 500
      _ = pace.onFrameDone(nowMs: now)
    }
    var again = 0
    for _ in 0..<10 {
      now += 5_000
      if pace.onFrameDone(nowMs: now) != nil { again += 1 }
    }
    XCTAssertEqual(again, 1)
  }

  func testCoveredAndDarkFromTheBrightnessGrid() {
    let count = WatchRecognizer.gridWidth * WatchRecognizer.gridHeight
    XCTAssertEqual(WatchViewCheck.issue(luma: [UInt8](repeating: 5, count: count)), .covered)
    XCTAssertEqual(WatchViewCheck.issue(luma: [UInt8](repeating: 60, count: count)), .tooDark)
    // A dim street with a lit sign: the bright part is enough.
    var street = [UInt8](repeating: 40, count: count)
    for index in 0..<(count / 10) { street[index] = 220 }
    XCTAssertNil(WatchViewCheck.issue(luma: street))
    // A flat wall isn't a problem here (a street isn't a page).
    XCTAssertNil(WatchViewCheck.issue(luma: [UInt8](repeating: 180, count: count)))
    // A frame that couldn't be drawn isn't "covered".
    XCTAssertNil(WatchViewCheck.issue(luma: []))
  }

  // MARK: Wording

  func testSightingWordingIsOrientationOnly() {
    let spot = WatchSpot(text: "42", x: 0.85, heightFraction: 0.05)
    XCTAssertEqual(WatchWording.seen("42", WatchWording.place(spot, camera: .phone)), "42, on your right.")
    XCTAssertEqual(WatchWording.place(WatchSpot(text: "exit", x: 0.5, heightFraction: 0.2), camera: .phone), "ahead, close")
    XCTAssertEqual(WatchWording.place(WatchSpot(text: "exit", x: 0.1, heightFraction: 0.01), camera: .glasses), "on your left, far off")
    XCTAssertEqual(WatchWording.gone("42"), "42, gone.")
    XCTAssertEqual(WatchWording.nearMiss(seen: "24", target: "42"), "I see 24, not 42.")
    let everything = [
      WatchWording.startFirst("42"), WatchWording.help(camera: .phone), WatchWording.help(camera: .glasses),
      WatchWording.covered(camera: .phone), WatchWording.dark, WatchWording.noFrames(camera: .phone),
    ].joined(separator: " ").lowercased()
    for unsafe in ["safe", "cross", "danger", "clear to"] {
      XCTAssertFalse(everything.contains(unsafe), unsafe)
    }
    XCTAssertTrue(WatchWording.startFirst("42").contains("cane or dog"))
    XCTAssertTrue(WatchWording.startFirst("42").contains("silence doesn't mean"))
    XCTAssertTrue(WatchWording.help(camera: .phone).contains("silence doesn't mean"))
  }

  // MARK: Grammar

  private func p(_ said: String) -> WatchCommand? { WatchGrammar.parse(said) }

  func testStopAndCarryOn() {
    for said in [
      "stop watching", "Stop looking for it", "cancel", "never mind", "forget it", "pause watching", "don't look any more",
      "stop watching for 42",
    ] {
      XCTAssertEqual(p(said), .stop, said)
    }
    for said in ["carry on watching", "keep watching", "start watching again", "watch again", "resume watching"] {
      XCTAssertEqual(p(said), .resume, said)
    }
  }

  func testWhatAndWhere() {
    for said in ["what are you watching for", "What am I looking for?", "what's the target", "what did I ask you to look for"] {
      XCTAssertEqual(p(said), .whatTarget, said)
    }
    for said in [
      "where is it", "where", "where's 42", "Where was it?", "which side", "which way is it", "where did you see it",
      "where's platform 3",
    ] {
      XCTAssertEqual(p(said), .whereIsIt, said)
    }
    XCTAssertNil(p("where did he go"))
    XCTAssertNil(p("where am i"))
    XCTAssertNil(p("where are we"))
  }

  func testNewTargets() {
    XCTAssertEqual(p("watch for something else: 73"), .newTarget("73"))
    XCTAssertEqual(p("watch for something else, 73"), .newTarget("73"))
    XCTAssertEqual(p("watch for something else"), .newTarget(nil))
    XCTAssertEqual(p("something else, platform 4"), .newTarget("platform 4"))
    XCTAssertEqual(p("change it to exit"), .newTarget("exit"))
    XCTAssertEqual(p("now watch for 73 please"), .newTarget("73"))
    XCTAssertEqual(p("watch for 73"), .newTarget("73"))
    XCTAssertEqual(p("look out for the right exit"), .newTarget("right exit"))
    XCTAssertEqual(p("find Boots"), .newTarget("boots"))
  }

  func testTicks() {
    XCTAssertEqual(p("ticks off"), .ticks(0))
    XCTAssertEqual(p("turn off the ticking"), .ticks(0))
    XCTAssertEqual(p("stop ticking"), .ticks(0))
    XCTAssertEqual(p("no clicks"), .ticks(0))
    XCTAssertEqual(p("ticks on"), .ticks(nil))
    XCTAssertEqual(p("turn the ticks back on"), .ticks(nil))
    XCTAssertEqual(p("tick every 20 seconds"), .ticks(20))
    XCTAssertEqual(p("tick every thirty seconds"), .ticks(30))
    XCTAssertEqual(p("ticks every five seconds"), .ticks(5))
  }

  func testOtherCommandsAreLeftAlone() {
    for said in [
      "stop", "close", "help", "say that again", "carry on", "battery", "faster", "read my mail", "open the book reader",
      "scan this", "is the light on", "what colour is this", "what does exit mean", "the bus is late again", "",
    ] {
      XCTAssertNil(p(said), said)
    }
  }

  func testOpenersCarryTheFreeTarget() {
    XCTAssertEqual(WatchGrammar.opens("find Boots"), WatchOpenRequest(target: "boots"))
    XCTAssertEqual(WatchGrammar.opens("find me the exit"), WatchOpenRequest(target: "exit"))
    XCTAssertEqual(WatchGrammar.opens("watch for 42"), WatchOpenRequest(target: "42"))
    XCTAssertEqual(WatchGrammar.opens("Tell me when you see 42."), WatchOpenRequest(target: "42"))
    XCTAssertEqual(WatchGrammar.opens("please watch for platform 4"), WatchOpenRequest(target: "platform 4"))
    XCTAssertEqual(WatchGrammar.opens("reader, look out for the number 73 bus"), WatchOpenRequest(target: "number 73 bus"))
    XCTAssertEqual(WatchGrammar.opens("watch for text"), WatchOpenRequest(target: nil))
    XCTAssertEqual(WatchGrammar.opens("open watch for text"), WatchOpenRequest(target: nil))
    XCTAssertEqual(WatchGrammar.opens("watch for something"), WatchOpenRequest(target: nil))
    XCTAssertNil(WatchGrammar.opens("find out what happened"))
    XCTAssertNil(WatchGrammar.opens("I watched for ages"))
    XCTAssertNil(WatchGrammar.opens("read this"))
    // What the opener carries parses into the target that's said back.
    XCTAssertEqual(WatchTarget.parse(WatchGrammar.opens("reader, look out for the number 73 bus")!.target!)?.display, "73")
  }

  func testHeardTextNormalisesLikeAndroid() {
    XCTAssertEqual(HeardText.light("Watch for 4.2, please!"), "watch for 4.2 please")
    XCTAssertEqual(HeardText.normalize("Um, could you watch for exit now please"), "watch for exit")
    XCTAssertEqual(HeardText.normalize("Glasses, where is it?"), "where is it")
    XCTAssertEqual(HeardText.levenshtein("kitten", "sitting"), 3)
  }
}
