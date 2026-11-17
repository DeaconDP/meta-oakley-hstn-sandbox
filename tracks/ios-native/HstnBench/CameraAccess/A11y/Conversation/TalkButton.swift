/*
 * TalkButton - starts and ends a Conversation, and shows its last two lines in large print
 *
 * Sits under Read on the camera screen. Blue (the Listen family), so Read stays the only yellow
 * action. The voice command "talk" does the same thing; this is for sighted helpers, low-vision
 * users and VoiceOver. While talking, the last thing each side said is shown, so a helper can
 * follow along and a low-vision user can check a word.
 */

import SwiftUI

struct TalkButton: View {
  private var conversation: Conversation { Conversation.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.md) {
      Button {
        conversation.toggle()
      } label: {
        PathTileLabel(
          icon: conversation.isActive ? "stop.circle" : "bubble.left.and.bubble.right",
          title: conversation.isActive ? "End conversation" : "Talk about it",
          value: statusText, coin: .neutral, say: conversation.isActive ? nil : .talk)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .blue, lipHeight: 5, radius: Theme.Radius.xl))
      .accessibilityIdentifier("talk_button")
      .accessibilityLabel(conversation.isActive ? "End conversation" : "Talk about it")
      .accessibilityValue(statusText ?? "")
      .accessibilityHint(
        conversation.isActive
          ? "Ends the conversation. Saying goodbye does the same."
          : "Starts a spoken conversation about the text you just had read. You can also say talk.")

      if conversation.isActive {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
          if !conversation.userLine.isEmpty { line(label: "You", text: conversation.userLine) }
          if !conversation.assistantLine.isEmpty { line(label: "SpeakUp", text: conversation.assistantLine) }
        }
        .transition(.opacity)
      }
    }
  }

  private var statusText: String? {
    switch conversation.phase {
    case .idle: nil
    case .connecting: "Connecting…"
    case .listening: "Listening"
    case .replying: "Speaking"
    }
  }

  private func line(label: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.rounded(.subheadline, weight: .heavy))
        .foregroundStyle(Theme.inkSoft)
      Text(text)
        .font(.rounded(.title3, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
