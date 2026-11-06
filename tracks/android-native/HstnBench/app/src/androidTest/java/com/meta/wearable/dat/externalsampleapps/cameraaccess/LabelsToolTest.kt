// LabelsToolTest - the label reader on the Mock Device Kit, driven by voice
//
// (1) A cereal label with an EAN-13 barcode and "Best before: 12/03/27" is both the live stream
// (480x864 video) and the in-stream photo (960x1440). Launching voice-first into the tool starts the
// barcode search, which must decode 4006381333931 from the stream; "look it up" goes to an injected
// fake product source (no network in tests); "when does it expire" takes a photo, reads it and says
// "12 March 2027"; "does it contain nuts" finds the almonds.
// (2) A paracetamol label: "read the label" says it looks like medicine and gives the name only,
// "how many should I take" is declined, and no dose, strength or count is ever sent to speech or
// shown on screen.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsLookup
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LookupResult
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.OffProduct
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.ProductSource
import java.util.Collections
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
class LabelsToolTest {

  companion object {
    const val TIMEOUT = 30_000L
    const val READ_TIMEOUT = 60_000L
  }

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context
  private val lookups = Collections.synchronizedList(mutableListOf<String>())

  @Before
  fun setup() {
    ToolTestKit.setUp()
    LabelsLookup.source = ProductSource { code ->
      lookups += code
      if (code == "4006381333931") {
        LookupResult.Found(
            OffProduct(code, "Oat Crunch", listOf("Test Mills"), "500 g", listOf("en:gluten", "en:nuts"), emptyList(), "Oats, sugar, almonds", listOf("en:cereals")),
        )
      } else {
        LookupResult.NotFound
      }
    }
  }

  @After
  fun tearDown() {
    LabelsLookup.source = null
    ToolTestKit.tearDown(scenario)
  }

  private fun waitForSpeech(hub: ToolHub, timeout: Long = TIMEOUT, what: (String) -> Boolean) =
      compose.waitUntil(timeoutMillis = timeout) { hub.recentSpeech().any(what) }

  private fun openListening(request: ToolRequest = ToolRequest(ToolId.LABELS)): ToolHub {
    scenario = ToolTestKit.launch(request)
    val hub = ToolTestKit.hub(scenario!!)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "tool_screen_labels") }
    val onGlasses = ctx.getString(R.string.voice_mic_glasses)
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "tool_voice_mic") == onGlasses }
    return hub
  }

  @Test
  fun decodesTheBarcodeLooksItUpAndReadsTheDate() {
    val glasses = ToolTestKit.pairHstn()
    val stream = LabelRenderer.render(LabelRenderer.cereal, 480, 864)
    ToolTestKit.playFrames(glasses, listOf(stream, stream))
    ToolTestKit.showImage(glasses, LabelRenderer.render(LabelRenderer.cereal, 960, 1440))
    val hub = openListening()

    // The search starts by itself and decodes the barcode from the stream.
    val found = ctx.getString(R.string.labels_found_product)
    waitForSpeech(hub, READ_TIMEOUT) { it == found }
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "labels_code")?.contains("4006381333931") == true }
    assertTrue("no lookup before asked", lookups.isEmpty())

    // "look it up": only now, and only the number.
    ToolTestKit.say(glasses, "look it up")
    waitForSpeech(hub) { it.startsWith("Oat Crunch, by Test Mills, 500 grams.") }
    assertEquals(listOf("4006381333931"), lookups.toList())
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "labels_product") == "Oat Crunch, by Test Mills, 500 grams." }

    // "when does it expire": photo, OCR, the date said as a date.
    ToolTestKit.say(glasses, "when does it expire")
    waitForSpeech(hub, READ_TIMEOUT) { it.startsWith("Best before 12 March 2027.") }
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.text(compose, "labels_text")?.contains("Best before") == true }

    // "does it contain nuts": the label lists almonds.
    ToolTestKit.say(glasses, "does it contain nuts")
    waitForSpeech(hub, READ_TIMEOUT) { it.startsWith("Yes. The label mentions almonds.") }
    // The label text was published for "ask about the text".
    assertTrue(hub.recentText.snapshot(ToolId.LABELS)?.fullText?.contains("Wholegrain oats") == true)
  }

  @Test
  fun medicineGivesTheNameOnlyAndNeverADose() {
    val glasses = ToolTestKit.pairHstn()
    val stream = LabelRenderer.render(LabelRenderer.paracetamol, 480, 864)
    ToolTestKit.playFrames(glasses, listOf(stream, stream))
    ToolTestKit.showImage(glasses, LabelRenderer.render(LabelRenderer.paracetamol, 960, 1440))
    val hub = openListening()
    waitForSpeech(hub) { it == ctx.getString(R.string.labels_searching) }

    ToolTestKit.say(glasses, "read the label")
    val name = ctx.getString(R.string.labels_medicine_name, "PARACETAMOL")
    waitForSpeech(hub, READ_TIMEOUT) { it.startsWith(name) }
    val refusal = ctx.getString(R.string.labels_medicine_dose)
    assertTrue(hub.recentSpeech().any { it.startsWith(name) && it.endsWith(refusal) })
    compose.waitUntil(timeoutMillis = TIMEOUT) { ToolTestKit.exists(compose, "labels_medicine") }

    ToolTestKit.say(glasses, "how many should I take")
    compose.waitUntil(timeoutMillis = TIMEOUT) { hub.recentSpeech().count { it.contains(refusal) } >= 2 }
    ToolTestKit.say(glasses, "read it all")
    compose.waitUntil(timeoutMillis = TIMEOUT) { hub.recentSpeech().count { it.contains(refusal) } >= 3 }

    // The date isn't a dose: it's still given.
    ToolTestKit.say(glasses, "when does it expire")
    waitForSpeech(hub, READ_TIMEOUT) { it.startsWith("Expiry date the end of June 2028.") }

    // Nothing that is a dose, strength or count reached speech, the screen or RecentText.
    val spoken = hub.recentSpeech().joinToString("\n")
    for (dose in listOf("500", "2 tablets", "4 hours", "every", "Do not exceed", "24 hours", "Dosage")) {
      assertFalse("said \"$dose\": $spoken", spoken.contains(dose, ignoreCase = true))
    }
    assertFalse(ToolTestKit.exists(compose, "labels_text"))
    assertFalse(hub.recentText.snapshot(ToolId.LABELS)?.fullText.orEmpty().contains("tablets", ignoreCase = true))
  }
}
