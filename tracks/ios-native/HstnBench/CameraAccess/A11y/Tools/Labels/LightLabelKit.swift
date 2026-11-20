/*
 * LightLabelKit - what the label reader and the light tool share: waiting for the camera, taking a
 * recent frame, and optional haptics
 *
 * Waiting mirrors TextReader.ensureStream: ask the source to get ready, nudge it every 100 ms, say
 * "starting the camera" once, give up after 30 s with a spoken reason. Haptics are a help on the
 * phone (the glasses user may have the phone in a pocket, where a tap still lands): a firm tap when
 * a barcode is found, a lighter one when a colour is named. They are optional: off with the
 * "tools.hapticsEnabled" default set to false, and iOS's own System Haptics switch turns them off.
 */

import Foundation
import UIKit

@MainActor
enum LightLabelKit {
  enum StreamWait: Equatable {
    case ready
    /// An alert or permission prompt is up and the camera screen says it.
    case blocked
    /// Can't start; the line says why.
    case failed(String)
    case cancelled
  }

  static let streamTimeout: Duration = .seconds(30)

  /// Waits for a streaming camera. `isCurrent` false ends the wait (the user moved on).
  static func waitForStream(
    _ source: any ReadFrameSource, isCurrent: () -> Bool, onStarting: () -> Void
  ) async -> StreamWait {
    let deadline = ContinuousClock.now + streamTimeout
    var announced = false
    while isCurrent(), !Task.isCancelled {
      switch source.prepareStreamForReading() {
      case .ready: return .ready
      case .blocked: return .blocked
      case .unavailable(let reason): return .failed(reason)
      case .starting:
        if !announced {
          announced = true
          onStarting()
        }
      }
      if ContinuousClock.now >= deadline { return .failed("The camera didn't start in time. Try again.") }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return .cancelled
  }

  /// The source's latest frame if it's younger than `maxAge`, waiting up to `wait` for one.
  static func recentFrame(_ source: any ReadFrameSource, maxAge: TimeInterval = 1.0, wait: Duration = .milliseconds(1500)) async -> ReadFrame? {
    let deadline = ContinuousClock.now + wait
    while !Task.isCancelled {
      if let frame = source.latestReadFrame, age(of: frame) <= maxAge { return frame }
      if ContinuousClock.now >= deadline { return nil }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }

  static func age(of frame: ReadFrame) -> TimeInterval {
    Double(BenchClock.uptimeNanoseconds() &- frame.arrivedAt) / 1_000_000_000
  }

  // MARK: Haptics

  static let hapticsKey = "tools.hapticsEnabled"

  static var hapticsEnabled: Bool {
    UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
  }

  enum Feel {
    /// A barcode decoded.
    case found
    /// A colour named.
    case locked
    /// Something failed.
    case failed
  }

  static func haptic(_ feel: Feel) {
    guard hapticsEnabled else { return }
    switch feel {
    case .found: UINotificationFeedbackGenerator().notificationOccurred(.success)
    case .locked: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    case .failed: UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }
}
