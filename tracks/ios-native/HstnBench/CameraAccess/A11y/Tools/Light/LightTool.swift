/*
 * LightTool - "Light and colour": a tone that rises with brightness, and "what colour is this?"
 *
 * Port of Android's tools/light/LightViewModel.kt, phone first. Two modes, both entirely on the
 * phone; nothing leaves it:
 *  - Light probe (default; "is the light on", "light mode"): reads frames 4 times a second, measures
 *    centre-weighted brightness (LightMeter), and plays a continuous tone (ToolTonePlayer) whose
 *    pitch rises with it (PitchMap, smoothed by PitchSmoother), so turning the phone finds a window
 *    or tells whether a lamp is on. FlickerDetector watches for a blinking light and says "It's
 *    blinking" once when it starts (at most every 10 s). "How bright is it" speaks a level, saying
 *    it's the camera's estimate. On the phone camera, exposure and white balance are locked while
 *    the probe runs (PhoneExposureLock), because auto exposure would pull every view back to grey.
 *    "Tone off" / "quiet" / "pause" stop the tone; "tone on" restarts it. The tone stops at once
 *    when the tool closes, and goes silent if no frame has arrived for 2 s (a stale pitch would
 *    mislead).
 *  - Colour ("what colour is this", "colour mode"): takes the latest frame and names the colour in
 *    the centre (ColourReader, ColourSpeech), hedged when the light is dim or tinted. "Again"
 *    measures again. A light haptic tap when a colour is named.
 * Every action plays an earcon; every failure is spoken; "can't tell" rather than a guess.
 * See notes/labels-and-light-ios.md.
 */

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LightTool: SpeakUpTool {
  enum Mode: Equatable, Sendable {
    case probe
    case colour
  }

  let toolID = ToolID.light

  /// Which mode `start` opens in. The integrator sets it from the opening phrase ("what colour is
  /// this" opens colour; see `mode(forOpeningPhrase:)`).
  @ObservationIgnored var openingMode: Mode = .probe

  private(set) var mode: Mode = .probe
  /// The probe loop is running (it may still be silent until the first frame).
  private(set) var probing = false
  /// The user turned the tone off; it stays off until "tone on".
  private(set) var paused = false
  /// Frequency of the tone playing now, or 0 when silent.
  private(set) var toneHz: Double = 0
  private(set) var level: LightLevel?
  private(set) var blinking = false
  /// True while exposure and white balance are locked on the phone camera.
  private(set) var exposureLocked = false
  /// The last colour answer, as spoken.
  private(set) var colourText = ""
  /// Swatch to show (ARGB), the white-balanced colour.
  private(set) var swatch: UInt32?
  private(set) var isMeasuringColour = false
  /// The last line spoken, for the screen.
  private(set) var lastLine = ""

  // Timing, as on Android.
  static let probeInterval: Duration = .milliseconds(250)
  static let staleAfter: TimeInterval = 2
  static let blinkRepeat: TimeInterval = 10
  /// Lets auto exposure settle on the scene before the lock.
  static let lockDelay: Duration = .milliseconds(800)
  /// After unlocking, how long auto exposure gets before a colour is measured.
  static let unlockSettle: Duration = .milliseconds(600)

  private static let toneOwner = "light"

  @ObservationIgnored private weak var source: (any ReadFrameSource)?
  @ObservationIgnored private let tones: ToolTonePlayer
  @ObservationIgnored private let exposureLock: PhoneExposureLock
  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared
  @ObservationIgnored private var probeTask: Task<Void, Never>?
  @ObservationIgnored private var colourTask: Task<Void, Never>?
  @ObservationIgnored private var oneOffTask: Task<Void, Never>?
  @ObservationIgnored private var smoother = PitchSmoother()
  @ObservationIgnored private var flicker = FlickerDetector()
  @ObservationIgnored private var lastReading: LightReading?
  @ObservationIgnored private var lastReadingAt: Date = .distantPast
  @ObservationIgnored private var lastBlinkSaidAt: Date = .distantPast
  /// Bumped by start, stop and every mode change, so late work from before does nothing.
  @ObservationIgnored private var generation = 0

  init(tones: ToolTonePlayer = .shared, exposureLock: PhoneExposureLock = PhoneExposureLock()) {
    self.tones = tones
    self.exposureLock = exposureLock
  }

  /// "what colour is this" (or "colour mode") opens colour mode; anything else, the tool's name included, the probe.
  static func mode(forOpeningPhrase phrase: String) -> Mode {
    // "switch to colour" (ToolID.switchPhrases): LightGrammar wants "colour mode" for the bare word.
    let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
    if ["switch to colour", "switch to color", "go to colour", "go to color"].contains(words) { return .colour }
    return LightGrammar.parse(phrase) == .colour ? .colour : .probe
  }

  // MARK: SpeakUpTool

  var helpLine: String {
    "Light and colour. Say how bright is it, where's the light, or tone off. Say what colour is this, or light mode for the tone."
  }

  func start(source: any ReadFrameSource) {
    self.source = source
    generation += 1
    paused = false
    if openingMode == .colour {
      toColour(announce: true)
    } else {
      toLight(announce: "Light probe on. The tone rises with brightness. Say how bright, what colour is this, or tone off.")
    }
  }

  func stop() {
    generation += 1
    stopProbe()
    colourTask?.cancel()
    colourTask = nil
    oneOffTask?.cancel()
    oneOffTask = nil
    isMeasuringColour = false
    announcer.stop()
  }

  func handle(transcript: String) -> Bool {
    guard let command = LightGrammar.parse(transcript) else { return false }
    perform(command)
    return true
  }

  func makePanel() -> AnyView { AnyView(LightPanel(tool: self)) }

  // MARK: Commands (voice and buttons)

  func perform(_ command: LightCommand) {
    switch command {
    case .howBright: howBright()
    case .whereBright: whereBright()
    case .isBlinking: isBlinking()
    case .again:
      if mode == .colour {
        measureColour(first: false)
      } else {
        howBright()
      }
    case .colour: toColour(announce: mode != .colour)
    case .light: toLight(announce: "Light probe on.")
    case .toneOff: pauseTone()
    case .toneOn: toLight(announce: "Tone on.")
    }
  }

  /// The app's global "stop" while the tool stays open: the tone goes quiet (ToolHub).
  func pauseForStop() {
    if mode == .probe, probing { pauseTone() }
  }

  /// For the integrator: the global "stop" while this tool is open should silence the tone too.
  func pauseTone() {
    guard mode == .probe else {
      announcer.stop()
      return
    }
    stopProbe()
    paused = true
    say("Tone off. Say tone on to hear it again.", earcon: .ready)
  }

  // MARK: Modes

  private func toLight(announce: String?) {
    colourTask?.cancel()
    colourTask = nil
    isMeasuringColour = false
    mode = .probe
    paused = false
    startProbe(announce: announce)
  }

  private func toColour(announce: Bool) {
    stopProbe()
    mode = .colour
    if announce { say("Colour mode. Hold it in front of the camera, in the middle.", earcon: .ready, interrupt: true) }
    measureColour(first: true)
  }

  // MARK: Light probe

  private func startProbe(announce: String?) {
    if probeTask != nil {
      if let announce { say(announce, earcon: .ready, interrupt: true) }
      return
    }
    guard let source else { return fail("The camera isn't ready yet. Try again in a moment.") }
    generation += 1
    let myGeneration = generation
    smoother.reset()
    flicker.reset()
    probing = true
    blinking = false
    tones.begin(owner: Self.toneOwner)
    earcons.play(.working)
    probeTask = Task { [weak self] in
      await self?.runProbe(source, announce: announce, myGeneration)
    }
  }

  private func runProbe(_ source: any ReadFrameSource, announce: String?, _ myGeneration: Int) async {
    let wait = await LightLabelKit.waitForStream(source, isCurrent: { isCurrent(myGeneration) }) {
      say("Starting the camera.", earcon: nil)
    }
    switch wait {
    case .ready: break
    case .blocked, .cancelled:
      if isCurrent(myGeneration) { stopProbe() }
      return
    case .failed(let reason):
      guard isCurrent(myGeneration) else { return }
      stopProbe()
      return fail(reason)
    }
    if let announce { say(announce, earcon: .ready, interrupt: true) }
    if source.cameraKind == .phone {
      // Let auto exposure settle on the scene, then hold it.
      Task { [weak self] in
        try? await Task.sleep(for: Self.lockDelay)
        guard let self, self.isCurrent(myGeneration), self.probing else { return }
        self.exposureLocked = self.exposureLock.lock()
      }
    }
    var lastFrameAt = Date()
    while isCurrent(myGeneration) {
      let tickStarted = ContinuousClock.now
      if let frame = source.latestReadFrame, LightLabelKit.age(of: frame) < Self.staleAfter {
        lastFrameAt = Date()
        let image = frame.image
        let sampled = await Task.detached(priority: .userInitiated) {
          ToolImageSampler.argb(image, width: ToolImageSampler.probeWidth)
        }.value
        guard isCurrent(myGeneration) else { return }
        if let sampled, let reading = LightMeter.measure(sampled.pixels, width: sampled.width, height: sampled.height) {
          probeFrame(reading, pixels: sampled.pixels, width: sampled.width, height: sampled.height)
        }
      } else if Date().timeIntervalSince(lastFrameAt) > Self.staleAfter, toneHz != 0 {
        // No frames: a stale pitch would mislead.
        tones.silenceTone()
        toneHz = 0
      }
      try? await Task.sleep(until: tickStarted + Self.probeInterval, clock: .continuous)
    }
  }

  private func probeFrame(_ reading: LightReading, pixels: [UInt32], width: Int, height: Int) {
    let hz = PitchMap.frequency(smoother.update(PitchMap.position(reading.luminance)))
    let wasBlinking = blinking
    let nowBlinking = flicker.update(pixels, width: width, height: height)
    lastReading = reading
    lastReadingAt = Date()
    tones.setTone(hz: hz)
    toneHz = hz
    level = LightMeter.level(reading)
    blinking = nowBlinking
    if nowBlinking, !wasBlinking, Date().timeIntervalSince(lastBlinkSaidAt) > Self.blinkRepeat {
      lastBlinkSaidAt = Date()
      say("It's blinking.", earcon: .attention)
    }
  }

  private func stopProbe() {
    probeTask?.cancel()
    probeTask = nil
    if probing || toneHz != 0 {
      tones.silenceTone()
      tones.end(owner: Self.toneOwner)
    }
    probing = false
    toneHz = 0
    if exposureLock.isLocked { exposureLock.unlock() }
    exposureLocked = false
  }

  // MARK: Answers

  private func howBright() {
    withReading { reading in
      let level = LightMeter.level(reading)
      self.level = level
      return "\(level.spoken). That's the camera's estimate, so it's only relative."
    }
  }

  private func whereBright() {
    withReading { reading in
      switch reading.brightestSide {
      case .left: "Brighter to your left."
      case .right: "Brighter to your right."
      case .middle: "Brightest straight ahead."
      case nil: "About even. Turn the phone slowly and follow the tone up."
      }
    }
  }

  private func isBlinking() {
    guard mode == .probe, probing else {
      return toLight(announce: "Nothing's blinking that I can see yet. Hold still for a few seconds and ask again.")
    }
    say(
      blinking ? "It's blinking." : "Nothing's blinking that I can see. Hold still for a few seconds and ask again.",
      earcon: .done, interrupt: true)
  }

  /// A fresh reading from the probe, or one measured from the latest frame now.
  private func withReading(_ text: @escaping @MainActor (LightReading) -> String) {
    if let lastReading, probing, Date().timeIntervalSince(lastReadingAt) < 1.5 {
      return say(text(lastReading), earcon: .done, interrupt: true)
    }
    guard let source else { return fail("The camera isn't ready yet. Try again in a moment.") }
    earcons.play(.working)
    let myGeneration = generation
    oneOffTask?.cancel()
    oneOffTask = Task { [weak self] in
      guard let self else { return }
      let wait = await LightLabelKit.waitForStream(source, isCurrent: { self.isCurrent(myGeneration) }) {
        self.say("Starting the camera.", earcon: nil)
      }
      guard self.isCurrent(myGeneration) else { return }
      guard wait == .ready else {
        if case .failed(let reason) = wait { self.fail(reason) }
        return
      }
      guard let frame = await LightLabelKit.recentFrame(source), self.isCurrent(myGeneration) else {
        if self.isCurrent(myGeneration) { self.fail("I couldn't get a picture from the camera. Say again to try once more.") }
        return
      }
      let image = frame.image
      let reading = await Task.detached(priority: .userInitiated) { () -> LightReading? in
        guard let s = ToolImageSampler.argb(image, width: ToolImageSampler.probeWidth) else { return nil }
        return LightMeter.measure(s.pixels, width: s.width, height: s.height)
      }.value
      guard self.isCurrent(myGeneration) else { return }
      guard let reading else { return self.fail("I couldn't measure that picture. Say again to try once more.") }
      self.say(text(reading), earcon: .done, interrupt: true)
    }
  }

  // MARK: Colour

  private func measureColour(first: Bool) {
    guard !isMeasuringColour else { return }
    guard let source else { return fail("The camera isn't ready yet. Try again in a moment.") }
    isMeasuringColour = true
    if !first { earcons.play(.working) }
    let myGeneration = generation
    let wasLocked = exposureLock.isLocked
    if wasLocked { exposureLock.unlock() }
    colourTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.isCurrent(myGeneration) { self.isMeasuringColour = false } }
      let wait = await LightLabelKit.waitForStream(source, isCurrent: { self.isCurrent(myGeneration) }) {
        self.say("Starting the camera.", earcon: nil)
      }
      guard self.isCurrent(myGeneration) else { return }
      guard wait == .ready else {
        if case .failed(let reason) = wait { self.fail(reason) }
        return
      }
      if wasLocked { try? await Task.sleep(for: Self.unlockSettle) }
      guard let frame = await LightLabelKit.recentFrame(source), self.isCurrent(myGeneration) else {
        if self.isCurrent(myGeneration) { self.fail("I couldn't get a picture from the camera. Say again to try once more.") }
        return
      }
      let image = frame.image
      let result = await Task.detached(priority: .userInitiated) { () -> ColourResult? in
        guard let s = ToolImageSampler.argb(image, width: ToolImageSampler.colourWidth) else { return nil }
        return ColourReader.read(s.pixels, width: s.width, height: s.height)
      }.value
      guard self.isCurrent(myGeneration) else { return }
      guard let result else { return self.fail("I couldn't measure that picture. Say again to try once more.") }
      var text = ColourSpeech.describe(result)
      if result.confidence == .abstain, result.reasons.first == .tooDark, source.cameraKind == .phone {
        text = "Too dark to tell. Turn a light on, or say torch on, and say again."
      }
      self.colourText = text
      self.swatch = result.confidence == .abstain ? nil : result.swatch
      if result.confidence != .abstain { LightLabelKit.haptic(.locked) }
      self.say(text, earcon: result.confidence == .abstain ? .attention : .done, interrupt: !first)
    }
  }

  // MARK: Speaking

  private func say(_ text: String, earcon: Earcon?, interrupt: Bool = false) {
    lastLine = text
    announcer.announce(text, earcon: earcon, kind: .reply, interrupt: interrupt)
  }

  private func fail(_ text: String) {
    LightLabelKit.haptic(.failed)
    say(text, earcon: .error, interrupt: true)
  }

  private func isCurrent(_ myGeneration: Int) -> Bool { myGeneration == generation && !Task.isCancelled }
}
