// PitfallsTest - the reader explains what's wrong, out loud, and recovers
//
// Voice-first launch on mock HSTN glasses, then one thing going wrong after another: lens covered,
// room too dark, then a real page; glasses battery low, glasses taken off and put back on,
// overheating (the glasses end the session) and cooling; folded, then unfolded and worn again
// (reconnects by itself). Each spoken
// message is also put on the status line, which is what this asserts.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.util.Log
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.ThermalLevel
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import java.io.File
import java.io.FileOutputStream
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class PitfallsTest {

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

  @Before
  fun setup() {
    listOf("BLUETOOTH", "BLUETOOTH_CONNECT", "CAMERA", "INTERNET").forEach {
      InstrumentationRegistry.getInstrumentation()
          .uiAutomation
          .executeShellCommand("pm grant ${ctx.packageName} android.permission.$it")
    }
    ctx.getSharedPreferences("book_reader", Context.MODE_PRIVATE).edit().clear().commit()
  }

  @After
  fun tearDown() {
    scenario?.close()
    MockDeviceKit.getInstance(ctx).disable()
  }

  @Test
  fun explainsAndRecoversFromEachPitfall() {
    val page = BookPageRenderer.render(960, 1440, listOf(BookPageRenderer.houndPage))
    val covered = Bitmap.createBitmap(960, 1440, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(4, 4, 4)) }
    val dark = darken(page)

    val kit = MockDeviceKit.getInstance(ctx)
    kit.enable(MockDeviceKitConfig(initialPermissionsGranted = true))
    kit.permissions.set(Permission.CAMERA, PermissionStatus.Granted)
    kit.permissions.set(Permission.MICROPHONE, PermissionStatus.Granted)
    val glasses = kit.pairGlasses(GlassesModel.OAKLEY_META_HSTN).getOrThrow()
    glasses.powerOn()
    glasses.don()
    glasses.unfold()
    glasses.setBatteryLevel(80)
    glasses.services.camera.setCameraFeed(assetUri("plant.mp4"))
    glasses.services.camera.setCapturedImage(save(covered, "covered.png"))

    scenario =
        ActivityScenario.launch(
            Intent(ctx, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_BOOK_READER, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    waitFor("glasses mic") { text("book_voice_mic") == onGlasses }
    say(glasses, "stop detecting page turns")
    waitFor("heard") { text("book_voice_heard")?.contains("page turns") == true }

    // Lens covered: said at once, before any OCR.
    say(glasses, "read")
    waitForStatus(R.string.book_hint_covered)
    // The automatic retry sees a dark room next...
    glasses.services.camera.setCapturedImage(save(dark, "dark.png"))
    waitForStatus(R.string.book_hint_dark, timeout = 30_000)
    // ...and then a readable page.
    glasses.services.camera.setCapturedImage(save(page, "page.png"))
    waitFor("page read", 60_000) { text("book_page_text")?.contains("Penang") == true }

    glasses.setBatteryLevel(9)
    waitFor("battery") { status() == ctx.getString(R.string.health_glasses_battery_low, 9) }

    glasses.doff()
    waitForStatus(R.string.health_removed)
    glasses.don()
    waitForStatus(R.string.health_worn_again)

    glasses.setThermalLevel(ThermalLevel.CRITICAL)
    waitForStatus(R.string.health_too_hot)
    glasses.setThermalLevel(ThermalLevel.NONE)
    waitForStatus(R.string.health_cooled)

    // Folding drops the link; unfolding brings it back without anyone touching the phone.
    glasses.fold()
    waitFor("disconnected/stream lost", 30_000) {
      status() in
          setOf(
              ctx.getString(R.string.health_disconnected),
              ctx.getString(R.string.book_status_stream_lost),
              ctx.getString(R.string.health_removed),
          )
    }
    // Unfold and put them back on: the reader reconnects on its own.
    glasses.unfold()
    glasses.don()
    waitForStatus(R.string.book_say_glasses_back, timeout = 45_000)
  }

  // MARK: - Helpers

  private fun say(glasses: MockGlasses, text: String) {
    Log.i("PitfallsTest", "say \"$text\"")
    glasses.services.speech.simulateTranscription(text, true, 0.9f)
  }

  private fun waitForStatus(id: Int, timeout: Long = 20_000) {
    val want = ctx.getString(id)
    waitFor("status \"$want\"", timeout) { status() == want }
  }

  private fun waitFor(what: String, timeout: Long = 20_000, condition: () -> Boolean) {
    try {
      composeTestRule.waitUntil(timeoutMillis = timeout, condition = condition)
    } catch (e: Throwable) {
      throw AssertionError("Timed out waiting for $what. Status was \"${status()}\"", e)
    }
  }

  private fun status(): String? = text("book_status")

  private fun text(tag: String): String? =
      composeTestRule
          .onAllNodes(hasTestTag(tag), useUnmergedTree = true)
          .fetchSemanticsNodes()
          .firstOrNull()
          ?.config
          ?.getOrNull(SemanticsProperties.Text)
          ?.joinToString("") { it.text }

  private fun darken(src: Bitmap): Bitmap {
    val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
    val paint = Paint().apply { colorFilter = PorterDuffColorFilter(Color.rgb(50, 50, 50), PorterDuff.Mode.MULTIPLY) }
    Canvas(out).drawBitmap(src, 0f, 0f, paint)
    return out
  }

  private fun save(bitmap: Bitmap, name: String) = BookPageRenderer.savePng(bitmap, ctx.cacheDir, name)

  private fun assetUri(assetName: String): android.net.Uri {
    val outFile = File(ctx.cacheDir, assetName)
    InstrumentationRegistry.getInstrumentation().context.assets.open(assetName).use { input ->
      FileOutputStream(outFile).use { output -> input.copyTo(output) }
    }
    return android.net.Uri.fromFile(outFile)
  }
}
