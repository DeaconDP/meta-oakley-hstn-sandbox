/*
 * EarsSettingsSection - "Your ears" on screen, for the settings screen to embed
 *
 * Every control goes through EarsArea, like the voice commands, so a change is spoken, can be
 * undone, and is refused while settings are locked. The spoken line is the same one voice gets.
 */

import SwiftUI

struct EarsSettingsSection: View {
  private var area: EarsArea { EarsArea.shared }
  private var conversation: ConversationMode { ConversationMode.shared }

  var body: some View {
    CustomiseHeader(title: "Your ears")
    Text(area.isMono ? "Mono is on: left and right are marked by pitch." : "Stereo")
      .customiseLabel(id: "ears_mono_status")

    VStack(alignment: .leading, spacing: 4) {
      Text("Balance: \(EarsArea.balanceWords(area.values.balance))")
        .customiseLabel(id: "ears_balance_label")
      Slider(
        value: Binding(
          get: { Double(area.values.balance) },
          set: { speak(area.setBalance(Float($0))) }),
        in: -1...1, step: Double(EarsArea.balanceStep)
      ) {
        Text("Balance")
      } minimumValueLabel: {
        Text("L")
      } maximumValueLabel: {
        Text("R")
      }
      .accessibilityValue(EarsArea.balanceWords(area.values.balance))
      .accessibilityIdentifier("ears_balance_slider")
    }

    ForEach(SoundKind.allCases, id: \.self) { kind in
      VStack(alignment: .leading, spacing: 4) {
        Text(Self.routeTitle(kind)).customiseLabel(id: "ears_route_label_\(kind.rawValue)")
        Picker(
          Self.routeTitle(kind),
          selection: Binding(
            get: { area.values.route(for: kind) },
            set: { speak(area.setRoute($0, for: [kind])) })
        ) {
          ForEach(EarRoute.allCases, id: \.self) { route in
            Text(route.title).tag(route)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ears_route_\(kind.rawValue)")
      }
    }

    CustomiseToggle(
      title: "I use mono", hint: "For one earbud or a mono speaker. Left and right are marked by pitch instead.",
      id: "ears_mono_toggle", isOn: area.values.userMono
    ) { speak(area.setUserMono($0)) }

    CustomiseToggle(
      title: "Clear speech", hint: "Makes SpeakUp's voice a little slower, steadier and brighter.",
      id: "ears_clear_speech_toggle", isOn: area.values.clearSpeech
    ) { speak(area.setClearSpeech($0)) }

    CustomButton(title: "Check clear speech", style: .secondary, isDisabled: ClarityCheck.shared.isRunning) {
      speak(ClarityCheck.shared.start())
    }
    .accessibilityHint("Plays a sentence two ways and asks which is clearer, A or B. Answer by voice.")
    .accessibilityIdentifier("ears_clarity_check_button")

    CustomButton(
      title: conversation.isActive ? "Carry on talking" : "Someone's talking to me", style: .secondary, isDisabled: false
    ) {
      speak(conversation.isActive ? conversation.end() : conversation.start())
    }
    .accessibilityHint("Conversation mode: SpeakUp goes quiet and only uses sounds until you carry on.")
    .accessibilityIdentifier("ears_conversation_button")
  }

  private static func routeTitle(_ kind: SoundKind) -> String {
    switch kind {
    case .speech: "Speech in"
    case .earcon: "Sounds in"
    case .alert: "Alerts in"
    }
  }

  private func speak(_ line: String) {
    Announcer.shared.say(line)
  }
}

// MARK: - Shared pieces for the Ears and Sounds sections

struct CustomiseHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.rounded(.headline, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A toggle whose change goes through an area method (so it can be refused and undone) rather than
/// straight into a binding.
struct CustomiseToggle: View {
  let title: String
  let hint: String
  let id: String
  let isOn: Bool
  let change: (Bool) -> Void

  var body: some View {
    Toggle(isOn: Binding(get: { isOn }, set: { change($0) })) {
      Text(title)
        .font(.rounded(.body, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(minHeight: 60)
    .accessibilityHint(hint)
    .accessibilityIdentifier(id)
  }
}

extension Text {
  func customiseLabel(id: String) -> some View {
    self
      .font(.rounded(.subheadline, weight: .bold))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(id)
  }
}
