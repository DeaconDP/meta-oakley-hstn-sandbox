// HandsFreeModeTest - the toolbox by default, push to talk, and the glasses display card
//
// notes/hands-free-mode.md. (1) With hands-free off the camera screen is a touch toolbox: nothing
// connects, listens or talks by itself; the connect button brings the glasses up; the mic button
// hears one command through the glasses and the mic goes off again. (2) "Hands-free on" by push to
// talk switches the mode and the mic stays on. (3) On mock Ray-Ban Display glasses (MockDisplayKit,
// GlassesModel.META_RAYBAN_DISPLAY), hands-free sends the card to the display, and "glasses display
// off" stops it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.HandsFreeStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Microphone
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
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
class HandsFreeModeTest {

  companion object {
    const val TIMEOUT = 30_000L
  }

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx: Context
    get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After
  fun tearDown() {
    ToolTestKit.tearDown(scenario)
    HandsFreeStore.get(ctx).setHandsFree(true)
  }

  private fun waitUntil(condition: () -> Boolean) = compose.waitUntil(timeoutMillis = TIMEOUT, condition = condition)

  @Test
  fun theToolboxWaitsForATapAndPushToTalkHearsOneCommand() {
    HandsFreeStore.get(ctx).setHandsFree(false)
    val glasses = ToolTestKit.pairHstn()
    scenario = ToolTestKit.launchFromIcon()
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)

    waitUntil { ToolTestKit.exists(compose, "toolbox_panel") }
    // Nothing by itself: no connection, no mic, no welcome.
    Thread.sleep(4_000)
    assertFalse("no auto-connect", camera.isStreaming.value)
    assertEquals(Microphone.NONE, hub.microphone.value)
    assertFalse(hub.recentSpeech().contains(ctx.getString(R.string.home_welcome)))
    assertFalse(ToolTestKit.exists(compose, "home_voice_panel"))

    // One tap connects.
    compose.onNodeWithTag("toolbox_connect").performScrollTo().performClick()
    waitUntil { camera.isStreaming.value }

    // Push to talk: the glasses listen for one command, then the mic goes off.
    compose.onNodeWithTag("push_to_talk_button").performScrollTo().performClick()
    waitUntil { hub.pushToTalkReady && hub.microphone.value == Microphone.GLASSES }
    ToolTestKit.say(glasses, "status")
    waitUntil { hub.recentSpeech().any { it.startsWith(ctx.getString(R.string.hf_link_streaming)) } }
    waitUntil { hub.microphone.value == Microphone.NONE }
    assertFalse(hub.isListening)

    // "Hands-free on" by push to talk: the mode switches and the mic stays on.
    compose.onNodeWithTag("push_to_talk_button").performScrollTo().performClick()
    waitUntil { hub.pushToTalkReady && hub.microphone.value == Microphone.GLASSES }
    ToolTestKit.say(glasses, "hands-free on")
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.hf_turned_on)) }
    assertTrue(HandsFreeStore.get(ctx).handsFree)
    waitUntil { hub.isListening && hub.microphone.value == Microphone.GLASSES }
    waitUntil { ToolTestKit.exists(compose, "home_voice_panel") }

    // ...and back off by voice.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "hands-free off")
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.hf_turned_off)) }
    waitUntil { hub.microphone.value == Microphone.NONE }
    assertFalse(HandsFreeStore.get(ctx).handsFree)
  }

  @Test
  fun handsFreeShowsTheCardOnADisplayAndStopsWhenAsked() {
    HandsFreeStore.get(ctx).setHandsFree(true)
    HandsFreeStore.get(ctx).setGlassesDisplay(true)
    val kit = MockDeviceKit.getInstance(ctx)
    kit.enable(MockDeviceKitConfig(initialPermissionsGranted = true))
    kit.permissions.set(Permission.CAMERA, PermissionStatus.Granted)
    kit.permissions.set(Permission.MICROPHONE, PermissionStatus.Granted)
    val glasses = kit.pairGlasses(GlassesModel.META_RAYBAN_DISPLAY).getOrThrow()
    glasses.powerOn()
    glasses.don()
    glasses.unfold()
    glasses.services.camera.setCameraFeed(ToolTestKit.assetUri("plant.mp4"))

    scenario = ToolTestKit.launchFromIcon()
    val hub = ToolTestKit.hub(scenario!!)
    val camera = ToolTestKit.camera(scenario!!)
    waitUntil { camera.isStreaming.value }
    // The card reaches the mock display (sendContent succeeded).
    waitUntil { hub.surface.sentCount > 0 }
    waitUntil { hub.microphone.value == Microphone.GLASSES }

    // What's heard updates the card (on change, throttled).
    ToolTestKit.waitForQuiet(hub)
    val before = hub.surface.sentCount
    ToolTestKit.say(glasses, "where am I")
    waitUntil { hub.recentSpeech().any { it.startsWith(ctx.getString(R.string.hf_where_home)) } }
    waitUntil { hub.surface.sentCount > before }
    assertTrue(hub.surface.card.value.heard.isNotEmpty())

    // "Glasses display off": said, saved, and nothing more is sent.
    ToolTestKit.waitForQuiet(hub)
    ToolTestKit.say(glasses, "glasses display off")
    waitUntil { hub.recentSpeech().contains(ctx.getString(R.string.hf_display_off)) }
    assertFalse(HandsFreeStore.get(ctx).settings.value.glassesDisplay)
    ToolTestKit.waitForQuiet(hub)
    Thread.sleep(1_000)
    val after = hub.surface.sentCount
    ToolTestKit.say(glasses, "battery")
    Thread.sleep(2_000)
    assertEquals(after, hub.surface.sentCount)
    HandsFreeStore.get(ctx).setGlassesDisplay(true)
  }
}
