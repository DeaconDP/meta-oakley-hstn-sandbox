// PhoneCameraTest - SpeakUp on the phone alone: no glasses, no Meta AI (notes/phone-camera.md)
//
// Launched like the normal app icon with the camera source set to PHONE and no Mock Device Kit
// glasses at all. Hands-free is on (ToolTestKit.setUp), so the home menu brings the camera up by
// itself: on an emulator that's the virtual back camera. Checks the phone camera streams, gives a
// still (capturePage) and frames, produces a motion score, shows its preview, answers "which
// camera" and "torch on", and that a tool (the light detector) runs on it. Logs the timings that
// notes/phone-camera.md quotes.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.HandsFreeStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceSetting
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneCameraWording
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import kotlinx.coroutines.flow.first
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
class PhoneCameraTest {

  companion object {
    private const val TAG = "PhoneCameraTest"
    const val TIMEOUT = 30_000L
    /** A cold CameraX start on a loaded emulator can take minutes; a phone takes about a second. */
    const val FIRST_STREAM_TIMEOUT = 240_000L
  }

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before
  fun setup() {
    ToolTestKit.setUp()
    HandsFreeStore.get(ctx).setCameraSource(CameraSourceSetting.PHONE)
  }

  @After
  fun tearDown() {
    ToolTestKit.tearDown(scenario)
    HandsFreeStore.get(ctx).setCameraSource(CameraSourceSetting.AUTO)
  }

  private fun waitUntil(condition: () -> Boolean) =
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT, condition = condition)

  @Test
  fun thePhoneCameraStreamsAndGivesStillsAndFrames() {
    val launchedAt = SystemClock.elapsedRealtime()
    scenario = ToolTestKit.launchFromIcon()
    val hub = ToolTestKit.hub(scenario!!)
    assertEquals(CameraSource.PHONE, hub.cameraSource.value)

    // No glasses, no Meta AI: the camera screen shows straight away and the phone camera comes up.
    composeTestRule.waitUntil(timeoutMillis = FIRST_STREAM_TIMEOUT) { hub.camera.isStreaming.value }
    val streamingMs = SystemClock.elapsedRealtime() - launchedAt
    waitUntil { ToolTestKit.exists(composeTestRule, "phone_preview") }
    waitUntil { ToolTestKit.exists(composeTestRule, "camera_source_switch") }

    // A still for OCR.
    val t0 = SystemClock.elapsedRealtime()
    val still = runBlocking { hub.camera.capturePage() }
    val captureMs = SystemClock.elapsedRealtime() - t0
    assertNotNull("capturePage() on the phone", still)
    assertTrue("a usable still: ${still!!.width}x${still.height}", maxOf(still.width, still.height) >= 640)

    // Frames for continuous tools, upright (portrait), at most ~1024 px on the long side.
    val f0 = SystemClock.elapsedRealtime()
    val frames = runBlocking { withTimeout(15_000) { hub.camera.frames(5f).take(5).toList() } }
    val framesMs = SystemClock.elapsedRealtime() - f0
    assertEquals(5, frames.size)
    val frame = frames.first()
    assertTrue("upright: ${frame.width}x${frame.height}", frame.height >= frame.width)
    assertTrue("modest size: ${frame.width}x${frame.height}", maxOf(frame.width, frame.height) <= 1024)

    // A motion score for page turns.
    val motion = runBlocking { withTimeout(10_000) { hub.camera.motion.first() } }
    assertTrue("motion in 0..1: $motion", motion in 0f..1f)

    Log.i(
        TAG,
        "timings: launch->streaming ${streamingMs} ms, capture ${captureMs} ms " +
            "(${still.width}x${still.height}), 5 frames at 5 fps in ${framesMs} ms " +
            "(${frame.width}x${frame.height}), convert ${hub.phoneCamera.lastConvertMs} ms/frame",
    )

    // Spoken answers about the camera.
    ToolTestKit.waitForQuiet(hub)
    scenario!!.onActivity { hub.runCommand("which camera") }
    waitUntil { hub.recentSpeech().contains(PhoneCameraWording.which(CameraSource.PHONE, streaming = true)) }
    scenario!!.onActivity { hub.runCommand("torch on") }
    waitUntil {
      hub.recentSpeech().let { it.contains(PhoneCameraWording.TORCH_ON) || it.contains(PhoneCameraWording.NO_TORCH) }
    }
    scenario!!.onActivity { hub.runCommand("torch off") }

    // A tool runs on the phone camera: the light detector opens and keeps streaming.
    scenario!!.onActivity { hub.runCommand("light detector") }
    waitUntil { hub.activeTool.value?.tool == ToolId.LIGHT }
    waitUntil { ToolTestKit.exists(composeTestRule, "tool_screen_light") }
    val toolFrame = runBlocking { withTimeout(10_000) { hub.camera.frames(2f).first() } }
    assertNotNull(toolFrame)
    assertTrue(hub.camera.isStreaming.value)
  }
}
