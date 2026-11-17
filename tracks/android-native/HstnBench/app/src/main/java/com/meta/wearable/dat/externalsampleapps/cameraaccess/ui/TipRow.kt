/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** A single onboarding tip: an icon in a Dusk disc next to a bold title and a short description. */
@Composable
fun TipRow(
    icon: Painter,
    title: String,
    text: String,
    modifier: Modifier = Modifier,
) {
  Row(
      modifier = modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
      horizontalArrangement = Arrangement.spacedBy(16.dp),
      verticalAlignment = Alignment.Top,
  ) {
    Box(
        modifier = Modifier.size(52.dp).clip(CircleShape).background(SpeakUpColors.Dusk),
        contentAlignment = Alignment.Center,
    ) {
      Icon(
          painter = icon,
          contentDescription = null,
          tint = SpeakUpColors.SignalYellow,
          modifier = Modifier.size(28.dp),
      )
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Text(text = title, style = MaterialTheme.typography.titleMedium, color = SpeakUpColors.Paper)
      Text(text = text, style = MaterialTheme.typography.bodyMedium, color = SpeakUpColors.PaperMuted)
    }
  }
}
