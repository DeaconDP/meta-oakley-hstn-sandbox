/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CircleButton.swift
//
// Reusable button component used in streaming controls and UI actions.
// HstnBench: with text, a chunky full-width button; without, a round chunky one, 60 pt across.
//

import SwiftUI

struct CircleButton: View {
  let icon: String
  let text: String?
  let action: () -> Void
  /// VoiceOver name for an icon-only button (the SF Symbol name would be read otherwise).
  let accessibilityLabel: String?

  init(icon: String, text: String?, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
    self.icon = icon
    self.text = text
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var body: some View {
    Group {
      if let text {
        Button(action: action) {
          HStack(spacing: 8) {
            Image(systemName: icon)
              .accessibilityHidden(true)
            Text(text)
          }
        }
        .buttonStyle(.a11yPrimary)
      } else {
        Button(action: action) {
          Image(systemName: icon)
            .font(.rounded(.title3, weight: .heavy))
            .accessibilityHidden(true)
        }
        .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5, radius: 33))
        .frame(width: 66)
      }
    }
    .accessibilityLabel(accessibilityLabel ?? text ?? icon)
  }
}
