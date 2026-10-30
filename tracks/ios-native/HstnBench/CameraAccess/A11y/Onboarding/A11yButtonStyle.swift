/*
 * A11yButtonStyle - large, high-contrast buttons for onboarding and the home screen
 *
 * Low-vision rules from notes/a11y-onboarding.md: targets of at least 60 pt, text in Dynamic Type
 * styles so it grows to the accessibility sizes (wrapping, never truncating), text contrast of
 * 4.5:1 or more in light and dark mode, stronger colours under Increase Contrast, and state
 * carried by words and shape, not colour alone. Components/CustomButton keeps the sample's fixed
 * 56 pt look for the camera screen; this is the accessible counterpart.
 */

import SwiftUI

struct A11yButtonStyle: ButtonStyle {
  enum Kind {
    /// Filled: the one main action on a screen.
    case primary
    /// Outlined: every other choice.
    case secondary
  }

  var kind: Kind = .primary

  func makeBody(configuration: Configuration) -> some View {
    A11yButtonBody(configuration: configuration, kind: kind)
  }
}

extension ButtonStyle where Self == A11yButtonStyle {
  static var a11yPrimary: A11yButtonStyle { A11yButtonStyle(kind: .primary) }
  static var a11ySecondary: A11yButtonStyle { A11yButtonStyle(kind: .secondary) }
}

/// A view, not inline in the style, so it can read the environment.
private struct A11yButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let kind: A11yButtonStyle.Kind

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var colorScheme

  /// Minimum height: 60 pt targets (notes/a11y-onboarding.md, "Low vision is its own path").
  @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 60

  var body: some View {
    configuration.label
      .font(.headline)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(foreground)
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: max(60, minHeight))
      .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        if kind == .secondary {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary, lineWidth: contrast == .increased ? 3 : 2)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.6))
  }

  private var foreground: Color {
    kind == .primary ? .white : .primary
  }

  /// White on #0064E0 is about 5.4:1; Increase Contrast and dark mode get a deeper blue (about
  /// 8:1), since the asset colour has no dark variant.
  private var background: Color {
    switch kind {
    case .primary:
      contrast == .increased || colorScheme == .dark ? Color(red: 0, green: 0.27, blue: 0.62) : .appPrimary
    case .secondary:
      Color(.systemBackground)
    }
  }
}

/// A caption-sized line that still meets 4.5:1 (unlike `.secondary` on white, about 3.4:1).
struct A11yNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
