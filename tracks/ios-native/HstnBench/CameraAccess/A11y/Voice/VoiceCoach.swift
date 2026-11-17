/*
 * VoiceCoach - after a quiet spell, says what the user can say next
 *
 * A blind user who has just connected, or just heard a page, may not know the app is waiting for
 * them, or which words it takes. The status lines say what state things are in ("Ready to read");
 * the coach names words ("Hold some text in front of you and say read"). Same idea as
 * the Android track's IdleNudge (notes/tools-layer.md > Silence reminders).
 *
 * When: only while voice control is listening (the tips are all "say ..."), the tips setting is on,
 * and nothing is being said or read. Quiet means quiet on both sides: while the app speaks or
 * reads the gap restarts without using up a tip. The first tip comes 8 s into the quiet, then 30 s,
 * 1 min and 2 min later; the last one says it will stop, and then it stays quiet until the user
 * acts. A command, a VoiceOver focus move, or a change of situation (the glasses came on, a page
 * was read) starts over. Once a situation's first tip has been heard three times, that situation
 * starts at the 30 s gap: the user has learned it. Replay setup brings the quick tips back.
 *
 * Never: from outside the app, or over the user.
 *
 * Pure parts (VoiceCoachSchedule, VoiceCoachLines, CameraViewModel.coachSituation) are unit
 * tested; the driver takes its world through Environment, so tests run it with a fake clock.
 */

import Foundation
import MWDATCore
import UIKit

/// What the screen is waiting for, as far as tips go. nil from a screen means "don't prompt now":
/// a wait or an alert.
enum CoachSituation: Equatable, Sendable {
  /// The first screen, before connecting.
  case welcome
  /// The first screen, after a connection that didn't finish.
  case welcomeRetry
  /// The first screen, replayed with the glasses already connected.
  case welcomeConnected
  /// The home screen: registered with Meta AI not yet.
  case notLinked
  case noGlasses
  /// Folded, or not worn with no session.
  case glassesNotReady
  /// Glasses ready, nothing read yet. The camera may be on or off: Read starts it either way.
  case ready
  /// A page has been read.
  case afterReading
  case paused

  /// Stable key for counting how often a tip was heard.
  var key: String {
    switch self {
    case .welcome: "welcome"
    case .welcomeRetry: "welcomeRetry"
    case .welcomeConnected: "welcomeConnected"
    case .notLinked: "notLinked"
    case .noGlasses: "noGlasses"
    case .glassesNotReady: "glassesNotReady"
    case .ready: "ready"
    case .afterReading: "afterReading"
    case .paused: "paused"
    }
  }
}

// MARK: - When

/// When to give the next tip. Pure: times in, a tip index out.
struct VoiceCoachSchedule: Equatable, Sendable {
  static let newUserGaps: [TimeInterval] = [8, 30, 60, 120]
  static let familiarGaps: [TimeInterval] = [30, 60, 120]
  /// A situation's first tip heard to the end this many times counts as learned.
  static let learnedAfter = 3

  let gaps: [TimeInterval]
  private(set) var quietSince: Date
  private(set) var given = 0

  init(gaps: [TimeInterval], start: Date) {
    self.gaps = gaps
    quietSince = start
  }

  init(timesHeard: Int, start: Date) {
    self.init(gaps: timesHeard >= Self.learnedAfter ? Self.familiarGaps : Self.newUserGaps, start: start)
  }

  /// The user said or did something: tips start over from the first gap.
  mutating func userActed(at now: Date) {
    quietSince = now
    given = 0
  }

  /// Something is being said or read: the quiet hasn't started yet.
  mutating func busy(at now: Date) {
    quietSince = now
  }

  /// The tip to give now (0 = first), or nil if it isn't time yet or all have been given.
  mutating func due(at now: Date) -> Int? {
    guard given < gaps.count, now.timeIntervalSince(quietSince) >= gaps[given] else { return nil }
    quietSince = now
    given += 1
    return given - 1
  }

  /// The final tip, after which the coach stays quiet until the user acts.
  func isLast(_ tip: Int) -> Bool { tip == gaps.count - 1 }
}

// MARK: - What

enum VoiceCoachLines {
  /// The whole line for one tip. Later tips start "I'm still listening."; the last one says it will
  /// stop. `wakeWord`: commands are given as "reader, read", since bare ones are ignored right now.
  static func line(
    for situation: CoachSituation, tip: Int, isLast: Bool, wakeWord: Bool, verbosity: Verbosity
  ) -> String {
    let words = Words(wakeWord: wakeWord)
    let short = verbosity == .short
    var parts: [String] = []
    if tip > 0, !short { parts.append("I'm still listening.") }
    parts.append(hint(for: situation, words, short: short))
    if isLast { parts.append("I'll stop reminding you now. \(words.sayFirst("help")) whenever you need me.") }
    return parts.joined(separator: " ")
  }

  /// Spoken commands, with the wake word when it's needed.
  struct Words {
    let wakeWord: Bool

    func say(_ command: String) -> String { wakeWord ? "say reader, \(command)" : "say \(command)" }
    /// At the start of a sentence.
    func sayFirst(_ command: String) -> String { wakeWord ? "Say reader, \(command)" : "Say \(command)" }
  }

  static func hint(for situation: CoachSituation, _ w: Words, short: Bool) -> String {
    switch situation {
    case .welcome:
      return short
        ? "\(w.sayFirst("connect")), or \(w.say("not now"))."
        : "To connect your glasses, \(w.say("connect")). I'll open the Meta AI app so you can approve it. "
          + "Or \(w.say("not now"))."
    case .welcomeRetry:
      return short
        ? "\(w.sayFirst("try again")), or \(w.say("not now"))."
        : "Your glasses aren't connected yet. \(w.sayFirst("try again")), and I'll open the Meta AI app again. "
          + "Or \(w.say("not now"))."
    case .welcomeConnected:
      return short
        ? "\(w.sayFirst("continue")) to start."
        : "Your glasses are already connected. \(w.sayFirst("continue")) to start reading."
    case .notLinked:
      return short
        ? "\(w.sayFirst("connect")) to link your glasses."
        : "Your glasses aren't linked to SpeakUp yet. \(w.sayFirst("connect")), and I'll open the Meta AI app so you can approve it."
    case .noGlasses:
      return short
        ? "Glasses not found. \(w.sayFirst("status")) to check again."
        : "I can't find your glasses. Check that Bluetooth is on and the glasses are out of the case, then \(w.say("status"))."
    case .glassesNotReady:
      return "Put your glasses on and unfold them, then \(w.say("status"))."
    case .ready:
      return short
        ? "Hold up some text and \(w.say("read"))."
        : "Want me to read something? Hold a page, a letter or a label about an arm's length away, "
          + "a little to your right, and \(w.say("read"))."
    case .afterReading:
      return short
        ? "\(w.sayFirst("read")) for something new."
        : "\(w.sayFirst("read")) to read something new. \(w.sayFirst("back")) or \(w.say("next")) moves between sentences, "
          + "and \(w.say("repeat")) says one again."
    case .paused:
      return "Paused. Tap your glasses to carry on, or \(w.say("status"))."
    }
  }
}

// MARK: - The main screen's situation

extension CameraViewModel {
  /// What a tip should be about on the main screen, or nil when nothing should be suggested.
  func coachSituation(updateRequired: Bool, hasReadSentences: Bool) -> CoachSituation? {
    // An alert owns the moment; the update has its own button and line.
    if showError || showCameraPermissionRedirectConfirm || updateRequired {
      return nil
    }
    if !hasActiveDevice { return .noGlasses }
    if hingeState == .closed || (donState == .doffed && !hasSession) { return .glassesNotReady }
    switch a11yPhase {
    case .idle, .sessionReady, .streaming: return hasReadSentences ? .afterReading : .ready
    case .paused: return .paused
    case .noDevice: return .noGlasses
    case .sessionStarting, .previewStarting, .waitingForDevice, .stopping: return nil
    }
  }
}

// MARK: - The driver

@MainActor
final class VoiceCoach {
  static let shared = VoiceCoach(environment: .live)

  struct Environment {
    /// Tests and UI tests: never runs its own clock or speaks unless ticked.
    var isInert: Bool
    var now: @MainActor () -> Date
    var tipsEnabled: @MainActor () -> Bool
    var isListening: @MainActor () -> Bool
    /// The app is speaking or reading.
    var isBusy: @MainActor () -> Bool
    var screen: @MainActor () -> VoiceScreen?
    var lastCommandAt: @MainActor () -> Date?
    var needsWakeWord: @MainActor () -> Bool
    var verbosity: @MainActor () -> Verbosity
    var timesHeard: @MainActor (_ key: String) -> Int
    var noteHeard: @MainActor (_ key: String) -> Void
    var say: @MainActor (_ text: String, _ onFinish: @escaping Announcer.Completion) -> Void
  }

  private let environment: Environment
  private var schedule: VoiceCoachSchedule
  private var situation: CoachSituation?
  private var lastSeenCommandAt: Date?
  private var isSpeakingTip = false
  /// The current screen's state (first screen, home or camera), for the screen that set it.
  private var provider: (screen: VoiceScreen, situation: @MainActor () -> CoachSituation?)?
  private var loop: Task<Void, Never>?
  private var observer: NSObjectProtocol?

  init(environment: Environment) {
    self.environment = environment
    schedule = VoiceCoachSchedule(gaps: VoiceCoachSchedule.newUserGaps, start: environment.now())
  }

  /// Starts the once-a-second check. Idempotent; does nothing in tests.
  func begin() {
    guard loop == nil, !environment.isInert else { return }
    // VoiceOver users exploring the screen are busy, not stuck.
    observer = NotificationCenter.default.addObserver(
      forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.userActed() }
    }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        self?.tick()
      }
    }
  }

  /// A screen says what it's waiting for. Replaces the last screen's.
  func provide(for screen: VoiceScreen, _ situation: @escaping @MainActor () -> CoachSituation?) {
    provider = (screen, situation)
  }

  /// A screen going away: only drops its own, since the next screen may have appeared first.
  func stopProviding(for screen: VoiceScreen) {
    if provider?.screen == screen { provider = nil }
  }

  /// A touch, a focus move, anything the user did that voice control didn't see.
  func userActed() {
    schedule.userActed(at: environment.now())
  }

  /// One check: gives a tip if one is due. Called every second by begin(), and by tests.
  func tick() {
    let now = environment.now()
    let commandAt = environment.lastCommandAt()
    if commandAt != lastSeenCommandAt {
      lastSeenCommandAt = commandAt
      schedule.userActed(at: now)
    }
    let current = currentSituation()
    if current != situation {
      situation = current
      schedule = VoiceCoachSchedule(timesHeard: current.map { environment.timesHeard($0.key) } ?? 0, start: now)
    }
    guard let current, environment.tipsEnabled(), environment.isListening(), !isSpeakingTip, !environment.isBusy() else {
      schedule.busy(at: now)
      return
    }
    guard let tip = schedule.due(at: now) else { return }
    let line = VoiceCoachLines.line(
      for: current, tip: tip, isLast: schedule.isLast(tip), wakeWord: environment.needsWakeWord(),
      verbosity: environment.verbosity())
    isSpeakingTip = true
    environment.say(line) { [weak self] finished in
      guard let self else { return }
      self.isSpeakingTip = false
      self.schedule.busy(at: self.environment.now())
      if finished, tip == 0 { self.environment.noteHeard(current.key) }
    }
  }

  private func currentSituation() -> CoachSituation? {
    guard let screen = environment.screen(), let provider, provider.screen == screen else { return nil }
    return provider.situation()
  }
}

extension VoiceCoach.Environment {
  static let live = VoiceCoach.Environment(
    isInert: LaunchOptions.isAutomatedTest,
    now: { Date() },
    tipsEnabled: { A11yPreferences.shared.voiceTipsEnabled },
    isListening: { VoiceControl.shared.status == .listening },
    // An alert or question waiting for its answer counts as busy: no tip over it.
    isBusy: { Announcer.shared.isSpeaking || TextReader.shared.isActive || VoiceControl.shared.activePrompt != nil },
    screen: { VoiceControl.shared.screen },
    lastCommandAt: { VoiceControl.shared.lastCommandAt },
    needsWakeWord: { VoiceControl.shared.needsWakeWord },
    verbosity: { A11yPreferences.shared.verbosity },
    timesHeard: { A11yPreferences.shared.voiceTipsHeard[$0] ?? 0 },
    noteHeard: { A11yPreferences.shared.voiceTipsHeard[$0, default: 0] += 1 },
    say: { text, onFinish in Announcer.shared.say(text, interrupt: false, onFinish: onFinish) }
  )
}
