/*
 * WatchPanel - Watch for text on the phone screen
 *
 * What it's watching for in large print, the last sighting, and the controls: type a target and
 * Watch, Where is it, Stop / Carry on watching, and the tick setting. Everything is also said, and
 * every control works by voice; the field is for people who'd rather type. Dynamic Type through
 * the brand font, 60 pt targets (ChunkyButtonStyle), VoiceOver labels and hints, theme colours.
 */

import SwiftUI

struct WatchPanel: View {
  let tool: WatchTool

  @State private var typed = ""
  @FocusState private var fieldFocused: Bool

  private var heading: String {
    switch tool.phase {
    case .watching: "Watching for: \(tool.target?.display ?? "")"
    case .stopped: tool.target.map { "Stopped. Was watching for: \($0.display)" } ?? "Stopped."
    case .asking: "Not watching yet. Say or type what to watch for."
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(heading)
        .font(.rounded(.title2, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("watch_heading")

      if let sighting = tool.lastSighting {
        Text("Last: \(sighting)")
          .font(.rounded(.title3, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("watch_last_sighting")
      }

      if let spoken = tool.lastSpoken, spoken != tool.lastSighting {
        Text(spoken)
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Said: \(spoken)")
          .accessibilityIdentifier("watch_said")
      }

      targetField

      VStack(spacing: 10) {
        if tool.target != nil {
          Button { tool.sayWhere() } label: { Label("Where is it?", systemImage: "location.viewfinder") }
            .buttonStyle(ChunkyButtonStyle(tone: .blue))
            .accessibilityHint("Says which side it was last seen on.")
            .accessibilityIdentifier("watch_where_button")
        }
        Button { tool.toggleWatching() } label: {
          Label(toggleTitle, systemImage: tool.phase == .watching ? "stop.fill" : "eye")
        }
        .buttonStyle(ChunkyButtonStyle(tone: tool.phase == .watching ? .red : .yellow))
        .accessibilityIdentifier("watch_toggle_button")

        Button { tool.cycleTicks() } label: {
          Label("Tick: \(WatchWording.tickSetting(tool.tickSeconds))", systemImage: "metronome")
        }
        .buttonStyle(.a11ySecondary)
        .accessibilityLabel("Still-watching tick, \(tool.tickSeconds == 0 ? "off" : "every \(tool.tickSeconds) seconds")")
        .accessibilityHint("Changes how often a soft tick says it's still watching.")
        .accessibilityIdentifier("watch_ticks_button")
      }

      Text("Say: where is it, stop watching, or watch for something else.")
        .font(.rounded(.subheadline, weight: .medium))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)

      if let read = tool.lastRead, tool.phase == .watching {
        Text("I can read: \(read)")
          .font(.rounded(.footnote, weight: .medium))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("watch_last_read")
      }
    }
    .themeCard()
    .accessibilityElement(children: .contain)
  }

  private var toggleTitle: String {
    switch tool.phase {
    case .watching: "Stop watching"
    case .stopped where tool.target != nil: "Carry on watching"
    default: "Ask me what to watch for"
    }
  }

  private var targetField: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { field; watchButton }
      VStack(alignment: .leading, spacing: 10) { field; watchButton }
    }
  }

  private var field: some View {
    TextField("A word or number, like 42", text: $typed)
      .font(.rounded(.title3, weight: .bold))
      .foregroundStyle(Theme.ink)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.go)
      .focused($fieldFocused)
      .onSubmit(submit)
      .padding(.horizontal, 14)
      .frame(minHeight: 60)
      .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2)
      }
      .accessibilityLabel("What to watch for")
      .accessibilityHint("Type a word or number, then Watch.")
      .accessibilityIdentifier("watch_target_field")
  }

  private var watchButton: some View {
    Button(action: submit) { Text("Watch") }
      .buttonStyle(.a11yPrimary)
      .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
      .accessibilityHint("Starts watching for what you typed.")
      .accessibilityIdentifier("watch_start_button")
  }

  private func submit() {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    fieldFocused = false
    typed = ""
    tool.watch(for: text)
  }
}
