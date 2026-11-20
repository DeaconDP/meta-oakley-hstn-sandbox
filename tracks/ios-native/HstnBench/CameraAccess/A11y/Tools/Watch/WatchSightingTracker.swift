/*
 * WatchSightingTracker - when to speak while watching, so each sighting is heard once
 *
 * Ported from Android's tools/watch/SightingTracker.kt. OCR runs on every frame (about 2 a second),
 * but the user should hear "42, on your right" once when it comes into view, "gone" once when it
 * has been out of view for a few seconds, and again only if it comes back. A single frame is never
 * enough: the target must be in at least `need` of the last `window` frames, so one misread frame
 * doesn't raise a false alarm. Near misses ("I see 24, not 42") need the same agreement, are said
 * at most every `nearMissGapMs`, the same one at most every `sameNearMissGapMs`, and never while
 * the target is in view.
 *
 * Also here: WatchPosition (left / ahead / right and close / far), WatchViewIssueWatch (lens covered
 * or too dark: said when it starts, now and then while it lasts, and when it clears), WatchPaceWatch
 * (OCR can't keep up) and WatchViewCheck (covered / dark from a small brightness grid). Times are
 * milliseconds from any monotonic clock. Pure, unit-tested.
 */

import Foundation

enum WatchEvent: Equatable, Sendable {
  case appeared(WatchSpot)
  case gone
  case nearMiss(String)
}

enum WatchWhereAnswer: Equatable, Sendable {
  case inView(WatchSpot)
  case lastSeen(WatchSpot, agoMs: Int64)
  case notSeen
}

struct WatchSightingTracker {
  var window = 4
  var need = 2
  /// Out of view this long before "gone".
  var goneAfterMs: Int64 = 4_000
  /// Frames older than this don't count towards `need` (slow OCR).
  var maxAgeMs: Int64 = 8_000
  var nearMissGapMs: Int64 = 20_000
  var sameNearMissGapMs: Int64 = 60_000

  private struct Frame {
    var atMs: Int64
    var hit: Bool
    var nearMiss: String?
  }

  private var recent: [Frame] = []
  private(set) var inView = false
  private var lastSpot: WatchSpot?
  private var lastSeenMs: Int64 = 0
  private var lastNearMissMs: Int64 = .min / 2
  private var nearMissSaid: [String: Int64] = [:]

  init(
    window: Int = 4, need: Int = 2, goneAfterMs: Int64 = 4_000, maxAgeMs: Int64 = 8_000, nearMissGapMs: Int64 = 20_000,
    sameNearMissGapMs: Int64 = 60_000
  ) {
    self.window = window
    self.need = need
    self.goneAfterMs = goneAfterMs
    self.maxAgeMs = maxAgeMs
    self.nearMissGapMs = nearMissGapMs
    self.sameNearMissGapMs = sameNearMissGapMs
  }

  /// Forget everything (new target, or the camera came back after a gap).
  mutating func reset() {
    recent.removeAll()
    inView = false
    lastSpot = nil
    nearMissSaid.removeAll()
    lastNearMissMs = .min / 2
  }

  /// One frame's result at `nowMs`. Returns what to say, usually nothing.
  mutating func onFrame(nowMs: Int64, match: WatchFrameMatch) -> [WatchEvent] {
    recent.append(Frame(atMs: nowMs, hit: match.hit != nil, nearMiss: match.nearMiss))
    while recent.count > window { recent.removeFirst() }
    while let first = recent.first, nowMs - first.atMs > maxAgeMs { recent.removeFirst() }

    var events: [WatchEvent] = []
    if let hit = match.hit {
      if !inView, recent.filter(\.hit).count >= need {
        inView = true
        events.append(.appeared(hit))
      }
      if inView {
        lastSpot = hit
        lastSeenMs = nowMs
      }
      return events
    }

    if inView, nowMs - lastSeenMs >= goneAfterMs {
      inView = false
      // Old hits mustn't help a single new frame count as "back".
      recent.removeAll()
      events.append(.gone)
    }

    if let near = match.nearMiss, !inView {
      let agreed = recent.filter { $0.nearMiss == near }.count >= need
      let sameOK = nowMs - (nearMissSaid[near] ?? .min / 2) >= sameNearMissGapMs
      if agreed, sameOK, nowMs - lastNearMissMs >= nearMissGapMs {
        lastNearMissMs = nowMs
        nearMissSaid[near] = nowMs
        events.append(.nearMiss(near))
      }
    }
    return events
  }

  func whereIs(nowMs: Int64) -> WatchWhereAnswer {
    guard let spot = lastSpot else { return .notSeen }
    return inView ? .inView(spot) : .lastSeen(spot, agoMs: nowMs - lastSeenMs)
  }
}

enum WatchSide: Equatable, Sendable { case left, ahead, right }

enum WatchNearness: Equatable, Sendable { case close, far }

enum WatchPosition {
  /// Where straight ahead falls in the glasses' frame. Their camera sits at the front left, so
  /// something straight ahead is a little right of the picture's centre. An estimate (Android).
  static let glassesCentreX = 0.53
  /// The phone's camera is held in front of the user: the picture's centre is ahead.
  static let phoneCentreX = 0.5
  /// How far from the centre still counts as "ahead". The portrait frame is narrow.
  static let aheadHalfWidth = 0.16
  /// Text at least this share of the frame's height is "close"; this small or less, "far off".
  static let closeHeight = 0.10
  static let farHeight = 0.025

  static func centreX(for camera: CameraKind) -> Double {
    camera == .phone ? phoneCentreX : glassesCentreX
  }

  static func side(x: Double, centre: Double = glassesCentreX) -> WatchSide {
    if x < centre - aheadHalfWidth { return .left }
    if x > centre + aheadHalfWidth { return .right }
    return .ahead
  }

  static func nearness(heightFraction: Double) -> WatchNearness? {
    if heightFraction >= closeHeight { return .close }
    if heightFraction <= farHeight { return .far }
    return nil
  }
}

/// A problem with the picture that stops reading signs.
enum WatchViewIssue: Equatable, Sendable { case covered, tooDark }

enum WatchViewIssueEvent: Equatable, Sendable {
  case started(WatchViewIssue)
  case stillThere(WatchViewIssue)
  case cleared
}

/// Says a view problem once it lasts `confirmFrames` frames, repeats it every `repeatMs`, and says
/// when it clears.
struct WatchViewIssueWatch {
  var confirmFrames = 2
  var repeatMs: Int64 = 45_000

  private var candidate: WatchViewIssue?
  private var count = 0
  private var clearCount = 0
  private(set) var current: WatchViewIssue?
  private var saidMs: Int64 = 0

  init(confirmFrames: Int = 2, repeatMs: Int64 = 45_000) {
    self.confirmFrames = confirmFrames
    self.repeatMs = repeatMs
  }

  mutating func reset() {
    candidate = nil
    count = 0
    clearCount = 0
    current = nil
  }

  mutating func onFrame(nowMs: Int64, issue: WatchViewIssue?) -> WatchViewIssueEvent? {
    guard let issue else {
      candidate = nil
      count = 0
      guard current != nil else { return nil }
      clearCount += 1
      guard clearCount >= confirmFrames else { return nil }
      current = nil
      clearCount = 0
      return .cleared
    }
    clearCount = 0
    if current != nil {
      // Covered and dark look alike; keep the one already said unless it's been a while.
      guard nowMs - saidMs >= repeatMs else { return nil }
      current = issue
      saidMs = nowMs
      return .stillThere(issue)
    }
    if issue == candidate {
      count += 1
    } else {
      candidate = issue
      count = 1
    }
    guard count >= confirmFrames else { return nil }
    current = issue
    saidMs = nowMs
    return .started(issue)
  }
}

/// Is OCR keeping up? Call after each processed frame. Returns the seconds between frames once
/// (and again after it recovered) when the average gap over `samples` frames exceeds `slowMs`.
struct WatchPaceWatch {
  var slowMs: Int64 = 3_000
  var samples = 4

  private var gaps: [Int64] = []
  private var lastMs: Int64?
  private var warned = false

  init(slowMs: Int64 = 3_000, samples: Int = 4) {
    self.slowMs = slowMs
    self.samples = samples
  }

  mutating func reset() {
    gaps.removeAll()
    lastMs = nil
  }

  var averageGapMs: Int64? { gaps.isEmpty ? nil : gaps.reduce(0, +) / Int64(gaps.count) }

  mutating func onFrameDone(nowMs: Int64) -> Int? {
    if let lastMs { gaps.append(nowMs - lastMs) }
    lastMs = nowMs
    while gaps.count > samples { gaps.removeFirst() }
    guard gaps.count >= samples else { return nil }
    let average = gaps.reduce(0, +) / Int64(gaps.count)
    if average > slowMs, !warned {
      warned = true
      return Int((average + 500) / 1000)
    }
    if average < slowMs * 2 / 3 { warned = false }
    return nil
  }
}

/// Covered or too dark, from a coarse grid of brightness samples (0...255). The same rule as
/// Android's ImageCheck, keeping only what stops reading signs: a street isn't a page, so "nothing
/// in view", glare and "partly blocked" are normal here.
enum WatchViewCheck {
  /// Even the brightest 5 % below this: something is over the lens.
  static let coveredBelow = 30
  /// Even the brightest 5 % below this: too dark to make out signs.
  static let darkBelow = 85

  static func issue(luma: [UInt8]) -> WatchViewIssue? {
    guard luma.count >= 16 else { return nil }
    let sorted = luma.sorted()
    let p95 = Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    if p95 < coveredBelow { return .covered }
    if p95 < darkBelow { return .tooDark }
    return nil
  }
}
