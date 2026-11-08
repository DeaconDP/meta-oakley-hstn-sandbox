// MailToolTest - the mail reader end to end on the Mock Device Kit
//
// A rendered utility bill (LetterRenderer) is what the mock glasses photograph. The app is launched
// straight into the mail reader (voice-first, no taps) and driven only through the glasses'
// recogniser: "what is this letter" must give the sender, the kind, the amount and the due date;
// "read it all" must read every line, table rows as rows; the letter must reach the ask seam. Then
// the money rule on the real ML Kit pipeline: two different amounts to pay, and a smudged digit,
// must never produce a figure that isn't on the letter.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.util.Log
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.LetterSpeech
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class MailToolTest {

  companion object {
    private const val TAG = "MailToolTest"
    const val TIMEOUT = 30_000L
    const val READ_TIMEOUT = 60_000L
    const val READ_ALL_TIMEOUT = 120_000L
  }

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  /** Voice-first into the mail reader with [letter] in front of the glasses; waits for the welcome. */
  private fun open(letter: android.graphics.Bitmap): Pair<MockGlasses, ToolHub> {
    val glasses = ToolTestKit.pairHstn()
    ToolTestKit.showImage(glasses, letter)
    scenario = ToolTestKit.launch(ToolRequest(ToolId.MAIL))
    val hub = ToolTestKit.hub(scenario!!)
    compose.waitUntil(TIMEOUT) { ToolTestKit.exists(compose, "tool_screen_mail") }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    compose.waitUntil(TIMEOUT) { ToolTestKit.text(compose, "tool_voice_mic") == onGlasses }
    val welcome = ctx.getString(R.string.mail_welcome)
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().contains(welcome) }
    return glasses to hub
  }

  private fun summaryOf(hub: ToolHub): String {
    compose.waitUntil(READ_TIMEOUT) { hub.recentSpeech().any { it.contains("Say read it all") } }
    return hub.recentSpeech().last { it.contains("Say read it all") }.also { Log.i(TAG, "summary: $it") }
  }

  @Test
  fun summarisesALetterThenReadsItAll() {
    val (glasses, hub) = open(LetterRenderer.utilityBill())

    ToolTestKit.say(glasses, "what is this letter")
    val summary = summaryOf(hub)
    assertTrue(summary, summary.contains("A bill"))
    assertTrue(summary, summary.contains("from Northgate Energy"))
    assertTrue(summary, summary.contains("for Mrs Jane Patel"))
    assertTrue(summary, summary.contains("Amount due: £84.17"))
    assertTrue(summary, summary.contains("by 24 November 2026"))
    // The screen mirrors it.
    assertTrue(ToolTestKit.text(compose, "mail_from")!!.contains("Northgate Energy"))
    assertTrue(ToolTestKit.text(compose, "mail_amount")!!.contains("£84.17"))

    // The letter went to the ask seam.
    val snapshot = hub.recentText.snapshot(ToolId.MAIL)
    assertNotNull(snapshot)
    assertTrue(snapshot!!.fullText.contains("Please pay the amount due by 24 November 2026."))

    // Follow-up questions are answered from the letter, without a new photo.
    ToolTestKit.say(glasses, "who's it from")
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().contains("It's from Northgate Energy.") }
    ToolTestKit.say(glasses, "when is it due")
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().contains("Pay by 24 November 2026.") }

    ToolTestKit.say(glasses, "double speed")
    ToolTestKit.say(glasses, "read it all")
    val end = ctx.getString(R.string.mail_end)
    compose.waitUntil(READ_ALL_TIMEOUT) { hub.recentSpeech().contains(end) }
    val spoken = hub.recentSpeech()
    val from = spoken.indexOfLast { it.contains("Northgate Energy") && !it.contains("Say read it all") && !it.startsWith("It's from") }
    val read = spoken.drop(from).joinToString("\n")
    Log.i(TAG, "read it all:\n$read")
    for (part in listOf("Mrs Jane Patel", "Dear Mrs Patel", "Here is your bill for October.", "Standing charge £12.30.",
        "Energy used £71.87.", "Amount due £84.17.", "Please pay the amount due by 24 November 2026.", "Yours sincerely", "Sam Lee")) {
      assertTrue("read it all said \"$part\"", read.contains(part))
    }
    // Phone and account numbers are spelled out, digit by digit.
    assertTrue(read, read.contains("8 8 4 2"))
    assertTrue(read.indexOf("Standing charge") < read.indexOf("Amount due £84.17"))
  }

  /** Mail and "ask about the text" were built apart: questions must work on a letter too. */
  @Test
  fun answersQuestionsAboutTheLetter() {
    val (glasses, hub) = open(LetterRenderer.utilityBill())
    ToolTestKit.say(glasses, "what is this letter")
    summaryOf(hub)

    ToolTestKit.say(glasses, "what did it say about the standing charge")
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().any { it.startsWith("About the standing charge") } }
    val found = hub.recentSpeech().last { it.startsWith("About the standing charge") }
    Log.i(TAG, "find: $found")
    assertTrue(found, found.contains("12.30"))

    ToolTestKit.say(glasses, "what does sincerely mean")
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().any { it.startsWith("Sincerely, adverb") } }

    ToolTestKit.say(glasses, "who is Sam Lee")
    compose.waitUntil(TIMEOUT) { hub.recentSpeech().any { it.contains("Sam Lee") && it.contains("mentioned") } }
    Log.i(TAG, "who: " + hub.recentSpeech().last { it.contains("mentioned") })
  }

  /** The money rule can't be bypassed by asking: a smudged amount must not come back through search. */
  @Test
  fun askingDoesNotBypassTheMoneyRule() {
    val (glasses, hub) = open(LetterRenderer.utilityBill(smudgeDigit = 2))
    ToolTestKit.say(glasses, "what is this letter")
    summaryOf(hub)
    ToolTestKit.say(glasses, "what did it say about the amount due")
    compose.waitUntil(TIMEOUT) {
      hub.recentSpeech().any { it.startsWith("About the amount due") || it.startsWith("I didn't find anything") }
    }
    val answer = hub.recentSpeech().last { it.startsWith("About the amount due") || it.startsWith("I didn't find anything") }
    Log.i(TAG, "ask amount: $answer")
    val figures = Regex("£[0-9][0-9,]*(?:\\.[0-9]{2})?").findAll(answer).map { it.value }.toList()
    assertTrue("ask said a figure not on the letter: $answer", figures.all { it == "£84.17" })
  }

  @Test
  fun refusesConflictingAmounts() {
    val (glasses, hub) = open(LetterRenderer.utilityBill(secondTotal = "£48.17"))
    ToolTestKit.say(glasses, "what is this letter")
    val summary = summaryOf(hub)
    assertTrue(summary, summary.contains(LetterSpeech.CONFLICTING_AMOUNTS))
    assertFalse(summary, summary.contains("84.17") || summary.contains("48.17"))
  }

  @Test
  fun neverSaysAFigureThatIsNotOnTheLetter() {
    // The 4 of £84.17 smudged beyond reading.
    val (glasses, hub) = open(LetterRenderer.utilityBill(smudgeDigit = 2))
    ToolTestKit.say(glasses, "how much")
    compose.waitUntil(READ_TIMEOUT) {
      hub.recentSpeech().any { it.startsWith("I can't read the amount for sure") || it.startsWith("The amount due is") || it.startsWith("I can't see an amount") }
    }
    val answer = hub.recentSpeech().last { it.startsWith("I can't") || it.startsWith("The amount due is") }
    Log.i(TAG, "smudged answer: $answer")
    // Either it refuses, or it's right. A confident wrong figure would fail here.
    val figures = Regex("£[0-9][0-9,]*(?:\\.[0-9]{2})?").findAll(answer).map { it.value }.toList()
    assertTrue("said a figure not on the letter: $answer", figures.all { it == "£84.17" })
    assertTrue("expected the refusal: $answer", answer.startsWith("I can't read the amount for sure"))
  }
}
