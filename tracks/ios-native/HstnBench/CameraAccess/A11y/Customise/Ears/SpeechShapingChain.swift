/*
 * SpeechShapingChain - pan, volume and Clear speech for one speech source in an AVAudioEngine
 *
 *   source (mono player) -> pan mixer (stereo) -> dynamics processor -> EQ -> destination
 *
 * The pan mixer is there because AVAudioPlayerNode.pan only works where a player feeds a mixer.
 * The dynamics processor evens out loud and soft syllables; the EQ then cuts low boom, lifts the
 * treble (consonants) and adds the make-up gain, so Clear speech is clearer and a little louder.
 * With Clear speech off both effects are bypassed, which costs nothing audible and adds no latency.
 *
 * Used twice: on the shared earcon engine for the app's own voice (AudioBus), and on
 * CloudVoicePlayer's engine for the natural voice. Not thread-safe: the owner calls it on whatever
 * confines its engine.
 */

import AVFoundation

final class SpeechShapingChain {
  let panMixer = AVAudioMixerNode()
  let dynamics: AVAudioUnitEffect
  let eq = AVAudioUnitEQ(numberOfBands: 2)

  init() {
    let description = AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    dynamics = AVAudioUnitEffect(audioComponentDescription: description)
  }

  /// Attaches the chain to `engine` and wires `source` through it into `destination`.
  func install(
    on engine: AVAudioEngine, source: AVAudioPlayerNode, sourceFormat: AVAudioFormat, destination: AVAudioNode
  ) {
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    engine.attach(panMixer)
    engine.attach(dynamics)
    engine.attach(eq)
    engine.connect(source, to: panMixer, format: sourceFormat)
    engine.connect(panMixer, to: dynamics, format: stereo)
    engine.connect(dynamics, to: eq, format: stereo)
    engine.connect(eq, to: destination, format: stereo)
    configureBands()
    apply(clearSpeech: nil)
  }

  /// Pan, volume and Clear speech from `shape`, for a speech `source`.
  func apply(_ shape: AudioShape, source: AVAudioPlayerNode) {
    source.pan = shape.pan(for: .speech)
    source.volume = shape.speechVolume
    apply(clearSpeech: shape.clearSpeech)
  }

  func apply(clearSpeech: ClearSpeech?) {
    guard let clearSpeech else {
      dynamics.bypass = true
      eq.bypass = true
      eq.globalGain = 0
      return
    }
    setDynamics(threshold: -22, headRoom: 6, attack: 0.002, release: 0.08)
    eq.bands[1].gain = clearSpeech.trebleGainDB
    eq.globalGain = ClearSpeech.makeUpGainDB
    dynamics.bypass = false
    eq.bypass = false
  }

  private func configureBands() {
    let lowCut = eq.bands[0]
    lowCut.filterType = .highPass
    lowCut.frequency = ClearSpeech.lowCutHz
    lowCut.bypass = false
    let treble = eq.bands[1]
    treble.filterType = .highShelf
    treble.frequency = ClearSpeech.shelfHz
    treble.gain = ClearSpeech.defaultTrebleGainDB
    treble.bypass = false
  }

  private func setDynamics(threshold: Float, headRoom: Float, attack: Float, release: Float) {
    let unit = dynamics.audioUnit
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, threshold, 0)
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, headRoom, 0)
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, attack, 0)
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, release, 0)
  }
}
