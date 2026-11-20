/*
 * LaunchActionRouter - hands a screen-free launch (Siri, Shortcuts, Back Tap, Action Button) to
 * the main screen
 *
 * An App Intent can run before any view exists (cold launch) or while the main screen is behind
 * onboarding, so it can't call the camera view model directly. It parks the action here; the main
 * screen observes `pending` and runs it once it can. One slot, latest wins: two quick "read"
 * requests mean one read, not two.
 *
 * A request expires after `maxAge`, so an action that waited behind onboarding or a long connect
 * doesn't fire minutes later when the user has moved on.
 */

import Foundation
import Observation

enum LaunchAction: String, Sendable, CaseIterable {
  /// Read the text in view aloud, word for word (TextReader).
  case read
  /// Speak the one-line readiness status ("Ready.", "Glasses aren't connected...").
  case status
  /// Repeat the last spoken line.
  case repeatLast
  /// Open one of the everyday tools (SpeakUpTool). `.read` stays the one-step "read now".
  case openMail
  case openLabels
  case openWatch
  case openAsk
  case openLight
  /// Read pages that came in from outside (share sheet, Photos, Files): ImportedReading.
  case readImported

  /// The tool this action opens, if it opens one.
  var tool: ToolID? {
    switch self {
    case .openMail: .mail
    case .openLabels: .labels
    case .openWatch: .watch
    case .openAsk: .ask
    case .openLight: .light
    case .read, .status, .repeatLast, .readImported: nil
    }
  }

  /// The action that opens `tool`. Read text maps to `.read`.
  static func open(_ tool: ToolID) -> LaunchAction {
    switch tool {
    case .read: .read
    case .mail: .openMail
    case .labels: .openLabels
    case .watch: .openWatch
    case .ask: .openAsk
    case .light: .openLight
    }
  }
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
