// CameraSourceControls - the camera switch (phone or glasses) and the saved camera source setting
//
// notes/phone-camera.md. The switch on the camera screen changes the camera now (ToolHub.useCamera,
// the same as saying "use the phone" / "use the glasses"); the settings menu's group saves the
// choice (Automatic, Phone, Glasses). Both are radio groups: TalkBack reads "Phone, radio button,
// selected, 1 of 2"; the selected option has a thicker cyan edge and a check mark, not colour alone.
// Tags: "camera_source_switch", "camera_source_phone", "camera_source_glasses",
// "camera_setting_auto", "camera_setting_phone", "camera_setting_glasses".

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.AutoMode
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceSetting

/** "Camera: Phone | Glasses", switching now. [glassesReady]: registered with Meta AI. */
@Composable
fun CameraSourceSwitch(
    current: CameraSource,
    glassesReady: Boolean,
    onSelect: (CameraSource) -> Unit,
    modifier: Modifier = Modifier,
) {
  Column(
      modifier =
          modifier
              .fillMaxWidth()
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk)
              .border(2.dp, SpeakUpColors.DuskLine, MaterialTheme.shapes.medium)
              .padding(12.dp)
              .testTag("camera_source_switch"),
      verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text(
        text = stringResource(R.string.source_switch_label),
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    Row(modifier = Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
      SourceOption(
          label = stringResource(R.string.source_switch_phone),
          icon = Icons.Filled.PhoneAndroid,
          selected = current == CameraSource.PHONE,
          tag = "camera_source_phone",
          onClick = { onSelect(CameraSource.PHONE) },
          modifier = Modifier.weight(1f),
      )
      SourceOption(
          label = stringResource(R.string.source_switch_glasses),
          icon = Icons.Filled.Visibility,
          selected = current == CameraSource.GLASSES,
          tag = "camera_source_glasses",
          onClick = { onSelect(CameraSource.GLASSES) },
          modifier = Modifier.weight(1f),
      )
    }
    Text(
        text =
            stringResource(
                when {
                  current == CameraSource.PHONE && !glassesReady -> R.string.source_switch_glasses_setup
                  current == CameraSource.PHONE -> R.string.source_switch_hint_phone
                  else -> R.string.source_switch_hint_glasses
                },
            ),
        color = SpeakUpColors.PaperMuted,
        style = MaterialTheme.typography.bodyMedium,
    )
  }
}

/** The saved camera source, in the settings menu. */
@Composable
fun CameraSourceSettingGroup(
    setting: CameraSourceSetting,
    onChange: (CameraSourceSetting) -> Unit,
    modifier: Modifier = Modifier,
) {
  Column(modifier = modifier.fillMaxWidth().selectableGroup(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    Text(
        text = stringResource(R.string.source_switch_setting_heading),
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    SourceOption(
        label = stringResource(R.string.source_switch_auto),
        hint = stringResource(R.string.source_switch_auto_hint),
        icon = Icons.Filled.AutoMode,
        selected = setting == CameraSourceSetting.AUTO,
        tag = "camera_setting_auto",
        onClick = { onChange(CameraSourceSetting.AUTO) },
    )
    SourceOption(
        label = stringResource(R.string.source_switch_phone),
        icon = Icons.Filled.PhoneAndroid,
        selected = setting == CameraSourceSetting.PHONE,
        tag = "camera_setting_phone",
        onClick = { onChange(CameraSourceSetting.PHONE) },
    )
    SourceOption(
        label = stringResource(R.string.source_switch_glasses),
        icon = Icons.Filled.Visibility,
        selected = setting == CameraSourceSetting.GLASSES,
        tag = "camera_setting_glasses",
        onClick = { onChange(CameraSourceSetting.GLASSES) },
    )
  }
}

@Composable
private fun SourceOption(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    tag: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    hint: String? = null,
) {
  Row(
      modifier =
          modifier
              .fillMaxWidth()
              .heightIn(min = SpeakUpDimens.MinTouchTarget)
              .clip(MaterialTheme.shapes.small)
              .background(if (selected) SpeakUpColors.Night else SpeakUpColors.Dusk)
              .border(
                  if (selected) 3.dp else 2.dp,
                  if (selected) SpeakUpColors.ListenCyan else SpeakUpColors.PaperMuted,
                  MaterialTheme.shapes.small,
              )
              .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
              .padding(horizontal = 12.dp, vertical = 8.dp)
              .testTag(tag),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    Icon(
        imageVector = if (selected) Icons.Filled.CheckCircle else icon,
        contentDescription = null,
        tint = if (selected) SpeakUpColors.ListenCyan else SpeakUpColors.Paper,
        modifier = Modifier.size(24.dp),
    )
    Column(modifier = Modifier.weight(1f)) {
      Text(text = label, color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium)
      if (hint != null) {
        Text(text = hint, color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
      }
    }
  }
}
