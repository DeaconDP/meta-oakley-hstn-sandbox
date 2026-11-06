// WatchTool - the watch tool's registry entry and screen (stub)
//
// ToolRegistry lists [WatchTool]; the router shows [WatchScreen] when ToolHub.activeTool is this
// tool. The screen is ToolScaffold (name, close, status, mic, last heard) with the tool's own
// controls below; the stub has none yet.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import android.app.Application
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.AttachTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScaffold
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScreenContext
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolSpec
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId

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
  ToolScaffold(toolId = ToolId.WATCH, title = stringResource(R.string.watch_name), ui = ui, onClose = ctx.onClose) {
    Text(
        text = stringResource(R.string.tool_not_ready, stringResource(R.string.watch_name)),
        color = Color.White,
        fontSize = 22.sp,
    )
  }
}
