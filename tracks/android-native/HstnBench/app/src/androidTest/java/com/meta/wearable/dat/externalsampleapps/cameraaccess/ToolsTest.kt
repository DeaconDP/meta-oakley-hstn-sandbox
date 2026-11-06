// ToolsTest - opening tools and switching between them by voice, on the Mock Device Kit
//
// Launches voice-first into the mail reader (a stub) with mock HSTN glasses, then drives everything
// through the glasses' recogniser: "open the book reader" switches to the book with the same glasses
// session and stream; the page is read; a question about it goes to the ask seam (not ready yet);
// "watch for 42" switches to Watch for text with its target and keeps the bookmark; "back to my book"
// returns. The stream must never drop during the switches. Also: a deep link with a mode, and each
// stub opens and says it isn't ready yet.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.dropWhile
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class ToolsTest {

  companion object {
    const val TIMEOUT = 30_000L
    const val READ_TIMEOUT = 60_000L
  }

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  private fun waitFor(tag: String, timeout: Long = TIMEOUT) =
      composeTestRule.waitUntil(timeoutMillis = timeout) { ToolTestKit.exists(composeTestRule, tag) }

  @Test
  fun switchesToolsByVoiceKeepingTheSessionAndTheBookmark() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.showImage(glasses, BookPageRenderer.render(960, 1440, listOf(BookPageRenderer.houndPage)))
    scenario = ToolTestKit.launch(ToolRequest(ToolId.MAIL))
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)

    // Voice-first into the mail stub: connects, listens on the glasses, says it isn't ready.
    waitFor("tool_screen_mail")
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { camera.isStreaming.value }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(composeTestRule, "tool_voice_mic") == onGlasses }
    val notReady = ctx.getString(R.string.tool_not_ready, ctx.getString(R.string.mail_name))
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(composeTestRule, "tool_status") == notReady }

    // From here on the stream must not drop: switching keeps the session.
    val dropped = AtomicBoolean(false)
    val watcher = CoroutineScope(Dispatchers.Default)
    watcher.launch { camera.isStreaming.drop(1).collect { if (!it) dropped.set(true) } }

    ToolTestKit.say(glasses, "open the book reader")
    waitFor("book_reader_screen")
    assertTrue(hub.recentSpeech().contains(ctx.getString(R.string.tool_switched, ctx.getString(R.string.book_reader_title))))

    ToolTestKit.say(glasses, "stop detecting page turns")
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) {
      ToolTestKit.text(composeTestRule, "book_voice_heard")?.contains("page turns") == true
    }
    ToolTestKit.say(glasses, "read")
    composeTestRule.waitUntil(timeoutMillis = READ_TIMEOUT) {
      ToolTestKit.text(composeTestRule, "book_page_text")?.contains("Penang") == true
    }
    // The page went to the ask seam's text store...
    val snapshot = hub.recentText.snapshot(ToolId.BOOK)
    assertNotNull(snapshot)
    assertTrue(snapshot!!.fullText.contains("Penang lawyer"))
    // ...and a question about it reaches AskAboutText (a stub for now).
    ToolTestKit.say(glasses, "what does Penang lawyer mean")
    val cantYet = ctx.getString(R.string.tool_ask_unavailable)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { hub.recentSpeech().contains(cantYet) }

    // Wait for a sentence or two to be read, so there's a place to keep.
    composeTestRule.waitUntil(timeoutMillis = READ_TIMEOUT) {
      ctx.getSharedPreferences("book_reader", Context.MODE_PRIVATE).getString("bookmark", null) != null
    }
    ToolTestKit.say(glasses, "tell me when you see 42")
    waitFor("tool_screen_watch")
    assertEquals(ToolRequest(ToolId.WATCH, argument = "42"), hub.activeTool.value)
    val bookmark = ctx.getSharedPreferences("book_reader", Context.MODE_PRIVATE).getString("bookmark", null)
    assertNotNull("bookmark kept", bookmark)

    ToolTestKit.say(glasses, "what colour is this")
    waitFor("tool_screen_light")
    assertEquals(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR), hub.activeTool.value)

    ToolTestKit.say(glasses, "back to my book")
    waitFor("book_reader_screen")
    assertEquals(bookmark, ctx.getSharedPreferences("book_reader", Context.MODE_PRIVATE).getString("bookmark", null))

    assertFalse("the stream dropped during a switch", dropped.get())
    watcher.cancel()

    ToolTestKit.say(glasses, "close")
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { hub.activeTool.value == null }
  }

  @Test
  fun deepLinkOpensATool() {
    ToolTestKit.pairHstn()
    scenario = ToolTestKit.launchDeepLink("hstnbench://light?mode=colour")
    waitFor("tool_screen_light")
    assertEquals(ToolRequest(ToolId.LIGHT, mode = ToolRequest.MODE_COLOUR), ToolTestKit.hub(scenario!!).activeTool.value)
  }

  @Test
  fun everyStubOpensConnectsAndSaysItIsNotReady() {
    val glasses = ToolTestKit.pairHstn()
    scenario = ToolTestKit.launch(ToolRequest(ToolId.WATCH, argument = "exit"))
    val camera = ToolTestKit.camera(scenario!!)
    composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { camera.isStreaming.value }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    for ((id, phrase) in listOf(
        ToolId.WATCH to null,
        ToolId.MAIL to "read my mail",
    )) {
      phrase?.let { ToolTestKit.say(glasses, it) }
      waitFor("tool_screen_${id.id}")
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(composeTestRule, "tool_voice_mic") == onGlasses }
      if (id == ToolId.WATCH) continue // built: WatchForTextTest covers it
      val name = ctx.getString(ToolRegistryNames.of(id))
      val notReady = ctx.getString(R.string.tool_not_ready, name)
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(composeTestRule, "tool_status") == notReady }
    }
  }
}

/** Name resources by tool id, without going through the Compose registry. */
private object ToolRegistryNames {
  fun of(id: ToolId): Int =
      when (id) {
        ToolId.BOOK -> R.string.book_reader_title
        ToolId.MAIL -> R.string.mail_name
        ToolId.WATCH -> R.string.watch_name
        ToolId.LABELS -> R.string.labels_name
        ToolId.LIGHT -> R.string.light_name
      }
}
