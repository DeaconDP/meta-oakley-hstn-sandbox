// ToolScreen - the phone screen pieces every tool uses
//
// The glasses and voice do the work; the phone screen mirrors the state for sighted helpers,
// low-vision users and TalkBack users (ROADMAP ground rules). ToolScaffold gives each tool the same
// accessible SpeakUp frame: a heading with the tool's name, a large close button, the voice ribbon
// (decorative), the status line in large Signal Yellow on a Dusk card, which microphone is listening
// (icon + words), and what was last heard, with the tool's own controls below. Test tags:
// "tool_screen_<id>", "tool_close", "tool_status", "tool_voice_mic", "tool_voice_heard".
// AttachTool connects a tool's ViewModel to ToolHub while its screen is showing. In the toolbox
// (hands-free off) the camera screen provides LocalPushToTalk and the scaffold shows the mic button
// under the status card: one command, the same grammar as hands-free.
// Status changes aren't a live region: the tool already speaks them and TalkBack would repeat them.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.PushToTalkButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.SpeakUpCard
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.SpeakUpColors
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.SpeakUpDimens
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.VoiceRibbon
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.VoiceState

/** The toolbox's push-to-talk for tool screens: [listening] for one command; [onClick] starts/cancels. */
class PushToTalk(val listening: Boolean, val onClick: () -> Unit)

/** Provided by the camera screen in the toolbox; null in hands-free mode (the mic is always on). */
val LocalPushToTalk = compositionLocalOf<PushToTalk?> { null }

/** The push-to-talk button, if the toolbox provides one. */
@Composable
fun ToolPushToTalk() {
  LocalPushToTalk.current?.let { PushToTalkButton(listening = it.listening, onClick = it.onClick) }
}

/** Signal Yellow: the accent for status lines and main tool buttons (Night text on it). */
val ToolAccent = SpeakUpColors.SignalYellow

/** Everything a tool screen gets from the app. */
data class ToolScreenContext(
    val hub: ToolHub,
    /** What was asked for (mode, argument). Updates when the same tool is asked for again. */
    val request: ToolRequest,
    /** Close the tool (back to the camera screen). */
    val onClose: () -> Unit,
    val onRequestWearablesPermission: suspend (Permission) -> PermissionStatus,
    val onRequestRecordAudioPermission: suspend () -> Boolean,
)

/** Attaches [host] to [hub] while this composable is showing. Call it first in a tool screen. */
@Composable
fun AttachTool(hub: ToolHub, host: ToolHost, request: ToolRequest) {
  DisposableEffect(host) {
    hub.attach(host, request)
    onDispose { hub.detach(host) }
  }
}

/** What the ribbon shows for a microphone state when the tool doesn't say more. */
fun voiceStateFor(microphone: Microphone): VoiceState =
    if (microphone == Microphone.NONE) VoiceState.IDLE else VoiceState.LISTENING

/**
 * The common tool screen. [title] is the tool's name; [content] is the tool's own controls (big
 * labelled buttons, large text), laid out in a column below the status block. [voiceState] drives
 * the ribbon; by default it follows the microphone (listening or idle).
 */
@Composable
fun ToolScaffold(
    toolId: ToolId,
    title: String,
    ui: ToolUiState,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    voiceState: VoiceState = voiceStateFor(ui.microphone),
    content: @Composable ColumnScope.() -> Unit = {},
) {
  BackHandler(onBack = onClose)
  Column(
      modifier =
          modifier
              .fillMaxSize()
              .background(SpeakUpColors.Night)
              .statusBarsPadding()
              .navigationBarsPadding()
              .padding(horizontal = 16.dp, vertical = 8.dp)
              .testTag("tool_screen_${toolId.id}"),
      verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    ToolHeader(
        title = title,
        closeDescription = stringResource(R.string.tool_close, title),
        onClose = onClose,
        closeTag = "tool_close",
    )
    // At very large font scales the controls need the room more than the decoration does.
    if (LocalDensity.current.fontScale < 1.6f) VoiceRibbon(state = voiceState, height = 44.dp)
    SpeakUpCard(modifier = Modifier.fillMaxWidth()) {
      Text(
          text = ui.status.ifEmpty { stringResource(R.string.tool_status_idle) },
          color = ToolAccent,
          style = MaterialTheme.typography.titleMedium,
          modifier = Modifier.testTag("tool_status"),
      )
      MicStatusLine(microphone = ui.microphone, tag = "tool_voice_mic")
      if (ui.heard.isNotEmpty()) {
        Text(
            text = stringResource(R.string.voice_heard, ui.heard),
            color = SpeakUpColors.PaperMuted,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.testTag("tool_voice_heard"),
        )
      }
    }
    ToolPushToTalk()
    content()
  }
}

/** A screen heading with the SpeakUp mark and a 56dp close button. */
@Composable
fun ToolHeader(title: String, closeDescription: String, onClose: () -> Unit, closeTag: String) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Icon(
        painter = painterResource(R.drawable.speakup_mark),
        contentDescription = null,
        tint = SpeakUpColors.SignalYellow,
        modifier = Modifier.size(30.dp),
    )
    Spacer(modifier = Modifier.width(10.dp))
    Text(
        text = title,
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.headlineMedium,
        modifier = Modifier.weight(1f).semantics { heading() },
    )
    IconButton(
        onClick = onClose,
        modifier = Modifier.size(SpeakUpDimens.MinTouchTarget).testTag(closeTag),
        colors =
            IconButtonDefaults.iconButtonColors(
                containerColor = SpeakUpColors.Dusk,
                contentColor = SpeakUpColors.Paper,
            ),
    ) {
      Icon(
          imageVector = Icons.Filled.Close,
          contentDescription = closeDescription,
          modifier = Modifier.size(32.dp),
      )
    }
  }
}

/**
 * Which microphone is listening: a mic icon (Listen Cyan) or a crossed-out mic, then the words.
 * [tag] goes on the text, which tests read.
 */
@Composable
fun MicStatusLine(microphone: Microphone, tag: String, color: Color = SpeakUpColors.Paper) {
  Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    Icon(
        imageVector = if (microphone == Microphone.NONE) Icons.Filled.MicOff else Icons.Filled.Mic,
        contentDescription = null,
        tint = if (microphone == Microphone.NONE) SpeakUpColors.PaperMuted else SpeakUpColors.ListenCyan,
        modifier = Modifier.size(26.dp),
    )
    Text(
        text =
            stringResource(
                when (microphone) {
                  Microphone.GLASSES -> R.string.voice_mic_glasses
                  Microphone.PHONE -> R.string.voice_mic_phone
                  Microphone.NONE -> R.string.voice_mic_none
                },
            ),
        color = color,
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier.testTag(tag),
    )
  }
}
