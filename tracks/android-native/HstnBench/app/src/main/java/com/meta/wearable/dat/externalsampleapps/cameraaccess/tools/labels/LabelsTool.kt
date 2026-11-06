// LabelsTool - the labels tool's registry entry and screen (stub)
//
// ToolRegistry lists [LabelsTool]; the router shows [LabelsScreen] when ToolHub.activeTool is this
// tool. The screen is ToolScaffold (name, close, status, mic, last heard) with the tool's own
// controls below; the stub has none yet.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import android.app.Application
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
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

val LabelsTool =
    ToolSpec(
        id = ToolId.LABELS,
        nameRes = R.string.labels_name,
        buttonRes = R.string.labels_button,
        buttonDescriptionRes = R.string.labels_button_description,
        icon = Icons.Filled.QrCodeScanner,
        content = { LabelsScreen(it) },
    )

@Composable
fun LabelsScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: LabelsViewModel = viewModel(factory = LabelsViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)
  val ui by vm.ui.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.LABELS, title = stringResource(R.string.labels_name), ui = ui, onClose = ctx.onClose) {
    Text(
        text = stringResource(R.string.tool_not_ready, stringResource(R.string.labels_name)),
        color = Color.White,
        fontSize = 22.sp,
    )
  }
}
