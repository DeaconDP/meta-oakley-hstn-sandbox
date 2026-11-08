// ToolScreen - the phone screen pieces every tool uses
//
// The glasses and voice do the work; the phone screen mirrors the state for sighted helpers,
// low-vision users and TalkBack users (ROADMAP ground rules). ToolScaffold gives each tool the same
// accessible frame: a heading with the tool's name, a large close button, the status line in large
// yellow-on-black type, which microphone is listening, and what was last heard, with the tool's own
// controls below. Test tags: "tool_screen_<id>", "tool_close", "tool_status", "tool_voice_mic",
// "tool_voice_heard". AttachTool connects a tool's ViewModel to ToolHub while its screen is showing.
// Status changes aren't a live region: the tool already speaks them and TalkBack would repeat them.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

/** Yellow on black: the same high-contrast pair as the book reader. */
val ToolAccent = Color(0xFFFFD60A)

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

/**
 * The common tool screen. [title] is the tool's name; [content] is the tool's own controls (big
 * labelled buttons, large text), laid out in a column below the status block.
 */
@Composable
fun ToolScaffold(
    toolId: ToolId,
    title: String,
    ui: ToolUiState,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit = {},
) {
  BackHandler(onBack = onClose)
  Column(
      modifier =
          modifier
              .fillMaxSize()
              .background(Color.Black)
              .statusBarsPadding()
              .navigationBarsPadding()
              .padding(horizontal = 16.dp, vertical = 8.dp)
              .testTag("tool_screen_${toolId.id}"),
      verticalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text(
          text = title,
          color = Color.White,
          fontSize = 26.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.weight(1f).semantics { heading() },
      )
      IconButton(onClick = onClose, modifier = Modifier.size(56.dp).testTag("tool_close")) {
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = stringResource(R.string.tool_close, title),
            tint = Color.White,
            modifier = Modifier.size(32.dp),
        )
      }
    }
    Text(
        text = ui.status.ifEmpty { stringResource(R.string.tool_status_idle) },
        color = ToolAccent,
        fontSize = 22.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.testTag("tool_status"),
    )
    Text(
        text =
            stringResource(
                when (ui.microphone) {
                  Microphone.GLASSES -> R.string.voice_mic_glasses
                  Microphone.PHONE -> R.string.voice_mic_phone
                  Microphone.NONE -> R.string.voice_mic_none
                },
            ),
        color = Color.White,
        fontSize = 18.sp,
        modifier = Modifier.testTag("tool_voice_mic"),
    )
    if (ui.heard.isNotEmpty()) {
      Text(
          text = stringResource(R.string.voice_heard, ui.heard),
          color = Color.White,
          fontSize = 18.sp,
          modifier = Modifier.testTag("tool_voice_heard"),
      )
    }
    content()
  }
}
