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
// Reusable circular button component used in streaming controls and UI actions.
//

import SwiftUI

struct CircleButton: View {
  let icon: String
  let text: String?
  let action: () -> Void
  /// VoiceOver name for an icon-only button (the SF Symbol name would be read otherwise).
  let accessibilityLabel: String?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(icon: String, text: String?, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
    self.icon = icon
    self.text = text
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      if let text, dynamicTypeSize.isAccessibilitySize {
        // Large text doesn't fit a circle: a capsule that grows with the text instead.
        HStack(spacing: 8) {
          Image(systemName: icon)
            .accessibilityHidden(true)
          Text(text)
        }
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minWidth: 60, minHeight: 60)
        .background(.white, in: Capsule())
      } else if let text {
        VStack(spacing: 2) {
          Image(systemName: icon)
            .font(.system(size: 16))
            .accessibilityHidden(true)
          Text(text)
            .font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 60, height: 60)
        .background(.white, in: Circle())
      } else {
        Image(systemName: icon)
          .font(.system(size: 20, weight: .semibold))
          .frame(width: 60, height: 60)
          .background(.white, in: Circle())
      }
    }
    .foregroundStyle(.black)
    // Dark outline: the white button stays distinct over a bright photo (3:1 boundary).
    .overlay {
      if text == nil || !dynamicTypeSize.isAccessibilitySize {
        Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5)
      } else {
        Capsule().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5)
      }
    }
    .accessibilityLabel(accessibilityLabel ?? text ?? icon)
  }
}
