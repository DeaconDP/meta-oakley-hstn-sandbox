// WatchTool - the watch tool's registry entry and screen
//
// ToolRegistry lists [WatchTool]; the router shows [WatchScreen] when ToolHub.activeTool is this
// tool. The screen is ToolScaffold (name, close, status, mic, last heard) plus what Watch for text
// is doing, in large type for low-vision users and sighted helpers: the target, the last sighting,
// how fast reading is going, and big labelled buttons for everything the voice commands do (where
// is it, stop / carry on, watch for something else, the alive tick). Everything here can also be
// done by voice. Test tags: watch_target, watch_last, watch_pace, watch_read, watch_where, watch_toggle,
// watch_change, watch_ticks.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.AttachTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolAccent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScaffold
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScreenContext
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolSpec
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import java.util.Locale

val WatchTool =
    ToolSpec(
        id = ToolId.WATCH,
        nameRes = R.string.watch_name,
        buttonRes = R.string.watch_button,
        buttonDescriptionRes = R.string.watch_button_description,
        icon = Icons.Filled.Visibility,
        content = { WatchScreen(it) },
    )

@Composable
fun WatchScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: WatchViewModel = viewModel(factory = WatchViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)
  val ui by vm.ui.collectAsStateWithLifecycle()
  val w by vm.watch.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.WATCH, title = stringResource(R.string.watch_name), ui = ui, onClose = ctx.onClose) {
    Column(
        modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
      Text(
          text =
              when {
                w.target == null -> stringResource(R.string.watch_screen_no_target)
                w.phase == WatchPhase.WATCHING -> stringResource(R.string.watch_screen_target, w.target!!)
                else -> stringResource(R.string.watch_screen_stopped, w.target!!)
              },
          color = Color.White,
          fontSize = 30.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.testTag("watch_target"),
      )
      w.lastSighting?.let {
        Text(
            text = stringResource(R.string.watch_screen_last, it),
            color = ToolAccent,
            fontSize = 24.sp,
            modifier = Modifier.testTag("watch_last"),
        )
      }
      if (w.phase == WatchPhase.WATCHING && w.ocrMs != null) {
        Text(
            text =
                stringResource(
                    R.string.watch_screen_pace,
                    w.ocrMs!!,
                    w.fps?.let { String.format(Locale.US, "%.1f", it) } ?: "-",
                ),
            color = Color.White,
            fontSize = 16.sp,
            modifier = Modifier.testTag("watch_pace"),
        )
      }
      if (w.phase == WatchPhase.WATCHING && w.lastRead != null) {
        Text(
            text = stringResource(R.string.watch_screen_read, w.lastRead!!.ifEmpty { stringResource(R.string.watch_screen_read_nothing) }),
            color = Color.White,
            fontSize = 18.sp,
            modifier = Modifier.testTag("watch_read"),
        )
      }
      BigButton(stringResource(R.string.watch_button_where), "watch_where", enabled = w.target != null) { vm.whereButton() }
      BigButton(
          stringResource(if (w.phase == WatchPhase.WATCHING) R.string.watch_button_stop else R.string.watch_button_resume),
          "watch_toggle",
      ) {
        vm.toggleButton()
      }
      BigButton(stringResource(R.string.watch_button_change), "watch_change") { vm.changeButton() }
      BigButton(
          stringResource(
              R.string.watch_button_ticks,
              if (w.tickSeconds == 0) stringResource(R.string.watch_ticks_off_short)
              else stringResource(R.string.watch_ticks_every_short, w.tickSeconds),
          ),
          "watch_ticks",
      ) {
        vm.cycleTicksButton()
      }
    }
  }
}

@Composable
private fun BigButton(label: String, tag: String, enabled: Boolean = true, onClick: () -> Unit) {
  Button(
      onClick = onClick,
      enabled = enabled,
      colors = ButtonDefaults.buttonColors(containerColor = ToolAccent, contentColor = Color.Black),
      modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp).testTag(tag),
  ) {
    Text(label, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
  }
}
