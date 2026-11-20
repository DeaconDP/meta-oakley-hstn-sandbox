/*
 * ControlsSettingsViews - "Your buttons" on the settings screen: the favourite tool (both builds),
 * and in the Beta build, glasses buttons on or off and what each glasses event does
 *
 * Mirrors the voice grammar through ControlsArea, and speaks each change.
 */

import SwiftUI

struct ControlsSettingsSection: View {
  private var area: ControlsArea { ControlsArea.shared }
  private var macros: [WordMacro] { WordsArea.shared.macros }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      WordsHeader(title: GlassesSupport.isBuiltIn ? "Your buttons (Experimental)" : "Your favourite tool", id: "controls_header")

      Picker("Favourite tool", selection: favouriteBinding) {
        Text("None").tag(ToolID?.none)
        ForEach(ToolID.allCases) { Text($0.title).tag(ToolID?.some($0)) }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("controls_favourite_picker")
      CustomiseNote(text: "Open it with the Open my favourite tool shortcut, Back Tap, or by saying open my favourite.")

      if GlassesSupport.isBuiltIn {
        CustomButton(title: area.enabled ? "Turn glasses buttons off" : "Turn glasses buttons on", style: .secondary, isDisabled: false) {
          speak(area.setEnabled(!area.enabled))
        }
        .accessibilityHint("Off gives the glasses' own button actions back.")
        .accessibilityIdentifier("controls_enabled_toggle")
        if area.enabled {
          ForEach(GlassesControl.allCases) { control in
            Picker(control.title, selection: binding(for: control)) {
              ForEach(choices, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("controls_picker_\(control.rawValue)")
          }
        }
        CustomButton(title: "What do my buttons do?", style: .secondary, isDisabled: false) {
          speak(area.readBack())
        }
        .accessibilityIdentifier("controls_read_back_button")
        CustomiseNote(text: SpokenMessage.controlsWarning)
      }
    }
  }

  private var choices: [ControlAction] {
    ControlAction.simple + ToolID.allCases.map(ControlAction.tool) + macros.map { ControlAction.macro($0.name) }
  }

  private func binding(for control: GlassesControl) -> Binding<ControlAction> {
    Binding(get: { area.action(for: control) }, set: { speak(area.set(control, to: $0)) })
  }

  private var favouriteBinding: Binding<ToolID?> {
    Binding(get: { area.favouriteTool }, set: { speak(area.setFavourite($0)) })
  }

  private func speak(_ line: String) {
    if !line.isEmpty { Announcer.shared.say(line, kind: .reply) }
  }
}
