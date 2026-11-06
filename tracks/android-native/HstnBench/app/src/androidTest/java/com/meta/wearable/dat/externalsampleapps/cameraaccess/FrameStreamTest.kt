// FrameStreamTest - decoded stream frames for continuous tools (PageCamera.frames / latestFrame)
//
// The mock glasses stream a video built on the phone from two rendered scenes (a bright block on
// the left, then on the right, one second each). A tool opened voice-first brings the stream up; the
// test then collects CameraViewModel.frames and checks that frames arrive at about the asked rate,
// have the video's size, and change over time (both scenes seen), on both paths: copied off the
// preview Surface (the normal case) and decoded by the fallback FrameGrabber (as with the screen
// off). It also measures what each costs the app in CPU (logged as "FrameCost"; see
// notes/tools-layer.md).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class FrameStreamTest {

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  /** A dark scene with a white block on the left or the right half. */
  private fun scene(left: Boolean): Bitmap =
      Bitmap.createBitmap(MockVideo.WIDTH, MockVideo.HEIGHT, Bitmap.Config.ARGB_8888).apply {
        eraseColor(Color.rgb(20, 20, 20))
        val x0 = if (left) 0f else MockVideo.WIDTH / 2f
        Canvas(this).drawRect(x0, 0f, x0 + MockVideo.WIDTH / 2f, MockVideo.HEIGHT.toFloat(), Paint().apply { color = Color.WHITE })
      }

  /** Mean brightness of the left half minus the right half: > 0 left scene, < 0 right scene. */
  private fun leftMinusRight(b: Bitmap): Int {
    var left = 0L
    var right = 0L
    val step = 8
    for (y in 0 until b.height step step) for (x in 0 until b.width step step) {
      val g = Color.green(b.getPixel(x, y))
      if (x < b.width / 2) left += g else right += g
    }
    val n = (b.height / step) * (b.width / step) / 2
    return ((left - right) / n).toInt()
  }

  @Test
  fun framesArriveWithTheStreamSizeAndChange() = checkFrames(previewCopy = true)

  @Test
  fun framesArriveWhenDecodedWithoutThePreview() = checkFrames(previewCopy = false)

  private fun checkFrames(previewCopy: Boolean) {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.playFrames(glasses, listOf(scene(left = true), scene(left = false)), holdMs = 1_000L)
    // The light tool is a stub that only connects: a quiet way to bring the stream up voice-first.
    scenario = ToolTestKit.launch(ToolRequest(ToolId.LIGHT))
    val camera = ToolTestKit.camera(scenario!!)
    camera.previewCopyEnabled = previewCopy
    composeTestRule.waitUntil(timeoutMillis = 30_000L) { camera.isStreaming.value }

    val started = SystemClock.elapsedRealtime()
    val frames = runBlocking { withTimeout(30_000L) { camera.frames(maxFps = 5f).take(20).toList() } }
    val seconds = (SystemClock.elapsedRealtime() - started) / 1000f
    val signs = frames.map { leftMinusRight(it) }
    Log.i("FrameStreamTest", "previewCopy=$previewCopy 20 frames in ${seconds}s sizes=${frames.map { "${it.width}x${it.height}" }.distinct()} leftMinusRight=$signs")

    frames.forEach {
      assertEquals(MockVideo.WIDTH, it.width)
      assertEquals(MockVideo.HEIGHT, it.height)
    }
    assertTrue("left scene never seen: $signs", signs.any { it > 100 })
    assertTrue("right scene never seen: $signs", signs.any { it < -100 })
    // 20 frames at <= 5 fps take at least ~4 s (the first may come as soon as the decoder starts).
    assertTrue("throttle not applied: ${seconds}s", seconds >= 3.5f)

    val latest = runBlocking { camera.latestFrame() }
    assertNotNull(latest)
  }

  @Test
  fun measuresTheCostOfDecodingFrames() {
    ToolTestKit.pairHstn()
    scenario = ToolTestKit.launch(ToolRequest(ToolId.LIGHT))
    val camera = ToolTestKit.camera(scenario!!)
    composeTestRule.waitUntil(timeoutMillis = 30_000L) { camera.isStreaming.value }
    Thread.sleep(3_000L)

    fun cpuPercent(window: Long, collect: Float?): Pair<Float, Int> {
      var count = 0
      val cpu0 = Process.getElapsedCpuTime()
      val t0 = SystemClock.elapsedRealtime()
      if (collect == null) {
        Thread.sleep(window)
      } else {
        runBlocking {
          kotlinx.coroutines.withTimeoutOrNull(window) { camera.frames(collect).collect { count++ } }
        }
      }
      val cpu = Process.getElapsedCpuTime() - cpu0
      val wall = SystemClock.elapsedRealtime() - t0
      return 100f * cpu / wall to count
    }

    val window = 10_000L
    val (base, _) = cpuPercent(window, null)
    Log.i("FrameCost", "streaming only (preview decode, no frames collected): app CPU %.1f%% of one core".format(base))
    var n2 = 0
    var n5 = 0
    for (copy in listOf(true, false)) {
      camera.previewCopyEnabled = copy
      for (fps in listOf(2f, 5f, 10f)) {
        val (cpu, n) = cpuPercent(window, fps)
        val path = if (copy) "preview copy" else "decoder"
        Log.i("FrameCost", "%s frames(%.0f): app CPU %.1f%% of one core, %d frames in %d s; %s".format(path, fps, cpu, n, window / 1000, camera.frameGrabberStats()))
        if (copy && fps == 2f) n2 = n
        if (copy && fps == 5f) n5 = n
      }
    }
    camera.previewCopyEnabled = true
    val (baseAfter, _) = cpuPercent(window, null)
    Log.i("FrameCost", "streaming only, again at the end: app CPU %.1f%% of one core".format(baseAfter))
    assertTrue("no frames at 2 fps", n2 >= 10)
    assertTrue("no frames at 5 fps", n5 >= 25)
  }
}
