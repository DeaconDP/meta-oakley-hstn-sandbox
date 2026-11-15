/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * A full-width SpeakUp button: Signal Yellow for the main action, Voice Coral when [isDestructive].
 * At least 56dp tall and grows with the font scale.
 */
@Composable
fun SwitchButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    isDestructive: Boolean = false,
    enabled: Boolean = true,
) {
  SpeakUpButton(
      label = label,
      onClick = onClick,
      modifier = modifier.fillMaxWidth(),
      kind = if (isDestructive) ButtonKind.DANGER else ButtonKind.PRIMARY,
      enabled = enabled,
  )
}
