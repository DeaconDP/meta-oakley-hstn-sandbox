// AskAboutTextTest - questions about the page while the book reader reads it, on the Mock Device Kit
//
// A rendered page (Conan Doyle, public domain) is the mock HSTN's captured photo. The book reader is
// launched voice-first and starts reading by voice; then, all through the glasses' recogniser:
// a question as a partial result stops the reading (barge-in), "what does effusive mean" is
// answered from the bundled dictionary, "spell it", "who is Holmes", "what did it say about the
// fire", then "carry on" reads on. The app is closed and launched again, and "what happened last
// time" reads the end of the last session, kept next to the bookmark. Asserts on what was sent to
// speech (hub.recentSpeech()). A second test times loading and lookups on the phone.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskMemory
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.AskProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.Dictionary
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.Sentences
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.WordLookup
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class AskAboutTextTest {

  companion object {
    private const val TAG = "AskAboutTextTest"
    const val TIMEOUT = 30_000L
    const val READ_TIMEOUT = 60_000L

    /** "A Scandal in Bohemia", lightly rearranged so the fire comes early on the page. */
    val PAGE =
        BookPageRenderer.Page(
            header = "A SCANDAL IN BOHEMIA",
            lines =
                BookPageRenderer.paragraphs(
                    "To Sherlock Holmes she is always the woman. He\n" +
                        "stood before the fire and looked me over in his\n" +
                        "singular introspective fashion.",
                    "His manner was not effusive. It seldom was; but\n" +
                        "he was glad, I think, to see me. With hardly a\n" +
                        "word spoken, he waved me to an armchair.",
                    "Holmes was sitting with his back to me, and I\n" +
                        "had given him no sign of my occupation.",
                ),
            pageNumber = "5",
        )
  }

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  private fun waitFor(tag: String, timeout: Long = TIMEOUT) =
      compose.waitUntil(timeoutMillis = timeout) { ToolTestKit.exists(compose, tag) }

  private fun waitForSpeech(hub: ToolHub, timeout: Long = TIMEOUT, what: String, test: (String) -> Boolean): String {
    var found = ""
    try {
      compose.waitUntil(timeoutMillis = timeout) {
        hub.recentSpeech().lastOrNull(test)?.also { found = it } != null
      }
    } catch (e: Throwable) {
      throw AssertionError("never said $what; said:\n" + hub.recentSpeech().joinToString("\n"), e)
    }
    Log.i(TAG, "said: $found")
    return found
  }

  private fun launchBookAndListen(): ToolHub {
    scenario = ToolTestKit.launch(ToolRequest(ToolId.BOOK))
    val hub = ToolTestKit.hub(scenario!!)
    waitFor("book_reader_screen")
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "book_voice_mic") == onGlasses }
    return hub
  }

  private fun status() = ToolTestKit.text(compose, "book_status")

  @Test
  fun answersQuestionsWhileReadingAndAfterARestart() {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.showImage(glasses, BookPageRenderer.render(960, 1440, listOf(PAGE)))
    var hub = launchBookAndListen()

    ToolTestKit.say(glasses, "stop detecting page turns")
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "book_voice_heard")?.contains("page turns") == true }
    ToolTestKit.say(glasses, "read")
    compose.waitUntil(timeoutMillis = READ_TIMEOUT) { ToolTestKit.text(compose, "book_page_text")?.contains("effusive") == true }
    // Let it read up to the sentence with the word in it.
    waitForSpeech(hub, READ_TIMEOUT, "the effusive sentence") { it.contains("effusive") }

    // Barge-in: the question as a partial result stops the reading before the recogniser is done.
    ToolTestKit.say(glasses, "what does effusive mean", isFinal = false)
    val paused = ctx.getString(R.string.book_status_paused)
    compose.waitUntil(timeoutMillis = TIMEOUT) { status() == paused }
    ToolTestKit.say(glasses, "what does effusive mean")
    val definition = waitForSpeech(hub, what = "the definition") { it.startsWith("Effusive, adjective:") }
    assertTrue(definition, definition.contains("demonstrative") || definition.contains("unrestrained"))
    // The reader stays paused after the answer (follow-ups may come).
    SystemClock.sleep(1_500)
    assertTrue(status() == paused)

    ToolTestKit.say(glasses, "spell it")
    waitForSpeech(hub, what = "the spelling") { it == "Effusive is spelt E, F, F, U, S, I, V, E." }

    ToolTestKit.say(glasses, "who is Holmes")
    val holmes = waitForSpeech(hub, what = "who Holmes is") { it.contains("Holmes") && it.contains("is mentioned once") || it.contains("first comes up here") }
    assertTrue(holmes, holmes.contains("To Sherlock Holmes she is always the woman."))

    ToolTestKit.say(glasses, "what did it say about the fire")
    val fire = waitForSpeech(hub, what = "the fire") { it.startsWith("About the fire:") }
    assertTrue(fire, fire.contains("stood before the fire"))

    // Carry on: reading resumes from the interrupted sentence.
    val before = hub.recentSpeech().size
    ToolTestKit.say(glasses, "carry on")
    // (The status line isn't updated on resume, so check what's spoken: page text again.)
    val pageText = PAGE.lines.joinToString(" ") { it.text }
    val resumed = waitForSpeech(hub, what = "the page again") { said ->
      hub.recentSpeech().indexOfLast { it == said } >= before && pageText.contains(said.take(24))
    }
    assertFalse(resumed.startsWith("About"))

    // The recent text is kept next to the bookmark...
    compose.waitUntil(timeoutMillis = READ_TIMEOUT) {
      AskMemory.load(ctx)?.contains("effusive") == true
    }
    val kept = AskMemory.load(ctx)!!
    Log.i(TAG, "kept: $kept")
    assertFalse("only read text is kept", kept.contains("BOHEMIA"))

    // ...so after closing and launching again, "what happened last time" reads it back.
    scenario!!.close()
    scenario = null
    hub = launchBookAndListen()
    ToolTestKit.say(glasses, "what happened last time")
    val last = waitForSpeech(hub, what = "the recap") { it.startsWith("Last time, we left off here:") }
    val lastSentence = Sentences.split(kept).last()
    assertTrue("$last\nshould end with: $lastSentence", last.endsWith(lastSentence))

    ToolTestKit.say(glasses, "close")
    compose.waitUntil(timeoutMillis = TIMEOUT) { hub.activeTool.value == null }
  }

  @Test
  fun measuresDictionaryLoadAndLookupOnThePhone() {
    val t0 = SystemClock.elapsedRealtime()
    val dict = ctx.assets.open(AskProvider.DICTIONARY_ASSET).use(Dictionary::load)
    val loadMs = SystemClock.elapsedRealtime() - t0
    val lookup = WordLookup(dict)
    val text = Sentences.split("The Time Traveller was expounding a recondite matter to us. His grey eyes shone and twinkled.")
    val words = listOf("recondite", "expounding", "travellers", "colour", "realised", "ephemeral", "recon dight", "gregarious")
    repeat(20) { for (w in words) lookup.define(lookup.choose(w, text)!!.word) } // warm up
    val n = 50
    val t1 = SystemClock.elapsedRealtimeNanos()
    repeat(n) { for (w in words) lookup.define(lookup.choose(w, text)!!.word) }
    val perQuestionMs = (SystemClock.elapsedRealtimeNanos() - t1) / 1e6 / (n * words.size)
    val heapMb = (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) / 1e6
    Log.i(TAG, "metric=ask_dictionary_phone load_ms=$loadMs per_question_ms=${"%.2f".format(perQuestionMs)} heap_mb=${"%.0f".format(heapMb)} lemmas=${dict.lemmaCount}")
    assertTrue("load took $loadMs ms", loadMs < 10_000)
    assertTrue("a lookup took $perQuestionMs ms", perQuestionMs < 100)
  }
}
