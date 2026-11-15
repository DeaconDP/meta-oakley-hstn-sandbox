/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** A round Signal Yellow button (Night icon on it), never smaller than 56dp. */
@Composable
fun CircleButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
  Button(
      modifier =
          modifier
              .sizeIn(minWidth = SpeakUpDimens.MinTouchTarget, minHeight = SpeakUpDimens.MinTouchTarget)
              .aspectRatio(1f),
      onClick = onClick,
      colors =
          ButtonDefaults.buttonColors(
              containerColor = SpeakUpColors.SignalYellow,
              contentColor = SpeakUpColors.OnAccent,
          ),
      border = BorderStroke(2.dp, SpeakUpColors.Night),
      shape = CircleShape,
      contentPadding = PaddingValues(0.dp),
      content = content,
  )
}
