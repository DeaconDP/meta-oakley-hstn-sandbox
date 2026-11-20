/*
 * VoiceCoachTests - spoken tips: when they come, what they say, and that every word they offer is a
 * command the parser takes on that screen
 */

@testable import CameraAccess
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class VoiceCoachScheduleTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000)

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  func testTipsComeAtGrowingGapsThenStop() {
    var schedule = VoiceCoachSchedule(timesHeard: 0, start: start)
    XCTAssertNil(schedule.due(at: at(7)))
    XCTAssertEqual(schedule.due(at: at(8)), 0)
    XCTAssertNil(schedule.due(at: at(37)))
    XCTAssertEqual(schedule.due(at: at(38)), 1)
    XCTAssertEqual(schedule.due(at: at(98)), 2)
    XCTAssertEqual(schedule.due(at: at(218)), 3)
    XCTAssertTrue(schedule.isLast(3))
    XCTAssertNil(schedule.due(at: at(10_000)))
  }

  func testBusyDelaysWithoutUsingATip() {
    var schedule = VoiceCoachSchedule(timesHeard: 0, start: start)
    schedule.busy(at: at(6))
    XCTAssertNil(schedule.due(at: at(13)))
    XCTAssertEqual(schedule.due(at: at(14)), 0)
  }

  func testActingStartsOver() {
    var schedule = VoiceCoachSchedule(timesHeard: 0, start: start)
    XCTAssertEqual(schedule.due(at: at(8)), 0)
    XCTAssertEqual(schedule.due(at: at(38)), 1)
    schedule.userActed(at: at(40))
    XCTAssertEqual(schedule.due(at: at(48)), 0)
  }

  func testALearnedTipStartsLater() {
    var schedule = VoiceCoachSchedule(timesHeard: VoiceCoachSchedule.learnedAfter, start: start)
    XCTAssertNil(schedule.due(at: at(8)))
    XCTAssertEqual(schedule.due(at: at(30)), 0)
    XCTAssertFalse(schedule.isLast(1))
    XCTAssertTrue(schedule.isLast(2))
  }
}

final class VoiceCoachLinesTests: XCTestCase {
  private func line(
    _ situation: CoachSituation, tip: Int = 0, isLast: Bool = false, wakeWord: Bool = false, verbosity: Verbosity = .normal
  ) -> String {
    VoiceCoachLines.line(for: situation, tip: tip, isLast: isLast, wakeWord: wakeWord, verbosity: verbosity)
  }

  func testMainScreenTipsLeadWithReading() {
    XCTAssertTrue(line(.ready).contains("say read"))
    XCTAssertFalse(line(.ready).contains("camera"), "No camera steps to take by hand")
    XCTAssertEqual(line(.ready, verbosity: .short), "Hold up some text and say read.")
  }

  func testWakeWordGoesOnEveryCommand() {
    let text = line(.welcome, wakeWord: true)
    XCTAssertEqual(
      text,
      "To read with your iPhone's camera, say reader, phone. To connect Meta glasses, say reader, connect, "
        + "and I'll open the Meta AI app so you can approve it.")
    XCTAssertTrue(line(.notLinked, isLast: true, wakeWord: true).hasSuffix("Say reader, help whenever you need me."))
  }

  func testLaterTipsAndTheLastOne() {
    XCTAssertTrue(line(.notLinked, tip: 1).hasPrefix("I'm still listening. "))
    XCTAssertFalse(line(.notLinked, tip: 1, verbosity: .short).contains("still listening"))
    XCTAssertTrue(line(.notLinked, tip: 3, isLast: true).hasSuffix("I'll stop reminding you now. Say help whenever you need me."))
  }

  /// Every "say X" in a tip must be something the parser accepts on that screen, or the tip lies.
  func testEveryOfferedCommandWorksWhereItIsOffered() {
    let cases: [(CoachSituation, VoiceContext)] = [
      (.welcome, VoiceContext(screen: .welcome)),
      (.welcomeRetry, VoiceContext(screen: .welcome)),
      (.welcomeConnected, VoiceContext(screen: .welcome)),
      (.notLinked, VoiceContext(screen: .home)),
      (.noGlasses, VoiceContext(screen: .camera)),
      (.glassesNotReady, VoiceContext(screen: .camera)),
      (.ready, VoiceContext(screen: .camera)),
      (.afterReading, VoiceContext(screen: .camera, hasReadSentences: true)),
      (.paused, VoiceContext(screen: .camera)),
      (.readyWithPhone, VoiceContext(screen: .camera)),
      (.phoneCameraBlocked, VoiceContext(screen: .camera)),
    ]
    for (situation, context) in cases {
      for verbosity in Verbosity.allCases {
        for isLast in [false, true] {
          let text = line(situation, isLast: isLast, verbosity: verbosity)
          let offered = Self.offeredCommands(in: text)
          XCTAssertFalse(offered.isEmpty, "\(situation) offers nothing: \(text)")
          for phrase in offered {
            XCTAssertNotNil(
              VoiceCommandParser.parse(phrase, context: context).command,
              "\"\(phrase)\" from \"\(text)\" isn't a command on \(context.screen)")
          }
        }
      }
    }
  }

  /// The words after each "say ", up to the next "for", "to", "and", "whenever" or punctuation.
  private static func offeredCommands(in text: String) -> [String] {
    let stops: Set<String> = ["for", "to", "and", "whenever", "or", "moves", "says"]
    var result: [String] = []
    let words = text.lowercased().split(separator: " ").map(String.init)
    var index = 0
    while index < words.count {
      defer { index += 1 }
      guard words[index] == "say" else { continue }
      var phrase: [String] = []
      var next = index + 1
      while next < words.count {
        let word = words[next]
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        if stops.contains(bare) { break }
        phrase.append(bare)
        if word.last.map({ ",.?".contains($0) }) == true { break }
        next += 1
      }
      if !phrase.isEmpty { result.append(phrase.joined(separator: " ")) }
    }
    return result
  }
}

extension VoiceParseResult {
  fileprivate var command: VoiceCommand? {
    if case .command(let command) = self { return command }
    return nil
  }
}

@MainActor
final class VoiceCoachDriverTests: XCTestCase {
  private final class World {
    var now = Date(timeIntervalSince1970: 1_000)
    var tipsEnabled = true
    var listening = true
    var busy = false
    var screen: VoiceScreen? = .camera
    var lastCommandAt: Date?
    var heard: [String: Int] = [:]
    var spoken: [String] = []
    var finish: Announcer.Completion?
  }

  private var world = World()
  private var coach: VoiceCoach!
  private var situation: CoachSituation? = .ready

  override func setUp() async throws {
    try await super.setUp()
    world = World()
    situation = .ready
    let world = world
    coach = VoiceCoach(
      environment: VoiceCoach.Environment(
        isInert: true,
        now: { world.now },
        tipsEnabled: { world.tipsEnabled },
        isListening: { world.listening },
        isBusy: { world.busy },
        screen: { world.screen },
        lastCommandAt: { world.lastCommandAt },
        needsWakeWord: { false },
        verbosity: { .short },
        timesHeard: { world.heard[$0] ?? 0 },
        noteHeard: { world.heard[$0, default: 0] += 1 },
        say: { text, onFinish in
          world.spoken.append(text)
          world.finish = onFinish
        }))
    coach.provide(for: .camera) { [unowned self] in self.situation }
  }

  /// Moves the clock one second at a time, ticking, and finishes each tip at once.
  private func pass(_ seconds: Int) {
    for _ in 0..<seconds {
      world.now.addTimeInterval(1)
      coach.tick()
      if let finish = world.finish {
        world.finish = nil
        finish(true)
      }
    }
  }

  func testFirstTipAfterEightQuietSeconds() {
    coach.tick()
    pass(7)
    XCTAssertTrue(world.spoken.isEmpty)
    pass(1)
    XCTAssertEqual(world.spoken, ["Hold up some text and say read."])
    XCTAssertEqual(world.heard["ready"], 1)
  }

  func testNothingWhileSpeakingNotListeningOrSwitchedOff() {
    coach.tick()
    world.busy = true
    pass(20)
    world.busy = false
    world.listening = false
    pass(20)
    world.listening = true
    world.tipsEnabled = false
    pass(20)
    XCTAssertTrue(world.spoken.isEmpty)
    world.tipsEnabled = true
    pass(8)
    XCTAssertEqual(world.spoken.count, 1)
  }

  func testNoSituationNoTip() {
    situation = nil
    coach.tick()
    pass(300)
    XCTAssertTrue(world.spoken.isEmpty)
    // Another screen's provider doesn't count for this one.
    world.screen = .home
    situation = .ready
    pass(300)
    XCTAssertTrue(world.spoken.isEmpty)
  }

  func testACommandStartsOverAndTheLastTipSaysItStops() {
    coach.tick()
    pass(8 + 30)
    XCTAssertEqual(world.spoken.count, 2)
    world.lastCommandAt = world.now
    coach.tick()
    pass(8)
    XCTAssertEqual(world.spoken.count, 3)
    pass(30 + 60 + 120)
    XCTAssertEqual(world.spoken.count, 6)
    XCTAssertTrue(world.spoken.last!.contains("I'll stop reminding you now."))
    pass(1_000)
    XCTAssertEqual(world.spoken.count, 6)
  }

  func testANewSituationStartsOver() {
    coach.tick()
    pass(8 + 30 + 60 + 120)
    XCTAssertEqual(world.spoken.count, 4)
    situation = .afterReading
    coach.tick()
    pass(8)
    XCTAssertEqual(world.spoken.last, "Say read for something new.")
  }

  func testFirstScreenTipsFollowItsState() {
    situation = .welcome
    coach.provide(for: .welcome) { [unowned self] in self.situation }
    world.screen = .welcome
    coach.tick()
    pass(8)
    XCTAssertEqual(world.spoken, ["Say phone, or say connect."])
    // A connection that didn't finish is a new situation: the tips start over with "try again".
    situation = .welcomeRetry
    coach.tick()
    pass(8)
    XCTAssertEqual(world.spoken.last, "Say try again, or say phone.")
  }

  func testLearnedSituationsWaitLonger() {
    world.heard["ready"] = VoiceCoachSchedule.learnedAfter
    coach.tick()
    pass(29)
    XCTAssertTrue(world.spoken.isEmpty)
    pass(1)
    XCTAssertEqual(world.spoken.count, 1)
  }
}
