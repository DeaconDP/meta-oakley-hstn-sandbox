// BookReaderTest - the book reader end to end on the Mock Device Kit
//
// Renders a printed-book page, hands it to a mock Oakley Meta HSTN as its captured image
// (setCapturedImage, as InstrumentationTest does with plant.png), streams, opens the reader, and
// checks the text it reads: running header and page number dropped, words hyphenated across lines
// rejoined, paragraphs intact. A second capture of the same page must be reported as the same page.
// A third test drives the whole reader by voice: the mock glasses' on-glasses speech recogniser
// "hears" the commands (simulateTranscription), with no button presses after opening the reader.
// BookOcrPipelineTest runs real ML Kit on rendered pages without the mock, including a spread.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.util.Log
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageLayout
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.TextDistance
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.MlKitOcr
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
@LargeTest
class BookReaderTest {

  companion object {
    private const val TAG = "BookReaderTest"
    private const val STREAM_TIMEOUT = 20_000L
    // capturePhoto takes ~4 s on the mock; the first OCR also loads the model.
    private const val READ_TIMEOUT = 60_000L
    private const val END_OF_PAGE_TIMEOUT = 120_000L
    // Rendered text OCRs almost perfectly; allow a stray character or two.
    private const val MAX_CER = 0.02f
  }

  @get:Rule val composeTestRule = createAndroidComposeRule<MainActivity>()
  private val targetContext: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

  @Before
  fun setup() {
    // Touch-driven: keep the home voice menu from starting the session under the taps.
    ToolHub.homeMenuEnabled = false
    listOf(
            "android.permission.BLUETOOTH",
            "android.permission.BLUETOOTH_CONNECT",
            "android.permission.CAMERA",
            "android.permission.INTERNET",
        )
        .forEach {
          InstrumentationRegistry.getInstrumentation()
              .uiAutomation
              .executeShellCommand("pm grant ${targetContext.packageName} $it")
        }
    // No bookmark or settings from an earlier run.
    targetContext.getSharedPreferences("book_reader", Context.MODE_PRIVATE).edit().clear().commit()
  }

  @After
  fun tearDown() {
    ToolHub.homeMenuEnabled = true
    MockDeviceKit.getInstance(targetContext).disable()
  }

  @Test
  fun readsABookPageFromTheGlassesCamera() {
    pairHstnShowingPage(BookPageRenderer.houndPage)
    startSessionAndStream()
    openReaderWithAutoTurnOff()

    composeTestRule.onNodeWithTag("book_start_pause").performClick()
    val text = waitForPageText("Penang")
    Log.i(TAG, "read=\n$text")

    val cer = TextDistance.cer(BookPageRenderer.HOUND_EXPECTED, text)
    assertTrue("CER $cer too high. Read:\n$text", cer <= MAX_CER)
    assertFalse("running header was read", text.contains("BASKERVILLES"))
    assertFalse("page number was read", text.trimEnd().endsWith("3"))
    // "oc-"/"casions" and "be-"/"hind": a leftover hyphen means the join failed; anything else
    // means the fragment was misread (ML Kit read "oc-" as "0C-" on a Galaxy A26).
    for ((word, broken) in listOf("occasions" to "oc-", "behind" to "be-")) {
      assertFalse("line-end hyphen not rejoined: $broken in\n$text", text.contains(broken))
      assertTrue("hyphenated word misread, expected $word in\n$text", text.contains(word))
    }
    assertTrue("real hyphen lost", text.contains("hearth-rug"))
    assertEquals("paragraphs", 3, text.split("\n\n").size)
  }

  @Test
  fun samePageIsNotReadTwice() {
    pairHstnShowingPage(BookPageRenderer.houndPage)
    startSessionAndStream()
    openReaderWithAutoTurnOff()

    composeTestRule.onNodeWithTag("book_start_pause").performClick()
    waitForPageText("Penang")

    // The mock keeps returning the same image: "Next page" must report the same page.
    composeTestRule.onNodeWithTag("book_next_page").performClick()
    val samePage = targetContext.getString(R.string.book_status_same_page)
    composeTestRule.waitUntil(timeoutMillis = READ_TIMEOUT) { statusText() == samePage }
  }

  @Test
  fun saysWhatToDoAtTheEndOfAPage() {
    pairHstnShowingPage(BookPageRenderer.houndPage)
    startSessionAndStream()
    openReaderWithAutoTurnOff()
    // Top speed, so the page is finished quickly.
    repeat(12) { composeTestRule.onNodeWithTag("book_rate_faster").performClick() }

    composeTestRule.onNodeWithTag("book_start_pause").performClick()
    waitForPageText("Penang")

    // A blind reader can't see the status line: it's spoken too (BookReaderViewModel.pageFinished).
    val endOfPage = targetContext.getString(R.string.book_status_press_next)
    composeTestRule.waitUntil(timeoutMillis = END_OF_PAGE_TIMEOUT) { statusText() == endOfPage }
  }

  @Test
  fun voiceDrivesTheReaderThroughTheGlasses() {
    val glasses = pairHstnShowingPage(BookPageRenderer.houndPage, micGranted = true)
    startSessionAndStream()
    composeTestRule.onNodeWithTag("book_reader_button").performClick()

    // Opening the reader starts listening on the glasses' own recogniser.
    val onGlasses = targetContext.getString(R.string.voice_mic_glasses)
    composeTestRule.waitUntil(timeoutMillis = STREAM_TIMEOUT) { nodeText("book_voice_mic") == onGlasses }

    // Settings by voice (the plant clip's cuts would otherwise look like page turns).
    say(glasses, "I'll tell you when I turn the page")
    composeTestRule.waitUntil(timeoutMillis = STREAM_TIMEOUT) {
      nodeText("book_voice_heard")?.contains("turn the page") == true
    }
    composeTestRule.onNodeWithTag("book_auto_turn_toggle").assertIsOff()

    say(glasses, "OK, start reading please")
    val text = waitForPageText("Penang")
    assertTrue(TextDistance.cer(BookPageRenderer.HOUND_EXPECTED, text) <= MAX_CER)

    say(glasses, "a bit faster")
    composeTestRule.waitUntil(timeoutMillis = STREAM_TIMEOUT) {
      nodeText("book_rate_value")?.startsWith("1.3") == true
    }

    say(glasses, "hang on")
    val paused = targetContext.getString(R.string.book_status_paused)
    composeTestRule.waitUntil(timeoutMillis = STREAM_TIMEOUT) { statusText() == paused }

    say(glasses, "Reader, close the book")
    composeTestRule.waitUntil(timeoutMillis = STREAM_TIMEOUT) {
      composeTestRule.onAllNodes(hasTestTag("book_reader_screen")).fetchSemanticsNodes().isEmpty()
    }
  }

  // MARK: - Helpers

  private fun say(glasses: MockGlasses, text: String) {
    Log.i(TAG, "say \"$text\"")
    glasses.services.speech.simulateTranscription(text, true, 0.9f)
  }

  private fun pairHstnShowingPage(
      page: BookPageRenderer.Page,
      micGranted: Boolean = false,
  ): MockGlasses {
    val bitmap = BookPageRenderer.render(960, 1440, listOf(page))
    val pageUri = BookPageRenderer.savePng(bitmap, targetContext.cacheDir, "book_page.png")
    val mockDeviceKit = MockDeviceKit.getInstance(targetContext)
    mockDeviceKit.enable(MockDeviceKitConfig(initialPermissionsGranted = false))
    mockDeviceKit.permissions.set(Permission.CAMERA, PermissionStatus.Denied)
    if (micGranted) mockDeviceKit.permissions.set(Permission.MICROPHONE, PermissionStatus.Granted)
    val device = mockDeviceKit.pairGlasses(GlassesModel.OAKLEY_META_HSTN).getOrThrow()
    device.powerOn()
    device.don()
    device.unfold()
    device.services.camera.setCameraFeed(assetUri("plant.mp4"))
    device.services.camera.setCapturedImage(pageUri)
    return device
  }

  // Same flow as InstrumentationTest.startSessionAndStream: session, preview, permission confirm.
  private fun startSessionAndStream() {
    composeTestRule.waitUntilExactlyOneExists(
        hasTestTag("start_session_button").and(isEnabled()),
        timeoutMillis = STREAM_TIMEOUT,
    )
    composeTestRule.onNodeWithTag("start_session_button").performClick()
    composeTestRule.waitUntilExactlyOneExists(
        hasTestTag("start_preview_button").and(isEnabled()),
        timeoutMillis = STREAM_TIMEOUT,
    )
    composeTestRule.onNodeWithTag("start_preview_button").performClick()
    val continueLabel = targetContext.getString(R.string.camera_permission_continue)
    composeTestRule.waitUntilExactlyOneExists(hasText(continueLabel), timeoutMillis = STREAM_TIMEOUT)
    composeTestRule.onNodeWithText(continueLabel).performClick()
    composeTestRule.waitUntilExactlyOneExists(
        hasTestTag("book_reader_button").and(isEnabled()),
        timeoutMillis = STREAM_TIMEOUT,
    )
  }

  // Auto page-turn detection watches the mock's looping plant video, whose cuts look like turns.
  // These tests drive captures with the buttons, so switch it off.
  private fun openReaderWithAutoTurnOff() {
    composeTestRule.onNodeWithTag("book_reader_button").performClick()
    composeTestRule.waitUntilExactlyOneExists(
        hasTestTag("book_reader_screen"),
        timeoutMillis = STREAM_TIMEOUT,
    )
    composeTestRule.onNodeWithTag("book_auto_turn_toggle").performClick()
  }

  /** The text of the node tagged [tag], or null if it isn't on screen (yet). */
  private fun nodeText(tag: String): String? =
      composeTestRule
          .onAllNodes(hasTestTag(tag), useUnmergedTree = true)
          .fetchSemanticsNodes()
          .firstOrNull()
          ?.config
          ?.getOrNull(SemanticsProperties.Text)
          ?.joinToString("") { it.text }

  private fun statusText(): String? = nodeText("book_status")

  private fun waitForPageText(marker: String): String {
    var text = ""
    composeTestRule.waitUntil(timeoutMillis = READ_TIMEOUT) {
      text = nodeText("book_page_text").orEmpty()
      text.contains(marker)
    }
    return text
  }

  private fun assetUri(assetName: String): android.net.Uri {
    val outFile = File(targetContext.cacheDir, assetName)
    InstrumentationRegistry.getInstrumentation().context.assets.open(assetName).use { input ->
      FileOutputStream(outFile).use { output -> input.copyTo(output) }
    }
    return android.net.Uri.fromFile(outFile)
  }
}

/** Real ML Kit on rendered pages, straight into the layout code. No mock, no UI. */
@RunWith(AndroidJUnit4::class)
class BookOcrPipelineTest {

  private fun readBack(bitmap: android.graphics.Bitmap): String =
      MlKitOcr().use { ocr ->
        val page = runBlocking { ocr.recognize(bitmap) }
        // Raw ML Kit lines, so a misread can be told apart from a layout bug.
        page.lines.forEach { Log.i("BookOcrPipelineTest", "raw: ${it.text}") }
        PageLayout.layout(page).bodyText()
      }

  @Test
  fun singlePage() {
    val text = readBack(BookPageRenderer.render(960, 1440, listOf(BookPageRenderer.houndPage)))
    Log.i("BookOcrPipelineTest", "single=\n$text")
    val cer = TextDistance.cer(BookPageRenderer.HOUND_EXPECTED, text)
    assertTrue("CER $cer. Read:\n$text", cer <= 0.02f)
  }

  @Test
  fun twoPageSpreadIsReadLeftThenRightWithGutterHyphenRejoined() {
    val bitmap = BookPageRenderer.render(1440, 960, BookPageRenderer.timeMachineSpread, textSize = 26f)
    val text = readBack(bitmap)
    Log.i("BookOcrPipelineTest", "spread=\n$text")
    val cer = TextDistance.cer(BookPageRenderer.TIME_MACHINE_EXPECTED, text)
    assertTrue("CER $cer. Read:\n$text", cer <= 0.02f)
    assertTrue(text.contains("extraordinarily"))
    // Known ML Kit quirk (notes/book-reader-android.md): on this render it returns the first line
    // as "TheTimeTravellerwasexpoundingarecondite", one word with no element split. CER still
    // passes; the layout assertions above are what this test is about.
    assertFalse(text.contains("THE TIME MACHINE"))
    assertFalse(text.contains("43"))
  }
}
