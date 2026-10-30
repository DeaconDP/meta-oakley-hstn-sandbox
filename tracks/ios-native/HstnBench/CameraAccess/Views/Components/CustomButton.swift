/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CustomButton.swift
//
// Reusable button component used throughout the CameraAccess app for consistent styling.
//

import SwiftUI

struct CustomButton: View {
  let title: String
  let style: ButtonStyle
  let isDisabled: Bool
  let action: () -> Void

  // Explicit, so the private scaled metric below doesn't make the memberwise init private.
  init(title: String, style: ButtonStyle, isDisabled: Bool, action: @escaping () -> Void) {
    self.title = title
    self.style = style
    self.isDisabled = isDisabled
    self.action = action
  }

  enum ButtonStyle {
    case primary, destructive

    var backgroundColor: Color {
      switch self {
      case .primary:
        return .appPrimary
      case .destructive:
        return .destructiveBackground
      }
    }

    var foregroundColor: Color {
      switch self {
      case .primary:
        return .white
      case .destructive:
        return .destructiveForeground
      }
    }
  }

  /// At least 60 pt tall (low-vision target size), growing with Dynamic Type; text wraps instead
  /// of truncating at the accessibility sizes.
  @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 60

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.headline)
        .foregroundStyle(style.foregroundColor)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: max(60, minHeight))
        .background(style.backgroundColor, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        // Light outline so the boundary stays visible over a dark camera frame (3:1).
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1.0)
  }
}
