/*
 * WatchTool - "Watch for text": keep looking and say when a word or number appears, and where
 *
 * "Tell me when you see 42", "watch for exit", "find Boots". Phone first: frames come from the
 * ReadFrameSource the app hands in (the iPhone's camera, or the glasses when linked). Once it has
 * a target (from watch(for:), a phrase while open, or by asking "What should I watch for?") it
 * takes the latest frame about twice a second, checks the view (covered, too dark), runs Vision's
 * fast OCR (WatchRecognizer) and looks for the target (WatchTextMatcher: loose for words, exact
 * for numbers). WatchSightingTracker decides what to say: an earcon, a haptic on the phone and
 * "42, on your right" once it's in two of the last four frames; "42, gone" a few seconds after it
 * leaves; again when it comes back; now and then "I see 24, not 42". A soft tick every 10 s
 * (user-tunable or off) says it's still watching, only while pictures are arriving and the view is
 * fine. Problems are always spoken: covered, too dark, no pictures, OCR failing or too slow. It
 * keeps watching until told to stop or the tool is closed.
 *
 * Orientation help only. It never says anything about whether it's safe to go, and the first start
 * in a session reminds the user to keep using their cane or dog (ROADMAP.md > "Awareness, not
 * safety"). Ported from Android's tools/watch/WatchViewModel.kt; notes/watch-and-ask-ios.md.
 */

import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class WatchTool: SpeakUpTool {
  enum Phase: Equatable {
    /// No target yet: asked "What should I watch for?".
    case asking
    /// Reading frames and looking for the target.
    case watching
    /// Stopped or paused; the target is kept for "carry on watching".
    case stopped
  }

  static let defaultTickSeconds = 10
  /// The tick button cycles through these (0 = off).
  static let tickChoices = [10, 20, 30, 0]
  static let tickSecondsKey = "watch_tick_seconds"
  /// Looks a second at most.
  static let lookInterval: Duration = .milliseconds(500)
  /// A frame older than this isn't worth reading.
  static let maxFrameAgeMs: Int64 = 2_000
  /// Streaming but no new frame for this long: say so.
  static let noFramesMs: Int64 = 10_000
  /// Ticks only while frames are arriving.
  static let frameFreshMs: Int64 = 5_000
  static let ocrFailsBeforeWarning = 3
  /// A spoken answer to "What should I watch for?" is short; longer speech is probably the room.
  static let maxAnswerWords = 4

  let toolID: ToolID = .watch

  private(set) var phase: Phase = .asking
  private(set) var target: WatchTarget?
  /// The last sighting as spoken ("42, on your right.").
  private(set) var lastSighting: String?
  /// The last thing said, for large print.
  private(set) var lastSpoken: String?
  /// What OCR read in the last frame, lines joined with " / " (for sighted helpers).
  private(set) var lastRead: String?
  private(set) var tickSeconds: Int
  /// Average OCR time per frame.
  private(set) var ocrMs: Int?

  @ObservationIgnored private weak var source: (any ReadFrameSource)?
  @ObservationIgnored private var pendingTarget: String?
  @ObservationIgnored private var tracker = WatchSightingTracker()
  @ObservationIgnored private var viewIssues = WatchViewIssueWatch()
  @ObservationIgnored private var pace = WatchPaceWatch()
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  /// Bumped on every start and stop, so a look still in flight can't speak for an old target.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var lastFrameArrivedAt: UInt64 = 0
  @ObservationIgnored private var lastFrameMs: Int64 = 0
  @ObservationIgnored private var lastTickMs: Int64 = 0
  @ObservationIgnored private var watchStartMs: Int64 = 0
  @ObservationIgnored private var noFramesSaid = false
  @ObservationIgnored private var unavailableSaid = false
  @ObservationIgnored private var ocrFails = 0
  @ObservationIgnored private var ocrFailSaid = false
  @ObservationIgnored private var ocrTimes: [Int] = []

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let haptic: @MainActor () -> Void
  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared

  /// The cane-or-dog line is said on the first start in an app session only.
  private static var saidCaneLine = false

  /// - Parameters:
  ///   - defaults: where the tick setting is kept.
  ///   - haptic: played with the sighting earcon. A success notification on the phone by default.
  init(defaults: UserDefaults = .standard, haptic: (@MainActor () -> Void)? = nil) {
    self.defaults = defaults
    self.haptic = haptic ?? { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    let saved = defaults.object(forKey: Self.tickSecondsKey) as? Int
    tickSeconds = saved.map { max(0, $0) } ?? Self.defaultTickSeconds
  }

  private var camera: CameraKind { source?.cameraKind ?? .phone }

  /// True while watching: room chatter is expected (a bus stop), so the app shouldn't answer
  /// unrecognised speech with "Sorry, I didn't get that".
  var isBusy: Bool { phase == .watching }

  // MARK: SpeakUpTool

  func start(source: ReadFrameSource) {
    self.source = source
    if let pending = pendingTarget {
      pendingTarget = nil
      startWatching(pending)
    } else if target != nil {
      resume()
    } else {
      ask(opening: true)
    }
  }

  /// The app's global "stop" while the tool stays open.
  func pauseForStop() { pause() }

  func stop() {
    stopLoop()
    if target != nil, phase == .watching { phase = .stopped }
    source = nil
  }

  func handle(transcript: String) -> Bool {
    let normalized = HeardText.normalize(transcript)
    let light = HeardText.light(transcript)
    if let command = WatchGrammar.parse(normalized: normalized, light: light) {
      perform(command)
      return true
    }
    if phase == .stopped, target != nil, ["carry on", "continue", "go on", "resume"].contains(normalized) {
      resume()
      return true
    }
    if phase == .asking {
      // The answer to "What should I watch for?". The app's own commands had their turn already.
      guard !normalized.isEmpty, HeardText.wordCount(normalized) <= Self.maxAnswerWords else { return false }
      startWatching(light)
      return true
    }
    return false
  }

  var helpLine: String { WatchWording.help(camera: camera) }

  func makePanel() -> AnyView { AnyView(WatchPanel(tool: self)) }

  // MARK: Entry points for the app and the panel

  /// Watch for `raw` ("42", "platform three"), as said or typed. Before start(source:) it is kept
  /// and used when the tool starts, so "watch for 42" from anywhere can open the tool with it.
  func watch(for raw: String) {
    guard source != nil else {
      pendingTarget = raw
      return
    }
    startWatching(raw)
  }

  /// The app's global "stop" or "pause" while watching. False if there was nothing to pause.
  @discardableResult
  func pause() -> Bool {
    guard let target, phase == .watching else { return false }
    stopLoop()
    phase = .stopped
    say("Paused. Say carry on watching to keep watching for \(target.display).")
    return true
  }

  func toggleWatching() {
    switch phase {
    case .watching: perform(.stop)
    case .stopped where target != nil: resume()
    default: ask()
    }
  }

  func sayWhere() { perform(.whereIsIt) }

  func askForNewTarget() { ask() }

  func cycleTicks() {
    let index = Self.tickChoices.firstIndex(of: tickSeconds) ?? -1
    setTicks(Self.tickChoices[(index + 1) % Self.tickChoices.count])
  }

  // MARK: Commands

  private func perform(_ command: WatchCommand) {
    switch command {
    case .stop:
      guard let target else { return say(WatchWording.notWatching) }
      stopLoop()
      phase = .stopped
      say(WatchWording.stopped(target.display))
    case .resume:
      if target == nil {
        ask()
      } else if phase == .watching {
        sayWhatTarget()
      } else {
        resume()
      }
    case .whatTarget:
      sayWhatTarget()
    case .whereIsIt:
      sayWhereIsIt()
    case .newTarget(let raw):
      if let raw { startWatching(raw) } else { ask() }
    case .ticks(let seconds):
      setTicks(seconds ?? Self.defaultTickSeconds)
    }
  }

  private func ask(opening: Bool = false) {
    stopLoop()
    target = nil
    lastSighting = nil
    phase = .asking
    if opening {
      say("Watch for text. " + WatchWording.askTarget, earcon: .ready)
      lastSpoken = WatchWording.askTarget
    } else {
      say(WatchWording.askTarget)
    }
  }

  private func sayWhatTarget() {
    guard let target else { return say(WatchWording.notWatching) }
    say(phase == .watching ? WatchWording.whatTarget(target.display) : WatchWording.whatTargetStopped(target.display))
  }

  private func sayWhereIsIt() {
    guard let target else { return say(WatchWording.notWatching) }
    switch tracker.whereIs(nowMs: Self.nowMs()) {
    case .inView(let spot):
      say(WatchWording.seen(target.display, WatchWording.place(spot, camera: camera)))
    case .lastSeen(let spot, let agoMs):
      say(WatchWording.whereLastSeen(target.display, WatchWording.place(spot, camera: camera), seconds: Int(agoMs / 1000)))
    case .notSeen:
      say(WatchWording.whereNotSeen(target.display))
    }
  }

  private func setTicks(_ seconds: Int) {
    tickSeconds = max(0, seconds)
    defaults.set(tickSeconds, forKey: Self.tickSecondsKey)
    say(tickSeconds == 0 ? WatchWording.ticksOff : WatchWording.ticksEvery(tickSeconds))
  }

  // MARK: Watching

  private func startWatching(_ raw: String) {
    guard let parsed = WatchTarget.parse(raw) else {
      phase = .asking
      announcer.announce(WatchWording.didntGetTarget, earcon: .error)
      lastSpoken = WatchWording.didntGetTarget
      return
    }
    target = parsed
    tracker.reset()
    lastSighting = nil
    if Self.saidCaneLine {
      say(WatchWording.start(parsed.display))
    } else {
      Self.saidCaneLine = true
      say(WatchWording.startFirst(parsed.display))
    }
    startLoop()
  }

  private func resume() {
    guard let target else { return ask() }
    tracker.reset()
    say(WatchWording.resumed(target.display))
    startLoop()
  }

  private func stopLoop() {
    generation += 1
    loopTask?.cancel()
    loopTask = nil
    tickTask?.cancel()
    tickTask = nil
  }

  private func startLoop() {
    stopLoop()
    guard source != nil else {
      // Not started yet: start(source:) picks it up.
      phase = .stopped
      return
    }
    viewIssues.reset()
    pace.reset()
    ocrTimes.removeAll()
    noFramesSaid = false
    unavailableSaid = false
    ocrFails = 0
    ocrFailSaid = false
    watchStartMs = Self.nowMs()
    lastFrameMs = 0
    lastTickMs = watchStartMs
    lastFrameArrivedAt = 0
    phase = .watching
    let myGeneration = generation
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.generation == myGeneration else { return }
        await self.lookOnce(myGeneration)
        try? await Task.sleep(for: Self.lookInterval)
      }
    }
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.generation == myGeneration else { return }
        self.tickAndWatchdog()
      }
    }
  }

  private func lookOnce(_ myGeneration: Int) async {
    guard let source else { return }
    switch source.prepareStreamForReading() {
    case .unavailable(let reason):
      if !unavailableSaid {
        unavailableSaid = true
        say(reason, earcon: .error)
      }
      return
    case .starting, .blocked:
      // Starting, or the camera screen is already saying what's wrong.
      return
    case .ready:
      unavailableSaid = false
    }
    guard let frame = source.latestReadFrame, frame.arrivedAt != lastFrameArrivedAt else { return }
    let ageMs = (Int64(BenchClock.uptimeNanoseconds()) - Int64(frame.arrivedAt)) / 1_000_000
    guard ageMs <= Self.maxFrameAgeMs else { return }
    lastFrameArrivedAt = frame.arrivedAt
    lastFrameMs = Self.nowMs()
    noFramesSaid = false

    let image = frame.image
    let result = await Task.detached(priority: .userInitiated) { () -> Result<WatchLook, any Error> in
      Result { try WatchRecognizer.look(at: image) }
    }.value
    guard generation == myGeneration, let target, phase == .watching else { return }
    switch result {
    case .failure:
      ocrFails += 1
      if ocrFails >= Self.ocrFailsBeforeWarning, !ocrFailSaid {
        ocrFailSaid = true
        say(WatchWording.ocrFailed, earcon: .error)
      }
    case .success(let look):
      ocrFails = 0
      handle(look, target: target)
    }
  }

  private func handle(_ look: WatchLook, target: WatchTarget) {
    let now = Self.nowMs()
    if let event = viewIssues.onFrame(nowMs: now, issue: look.issue) {
      switch event {
      case .started(let issue), .stillThere(let issue):
        say(issue == .covered ? WatchWording.covered(camera: camera) : WatchWording.dark, earcon: .error)
      case .cleared:
        say(WatchWording.viewBack(target.display), interrupt: false)
      }
    }
    guard look.issue == nil, let page = look.page else { return }

    ocrTimes.append(look.ocrMilliseconds)
    if ocrTimes.count > 10 { ocrTimes.removeFirst() }
    ocrMs = ocrTimes.reduce(0, +) / max(1, ocrTimes.count)
    let read = page.lines.map(\.text).joined(separator: " / ")
    lastRead = read.isEmpty ? nil : String(read.prefix(160))

    let match = WatchTextMatcher.find(target, in: page)
    for event in tracker.onFrame(nowMs: now, match: match) {
      switch event {
      case .appeared(let spot):
        let line = WatchWording.seen(target.display, WatchWording.place(spot, camera: camera))
        lastSighting = line
        haptic()
        say(line, earcon: .attention)
      case .gone:
        say(WatchWording.gone(target.display), interrupt: false)
      case .nearMiss(let seen):
        if !announcer.isSpeaking { say(WatchWording.nearMiss(seen: seen, target: target.display), interrupt: false) }
      }
    }
    if let seconds = pace.onFrameDone(nowMs: Self.nowMs()) { say(WatchWording.slow(seconds: seconds), interrupt: false) }
  }

  /// Soft tick while watching and pictures arrive; spoken if they stop.
  private func tickAndWatchdog() {
    guard phase == .watching, target != nil else { return }
    let now = Self.nowMs()
    let fresh = lastFrameMs != 0 && now - lastFrameMs < Self.frameFreshMs
    if tickSeconds > 0, fresh, viewIssues.current == nil, !announcer.isSpeaking, now - lastTickMs >= Int64(tickSeconds) * 1000 {
      lastTickMs = now
      earcons.play(.working)
    }
    let since = lastFrameMs == 0 ? now - watchStartMs : now - lastFrameMs
    if since > Self.noFramesMs, !noFramesSaid, !unavailableSaid {
      noFramesSaid = true
      say(WatchWording.noFrames(camera: camera), earcon: .error)
    }
  }

  // MARK: Speech

  private func say(_ text: String, earcon: Earcon? = nil, interrupt: Bool = true) {
    lastSpoken = text
    if let earcon {
      announcer.announce(text, earcon: earcon, interrupt: interrupt)
    } else {
      announcer.say(text, interrupt: interrupt)
    }
  }

  static func nowMs() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
  }
}
