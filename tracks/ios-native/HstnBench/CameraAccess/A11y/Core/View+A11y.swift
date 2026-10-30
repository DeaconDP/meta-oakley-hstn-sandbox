/*
 * View helpers for the accessibility work, kept small on purpose.
 */

import SwiftUI

extension View {
  /// Purely visual content (icons, illustrations): hidden from VoiceOver so it doesn't read asset
  /// names, and kept as-is under Smart Invert.
  func a11yDecorative() -> some View {
    accessibilityHidden(true).accessibilityIgnoresInvertColors()
  }

  /// Speaks a status line when `value` changes, so state changes that only show visually
  /// ("Connecting…") are heard too. Return nil from `message` to stay quiet for a value.
  func a11yAnnounce<Value: Equatable>(
    onChangeOf value: Value,
    earcon: Earcon? = nil,
    _ message: @escaping (Value) -> String?
  ) -> some View {
    onChange(of: value) { _, newValue in
      guard let text = message(newValue) else { return }
      Announcer.shared.announce(text, earcon: earcon)
    }
  }
}
