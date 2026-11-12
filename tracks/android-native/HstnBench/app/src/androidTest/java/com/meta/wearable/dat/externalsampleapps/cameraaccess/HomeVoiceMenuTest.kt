// HomeVoiceMenuTest - the camera screen is usable by voice alone, with no tool open
//
// Launched like the normal app icon (no tool, no extras) with mock HSTN glasses, and nothing is
// tapped: the glasses link comes up by itself, the home menu listens on the glasses and says what
// to say; "read my mail" opens the mail reader (switch semantics: earcon and name); "main menu"
// comes back to the menu with the session and stream still up; "close the app" ends the session
// and stops listening. See notes/tools-layer.md > Home voice menu.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Microphone
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
class HomeVoiceMenuTest {

  companion object {
    const val TIMEOUT = 30_000L
  }

  @get:Rule val composeTestRule = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  private fun waitUntil(condition: () -> Boolean) =
      composeTestRule.waitUntil(timeoutMillis = TIMEOUT, condition = condition)

  @Test
  fun theMainMenuWorksByVoiceFromTheNormalIcon() {
    val glasses = ToolTestKit.pairHstn()
    scenario = ToolTestKit.launchFromIcon()
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)

    // No taps: the session and stream come up, the menu listens on the glasses and welcomes.
    waitUntil { camera.isStreaming.value }
    waitUntil { hub.microphone.value == Microphone.GLASSES }
    waitUntil { ToolTestKit.text(composeTestRule, "home_voice_mic") == ctx.getString(R.string.voice_mic_glasses) }
    assertTrue("home menu listening", hub.isHome)
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.home_welcome)) }

    // "read my mail" opens the mail reader the way a voice switch does.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "read my mail")
    waitUntil { ToolTestKit.exists(composeTestRule, "tool_screen_mail") }
    assertEquals(ToolRequest(ToolId.MAIL), hub.activeTool.value)
    assertTrue(hub.recentSpeech().contains(ctx.getString(R.string.tool_switched, ctx.getString(R.string.mail_name))))
    assertFalse(hub.isHome)
    assertTrue("mic kept across the switch", hub.isVoiceOpen)

    // "main menu" closes the tool and comes back, without ending anything.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "main menu")
    waitUntil { hub.activeTool.value == null }
    waitUntil { ToolTestKit.exists(composeTestRule, "home_voice_panel") }
    assertTrue("back in the home menu", hub.isHome)
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.home_back)) }
    assertTrue("stream still up", camera.isStreaming.value)

    // "what can I say" lists the menu's commands.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "what can I say")
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.home_help)) }

    // "close the app" says goodbye, stops listening and ends the session.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "close the app")
    waitUntil { !hub.isVoiceOpen }
    waitUntil { !camera.uiState.value.hasSession }
    assertTrue(hub.recentSpeech().contains(ctx.getString(R.string.tool_goodbye)))
    assertFalse(camera.isStreaming.value)
  }

  /** A tool launched straight into ("Open Mail Reader"): "close" still leaves the app in one step. */
  @Test
  fun closeInAToolLaunchedStraightInLeavesTheApp() {
    val glasses = ToolTestKit.pairHstn()
    scenario = ToolTestKit.launch(ToolRequest(ToolId.MAIL))
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)
    waitUntil { ToolTestKit.exists(composeTestRule, "tool_screen_mail") }
    waitUntil { camera.isStreaming.value }
    waitUntil { hub.microphone.value == Microphone.GLASSES }
    assertTrue(hub.closeLeavesApp)

    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "close")
    waitUntil { !hub.isVoiceOpen }
    waitUntil { !camera.uiState.value.hasSession }
    assertEquals(null, hub.activeTool.value)
  }
}
