// LightTool - the light tool's registry entry and screen
//
// ToolRegistry lists [LightTool]; the router shows [LightScreen] when ToolHub.activeTool is this
// tool. The screen mirrors what's spoken, for sighted helpers, low-vision users and TalkBack: the
// mode, the tone's pitch (or "Tone off"), the brightness level, "Blinking", and in colour mode a
// large swatch of the measured colour with its name (the spoken sentence, hedges included). Big
// buttons do what the voice commands do; each plays the ACK earcon. Test tags: light_mode,
// light_tone_hz, light_level, light_blinking, light_swatch, light_colour_name, light_button_*.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LightMode
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
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

val LightTool =
    ToolSpec(
        id = ToolId.LIGHT,
        nameRes = R.string.light_name,
        buttonRes = R.string.light_button,
        buttonDescriptionRes = R.string.light_button_description,
        icon = Icons.Filled.LightMode,
        content = { LightScreen(it) },
    )

@Composable
fun LightScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: LightViewModel = viewModel(factory = LightViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)
  val ui by vm.ui.collectAsStateWithLifecycle()
  val s by vm.state.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.LIGHT, title = stringResource(R.string.light_name), ui = ui, onClose = ctx.onClose) {
    Text(
        text = stringResource(if (s.mode == LightMode.COLOUR) R.string.light_mode_colour_label else R.string.light_mode_probe_label),
        color = Color.White,
        fontSize = 22.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.testTag("light_mode"),
    )
    if (s.mode == LightMode.PROBE) {
      Text(
          text = if (s.toneHz > 0f) stringResource(R.string.light_tone_hz, s.toneHz.toInt()) else stringResource(R.string.light_tone_silent),
          color = ToolAccent,
          fontSize = 34.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.testTag("light_tone_hz"),
      )
      s.level?.let { level ->
        Text(
            text = stringResource(levelRes(level)),
            color = Color.White,
            fontSize = 28.sp,
            modifier = Modifier.testTag("light_level"),
        )
      }
      if (s.blinking) {
        Text(
            text = stringResource(R.string.light_blinking_label),
            color = ToolAccent,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.testTag("light_blinking").semantics { liveRegion = LiveRegionMode.Polite },
        )
      }
    } else {
      val description = s.colourText.ifEmpty { stringResource(R.string.light_no_colour_yet) }
      val swatchLabel = stringResource(R.string.light_swatch_description, description)
      Box(
          modifier =
              Modifier.fillMaxWidth()
                  .height(180.dp)
                  .border(3.dp, Color.White, RoundedCornerShape(12.dp))
                  .background(s.swatch?.let { Color(it) } ?: Color.DarkGray, RoundedCornerShape(12.dp))
                  .testTag("light_swatch")
                  .semantics { contentDescription = swatchLabel },
      )
      Text(
          text = description,
          color = Color.White,
          fontSize = 28.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.testTag("light_colour_name").semantics { liveRegion = LiveRegionMode.Polite },
      )
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
      if (s.mode == LightMode.PROBE) {
        BigButton(stringResource(R.string.light_button_how_bright), "light_button_how_bright", Modifier.weight(1f)) { vm.tapHowBright() }
        BigButton(
            stringResource(if (s.probing) R.string.light_button_tone_off else R.string.light_button_tone_on),
            "light_button_tone",
            Modifier.weight(1f),
        ) { vm.tapTone() }
      } else {
        BigButton(stringResource(R.string.light_button_measure), "light_button_measure", Modifier.weight(1f)) { vm.tapMeasure() }
      }
    }
    if (s.mode == LightMode.PROBE) {
      BigButton(stringResource(R.string.light_button_colour_mode), "light_button_colour_mode", Modifier.fillMaxWidth()) { vm.tapColour() }
    } else {
      BigButton(stringResource(R.string.light_button_light_mode), "light_button_light_mode", Modifier.fillMaxWidth()) { vm.tapLight() }
    }
  }
}

@Composable
private fun BigButton(label: String, tag: String, modifier: Modifier, onClick: () -> Unit) {
  Button(
      onClick = onClick,
      colors = ButtonDefaults.buttonColors(containerColor = ToolAccent, contentColor = Color.Black),
      modifier = modifier.heightIn(min = 64.dp).testTag(tag),
  ) {
    Text(text = label, fontSize = 22.sp, fontWeight = FontWeight.Bold)
  }
}

private fun levelRes(level: LightLevel): Int =
    when (level) {
      LightLevel.DARK -> R.string.light_level_dark
      LightLevel.DIM -> R.string.light_level_dim
      LightLevel.NORMAL -> R.string.light_level_normal
      LightLevel.BRIGHT -> R.string.light_level_bright
      LightLevel.VERY_BRIGHT -> R.string.light_level_very_bright
    }
