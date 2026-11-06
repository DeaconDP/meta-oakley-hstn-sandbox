// MailTool - the mail tool's registry entry and screen (stub)
//
// ToolRegistry lists [MailTool]; the router shows [MailScreen] when ToolHub.activeTool is this
// tool. The screen is ToolScaffold (name, close, status, mic, last heard) with the tool's own
// controls below; the stub has none yet.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import android.app.Application
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
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

val MailTool =
    ToolSpec(
        id = ToolId.MAIL,
        nameRes = R.string.mail_name,
        buttonRes = R.string.mail_button,
        buttonDescriptionRes = R.string.mail_button_description,
        icon = Icons.Filled.Email,
        content = { MailScreen(it) },
    )

@Composable
fun MailScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: MailViewModel = viewModel(factory = MailViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)
  val ui by vm.ui.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.MAIL, title = stringResource(R.string.mail_name), ui = ui, onClose = ctx.onClose) {
    Text(
        text = stringResource(R.string.tool_not_ready, stringResource(R.string.mail_name)),
        color = Color.White,
        fontSize = 22.sp,
    )
  }
}
