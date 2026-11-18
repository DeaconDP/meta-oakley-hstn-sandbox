// HandsFreeControls - the mode switch, the glasses display switch and the push-to-talk button
//
// notes/hands-free-mode.md > Turning it on and off. Shared by the camera screen (toolbox home and
// hands-free menu), its settings menu, and the setup screen. Each switch is one large toggleable
// row (TalkBack reads "Hands-free, switch, on" and the line under it); the mic button says what it
// will do. Tags: "hands_free_switch", "glasses_display_switch", "push_to_talk_button".

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R

/** The big "Hands-free" switch, with a line saying what on/off means. */
@Composable
fun HandsFreeSwitch(on: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
  LabelledSwitch(
      label = stringResource(R.string.hf_switch_label),
      hint = stringResource(if (on) R.string.hf_switch_on else R.string.hf_switch_off),
      on = on,
      onChange = onChange,
      tag = "hands_free_switch",
      modifier = modifier,
  )
}

/** "Glasses display" (a card on Ray-Ban Display glasses in hands-free mode). */
@Composable
fun GlassesDisplaySwitch(on: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
  LabelledSwitch(
      label = stringResource(R.string.hf_display_switch_label),
      hint = stringResource(R.string.hf_display_switch_hint),
      on = on,
      onChange = onChange,
      tag = "glasses_display_switch",
      modifier = modifier,
  )
}

@Composable
private fun LabelledSwitch(
    label: String,
    hint: String,
    on: Boolean,
    onChange: (Boolean) -> Unit,
    tag: String,
    modifier: Modifier = Modifier,
) {
  Row(
      modifier =
          modifier
              .fillMaxWidth()
              .heightIn(min = SpeakUpDimens.HeroButtonHeight)
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk)
              .border(2.dp, if (on) SpeakUpColors.ListenCyan else SpeakUpColors.DuskLine, MaterialTheme.shapes.medium)
              .toggleable(value = on, role = Role.Switch, onValueChange = onChange)
              .padding(horizontal = 16.dp, vertical = 10.dp)
              .testTag(tag),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(text = label, color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium)
      Text(text = hint, color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
    }
    // The row is the control; the Switch only shows the state.
    Switch(
        checked = on,
        onCheckedChange = null,
        colors =
            SwitchDefaults.colors(
                checkedThumbColor = SpeakUpColors.Night,
                checkedTrackColor = SpeakUpColors.ListenCyan,
                uncheckedThumbColor = SpeakUpColors.PaperMuted,
                uncheckedTrackColor = SpeakUpColors.Night,
            ),
    )
  }
}

/** Push to talk: listens for one command. While listening it says so and cancels on a tap. */
@Composable
fun PushToTalkButton(listening: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
  val description =
      stringResource(
          if (listening) R.string.hf_mic_button_description_listening else R.string.hf_mic_button_description,
      )
  SpeakUpButton(
      label = stringResource(if (listening) R.string.hf_mic_button_listening else R.string.hf_mic_button),
      onClick = onClick,
      icon = if (listening) Icons.Filled.Close else Icons.Filled.Mic,
      kind = if (listening) ButtonKind.SECONDARY else ButtonKind.PRIMARY,
      minHeight = SpeakUpDimens.HeroButtonHeight,
      modifier = modifier.fillMaxWidth().testTag("push_to_talk_button").semantics { contentDescription = description },
  )
}
