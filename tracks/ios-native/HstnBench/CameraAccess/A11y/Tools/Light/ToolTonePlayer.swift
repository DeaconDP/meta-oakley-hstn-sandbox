/*
 * ToolTonePlayer - the light probe's continuous gliding tone, and the barcode search's geiger ticks
 *
 * Android's ProbeTone (tools/light/ProbeTone.kt) on iOS. EarconPlayer only plays fixed earcons; the
 * probe needs one unbroken tone whose pitch slides as the user turns, without clicks between
 * updates, and the barcode search needs short ticks at a pitch that varies. This keeps its own
 * AVAudioEngine with:
 *  - an AVAudioSourceNode rendering a sine (plus a little second harmonic, so 220 Hz is still heard
 *    on the phone speaker) with a phase that carries over and the frequency and volume gliding
 *    towards their targets (~60 ms for pitch, ~15 ms for volume);
 *  - an AVAudioPlayerNode for ticks, rendered with EarconSynth like the earcons.
 *
 * Coexisting with A11yAudioSession: the session is shared and A11yAudioSession owns its category and
 * activation. While this player has any owner it takes the session's speech hold on the session's
 * own queue (beginSpeech/endSpeech), so the session is active in our playback category and isn't
 * deactivated under the tone by the idle check. Side effect: other apps' audio is ducked while the
 * probe or the barcode search runs, as while the app speaks. Every engine call runs on that same
 * queue, so session and engine changes are ordered. Speech and earcons mix with the tone; the tone
 * doesn't duck under speech (as on Android).
 *
 * Owners ("light", "labels") say why the engine is up, as EarconPlayer's tick owners do: one tool's
 * stop doesn't silence another's.
 */

import AVFoundation
import os

final class ToolTonePlayer: @unchecked Sendable {
  static let shared = ToolTonePlayer()

  static let defaultVolume = 0.3

  private let audio = A11yAudioSession.shared
  private var queue: DispatchQueue { audio.queue }
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  private let parameters = ToneParameters()

  // Queue-confined.
  private var engine: AVAudioEngine?
  private var tickNode: AVAudioPlayerNode?
  private var owners: Set<String> = []
  private var holdsSession = false
  private var configObserver: NSObjectProtocol?

  private static let logger = Logger(subsystem: "com.deaco.hstnbench", category: "ToolTone")

  private init() {}

  /// Takes the engine and the session for `owner`. Idempotent per owner.
  func begin(owner: String) {
    queue.async { [self] in
      owners.insert(owner)
      startIfNeeded()
    }
  }

  /// Releases `owner`; the engine stops once no owner is left. Silences the tone at once.
  func end(owner: String) {
    queue.async { [self] in
      guard owners.remove(owner) != nil else { return }
      if owners.isEmpty { shutDown() }
    }
  }

  /// Glides the continuous tone to `hz` at `volume` (0 silences it). Needs an owner (begin).
  func setTone(hz: Double, volume: Double = ToolTonePlayer.defaultVolume) {
    parameters.set(hz: hz, volume: min(max(volume, 0), 1))
  }

  /// Fades the continuous tone out within a few milliseconds.
  func silenceTone() {
    parameters.set(hz: nil, volume: 0)
  }

  /// One short tick at `hz` (the geiger tick). Needs an owner (begin).
  func tick(hz: Double, duration: TimeInterval = 0.025, gain: Double = 0.9) {
    let format = format
    queue.async { [self] in
      guard !owners.isEmpty, let tickNode, startEngine(),
        let buffer = EarconSynth.render([EarconNote(hz, duration: duration, gain: gain)], timbre: .bright, format: format)
      else { return }
      tickNode.scheduleBuffer(buffer, at: nil, options: [])
      tickNode.play()
    }
  }

  // MARK: Queue-confined

  private func startIfNeeded() {
    if !holdsSession {
      holdsSession = true
      // Our category, active, and kept active by the idle check while we hold it.
      audio.beginSpeech()
    }
    if engine == nil { build() }
    _ = startEngine()
  }

  private func build() {
    let engine = AVAudioEngine()
    let parameters = parameters
    let sampleRate = format.sampleRate
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
      parameters.render(into: bufferList, frames: Int(frameCount), sampleRate: sampleRate)
      return noErr
    }
    let tickNode = AVAudioPlayerNode()
    engine.attach(source)
    engine.attach(tickNode)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    engine.connect(tickNode, to: engine.mainMixerNode, format: format)
    tickNode.volume = 0.8
    engine.prepare()
    self.engine = engine
    self.tickNode = tickNode
    // A route change (headphones, glasses) stops the engine; start it again if still wanted.
    configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
      [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard !self.owners.isEmpty else { return }
        _ = self.startEngine()
      }
    }
  }

  private func startEngine() -> Bool {
    guard let engine else { return false }
    if engine.isRunning { return true }
    do {
      try engine.start()
      return true
    } catch {
      Self.logger.error("Tool tone engine failed to start: \(error.localizedDescription)")
      return false
    }
  }

  private func shutDown() {
    parameters.set(hz: nil, volume: 0)
    parameters.resetVolumeNow()
    tickNode?.stop()
    engine?.stop()
    if holdsSession {
      holdsSession = false
      audio.endSpeech()
    }
  }
}

/// The tone's targets and running state, shared with the real-time render callback. Plain 64-bit
/// loads and stores, which are atomic on arm64; a torn pair (new pitch, old volume) only lasts one
/// render cycle and glides anyway. No locks on the audio thread.
private final class ToneParameters: @unchecked Sendable {
  private let storage = UnsafeMutablePointer<Double>.allocate(capacity: 5)
  // 0 target Hz, 1 target volume, 2 current Hz, 3 current volume, 4 phase.

  init() {
    storage.initialize(repeating: 0, count: 5)
    storage[0] = 440
    storage[2] = 440
  }

  deinit { storage.deallocate() }

  func set(hz: Double?, volume: Double) {
    if let hz { storage[0] = hz }
    storage[1] = volume
  }

  func resetVolumeNow() {
    storage[3] = 0
  }

  func render(into bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, sampleRate: Double) {
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let targetHz = storage[0]
    let targetVolume = storage[1]
    var hz = storage[2]
    var volume = storage[3]
    var phase = storage[4]
    let pitchStep = 1 - exp(-1 / (0.06 * sampleRate))
    let volumeStep = 1 - exp(-1 / (0.015 * sampleRate))
    let twoPi = 2 * Double.pi
    for frame in 0..<frames {
      // From silence, start at the new pitch instead of gliding up to it.
      if volume < 0.0005 { hz = targetHz }
      hz += (targetHz - hz) * pitchStep
      volume += (targetVolume - volume) * volumeStep
      phase += twoPi * hz / sampleRate
      if phase > twoPi { phase -= twoPi }
      let sample = Float((sin(phase) + 0.3 * sin(2 * phase)) / 1.3 * volume)
      for buffer in buffers {
        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
      }
    }
    storage[2] = hz
    storage[3] = volume
    storage[4] = phase
  }
}
