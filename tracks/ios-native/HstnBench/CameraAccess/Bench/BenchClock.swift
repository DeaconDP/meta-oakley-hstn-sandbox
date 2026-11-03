/*
 * BenchClock - step-2 benchmark timings
 *
 * Records monotonic timestamps for each benchmark milestone and logs the elapsed time between a
 * start mark and its end mark. Every result line goes to the unified log under subsystem
 * "com.deaco.hstnbench", category "HstnBench", with the same key=value layout as the Android
 * track. Lines are logged at notice level so they persist and can be scraped with
 * `log show --predicate 'category == "HstnBench"'`.
 */

import Foundation
import os

final class BenchClock: @unchecked Sendable {
  static let shared = BenchClock()

  private let logger = Logger(subsystem: "com.deaco.hstnbench", category: "HstnBench")
  private let lock = NSLock()
  // Guarded by [lock].
  private var marks: [String: UInt64] = [:]

  /// Records the start of `metric`, replacing any earlier unfinished start.
  func start(_ metric: String) {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.withLock { marks[metric] = now }
  }

  /// Logs the time since `start` for `metric`. Does nothing if `metric` has no pending start.
  func end(_ metric: String, detail: String = "") {
    let now = DispatchTime.now().uptimeNanoseconds
    guard let startedAt = lock.withLock({ marks.removeValue(forKey: metric) }) else { return }
    let elapsedMs = (now - startedAt) / 1_000_000
    let suffix = detail.isEmpty ? "" : " \(detail)"
    logger.notice("metric=\(metric, privacy: .public) ms=\(elapsedMs, privacy: .public)\(suffix, privacy: .public)")
  }

  /// Logs a value measured elsewhere (a duration between two callbacks timestamped separately,
  /// or an age) in the same `metric=... ms=...` layout, so bench.sh summarises it too.
  func record(_ metric: String, ms: Int, detail: String = "") {
    let suffix = detail.isEmpty ? "" : " \(detail)"
    logger.notice("metric=\(metric, privacy: .public) ms=\(max(0, ms), privacy: .public)\(suffix, privacy: .public)")
  }

  /// Monotonic now, in the same clock as start/end, for callers that timestamp themselves.
  static func uptimeNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  func note(_ message: String) {
    logger.notice("\(message, privacy: .public)")
  }
}
