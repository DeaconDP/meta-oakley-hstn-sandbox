/*
 * SoundsSettingsSection - "Sounds" on screen, for the settings screen to embed
 *
 * Earcons on/off, earcon volume, voice volume, earcons only, and say it instead of beeping. Every
 * control goes through SoundsArea, so changes are spoken, undoable and refused while locked.
 */

import SwiftUI

struct SoundsSettingsSection: View {
  private var area: SoundsArea { SoundsArea.shared }

  var body: some View {
    CustomiseHeader(title: "Sounds")

    CustomiseToggle(
      title: "Earcons", hint: "Short tones for ready, done, problems and listening.", id: "sounds_earcons_toggle",
      isOn: area.values.earconsOn
    ) { speak(area.setEarcons(on: $0)) }

    volumeSlider(
      title: "Sounds volume", id: "sounds_earcon_volume", value: area.values.earconVolume,
      range: SoundsArea.minimumEarconVolume...1
    ) { speak(area.setEarconVolume($0)) }

    volumeSlider(
      title: "Voice volume", id: "sounds_speech_volume", value: area.values.speechVolume,
      range: SoundsArea.minimumSpeechVolume...1
    ) { speak(area.setSpeechVolume($0)) }

    CustomiseToggle(
      title: "Earcons only", hint: "For familiar things, just the sound. Answers are still spoken.",
      id: "sounds_earcons_only_toggle", isOn: area.values.earconsOnly
    ) { speak(area.setEarconsOnly($0)) }

    CustomiseToggle(
      title: "Say it instead of beeping", hint: "While you learn the sounds, says what each one means instead.",
      id: "sounds_say_instead_toggle", isOn: area.values.sayInsteadOfBeeping
    ) { speak(area.setSayInsteadOfBeeping($0)) }
  }

  private func volumeSlider(
    title: String, id: String, value: Float, range: ClosedRange<Float>, change: @escaping (Float) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(title): \(SoundsArea.percent(value))").customiseLabel(id: "\(id)_label")
      Slider(
        value: Binding(get: { Double(value) }, set: { change(Float($0)) }),
        in: Double(range.lowerBound)...Double(range.upperBound), step: Double(SoundsArea.volumeStep)
      ) {
        Text(title)
      }
      .accessibilityValue(SoundsArea.percent(value))
      .accessibilityIdentifier(id)
    }
  }

  private func speak(_ line: String) {
    Announcer.shared.say(line)
  }
}
