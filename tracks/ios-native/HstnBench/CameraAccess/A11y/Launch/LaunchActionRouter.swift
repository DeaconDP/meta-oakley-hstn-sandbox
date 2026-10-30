/*
 * LaunchActionRouter - hands a screen-free launch (Siri, Shortcuts, Back Tap, Action Button) to
 * the main screen
 *
 * An App Intent can run before any view exists (cold launch) or while the main screen is behind
 * onboarding, so it can't call the camera view model directly. It parks the action here; the main
 * screen observes `pending` and runs it once it can. One slot, latest wins: two quick "look"
 * requests mean one look, not two.
 *
 * A request expires after `maxAge`, so an action that waited behind onboarding or a long connect
 * doesn't fire minutes later when the user has moved on (a surprise photo is worse than none).
 */

import Foundation
import Observation

enum LaunchAction: String, Sendable, CaseIterable {
  /// Take a photo and describe it with the current pipeline.
  case look
  /// Speak the one-line readiness status ("Ready.", "Glasses aren't connected...").
  case status
  /// Repeat the last spoken line.
  case repeatLast
}

@MainActor
@Observable
final class LaunchActionRouter {
  static let shared = LaunchActionRouter()

  /// The action waiting for the main screen. Observe it; take it with consume().
  private(set) var pending: LaunchAction?

  /// Set by the main screen while it is alive: returns the current one-line status, so
  /// StatusIntent can answer through Siri without bringing the app forward.
  @ObservationIgnored var statusProvider: (@MainActor () -> String)?

  /// How long a request stays valid. Long enough to cover a cold launch and the glasses
  /// connecting; short enough that a forgotten request doesn't fire later.
  let maxAge: TimeInterval

  @ObservationIgnored private var requestedAt: Date?
  @ObservationIgnored private let now: () -> Date

  init(maxAge: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
    self.maxAge = maxAge
    self.now = now
  }

  /// Parks `action` for the main screen, replacing any action still waiting.
  func request(_ action: LaunchAction) {
    requestedAt = now()
    pending = action
  }

  /// Takes the waiting action, or nil if there is none or it expired. Always clears the slot,
  /// so an action runs at most once.
  func consume() -> LaunchAction? {
    defer {
      pending = nil
      requestedAt = nil
    }
    guard let pending, let requestedAt, now().timeIntervalSince(requestedAt) <= maxAge else { return nil }
    return pending
  }
}
