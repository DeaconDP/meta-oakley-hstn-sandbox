/*
 * HandsFreeSurface - the output fan-out for hands-free mode (notes/hands-free-mode.md, sections 4-5)
 *
 * Speech is the source of truth and stays with Announcer. Alongside it, features publish one small
 * card (screen, one line of state, the last command heard, up to three hints) here, and never talk
 * to a display API themselves. The surface keeps the card for the phone UI (observable) and hands
 * it to its sinks; today that is GlassesDisplaySink, which shows it on a Ray-Ban Display.
 *
 * GlassesDisplaySink only draws while a display-capable device is attached, hands-free is on and
 * the glasses display setting is on. Every send replaces the whole screen, so it sends only when
 * the card changed and at most about twice a second (CardThrottle, pure). A failure is logged and
 * spoken once per launch; audio never waits on the display.
 */

import Foundation
import Observation
import os

/// What the glasses display shows. Only what was also spoken or is on the phone screen.
struct HandsFreeCard: Equatable, Sendable {
  var title: String
  var state: String
  /// The last command understood, as its phrase. Never a raw transcript.
  var heard: String?
  /// Up to three phrases to say next. Shown as buttons that do the same as saying them.
  var hints: [VoiceCommand]

  static let maxHints = 3
  static let maxLineLength = 40

  init(title: String, state: String, heard: String? = nil, hints: [VoiceCommand] = []) {
    self.title = Self.shorten(title)
    self.state = Self.shorten(state)
    self.heard = heard.map { Self.shorten($0) }
    self.hints = Array(hints.prefix(Self.maxHints))
  }

  /// "Say: read · status · main menu".
  var hintLine: String? {
    hints.isEmpty ? nil : "Say: " + hints.map(\.phrase).joined(separator: " · ")
  }

  /// One short line: cut at a word boundary with an ellipsis.
  static func shorten(_ text: String, max: Int = maxLineLength) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > max else { return trimmed }
    let cut = trimmed.prefix(max - 1)
    let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
    return atWord.trimmingCharacters(in: .whitespaces) + "\u{2026}"
  }
}

/// When to send a card. Pure: card and time in, a decision out.
struct CardThrottle: Equatable, Sendable {
  static let minInterval: TimeInterval = 0.5

  enum Decision: Equatable, Sendable {
    case sendNow
    /// Too soon after the last send: send the latest card at this time.
    case sendAt(Date)
    /// Already showing.
    case skip
  }

  private(set) var lastSent: HandsFreeCard?
  private(set) var lastSentAt: Date?

  func decide(_ card: HandsFreeCard, now: Date) -> Decision {
    if card == lastSent { return .skip }
    if let lastSentAt, now.timeIntervalSince(lastSentAt) < Self.minInterval {
      return .sendAt(lastSentAt.addingTimeInterval(Self.minInterval))
    }
    return .sendNow
  }

  mutating func sent(_ card: HandsFreeCard, at time: Date) {
    lastSent = card
    lastSentAt = time
  }

  /// The display was cleared or re-attached: the next card goes out whatever it is.
  mutating func reset() {
    lastSent = nil
  }
}

@MainActor
protocol HandsFreeCardSink: AnyObject {
  func show(_ card: HandsFreeCard)
}

@MainActor
@Observable
final class HandsFreeSurface {
  static let shared: HandsFreeSurface = HandsFreeSurface(glasses: GlassesDisplaySink(environment: .live))

  /// The current card, which the phone UI may show.
  private(set) var card = HandsFreeCard(title: "SpeakUp", state: "Starting")

  @ObservationIgnored let glasses: GlassesDisplaySink
  @ObservationIgnored private var sinks: [HandsFreeCardSink]

  init(glasses: GlassesDisplaySink, extraSinks: [HandsFreeCardSink] = []) {
    self.glasses = glasses
    sinks = [glasses] + extraSinks
  }

  /// A screen or tool says where it is, what is going on, and what to say next.
  func publish(screen: VoiceScreen, state: String, hints: [VoiceCommand]) {
    update(HandsFreeCard(title: screen.cardTitle, state: state, heard: card.heard, hints: hints))
  }

  /// VoiceControl understood a command.
  func noteHeard(_ command: VoiceCommand) {
    update(HandsFreeCard(title: card.title, state: card.state, heard: "Heard: \(command.phrase)", hints: card.hints))
  }

  /// A setting that changes what sinks may show (hands-free, glasses display) changed.
  func refresh() {
    for sink in sinks { sink.show(card) }
  }

  private func update(_ new: HandsFreeCard) {
    guard new != card else { return }
    card = new
    refresh()
  }
}

// MARK: - The glasses display

/// A display the sink can draw on. The live one is DATGlassesDisplay (MWDATDisplay); tests use fakes.
@MainActor
protocol GlassesDisplayTarget: AnyObject {
  func send(_ card: HandsFreeCard, onCommand: @escaping @MainActor @Sendable (VoiceCommand) -> Void) async throws
  func clear() async
  func detach()
}

@MainActor
final class GlassesDisplaySink: HandsFreeCardSink {
  struct Environment {
    /// Hands-free is on and the user hasn't said "glasses display off".
    var isAllowed: @MainActor () -> Bool
    var now: @MainActor () -> Date
    var sleep: @MainActor (TimeInterval) async -> Void
    /// Logged always, spoken once per launch.
    var reportFailure: @MainActor (_ description: String, _ speak: Bool) -> Void
    /// A display button was pressed: run the command as if it was said.
    var perform: @MainActor (VoiceCommand) -> Void
  }

  private(set) var target: (any GlassesDisplayTarget)?
  /// The display is showing a card (so turning it off should clear it).
  private(set) var isShowing = false
  private(set) var sendCount = 0

  private let environment: Environment
  private var throttle = CardThrottle()
  private var latest: HandsFreeCard?
  private var flush: Task<Void, Never>?
  private var inFlight = false
  private var failureSpoken = false

  init(environment: Environment) {
    self.environment = environment
  }

  /// A display-capable device's display is ready to use. Shows the current card straight away.
  func attach(_ target: any GlassesDisplayTarget, showing card: HandsFreeCard) {
    detach()
    self.target = target
    throttle.reset()
    show(card)
  }

  /// The session ended, or the device has no display.
  func detach() {
    flush?.cancel()
    flush = nil
    target?.detach()
    target = nil
    isShowing = false
    throttle.reset()
  }

  func show(_ card: HandsFreeCard) {
    latest = card
    guard let target else { return }
    guard environment.isAllowed() else {
      if isShowing {
        isShowing = false
        throttle.reset()
        flush?.cancel()
        flush = nil
        Task { await target.clear() }
      }
      return
    }
    schedule()
  }

  private func schedule() {
    guard let latest, !inFlight, flush == nil else { return }
    switch throttle.decide(latest, now: environment.now()) {
    case .skip:
      return
    case .sendNow:
      send(latest)
    case .sendAt(let time):
      let wait = max(0, time.timeIntervalSince(environment.now()))
      flush = Task { [weak self] in
        await self?.environment.sleep(wait)
        guard let self, !Task.isCancelled else { return }
        self.flush = nil
        self.schedule()
      }
    }
  }

  private func send(_ card: HandsFreeCard) {
    guard let target else { return }
    inFlight = true
    throttle.sent(card, at: environment.now())
    let perform = environment.perform
    Task { [weak self] in
      var succeeded = true
      do {
        try await target.send(card) { command in perform(command) }
      } catch {
        succeeded = false
        // Logged every time, spoken once. No retry loop: the next change of card tries again.
        self?.environment.reportFailure(String(describing: error), !(self?.failureSpoken ?? true))
        self?.failureSpoken = true
      }
      guard let self else { return }
      self.inFlight = false
      if succeeded {
        self.isShowing = true
        self.sendCount += 1
      }
      // A newer card may have come in while this one was on its way.
      if self.target != nil, self.environment.isAllowed(), succeeded || self.latest != card { self.schedule() }
    }
  }
}

extension GlassesDisplaySink.Environment {
  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "GlassesDisplay")

  static let live: GlassesDisplaySink.Environment = GlassesDisplaySink.Environment(
    isAllowed: { A11yPreferences.shared.handsFree && A11yPreferences.shared.glassesDisplayEnabled },
    now: { Date() },
    sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
    reportFailure: { description, speak in
      logger.error("display failed: \(description, privacy: .public)")
      // Queued, never interrupting: the display is a mirror, not the main path.
      if speak { Announcer.shared.say(SpokenMessage.glassesDisplayFailed, interrupt: false) }
    },
    perform: { VoiceControl.shared.perform($0) }
  )
}
