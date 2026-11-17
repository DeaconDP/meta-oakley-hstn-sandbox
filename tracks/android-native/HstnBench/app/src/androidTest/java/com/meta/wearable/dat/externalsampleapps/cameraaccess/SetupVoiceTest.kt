// SetupVoiceTest - the setup screen (not yet connected to Meta AI) works by voice alone
//
// Launches unregistered on the Mock Device Kit (MockDeviceKitConfig(initiallyRegistered = false)),
// waits for the spoken welcome, then "says" commands. There's no glasses session before registration,
// so setup listens on the phone's recogniser, which a test can't feed audio to; the transcript is
// handed to SetupVoice.hear(), the same entry point the recogniser's final results use. On the mock,
// Wearables.startRegistration completes in-app (no Meta AI), so "connect" should end on the
// registered camera screen with the setup mic released.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Intent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupVoice
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@LargeTest
class SetupVoiceTest {

  @get:Rule val compose = createEmptyComposeRule()
  private var scenario: ActivityScenario<MainActivity>? = null
  private val ctx get() = ToolTestKit.context

  @Before fun setup() = ToolTestKit.setUp()

  @After fun tearDown() = ToolTestKit.tearDown(scenario)

  private fun launchUnregistered(registrationSucceeds: Boolean = true): SetupVoice {
    val kit = MockDeviceKit.getInstance(ctx)
    kit.enable(MockDeviceKitConfig(initiallyRegistered = false))
    kit.simulateRegistrationOutcome(registrationSucceeds)
    val glasses = kit.pairGlasses(GlassesModel.OAKLEY_META_HSTN).getOrThrow()
    glasses.powerOn()
    glasses.don()
    glasses.unfold()
    scenario =
        ActivityScenario.launch(
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    compose.waitUntil(TIMEOUT) { ToolTestKit.exists(compose, "setup_connect_button") }
    var voice: SetupVoice? = null
    scenario!!.onActivity { voice = it.setupVoice }
    // Every launch speaks first, not just voice-first ones.
    val welcome = ctx.getString(R.string.setup_welcome)
    compose.waitUntil(TIMEOUT) { voice!!.recentSpeech().contains(welcome) }
    return voice!!
  }

  private fun say(text: String) = scenario!!.onActivity { it.setupVoice.hear(text) }

  private fun registered(): Boolean {
    var registered = false
    scenario!!.onActivity { registered = it.viewModel.uiState.value.isRegistered }
    return registered
  }

  @Test
  fun connectByVoiceRegistersAndReleasesTheMic() {
    val voice = launchUnregistered()
    say("help")
    compose.waitUntil(TIMEOUT) { voice.recentSpeech().last() == ctx.getString(R.string.setup_help) }
    say("don't connect")
    compose.waitUntil(TIMEOUT) { voice.recentSpeech().last() == ctx.getString(R.string.setup_declined) }
    assertFalse("\"don't connect\" must not register", registered())

    say("connect")
    compose.waitUntil(TIMEOUT) { voice.recentSpeech().last() == ctx.getString(R.string.setup_handoff) }
    compose.waitUntil(REGISTER_TIMEOUT) { registered() }
    // The registered screen replaces setup, and setup let go of the mic.
    compose.waitUntil(TIMEOUT) { !ToolTestKit.exists(compose, "setup_connect_button") }
    assertFalse(voice.ui.value.listening)
  }

  @Test
  fun failedRegistrationIsSpokenWithARetry() {
    val voice = launchUnregistered(registrationSucceeds = false)
    say("yes please")
    compose.waitUntil(TIMEOUT) { voice.recentSpeech().contains(ctx.getString(R.string.setup_handoff)) }
    // Meta AI never takes over on the mock, so after the handoff timeout the app says so.
    compose.waitUntil(REGISTER_TIMEOUT) {
      voice.recentSpeech().contains(ctx.getString(R.string.setup_didnt_open))
    }
    assertFalse(registered())
    assert(ToolTestKit.exists(compose, "setup_connect_button"))
  }

  private companion object {
    const val TIMEOUT = 30_000L
    const val REGISTER_TIMEOUT = 45_000L
  }
}
