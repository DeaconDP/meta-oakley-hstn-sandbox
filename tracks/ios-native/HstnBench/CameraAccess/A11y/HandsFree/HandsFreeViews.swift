/*
 * HandsFreeViews - the mode switch, the toolbox's push-to-talk button, and the tools list
 *
 * The switch is large and labelled, on the home screen and in Settings (notes/hands-free-mode.md
 * section 2). The mic button only exists in the toolbox: in hands-free the mic is already open.
 * Styled from A11y/Theme.
 */

import SwiftUI

/// "Hands-free" with a one-line explanation, as a large switch.
struct HandsFreeToggle: View {
  private var voice: VoiceControl { VoiceControl.shared }
  private let preferences = A11yPreferences.shared

  var body: some View {
    Toggle(isOn: Binding(get: { preferences.handsFree }, set: { voice.setHandsFree($0) })) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Hands-free")
          .font(.rounded(.title3, weight: .heavy))
          .foregroundStyle(Theme.ink)
        Text(preferences.handsFree ? "Always listening. Use SpeakUp by voice, screen optional." : "Off. Tap to use, or tap the mic for one command.")
          .font(.rounded(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .tint(Theme.listen)
    .frame(minHeight: 60)
    .accessibilityHint("Runs the whole app by voice, with no need for the screen.")
    .accessibilityIdentifier("hands_free_toggle")
  }
}

/// Toolbox only: listens for one command, with the same words hands-free understands.
struct PushToTalkButton: View {
  private var voice: VoiceControl { VoiceControl.shared }

  var body: some View {
    let listening = voice.isPushToTalkActive
    Button {
      voice.pushToTalk()
    } label: {
      Label(listening ? "Listening… tap to cancel" : "Tap to talk", systemImage: listening ? "waveform" : "mic.fill")
        .font(.rounded(.title3, weight: .heavy))
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(ChunkyButtonStyle(tone: listening ? .blue : .neutral, lipHeight: 5))
    .accessibilityLabel(listening ? "Listening. Tap to cancel." : "Tap to talk")
    .accessibilityHint("Listens for one spoken command, such as read, status or help.")
    .accessibilityIdentifier("push_to_talk_button")
  }
}

/// The mode switch, and the mic button while hands-free is off.
struct HandsFreeControls: View {
  private let preferences = A11yPreferences.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HandsFreeToggle()
      if !preferences.handsFree {
        PushToTalkButton()
      }
    }
    .themeCard()
  }
}

/// The toolbox's list of what SpeakUp can do. Each row does what its spoken command does.
struct ToolboxList: View {
  var tools: [HandsFreeTool] = HandsFreeTool.allCases
  var perform: (HandsFreeTool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Tools")
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      ForEach(tools) { tool in
        Button {
          perform(tool)
        } label: {
          PathTileLabel(icon: tool.icon, title: tool.title, value: tool.summary, coin: .blue, say: tool.command)
        }
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("tool_\(tool.rawValue)")
      }
    }
  }
}
