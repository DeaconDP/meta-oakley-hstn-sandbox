/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// HomeScreen - SpeakUp setup (DAT registration entry point)
//
// Shown until the app is connected to Meta AI. A hero with the SpeakUp mark, wordmark and tagline;
// the voice ribbon and a status card showing that the screen is talking and listening (SetupVoice);
// three short tips; and the big yellow "Connect my glasses" button, which does the same as saying
// "connect". The hands-free switch is here too (notes/hands-free-mode.md); with it off the screen
// doesn't talk first, and the mic button listens for one command (SetupVoice.listenOnce).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.widget.Toast
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.HandsFreeStore
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupVoice
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

@Composable
fun HomeScreen(
    viewModel: WearablesViewModel,
    setupVoice: SetupVoice,
    modifier: Modifier = Modifier,
) {
  val scrollState = rememberScrollState()
  val uiState by viewModel.uiState.collectAsStateWithLifecycle()
  val voiceUi by setupVoice.ui.collectAsStateWithLifecycle()
  SetupVoiceEffect(setupVoice)
  val activity = LocalActivity.current
  val context = LocalContext.current
  val errorActivityUnavailable = stringResource(R.string.error_activity_unavailable)

  Column(
      modifier =
          modifier
              .fillMaxSize()
              .statusBarsPadding()
              .navigationBarsPadding()
              .verticalScroll(scrollState)
              .padding(horizontal = 24.dp, vertical = 24.dp),
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.spacedBy(20.dp),
  ) {
    // Hero: mark, wordmark, tagline. The mark is decorative; the wordmark names the app.
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(top = 16.dp),
    ) {
      Icon(
          painter = painterResource(id = R.drawable.speakup_mark),
          contentDescription = null,
          tint = SpeakUpColors.SignalYellow,
          modifier = Modifier.size(104.dp),
      )
      Spacer(modifier = Modifier.height(6.dp))
      Text(
          text = stringResource(R.string.app_name),
          style = MaterialTheme.typography.displayLarge,
          color = SpeakUpColors.Paper,
          textAlign = TextAlign.Center,
          modifier = Modifier.semantics { heading() },
      )
      Text(
          text = stringResource(R.string.speakup_tagline),
          style = MaterialTheme.typography.titleLarge,
          color = SpeakUpColors.SignalYellow,
          textAlign = TextAlign.Center,
      )
    }

    // The voice ribbon and, in words, what the setup voice is doing.
    val voiceState =
        when {
          voiceUi.speaking -> VoiceState.SPEAKING
          voiceUi.listening -> VoiceState.LISTENING
          else -> VoiceState.IDLE
        }
    VoiceRibbon(state = voiceState, height = 72.dp)
    SetupVoiceCard(voiceUi)
    val modeStore = remember { HandsFreeStore.get(context) }
    val modeSettings by modeStore.settings.collectAsStateWithLifecycle()
    HandsFreeSwitch(on = modeSettings.handsFree, onChange = { setupVoice.setHandsFree(it) })
    if (!modeSettings.handsFree) {
      PushToTalkButton(listening = voiceUi.pushToTalk, onClick = { setupVoice.listenOnce() })
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(18.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
      TipRow(
          icon = painterResource(R.drawable.smart_glasses_icon),
          title = stringResource(R.string.home_tip_session_title),
          text = stringResource(R.string.home_tip_session),
      )
      TipRow(
          icon = rememberVectorPainter(Icons.Filled.Mic),
          title = stringResource(R.string.home_tip_preview_title),
          text = stringResource(R.string.home_tip_preview),
      )
      TipRow(
          icon = rememberVectorPainter(Icons.AutoMirrored.Filled.VolumeUp),
          title = stringResource(R.string.home_tip_capture_title),
          text = stringResource(R.string.home_tip_capture),
      )
    }

    Spacer(modifier = Modifier.weight(1f))

    Text(
        text = stringResource(R.string.home_redirect_message),
        style = MaterialTheme.typography.bodyMedium,
        color = SpeakUpColors.PaperMuted,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
    val connectDescription = stringResource(R.string.setup_connect_description)
    SpeakUpButton(
        label = stringResource(R.string.register_button_title),
        enabled = uiState.canStartRegistration,
        icon = Icons.Filled.Link,
        minHeight = SpeakUpDimens.HeroButtonHeight,
        modifier =
            Modifier.fillMaxWidth().testTag("setup_connect_button").semantics {
              contentDescription = connectDescription
            },
        onClick = {
          activity?.let {
            setupVoice.connectTapped()
            viewModel.startRegistration(it)
          } ?: Toast.makeText(context, errorActivityUnavailable, Toast.LENGTH_SHORT).show()
        },
    )
  }
}

/**
 * What the setup screen's voice is doing, and the last thing it heard, with an icon for the state.
 * Not a live region: SetupVoice already speaks everything, so TalkBack shouldn't read it twice.
 */
@Composable
private fun SetupVoiceCard(voiceUi: SetupVoice.Ui) {
  val (icon, tint) =
      when {
        voiceUi.speaking -> Icons.AutoMirrored.Filled.VolumeUp to SpeakUpColors.VoiceCoral
        voiceUi.micGranted && voiceUi.listening -> Icons.Filled.Mic to SpeakUpColors.ListenCyan
        else -> Icons.Filled.MicOff to SpeakUpColors.PaperMuted
      }
  SpeakUpCard(modifier = Modifier.fillMaxWidth()) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
      Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(32.dp))
      Text(
          text =
              stringResource(
                  when {
                    voiceUi.speaking -> R.string.setup_status_speaking
                    !voiceUi.micGranted -> R.string.setup_status_no_mic
                    voiceUi.listening -> R.string.setup_status_listening
                    else -> R.string.setup_status_off
                  },
              ),
          style = MaterialTheme.typography.titleMedium,
          color = SpeakUpColors.Paper,
          modifier = Modifier.weight(1f).testTag("setup_voice_status"),
      )
    }
    voiceUi.heard?.let { heard ->
      Text(
          text = stringResource(R.string.setup_heard_label) + ": " + heard,
          style = MaterialTheme.typography.bodyLarge,
          color = SpeakUpColors.PaperMuted,
          modifier = Modifier.fillMaxWidth().testTag("setup_voice_heard"),
      )
    }
  }
}

/**
 * Runs the spoken setup while this screen shows: attaches SetupVoice with the activity as its Host,
 * and tells it when the app goes to the background (Meta AI, Settings) and comes back. Leaving the
 * composition (registered) detaches it, which releases the mic and TTS.
 */
@Composable
private fun SetupVoiceEffect(setupVoice: SetupVoice) {
  val activity = LocalActivity.current
  val lifecycleOwner = LocalLifecycleOwner.current
  DisposableEffect(setupVoice, activity, lifecycleOwner) {
    (activity as? SetupVoice.Host)?.let { setupVoice.attach(it) }
    val observer = LifecycleEventObserver { _, event ->
      when (event) {
        Lifecycle.Event.ON_START -> setupVoice.setForeground(true)
        Lifecycle.Event.ON_STOP -> setupVoice.setForeground(false)
        else -> Unit
      }
    }
    lifecycleOwner.lifecycle.addObserver(observer)
    onDispose {
      lifecycleOwner.lifecycle.removeObserver(observer)
      setupVoice.detach()
    }
  }
}
