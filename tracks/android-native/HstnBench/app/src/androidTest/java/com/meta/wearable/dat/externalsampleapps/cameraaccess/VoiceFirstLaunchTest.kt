// VoiceFirstLaunchTest - "Open Book Reader" with no taps at all
//
// A blind user starts the app by voice and never touches the screen. This launches MainActivity the
// way the Book Reader launcher alias does (EXTRA_BOOK_READER), with mock HSTN glasses already paired,
// worn and unfolded. It expects the reader to open by itself, the session and stream to come up
// without dialogs, the glasses' recogniser to start, and then a spoken "read" to read the page.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.content.Intent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import java.io.File
import java.io.FileOutputStream
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
@LargeTest
class VoiceFirstLaunchTest {

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val targetContext: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

  @Before
  fun setup() {
    listOf("BLUETOOTH", "BLUETOOTH_CONNECT", "CAMERA", "INTERNET").forEach {
      InstrumentationRegistry.getInstrumentation()
          .uiAutomation
          .executeShellCommand("pm grant ${targetContext.packageName} android.permission.$it")
    }
    targetContext.getSharedPreferences("book_reader", Context.MODE_PRIVATE).edit().clear().commit()
  }

  @After
  fun tearDown() {
    scenario?.close()
    MockDeviceKit.getInstance(targetContext).disable()
  }

  @Test
  fun launchesStraightIntoAListeningReaderAndReadsOnVoice() {
    val pageUri =
        BookPageRenderer.savePng(
            BookPageRenderer.render(960, 1440, listOf(BookPageRenderer.houndPage)),
            targetContext.cacheDir,
            "book_page.png",
        )
    val kit = MockDeviceKit.getInstance(targetContext)
    kit.enable(MockDeviceKitConfig(initialPermissionsGranted = true))
    kit.permissions.set(Permission.CAMERA, PermissionStatus.Granted)
    kit.permissions.set(Permission.MICROPHONE, PermissionStatus.Granted)
    val glasses = kit.pairGlasses(GlassesModel.OAKLEY_META_HSTN).getOrThrow()
    glasses.powerOn()
    glasses.don()
    glasses.unfold()
    glasses.services.camera.setCameraFeed(assetUri("plant.mp4"))
    glasses.services.camera.setCapturedImage(pageUri)

    scenario =
        ActivityScenario.launch(
            Intent(targetContext, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_BOOK_READER, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )

    // The reader is the first screen, with nothing tapped.
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { exists("book_reader_screen") }
    // The session and stream come up on their own, and the glasses start listening.
    val onGlasses = targetContext.getString(R.string.voice_mic_glasses)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { text("book_voice_mic") == onGlasses }

    glasses.services.speech.simulateTranscription("stop detecting page turns", true, 0.9f)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) {
      text("book_voice_heard")?.contains("page turns") == true
    }
    glasses.services.speech.simulateTranscription("read", true, 0.9f)
    composeTestRule.waitUntil(timeoutMillis = READ_TIMEOUT) {
      text("book_page_text")?.contains("Penang") == true
    }
  }

  private fun exists(tag: String): Boolean =
      composeTestRule.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes().isNotEmpty()

  private fun text(tag: String): String? =
      composeTestRule
          .onAllNodes(hasTestTag(tag), useUnmergedTree = true)
          .fetchSemanticsNodes()
          .firstOrNull()
          ?.config
          ?.getOrNull(SemanticsProperties.Text)
          ?.joinToString("") { it.text }

  private fun assetUri(assetName: String): android.net.Uri {
    val outFile = File(targetContext.cacheDir, assetName)
    InstrumentationRegistry.getInstrumentation().context.assets.open(assetName).use { input ->
      FileOutputStream(outFile).use { output -> input.copyTo(output) }
    }
    return android.net.Uri.fromFile(outFile)
  }

  private companion object {
    const val TIMEOUT = 30_000L
    const val READ_TIMEOUT = 60_000L
  }
}
