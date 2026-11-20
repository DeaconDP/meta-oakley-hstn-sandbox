/*
 * LightPanel - the light and colour tool on the phone screen
 *
 * Mirrors the state for low-vision users, sighted helpers and VoiceOver: the mode, in light mode the
 * tone's pitch in large print ("Tone 523 Hz" or "Tone off"), the level and "Blinking"; in colour
 * mode a big swatch of the measured (white-balanced) colour with the spoken sentence under it.
 * Buttons do exactly what the voice commands do. Dynamic Type throughout, 60 pt targets
 * (ChunkyButtonStyle), the theme's colours. The swatch's VoiceOver label is the sentence.
 */

import SwiftUI

struct LightPanel: View {
  let tool: LightTool

  @ScaledMetric(relativeTo: .largeTitle) private var swatchSize: CGFloat = 160

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(tool.mode == .probe ? "Light probe" : "Colour")
        .font(.rounded(.title, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("light_mode")

      if tool.mode == .probe { probeCard } else { colourCard }

      if !tool.lastLine.isEmpty {
        A11yNote(text: tool.lastLine)
          .accessibilityIdentifier("light_last_line")
      }

      buttons
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private var toneText: String {
    tool.toneHz > 0 ? "Tone \(Int(tool.toneHz.rounded())) Hz" : (tool.paused ? "Tone off" : (tool.probing ? "Listening for light" : "Tone off"))
  }

  private var probeCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(toneText)
        .font(.rounded(.largeTitle, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("light_tone")
      if let level = tool.level {
        Text(level.spoken)
          .font(.rounded(.title2, weight: .bold))
          .foregroundStyle(Theme.ink)
          .accessibilityLabel("Level: \(level.spoken)")
          .accessibilityIdentifier("light_level")
      }
      if tool.blinking {
        Label("Blinking", systemImage: "light.beacon.max")
          .font(.rounded(.title2, weight: .heavy))
          .foregroundStyle(Theme.speak)
          .accessibilityIdentifier("light_blinking")
      }
      if tool.exposureLocked {
        Text("Camera exposure held still while measuring.")
          .font(.rounded(.footnote, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .themeCard()
    .accessibilityElement(children: .combine)
  }

  private var colourCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        .fill(tool.swatch.map(Self.color) ?? Theme.track)
        .overlay {
          RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 3)
        }
        .frame(width: min(swatchSize, 260), height: min(swatchSize, 260))
        .accessibilityElement()
        .accessibilityLabel(tool.colourText.isEmpty ? "No colour yet" : "Measured colour. \(tool.colourText)")
        .accessibilityIdentifier("light_swatch")
      Text(tool.colourText.isEmpty ? (tool.isMeasuringColour ? "Looking…" : "No colour yet. Say what colour is this.") : tool.colourText)
        .font(.rounded(.title, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
        .accessibilityIdentifier("light_colour_text")
    }
    .themeCard()
  }

  @ViewBuilder
  private var buttons: some View {
    if tool.mode == .probe {
      Button("How bright?") { tool.perform(.howBright) }
        .buttonStyle(.a11yPrimary)
        .accessibilityIdentifier("light_how_bright")
      Button(tool.probing ? "Tone off" : "Tone on") { tool.perform(tool.probing ? .toneOff : .toneOn) }
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("light_tone_button")
      Button("Where's the light?") { tool.perform(.whereBright) }
        .buttonStyle(.a11ySecondary)
      Button("Colour mode") { tool.perform(.colour) }
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("light_colour_mode")
    } else {
      Button("What colour?") { tool.perform(.again) }
        .buttonStyle(.a11yPrimary)
        .disabled(tool.isMeasuringColour)
        .accessibilityIdentifier("light_measure")
      Button("Light mode") { tool.perform(.light) }
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("light_light_mode")
    }
  }

  private static func color(_ argb: UInt32) -> Color {
    Color(
      red: Double(ColourSpace.red(argb)) / 255, green: Double(ColourSpace.green(argb)) / 255, blue: Double(ColourSpace.blue(argb)) / 255)
  }
}
