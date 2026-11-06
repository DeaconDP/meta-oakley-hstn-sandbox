// LightToolTest - the light and colour tool on the mock glasses
//
// - The probe: the mock streams dark -> bright -> dark scenes (looping) and the probe tone's
//   frequency (on LightState, since tests can't hear) goes up then down again. "Quiet" silences it
//   at once, "carry on" brings it back, and switching to another tool by voice stops it.
// - Colour: a solid navy patch in the middle of a grey room, opened in colour mode by the deep link
//   hstnbench://light?mode=colour, is spoken as navy blue, shown on the screen, and "again" measures
//   again.
// - Cost: app CPU with the probe running at 2, 4 and 5 frames a second against colour mode (stream
//   only), logged as "LightCost" (notes/light-and-colour.md > CPU cost).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightMode
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightViewModel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class LightToolTest {

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  private fun solid(grey: Int): Bitmap =
      Bitmap.createBitmap(MockVideo.WIDTH, MockVideo.HEIGHT, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(grey, grey, grey)) }

  /** A grey room with a [colour] square, 40% of the width, in the middle. */
  private fun patch(colour: Int): Bitmap =
      solid(128).apply {
        val side = MockVideo.WIDTH * 0.4f
        val x0 = (MockVideo.WIDTH - side) / 2
        val y0 = (MockVideo.HEIGHT - side) / 2
        Canvas(this).drawRect(x0, y0, x0 + side, y0 + side, Paint().apply { color = colour })
      }

  /** The activity's LightViewModel: the same instance the screen uses (activity-scoped). */
  private fun light(s: ActivityScenario<MainActivity>): LightViewModel {
    val hub = ToolTestKit.hub(s)
    var vm: LightViewModel? = null
    s.onActivity { vm = ViewModelProvider(it, LightViewModel.Factory(it.application, hub))[LightViewModel::class.java] }
    return vm!!
  }

  private fun waitForGlassesMic() {
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) {
      ToolTestKit.text(composeTestRule, "tool_voice_mic") == ctx.getString(R.string.voice_mic_glasses)
    }
  }

  @Test
  fun probeToneRisesWithBrightnessThenFalls() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.playFrames(glasses, listOf(solid(20), solid(230), solid(20)), holdMs = 2_500L)
    scenario = ToolTestKit.launch(ToolRequest(ToolId.LIGHT))
    val vm = light(scenario!!)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(composeTestRule, "tool_screen_light") }
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { vm.state.value.toneHz > 0f }
    assertEquals(LightMode.PROBE, vm.state.value.mode)

    // Sample the tone for two loops of the clip (7.5 s each).
    val samples = mutableListOf<Float>()
    val end = SystemClock.elapsedRealtime() + 16_000L
    while (SystemClock.elapsedRealtime() < end) {
      samples += vm.state.value.toneHz
      Thread.sleep(100)
    }
    Log.i(TAG, "tone samples: ${samples.map { it.toInt() }}")
    val lo = samples.filter { it > 0 }.min()
    val hi = samples.max()
    assertTrue("range $lo..$hi", hi - lo > 600f)
    // Up then down: a high sample after a low one, and a low one after that.
    val firstLow = samples.indexOfFirst { it in 1f..lo + 150f }
    val highAfter = samples.withIndex().indexOfFirst { (i, v) -> i > firstLow && v > hi - 150f }
    val lowAfter = samples.withIndex().indexOfFirst { (i, v) -> i > highAfter && v in 1f..lo + 150f }
    assertTrue("low $firstLow, high $highAfter, low $lowAfter in ${samples.map { it.toInt() }}", firstLow >= 0 && highAfter > firstLow && lowAfter > highAfter)
    // The screen mirrors it.
    assertTrue(ToolTestKit.text(composeTestRule, "light_tone_hz")!!.startsWith("Tone "))

    // "Quiet" stops the tone at once; "carry on" brings it back.
    waitForGlassesMic()
    ToolTestKit.say(glasses, "quiet")
    composeTestRule.waitUntil(timeoutMillis = 2_000L) { vm.state.value.toneHz == 0f && vm.state.value.paused }
    Thread.sleep(1_500L)
    assertEquals("tone came back by itself", 0f, vm.state.value.toneHz)
    assertTrue(ToolTestKit.hub(scenario!!).recentSpeech().contains(ctx.getString(R.string.light_tone_off)))
    ToolTestKit.say(glasses, "carry on")
    composeTestRule.waitUntil(timeoutMillis = 5_000L) { vm.state.value.toneHz > 0f }

    // Switching tools stops it.
    ToolTestKit.say(glasses, "read my mail")
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(composeTestRule, "tool_screen_mail") }
    composeTestRule.waitUntil(timeoutMillis = 2_000L) { vm.state.value.toneHz == 0f && !vm.state.value.probing }
    Thread.sleep(1_500L)
    assertEquals(0f, vm.state.value.toneHz)
  }

  @Test
  fun namesANavyPatchOpenedInColourModeByDeepLink() {
    val glasses = ToolTestKit.pairHstn()
    val navy = Color.rgb(20, 30, 95)
    ToolTestKit.playFrames(glasses, listOf(patch(navy)), holdMs = 1_000L)
    ToolTestKit.showImage(glasses, patch(navy))
    scenario = ToolTestKit.launchDeepLink("hstnbench://light?mode=colour")
    val hub = ToolTestKit.hub(scenario!!)
    val vm = light(scenario!!)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(composeTestRule, "tool_screen_light") }
    assertEquals(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR), hub.activeTool.value)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { vm.state.value.colourText.isNotEmpty() }
    val answer = vm.state.value.colourText
    val result = vm.state.value.colour!!
    Log.i(TAG, "colour answer: $answer (${result.confidence}, ${result.reasons}, swatch=#%06x)".format(vm.state.value.swatch!! and 0xFFFFFF))
    assertTrue(answer, answer.lowercase().contains("navy blue"))
    assertEquals(LightMode.COLOUR, vm.state.value.mode)
    assertEquals(0f, vm.state.value.toneHz)
    composeTestRule.waitUntil(timeoutMillis = 5_000L) { hub.recentSpeech().any { it == answer } }
    assertEquals(answer, ToolTestKit.text(composeTestRule, "light_colour_name"))

    // "Again" measures again (by voice); still navy.
    waitForGlassesMic()
    val before = hub.recentSpeech().count { it.lowercase().contains("navy") }
    ToolTestKit.say(glasses, "again")
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { hub.recentSpeech().count { it.lowercase().contains("navy") } > before }
  }

  @Test
  fun measuresTheProbeCost() {
    ToolTestKit.pairHstn()
    scenario = ToolTestKit.launch(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR))
    val vm = light(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { camera.isStreaming.value }
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { vm.state.value.colourText.isNotEmpty() }
    Thread.sleep(3_000L)

    fun cpu(window: Long): Float {
      val cpu0 = Process.getElapsedCpuTime()
      val t0 = SystemClock.elapsedRealtime()
      Thread.sleep(window)
      return 100f * (Process.getElapsedCpuTime() - cpu0) / (SystemClock.elapsedRealtime() - t0)
    }

    val window = 10_000L
    val results = mutableListOf<String>()
    results += "colour mode (stream only): %.1f%%".format(cpu(window))
    for (fps in listOf(2f, 4f, 5f, 4f)) {
      vm.probeFps = fps
      scenario!!.onActivity { vm.tapLight() }
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { vm.state.value.toneHz > 0f }
      Thread.sleep(1_500L)
      val c = cpu(window)
      val s = vm.state.value
      results += "probe %.0f fps: %.1f%%, %d frames, %.2f ms/frame analysis".format(fps, c, s.probeFrames, s.probeFrameMs)
      scenario!!.onActivity { vm.tapColour() }
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { !vm.state.value.probing }
      Thread.sleep(2_000L)
    }
    results += "colour mode again: %.1f%%".format(cpu(window))
    results.forEach { Log.i("LightCost", "app CPU, % of one core: $it") }
    vm.probeFps = LightViewModel.DEFAULT_PROBE_FPS
  }

  private companion object {
    const val TAG = "LightToolTest"
    const val TIMEOUT = 30_000L
  }
}
