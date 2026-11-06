// LabelsTool - the label reader's registry entry and screen
//
// ToolRegistry lists [LabelsTool]; the router shows [LabelsScreen] when ToolHub.activeTool is this
// tool. The screen mirrors what the voice side is doing, for sighted helpers, low-vision users and
// TalkBack: what it's doing (searching, found, looking up, reading), the barcode, the product, and
// the label text (never for medicine: the name only). Big buttons do what the voice commands do;
// none of them is the only way to do anything. Test tags: labels_phase, labels_code, labels_product,
// labels_text, labels_medicine, labels_scan, labels_lookup, labels_read, labels_expiry,
// labels_allergens.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
  val state by vm.state.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.LABELS, title = stringResource(R.string.labels_name), ui = ui, onClose = ctx.onClose) {
    Text(
        text =
            stringResource(
                when (state.phase) {
                  LabelsPhase.IDLE -> R.string.labels_phase_idle
                  LabelsPhase.SEARCHING -> R.string.labels_phase_searching
                  LabelsPhase.FOUND -> R.string.labels_phase_found
                  LabelsPhase.LOOKING_UP -> R.string.labels_phase_looking_up
                  LabelsPhase.READING -> R.string.labels_phase_reading
                },
            ),
        color = Color.White,
        fontSize = 22.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.testTag("labels_phase").semantics { liveRegion = LiveRegionMode.Polite },
    )
    state.code?.let { code ->
      Text(
          text = stringResource(R.string.labels_code_line, code.format, code.raw),
          color = Color.White,
          fontSize = 20.sp,
          modifier = Modifier.testTag("labels_code"),
      )
    }
    if (state.isMedicine) {
      Text(
          text = stringResource(R.string.labels_medicine_screen, state.medicineName ?: ""),
          color = Color(0xFFFFD54F),
          fontSize = 22.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.testTag("labels_medicine"),
      )
    }
    state.product?.let {
      Text(text = it, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold, modifier = Modifier.testTag("labels_product"))
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
      BigButton(R.string.labels_scan_button, "labels_scan", Modifier.weight(1f)) { vm.press(LabelsCommand.Scan) }
      BigButton(R.string.labels_lookup_button, "labels_lookup", Modifier.weight(1f)) { vm.press(LabelsCommand.LookUp) }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
      BigButton(R.string.labels_read_button, "labels_read", Modifier.weight(1f)) { vm.press(LabelsCommand.ReadLabel) }
      BigButton(R.string.labels_expiry_button, "labels_expiry", Modifier.weight(1f)) { vm.press(LabelsCommand.Expiry) }
      BigButton(R.string.labels_allergens_button, "labels_allergens", Modifier.weight(1f)) { vm.press(LabelsCommand.Allergens(null)) }
    }
    state.labelText?.let {
      Column(modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
        Text(text = it, color = Color.White, fontSize = 22.sp, lineHeight = 30.sp, modifier = Modifier.testTag("labels_text"))
      }
    }
  }
}

@Composable
private fun BigButton(label: Int, tag: String, modifier: Modifier, onClick: () -> Unit) {
  Button(
      onClick = onClick,
      colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black),
      modifier = modifier.heightIn(min = 64.dp).testTag(tag),
  ) {
    Text(text = stringResource(label), fontSize = 18.sp, fontWeight = FontWeight.Bold)
  }
}
