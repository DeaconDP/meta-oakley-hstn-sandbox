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
// HstnBench: the chunky button from A11y/Theme, at least 60 pt tall, wrapping at large text.
//

import SwiftUI

struct CustomButton: View {
  let title: String
  let style: ButtonStyle
  let isDisabled: Bool
  let action: () -> Void

  enum ButtonStyle {
    case primary, secondary, destructive

    var tone: Tone {
      switch self {
      case .primary: .green
      case .secondary: .neutral
      case .destructive: .red
      }
    }
  }

  var body: some View {
    Button(action: action) {
      Text(title)
    }
    .buttonStyle(ChunkyButtonStyle(tone: style.tone))
    .disabled(isDisabled)
  }
}
