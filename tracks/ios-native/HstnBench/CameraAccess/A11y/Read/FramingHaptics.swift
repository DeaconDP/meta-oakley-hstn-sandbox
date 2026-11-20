/*
 * FramingHaptics - light taps that match the spoken framing guidance (V0 "Phone-specific UX")
 *
 * Spoken guidance stays; haptics add to it, so a page can be lined up by feel while the voice is
 * quiet. Two places give cues:
 * - Each read's framing verdict (TextReader), as the guidance is spoken.
 * - FramingAssist: while Read text is open and the phone camera is already running (after a read),
 *   and nothing is being read, it checks the latest frame about every 0.7 s with Vision's fast
 *   recognizer and taps as the page moves into place. It never starts the camera by itself, so
 *   there is no camera prompt and no camera light until the user reads.
 *
 * Cues (HapticCueMapper, pure):
 * - Page found: text comes into view (one medium tap).
 * - Edge cut off: text runs off one side (two light taps). The voice says which way.
 * - Too close: text runs off opposite sides (three quick firm taps).
 * - Too far: the print is too small (one soft tap).
 * - Lost: the text left the frame (one light tap).
 * - Dark: before the dark warning (the system warning pattern).
 * - Locked: well framed (one firm tap), repeated every 2 s while it stays framed. A steady tap,
 *   never a buzz.
 * HapticPacer (pure) keeps it calm: at least 0.4 s between any two cues, the same cue no more than
 * every 3 s (locked: 2 s, dark: 10 s).
 *
 * Off with the setting (PhoneReadingSettings.hapticsEnabled), and iOS itself skips UIKit feedback
 * when System Haptics is off, on phones without a Taptic Engine, and while the camera records
 * audio. Nothing here runs for the glasses.
 */

import CoreHaptics
import Observation
import UIKit

enum HapticCue: String, Equatable, Sendable {
  case locked
  case pageFound
  case edgeCut
  case tooClose
  case tooFar
  case lost
  case dark
}

enum HapticCueMapper {
  /// The cue for a framing verdict. `previous` is the verdict before it (nil for none), so "page
  /// found" and "lost" are changes, not states.
  static func cue(for verdict: FramingVerdict, previous: FramingVerdict?) -> HapticCue? {
    let hadText = previous.map(showsText) ?? false
    switch verdict {
    case .good:
      return .locked
    case .cutOff(let edges):
      let opposite = (edges.contains(.left) && edges.contains(.right)) || (edges.contains(.top) && edges.contains(.bottom))
      if opposite { return .tooClose }
      return hadText ? .edgeCut : .pageFound
    case .tooSmall:
      return hadText ? .tooFar : .pageFound
    case .noText:
      return hadText ? .lost : nil
    case .tooDark:
      return .dark
    case .tooBlurry:
      return nil
    }
  }

  /// Text is in view, readable or not.
  static func showsText(_ verdict: FramingVerdict) -> Bool {
    switch verdict {
    case .good, .cutOff, .tooSmall: true
    case .noText, .tooDark, .tooBlurry: false
    }
  }
}

/// Rate limits cues. Pure: time is passed in (seconds, any monotonic clock).
struct HapticPacer: Equatable {
  static let minGap: TimeInterval = 0.4
  static let sameCueRepeat: TimeInterval = 3.0
  static let lockedRepeat: TimeInterval = 2.0
  static let darkRepeat: TimeInterval = 10.0

  private(set) var lastCue: HapticCue?
  private(set) var lastAt: TimeInterval = -.infinity

  /// The cue to play now, or nil to stay still.
  mutating func allow(_ cue: HapticCue?, at now: TimeInterval) -> HapticCue? {
    guard let cue else { return nil }
    guard now - lastAt >= Self.minGap else { return nil }
    if cue == lastCue, now - lastAt < Self.repeatInterval(cue) { return nil }
    lastCue = cue
    lastAt = now
    return cue
  }

  static func repeatInterval(_ cue: HapticCue) -> TimeInterval {
    switch cue {
    case .locked: lockedRepeat
    case .dark: darkRepeat
    default: sameCueRepeat
    }
  }

  mutating func reset() {
    lastCue = nil
    lastAt = -.infinity
  }
}

/// Plays a cue on the Taptic Engine.
@MainActor
final class ReadHaptics {
  static let shared = ReadHaptics()

  /// Cues played, newest last (for tests and the log).
  private(set) var played: [HapticCue] = []
  var isEnabled: @MainActor () -> Bool = { PhoneReadingSettings.shared.hapticsEnabled }
  private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
  private let light = UIImpactFeedbackGenerator(style: .light)
  private let medium = UIImpactFeedbackGenerator(style: .medium)
  private let rigid = UIImpactFeedbackGenerator(style: .rigid)
  private let soft = UIImpactFeedbackGenerator(style: .soft)
  private let notice = UINotificationFeedbackGenerator()

  func play(_ cue: HapticCue) {
    guard isEnabled() else { return }
    played.append(cue)
    if played.count > 50 { played.removeFirst(played.count - 50) }
    BenchClock.shared.note("haptic cue=\(cue.rawValue)")
    guard supported else { return }
    switch cue {
    case .locked: rigid.impactOccurred(intensity: 1.0)
    case .pageFound: medium.impactOccurred(intensity: 0.8)
    case .edgeCut: taps(light, count: 2, gap: 0.12, intensity: 0.7)
    case .tooClose: taps(rigid, count: 3, gap: 0.09, intensity: 0.8)
    case .tooFar: soft.impactOccurred(intensity: 0.9)
    case .lost: light.impactOccurred(intensity: 0.5)
    case .dark: notice.notificationOccurred(.warning)
    }
  }

  private func taps(_ generator: UIImpactFeedbackGenerator, count: Int, gap: TimeInterval, intensity: CGFloat) {
    generator.impactOccurred(intensity: intensity)
    Task { @MainActor in
      for _ in 1..<count {
        try? await Task.sleep(for: .seconds(gap))
        generator.impactOccurred(intensity: intensity)
      }
    }
  }
}

/// Haptic cues while lining up a page with the phone camera already running.
@MainActor
@Observable
final class FramingAssist {
  static let shared = FramingAssist()

  /// How often the latest frame is checked while lining up.
  static let interval: Duration = .milliseconds(700)

  private(set) var isRunning = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private weak var source: (any ReadFrameSource)?
  @ObservationIgnored private var pacer = HapticPacer()
  @ObservationIgnored private var lastVerdict: FramingVerdict?
  @ObservationIgnored var haptics: ReadHaptics = .shared
  @ObservationIgnored var reader: TextReader = .shared

  /// Read text opened: watch frames whenever the phone camera is running.
  func start(source: any ReadFrameSource) {
    stop()
    self.source = source
    isRunning = true
    task = Task { [weak self] in await self?.loop() }
  }

  func stop() {
    task?.cancel()
    task = nil
    isRunning = false
    lastVerdict = nil
  }

  /// A read's framing verdict, as its guidance is spoken.
  func readVerdict(_ verdict: FramingVerdict) {
    cue(verdict)
  }

  /// Before the dark warning.
  func darkWarning() {
    if let cue = pacer.allow(.dark, at: Self.now()) { haptics.play(cue) }
  }

  private func cue(_ verdict: FramingVerdict) {
    let cue = HapticCueMapper.cue(for: verdict, previous: lastVerdict)
    lastVerdict = verdict
    if let allowed = pacer.allow(cue, at: Self.now()) { haptics.play(allowed) }
  }

  private func loop() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: Self.interval)
      guard !Task.isCancelled else { return }
      guard haptics.isEnabled(), let source, source.cameraKind == .phone, !reader.isActive,
        let frame = source.latestReadFrame,
        Double(BenchClock.uptimeNanoseconds() &- frame.arrivedAt) / 1e9 <= TextReader.maxFrameAge
      else {
        continue
      }
      let image = frame.image
      let recognized = await Task.detached(priority: .utility) { try? TextRecognizer.recognize(image, fast: true) }.value
      guard !Task.isCancelled, let recognized, !reader.isActive else { continue }
      cue(Self.framingVerdict(recognized))
    }
  }

  /// The fast recognizer's confidence is lower than the accurate one's, so only geometry, size and
  /// light count while lining up.
  static func framingVerdict(_ recognized: RecognizedFrame) -> FramingVerdict {
    var page = recognized.page
    page.lines = page.lines.map { line in
      ReadLine(words: line.words.map { ReadWord(text: $0.text, confidence: 1) }, box: line.box)
    }
    return FramingAdvisor.assess(page, quality: recognized.quality)
  }

  private static func now() -> TimeInterval {
    Double(BenchClock.uptimeNanoseconds()) / 1e9
  }
}
