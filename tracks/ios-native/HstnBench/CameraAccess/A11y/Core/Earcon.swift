/*
 * Earcon - the short state tones the app plays before (or instead of) speech
 *
 * Earcons are faster than words and don't collide with VoiceOver speech (notes/a11y-prior-art.md,
 * "Audio-first UX guidelines"). Each one is under 300 ms and has its own contour, so they can be
 * told apart without learning absolute pitches: rising means something good started or finished,
 * falling means something stopped or failed. They are synthesized here instead of shipped as
 * asset files, so tuning one is a code change and there is nothing to load at play time.
 */

import AVFoundation

enum Earcon: String, CaseIterable, Sendable {
  case ready
  case connected
  case disconnected
  case listening
  case capturing
  case working
  case done
  case error
  case uncertain
  case attention

  /// What the "learn the sounds" tutorial says after playing the earcon.
  var spokenMeaning: String {
    switch self {
    case .ready: "This sound means the app is ready."
    case .connected: "This sound means the glasses connected."
    case .disconnected: "This sound means the glasses disconnected."
    case .listening: "This sound means the app is listening to you."
    case .capturing: "This sound means the glasses took a photo."
    case .working: "This sound means the app is working on it. While you wait, you'll hear a soft tick about every second."
    case .done: "This sound means the answer is ready."
    case .error: "This sound means something went wrong. You'll hear what happened next."
    case .uncertain: "This sound means the app isn't sure. Treat what follows with care."
    case .attention: "This sound means the app needs you to do something."
    }
  }

  /// Total length, including the gaps between notes. Used to start speech after the tone ends.
  var duration: TimeInterval {
    notes.reduce(0) { $0 + $1.duration + $1.gap }
  }

  /// Pitch C5 = 523 Hz. Steps are kept to simple intervals so the contours read as "up" or "down"
  /// even through the glasses' small speakers.
  var notes: [EarconNote] {
    switch self {
    case .ready:
      [EarconNote(880, duration: 0.16)]
    case .connected:
      [EarconNote(523, duration: 0.07, gap: 0.015), EarconNote(659, duration: 0.07, gap: 0.015), EarconNote(784, duration: 0.1)]
    case .disconnected:
      [EarconNote(784, duration: 0.07, gap: 0.015), EarconNote(659, duration: 0.07, gap: 0.015), EarconNote(523, duration: 0.1)]
    case .listening:
      [EarconNote(587, to: 880, duration: 0.14)]
    case .capturing:
      [EarconNote(1760, duration: 0.025, gap: 0.045), EarconNote(1760, duration: 0.025)]
    case .working:
      [EarconNote(440, duration: 0.09, gain: 0.7)]
    case .done:
      [EarconNote(523, duration: 0.09, gap: 0.02), EarconNote(784, duration: 0.14)]
    case .error:
      [EarconNote(440, duration: 0.11, gap: 0.02), EarconNote(330, duration: 0.15)]
    case .uncertain:
      [EarconNote(622, duration: 0.1, gap: 0.05), EarconNote(622, duration: 0.11, vibrato: 0.03)]
    case .attention:
      [EarconNote(1319, duration: 0.04, gap: 0.035), EarconNote(1319, duration: 0.04, gap: 0.035), EarconNote(1319, duration: 0.04)]
    }
  }

  var timbre: EarconTimbre {
    switch self {
    case .ready, .connected, .disconnected, .working, .done, .uncertain: .soft
    case .listening, .capturing, .attention: .bright
    case .error: .buzzy
    }
  }
}

/// One note of an earcon: a pitch glide from `from` to `to` Hz, then `gap` seconds of silence.
struct EarconNote: Sendable {
  var from: Double
  var to: Double
  var duration: TimeInterval
  var gap: TimeInterval
  var gain: Double
  /// Pitch wobble depth as a fraction of the frequency (0.03 = 3 %), at 7 Hz.
  var vibrato: Double

  init(_ from: Double, to: Double? = nil, duration: TimeInterval, gap: TimeInterval = 0, gain: Double = 1, vibrato: Double = 0) {
    self.from = from
    self.to = to ?? from
    self.duration = duration
    self.gap = gap
    self.gain = gain
    self.vibrato = vibrato
  }
}

/// Harmonic recipes. Pure sines vanish on small speakers, so every timbre has some overtones.
enum EarconTimbre: Sendable {
  case soft
  case bright
  case buzzy

  /// Relative amplitudes of harmonics 1, 2, 3...
  var harmonics: [Double] {
    switch self {
    case .soft: [1, 0.25, 0.08]
    case .bright: [1, 0.45, 0.25, 0.12]
    case .buzzy: [1, 0, 0.4, 0, 0.25, 0, 0.12]
    }
  }
}

enum EarconSynth {
  /// Peak sample level. Modest on purpose: earcons sit under speech and next to VoiceOver.
  static let peak: Double = 0.35

  /// Renders `notes` into a mono float buffer in `format`.
  static func render(_ notes: [EarconNote], timbre: EarconTimbre, format: AVAudioFormat, length: TimeInterval? = nil) -> AVAudioPCMBuffer? {
    let sampleRate = format.sampleRate
    let total = length ?? notes.reduce(0) { $0 + $1.duration + $1.gap }
    let frameCount = AVAudioFrameCount((total * sampleRate).rounded(.up))
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = frameCount
    let out = channels[0]
    for frame in 0..<Int(frameCount) { out[frame] = 0 }

    let harmonics = timbre.harmonics
    let normalization = harmonics.reduce(0, +)
    // Short attack avoids clicks; the release is longer so notes ring off instead of stopping dead.
    let attackFrames = Int(0.005 * sampleRate)
    var start = length.map { Int(($0 - notes.reduce(0) { $0 + $1.duration + $1.gap }) * sampleRate) } ?? 0
    start = max(0, start)

    for note in notes {
      let noteFrames = Int(note.duration * sampleRate)
      let releaseFrames = max(1, min(noteFrames / 2, Int(0.04 * sampleRate)))
      var phase = 0.0
      for i in 0..<noteFrames where start + i < Int(frameCount) {
        let progress = Double(i) / Double(noteFrames)
        let seconds = Double(i) / sampleRate
        var frequency = note.from + (note.to - note.from) * progress
        if note.vibrato > 0 {
          frequency *= 1 + note.vibrato * sin(2 * .pi * 7 * seconds)
        }
        phase += 2 * .pi * frequency / sampleRate
        var sample = 0.0
        for (index, amplitude) in harmonics.enumerated() where amplitude > 0 {
          sample += amplitude * sin(phase * Double(index + 1))
        }
        var envelope = 1.0
        if i < attackFrames { envelope = Double(i) / Double(attackFrames) }
        let fromEnd = noteFrames - i
        if fromEnd < releaseFrames {
          envelope *= 0.5 * (1 - cos(.pi * Double(fromEnd) / Double(releaseFrames)))
        }
        out[start + i] = Float(sample / normalization * envelope * note.gain * peak)
      }
      start += noteFrames + Int(note.gap * sampleRate)
    }
    return buffer
  }

  /// One second of audio with a quiet click at the end, looped while the app is working. The click
  /// sits at the end so the first one lands a second after the "working" earcon, not on top of it.
  static func renderTick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
    render([EarconNote(1500, duration: 0.02, gain: 0.35)], timbre: .soft, format: format, length: 1.0)
  }
}
