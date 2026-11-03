/*
 * ChunkyButtonStyle - the 3D button: a saturated face on a darker lip that compresses when pressed
 *
 * Rules (notes/a11y-onboarding.md, "Low vision is its own path"): targets of at least 60 pt, text in
 * Dynamic Type styles that wraps instead of truncating, and state carried by shape: pressed moves
 * the face down onto its lip, disabled goes flat with a dashed outline. Reduce Motion takes away the
 * animation, not the state. A disabled button keeps full text contrast, because someone with low
 * vision still has to read what it is.
 *
 * `.sayHint(_:)` adds the "Say ..." line under the label. It is hidden from VoiceOver, so buttons
 * keep their names; VoiceOver users get the same list from "help".
 */

import SwiftUI

struct ChunkyButtonStyle: ButtonStyle {
  var tone: Tone = .green
  var lipHeight: CGFloat = 6
  var radius: CGFloat = Theme.buttonRadius

  func makeBody(configuration: Configuration) -> some View {
    ChunkyButtonBody(configuration: configuration, tone: tone, lipHeight: lipHeight, radius: radius)
  }
}

extension ButtonStyle where Self == ChunkyButtonStyle {
  /// The one main action on a screen.
  static var a11yPrimary: ChunkyButtonStyle { ChunkyButtonStyle(tone: .green) }
  /// Every other choice.
  static var a11ySecondary: ChunkyButtonStyle { ChunkyButtonStyle(tone: .neutral, lipHeight: 5) }
}

private struct ChunkyButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let tone: Tone
  let lipHeight: CGFloat
  let radius: CGFloat

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sayCommand) private var sayCommand

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    let pressed = configuration.isPressed && isEnabled
    let line: CGFloat = contrast == .increased ? 3 : 2

    VStack(spacing: 2) {
      configuration.label
        .font(.rounded(.headline, weight: .heavy))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let sayCommand, isEnabled {
        SayHint(command: sayCommand)
      }
    }
    .foregroundStyle(isEnabled ? Theme.onFace(tone) : Theme.lockedText)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 60)
    .background { shape.fill(isEnabled ? Theme.face(tone) : Theme.lockedFace) }
    .overlay {
      if isEnabled {
        shape.strokeBorder(Theme.lip(tone), lineWidth: line)
      } else {
        shape.strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: line, dash: [7, 5]))
      }
    }
    // Pressed: the face sits on the lip. Disabled: no lip at all, so it reads as flat.
    .offset(y: pressed ? lipHeight : 0)
    .padding(.bottom, lipHeight)
    .background {
      if isEnabled { shape.fill(Theme.lip(tone)) }
    }
    .contentShape(shape)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
  }
}

// MARK: - The "Say ..." hint

private struct SayCommandKey: EnvironmentKey {
  static let defaultValue: VoiceCommand? = nil
}

extension EnvironmentValues {
  var sayCommand: VoiceCommand? {
    get { self[SayCommandKey.self] }
    set { self[SayCommandKey.self] = newValue }
  }
}

extension View {
  /// Shows the phrase that triggers this button under its label, while voice control can hear it.
  func sayHint(_ command: VoiceCommand?) -> some View {
    environment(\.sayCommand, command)
  }
}

// MARK: - Plain text

/// A line of body text that meets 4.5:1 on the page and on cards.
struct A11yNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.rounded(.callout, weight: .medium))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
