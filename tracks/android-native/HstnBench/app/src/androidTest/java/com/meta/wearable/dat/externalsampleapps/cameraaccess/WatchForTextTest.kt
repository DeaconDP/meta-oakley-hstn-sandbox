// WatchForTextTest - Watch for text on the Mock Device Kit, with a rendered street video
//
// The mock glasses stream a looping video made on the phone from rendered frames: an empty street
// (sky, buildings, a "CAFE" sign on the left, road), then a sign reading "42" on the right, then the
// empty street again, then "421" on the right (which must not count as 42), then "24" (a near miss).
// The tests check, through what was sent to speech (hub.recentSpeech):
//  - launched voice-first with argument 42: the "not a mobility aid" start line, "42, on your
//    right." once, "42, gone." after it leaves the view, no announcement while 421 is in view (while
//    the screen shows OCR reading 421), and "I see 24, not 42.";
//  - opened by voice from another tool ("watch for 42" in the mail tool), then "where is it",
//    "what are you watching for" and "stop watching" by voice;
//  - the cost: OCR time per frame at the stream's size and the app's CPU while watching, against
//    the same app streaming with nothing watched (logged as "WatchCost" and sent as instrumentation
//    status).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class WatchForTextTest {

  companion object {
    const val TIMEOUT = 30_000L
    const val SIGHT_TIMEOUT = 60_000L
    private const val TAG = "WatchCost"
  }

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  // MARK: frames

  private val w = MockVideo.WIDTH
  private val h = MockVideo.HEIGHT

  /** Sky, two buildings, a small "CAFE" sign on the left, and a road. Bright enough to read. */
  private fun street(): Bitmap =
      Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { b ->
        val c = Canvas(b)
        val sky = Paint().apply { shader = LinearGradient(0f, 0f, 0f, h * 0.45f, Color.rgb(150, 190, 235), Color.rgb(215, 230, 245), Shader.TileMode.CLAMP) }
        c.drawRect(0f, 0f, w.toFloat(), h * 0.45f, sky)
        c.drawRect(0f, h * 0.2f, w * 0.45f, h * 0.7f, Paint().apply { color = Color.rgb(150, 120, 100) })
        c.drawRect(w * 0.55f, h * 0.15f, w.toFloat(), h * 0.7f, Paint().apply { color = Color.rgb(170, 170, 160) })
        c.drawRect(0f, h * 0.7f, w.toFloat(), h.toFloat(), Paint().apply { color = Color.rgb(80, 80, 85) })
        c.drawRect(w * 0.05f, h * 0.45f, w * 0.35f, h * 0.5f, Paint().apply { color = Color.rgb(240, 235, 220) })
        val small = Paint().apply {
          color = Color.rgb(40, 40, 40)
          textSize = 30f
          typeface = Typeface.DEFAULT_BOLD
          isAntiAlias = true
        }
        c.drawText("CAFE", w * 0.11f, h * 0.488f, small)
      }

  /** The street with a white sign on the right showing [text] in large black type. */
  private fun withSign(text: String): Bitmap =
      street().also { b ->
        val c = Canvas(b)
        val paint = Paint().apply {
          color = Color.BLACK
          textSize = 96f
          typeface = Typeface.DEFAULT_BOLD
          isAntiAlias = true
          textAlign = Paint.Align.CENTER
        }
        val cx = w * 0.8f
        val tw = paint.measureText(text)
        c.drawRect(cx - tw / 2 - 16f, h * 0.30f, cx + tw / 2 + 16f, h * 0.30f + 130f, Paint().apply { color = Color.WHITE })
        c.drawText(text, cx, h * 0.30f + 100f, paint)
      }

  /** 3 s empty, 4 s "42" on the right, 6 s empty, 5 s "421", 5 s "24"; loops (23 s). */
  private fun scenes(): List<Bitmap> {
    val empty = street()
    val s42 = withSign("42")
    val s421 = withSign("421")
    val s24 = withSign("24")
    return List(3) { empty } + List(4) { s42 } + List(6) { empty } + List(5) { s421 } + List(5) { s24 }
  }

  private fun waitForSpeech(hub: ToolHub, timeout: Long = SIGHT_TIMEOUT, what: (String) -> Boolean) =
      compose.waitUntil(timeoutMillis = timeout) { hub.recentSpeech().any(what) }

  private fun read(): String = ToolTestKit.text(compose, "watch_read") ?: ""

  private fun report(key: String, value: String) {
    Log.i(TAG, "$key: $value")
    InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("watch_$key", value) })
  }

  // MARK: tests

  @Test
  fun announcesFortyTwoOnTheRightThenGoneAndIgnoresFourTwentyOne() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.playFrames(glasses, scenes(), holdMs = 1_000L, name = "watch_street.mp4")
    scenario = ToolTestKit.launch(ToolRequest(ToolId.WATCH, argument = "42"))
    val hub = ToolTestKit.hub(scenario!!)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "tool_screen_watch") }

    val start = ctx.getString(R.string.watch_start_first, "42")
    waitForSpeech(hub, TIMEOUT) { it == start }
    assertTrue(start.contains("cane or dog"))

    val seen = ctx.getString(R.string.watch_seen, "42", ctx.getString(R.string.watch_right))
    waitForSpeech(hub) { it == seen }
    assertEquals("announced once per sighting", 1, hub.recentSpeech().count { it == seen })
    assertTrue(ToolTestKit.text(compose, "watch_last")?.contains(seen) == true)

    val gone = ctx.getString(R.string.watch_gone, "42")
    waitForSpeech(hub) { it == gone }
    val afterGone = hub.recentSpeech().lastIndexOf(gone)

    // Now 421 comes into view: OCR reads it, and it must not be announced as 42.
    compose.waitUntil(timeoutMillis = TIMEOUT) { Regex("\\b421\\b").containsMatchIn(read()) }
    // Keep looking while 421 stays in view (it's on for 5 s, at 2 frames a second).
    Thread.sleep(4_000L)
    val since = hub.recentSpeech().drop(afterGone + 1)
    Log.i(TAG, "speech while 421 was in view: $since")
    assertFalse("421 announced as 42: $since", since.any { it.startsWith("42,") && it != gone })

    // Then 24: a near miss, said once.
    val nearMiss = ctx.getString(R.string.watch_near_miss, "24", "42")
    waitForSpeech(hub, TIMEOUT) { it == nearMiss }

    // And when the video loops, 42 comes back and is announced again.
    compose.waitUntil(timeoutMillis = SIGHT_TIMEOUT) { hub.recentSpeech().count { it == seen } >= 2 }

    val pace = ToolTestKit.text(compose, "watch_pace") ?: ""
    report("pace_streaming_480x864", pace)
  }

  @Test
  fun opensByVoiceFromAnotherToolAndTakesCommands() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.playFrames(glasses, scenes(), holdMs = 1_000L, name = "watch_street.mp4")
    scenario = ToolTestKit.launch(ToolRequest(ToolId.MAIL))
    val hub = ToolTestKit.hub(scenario!!)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "tool_screen_mail") }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "tool_voice_mic") == onGlasses }

    ToolTestKit.say(glasses, "watch for 42")
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "tool_screen_watch") }
    assertEquals(ToolRequest(ToolId.WATCH, argument = "42"), hub.activeTool.value)
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_start_first, "42") }
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "watch_target") == ctx.getString(R.string.watch_screen_target, "42") }

    ToolTestKit.say(glasses, "what are you watching for")
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_what_target, "42") }

    val seen = ctx.getString(R.string.watch_seen, "42", ctx.getString(R.string.watch_right))
    waitForSpeech(hub) { it == seen }
    ToolTestKit.say(glasses, "where is it")
    val right = ctx.getString(R.string.watch_right)
    waitForSpeech(hub, TIMEOUT) { s ->
      s == ctx.getString(R.string.watch_where_in_view, "42", right) ||
          s.startsWith(ctx.getString(R.string.watch_where_last_seen, "42", right, 0).substringBefore(","))
    }

    ToolTestKit.say(glasses, "watch for something else, 73")
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_start, "73") }

    ToolTestKit.say(glasses, "stop watching")
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_stopped, "73") }
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "watch_target") == ctx.getString(R.string.watch_screen_stopped, "73") }

    ToolTestKit.say(glasses, "close")
    compose.waitUntil(timeoutMillis = TIMEOUT) { hub.activeTool.value == null }
  }

  @Test
  fun measuresOcrTimeAndCpu() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.playFrames(glasses, scenes(), holdMs = 1_000L, name = "watch_street.mp4")
    // No target: it asks, and reads no frames. That's the baseline.
    scenario = ToolTestKit.launch(ToolRequest(ToolId.WATCH))
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)
    compose.waitUntil(timeoutMillis = TIMEOUT) { camera.isStreaming.value }
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_ask_target) }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "tool_voice_mic") == onGlasses }
    Thread.sleep(3_000L)

    fun cpuPercent(window: Long): Float {
      val cpu0 = Process.getElapsedCpuTime()
      val t0 = SystemClock.elapsedRealtime()
      Thread.sleep(window)
      return 100f * (Process.getElapsedCpuTime() - cpu0) / (SystemClock.elapsedRealtime() - t0)
    }

    val base = cpuPercent(15_000L)
    report("cpu_streaming_not_watching", "%.0f%% of one core".format(base))

    // The answer to "What should I watch for?" (in words: the prompt itself says "like 42", and the
    // echo guard would take a bare "42" for our own voice coming back).
    ToolTestKit.say(glasses, "forty two")
    waitForSpeech(hub, TIMEOUT) { it == ctx.getString(R.string.watch_start_first, "42") }
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "watch_pace") }
    Thread.sleep(3_000L)
    val watching = cpuPercent(30_000L)
    val pace = ToolTestKit.text(compose, "watch_pace") ?: ""
    report("cpu_watching", "%.0f%% of one core".format(watching))
    report("pace", pace)
    Log.i(TAG, "base=%.1f watching=%.1f pace=%s".format(base, watching, pace))
    // Reading must keep up with at least one look a second.
    val fps = Regex("([0-9.]+) looks a second").find(pace)?.groupValues?.get(1)?.toFloatOrNull() ?: 0f
    assertTrue("OCR can't keep up: $pace", fps >= 1f)
  }
}
