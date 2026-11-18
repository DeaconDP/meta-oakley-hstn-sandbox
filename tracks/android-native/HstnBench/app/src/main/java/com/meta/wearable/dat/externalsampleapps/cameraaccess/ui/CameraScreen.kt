/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// CameraScreen - DAT camera capture screen
//
// A full-bleed camera preview with controls overlaid on a scrim. Walks the SDK's camera lifecycle
// as explicit steps (Start Session -> Start Preview -> Capture / Record -> Stop Preview -> End
// Session) and shows the live DeviceSessionState / StreamState so the state machine is legible.
//
// It is also the router for the everyday tools: ToolHub.activeTool picks which tool screen covers
// the live preview (which keeps streaming underneath), the bottom bar has a button per registered
// tool, and while any tool is open ToolHub listens (so switching tools by voice keeps the mic).
//
// The home area depends on the mode (notes/hands-free-mode.md): the toolbox (default) shows the
// tools with what each does, the hands-free switch, a push-to-talk mic button and the SDK features;
// hands-free shows the voice menu panel and the switch, and replaces the camera-permission dialog
// with speech. The settings menu (top right) has the hands-free and glasses display switches.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.AndroidExternalSurface
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Link
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.MicStatusLine
import androidx.compose.runtime.CompositionLocalProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.LocalPushToTalk
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.PushToTalk
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolAccent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolRegistry
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScreenContext
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.voiceStateFor
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.semantics.heading
import com.meta.wearable.dat.externalsampleapps.cameraaccess.camera.CameraUiState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.camera.CameraViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

// Night scrims behind the top/bottom bars so the controls stay legible over the live feed. Hoisted
// so they're allocated once instead of on every bar recomposition (the recording timer ticks).
private val TopScrimBrush =
    Brush.verticalGradient(listOf(SpeakUpColors.Night.copy(alpha = 0.85f), Color.Transparent))
private val BottomScrimBrush =
    Brush.verticalGradient(
        0f to Color.Transparent,
        0.25f to SpeakUpColors.Night.copy(alpha = 0.8f),
        1f to SpeakUpColors.Night.copy(alpha = 0.94f),
    )
private const val PREVIEW_ASPECT_RATIO = 9f / 16f

@Composable
fun CameraScreen(
    wearablesViewModel: WearablesViewModel,
    onRequestWearablesPermission: suspend (Permission) -> PermissionStatus,
    onRequestRecordAudioPermission: suspend () -> Boolean,
    modifier: Modifier = Modifier,
    launchTool: ToolRequest? = null,
    cameraViewModel: CameraViewModel = viewModel(
        factory =
            CameraViewModel.Factory(
                application = (LocalActivity.current as ComponentActivity).application,
                wearablesViewModel = wearablesViewModel,
            ),
    ),
) {
  val ui by cameraViewModel.uiState.collectAsStateWithLifecycle()
  val wearablesUi by wearablesViewModel.uiState.collectAsStateWithLifecycle()
  val activity = LocalActivity.current
  var showSettingsMenu by remember { mutableStateOf(false) }
  val application = (LocalActivity.current as ComponentActivity).application
  val hub: ToolHub = viewModel(factory = ToolHub.Factory(application, cameraViewModel))
  val activeTool by hub.activeTool.collectAsStateWithLifecycle()
  val modeSettings by hub.mode.settings.collectAsStateWithLifecycle()
  val pushToTalk by hub.pushToTalkActive.collectAsStateWithLifecycle()
  // Hands-free (saved, or a voice-first visit into a tool) vs the toolbox.
  val handsFree = modeSettings.handsFree || (launchTool != null && hub.isHandsFree)
  // The home voice menu: voice runs for this whole screen, not only while a tool is open, so a
  // blind user never needs the buttons (notes/tools-layer.md > Home voice menu). Off for the
  // touch-driven bench tests and with `--ez home_voice false`.
  val homeVoice = remember {
    ToolHub.homeMenuEnabled && activity?.intent?.getBooleanExtra(ToolHub.EXTRA_HOME_VOICE, true) != false
  }
  val requestWearablesForVoice by rememberUpdatedState(onRequestWearablesPermission)
  val requestRecordAudioForVoice by rememberUpdatedState(onRequestRecordAudioPermission)
  // Voice-first launch ("Open Book Reader", hstnbench://mail, --es tool watch): straight into the
  // tool, no taps needed. Leaving a tool opened that way ends the session and steps aside.
  var launchedVoiceFirst by remember { mutableStateOf(launchTool != null) }
  if (homeVoice) {
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(launchTool) {
      launchTool?.let { hub.open(it, voiceFirst = true) }
      // Each time the app comes to the front: listen (a no-op if already listening). After
      // "close the app" voice is off, so coming back starts the menu again.
      lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
        hub.openVoice(
            voiceFirst = true,
            requestWearablesPermission = { requestWearablesForVoice(it) },
            requestRecordAudio = { requestRecordAudioForVoice() },
            home = true,
        )
      }
    }
    DisposableEffect(hub) {
      hub.onExitApp = {
        cameraViewModel.endSession()
        activity?.moveTaskToBack(true)
      }
      onDispose {
        hub.onExitApp = null
        hub.closeVoice()
      }
    }
    // Hands-free: the voice path replaces the camera-permission prompt: ToolHub says why, then
    // Meta AI opens. The toolbox keeps the dialog.
    LaunchedEffect(ui.showCameraPermissionRedirectConfirm, handsFree) {
      if (ui.showCameraPermissionRedirectConfirm && handsFree) {
        cameraViewModel.confirmCameraPermissionRedirect(onRequestWearablesPermission)
      }
    }
  } else {
    LaunchedEffect(launchTool) { launchTool?.let { hub.open(it, voiceFirst = true) } }
  }

  val isUpdateRequired = wearablesUi.isFirmwareUpdateRequired

  Box(modifier = modifier.fillMaxSize().background(SpeakUpColors.Night)) {
    PreviewBackground(
        ui = ui,
        hasActiveDevice = wearablesUi.hasActiveDevice,
        isUpdateRequired = isUpdateRequired,
        onSurfaceChanged = cameraViewModel::setSurface,
    )

    // Tap outside the open settings menu dismisses it.
    if (showSettingsMenu) {
      Box(
          modifier =
              Modifier.fillMaxSize().clickable(
                  interactionSource = remember { MutableInteractionSource() },
                  indication = null,
              ) {
                showSettingsMenu = false
              },
      )
    }

    Column(modifier = Modifier.fillMaxSize()) {
      TopBar(
          // Above the home panel, so the settings menu isn't drawn under it.
          modifier = Modifier.zIndex(1f),
          ui = ui,
          isDisconnectEnabled = wearablesUi.registrationState == RegistrationState.REGISTERED,
          showSettingsMenu = showSettingsMenu,
          onToggleSettings = { showSettingsMenu = !showSettingsMenu },
          onDisconnect = {
            activity?.let { wearablesViewModel.startUnregistration(it) }
            showSettingsMenu = false
          },
          settings =
              if (homeVoice) {
                {
                  HandsFreeSwitch(on = handsFree, onChange = { hub.setHandsFree(it) })
                  GlassesDisplaySwitch(on = modeSettings.glassesDisplay, onChange = { hub.setGlassesDisplay(it) })
                }
              } else {
                null
              },
      )

      val toolbox = homeVoice && activeTool == null && !handsFree
      if (homeVoice && activeTool == null) {
        Column(
            modifier =
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          if (handsFree) {
            HomeVoicePanel(hub)
            HandsFreeSwitch(
                on = true,
                onChange = { hub.setHandsFree(it) },
                modifier = Modifier.padding(horizontal = 16.dp),
            )
          } else {
            ToolboxPanel(
                hub = hub,
                isStreaming = ui.isStreaming,
                isConnecting = ui.isBusy || ui.isStartingStream,
                pushToTalk = pushToTalk,
                onConnect = { cameraViewModel.connectAndStream(onRequestWearablesPermission) },
                onOpenTool = { hub.open(ToolRequest(it)) },
            )
          }
        }
      } else {
        Spacer(modifier = Modifier.weight(1f))
      }

      BottomBar(
          ui = ui,
          isUpdateRequired = isUpdateRequired,
          hasActiveDevice = wearablesUi.hasActiveDevice,
          onStartSession = cameraViewModel::startSession,
          onEndSession = cameraViewModel::endSession,
          onStartPreview = cameraViewModel::startStreaming,
          onStopPreview = cameraViewModel::stopStreaming,
          onCapturePhoto = cameraViewModel::capturePhoto,
          onToggleRecording = { cameraViewModel.toggleRecording(onRequestRecordAudioPermission) },
          onToggleMic = cameraViewModel::toggleMic,
          onOpenTool = { hub.open(ToolRequest(it)) },
          onUpdateFirmware = { activity?.let { wearablesViewModel.openFirmwareUpdate(it) } },
          // The toolbox lists the tools above, with what each does.
          showTools = !toolbox,
      )
    }

    ui.activePreview?.let { preview ->
      CapturePreviewScreen(
          preview = preview,
          onDismiss = { cameraViewModel.dismissCapturePreview() },
      )
    }

    // A tool: full-screen over the live preview, which keeps streaming underneath so the tool can
    // capture photos, read frames and watch for page turns.
    activeTool?.let { request ->
      if (!homeVoice) {
        // Without the home menu, listening runs while any tool is open, not per tool, so a switch
        // keeps the mic.
        LaunchedEffect(Unit) {
          hub.openVoice(
              voiceFirst = launchedVoiceFirst,
              requestWearablesPermission = { requestWearablesForVoice(it) },
              requestRecordAudio = { requestRecordAudioForVoice() },
          )
        }
        DisposableEffect(Unit) {
          onDispose {
            hub.closeVoice()
            if (launchedVoiceFirst) {
              // Launched just for this tool: end the session and step aside (the goodbye still
              // plays) rather than leaving a blind user on a camera screen with the stream running.
              launchedVoiceFirst = false
              cameraViewModel.endSession()
              activity?.moveTaskToBack(true)
            }
          }
        }
      }
      // The toolbox: tool screens show the push-to-talk button (hands-free: the mic is always on).
      val talk = if (homeVoice && !handsFree) PushToTalk(pushToTalk) { hub.pushToTalk() } else null
      CompositionLocalProvider(LocalPushToTalk provides talk) {
        key(request.tool) {
          ToolRegistry.spec(request.tool)
              .content(
                  ToolScreenContext(
                      hub = hub,
                      request = request,
                      onClose = { hub.closeTool() },
                      onRequestWearablesPermission = onRequestWearablesPermission,
                      onRequestRecordAudioPermission = onRequestRecordAudioPermission,
                  ),
              )
        }
      }
    }

    // The toolbox and the touch bench keep the prompt; hands-free replaces it with speech.
    if (ui.showCameraPermissionRedirectConfirm && !(homeVoice && handsFree)) {
      AlertDialog(
          onDismissRequest = { cameraViewModel.cancelCameraPermissionRedirect() },
          title = { Text(stringResource(R.string.camera_permission_redirect_title)) },
          text = { Text(stringResource(R.string.camera_permission_redirect_message)) },
          confirmButton = {
            TextButton(
                onClick = {
                  cameraViewModel.confirmCameraPermissionRedirect(onRequestWearablesPermission)
                },
            ) {
              Text(stringResource(R.string.camera_permission_continue))
            }
          },
          dismissButton = {
            TextButton(onClick = { cameraViewModel.cancelCameraPermissionRedirect() }) {
              Text(stringResource(R.string.camera_permission_cancel))
            }
          },
      )
    }
  }
}

// MARK: - Home voice menu

/**
 * What the home voice menu is doing, for sighted helpers and TalkBack: which mic is listening, the
 * last thing said and the last thing heard. Tags: "home_voice_mic", "home_status", "home_voice_heard".
 */
@Composable
private fun HomeVoicePanel(hub: ToolHub) {
  val mic by hub.microphone.collectAsStateWithLifecycle()
  val status by hub.homeStatus.collectAsStateWithLifecycle()
  val heard by hub.homeHeard.collectAsStateWithLifecycle()
  Column(
      modifier =
          Modifier.fillMaxWidth()
              .padding(horizontal = 16.dp)
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk.copy(alpha = 0.94f))
              .border(1.dp, SpeakUpColors.DuskLine, MaterialTheme.shapes.medium)
              .padding(SpeakUpDimens.CardPadding)
              .testTag("home_voice_panel"),
      verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Icon(
          painter = painterResource(R.drawable.speakup_mark),
          contentDescription = null,
          tint = SpeakUpColors.SignalYellow,
          modifier = Modifier.size(28.dp),
      )
      Spacer(modifier = Modifier.width(10.dp))
      Text(
          text = stringResource(R.string.home_heading),
          color = SpeakUpColors.Paper,
          style = MaterialTheme.typography.titleLarge,
          modifier = Modifier.semantics { heading() },
      )
    }
    // Decorative: the mic line and status below say the same in words.
    VoiceRibbon(state = voiceStateFor(mic), height = 40.dp)
    MicStatusLine(microphone = mic, tag = "home_voice_mic")
    if (status.isNotEmpty()) {
      Text(
          text = status,
          color = ToolAccent,
          style = MaterialTheme.typography.titleMedium,
          modifier = Modifier.testTag("home_status"),
      )
    }
    if (heard.isNotEmpty()) {
      Text(
          text = stringResource(R.string.voice_heard, heard),
          color = SpeakUpColors.PaperMuted,
          style = MaterialTheme.typography.bodyMedium,
          modifier = Modifier.testTag("home_voice_heard"),
      )
    }
  }
}

// MARK: - Toolbox home

/**
 * The toolbox (hands-free off): the tools with what each does, the hands-free switch, the
 * push-to-talk mic button (one command, the same grammar as hands-free), a connect button, the
 * last thing said and heard, and what the glasses SDK offers. Tags: "toolbox_panel",
 * "toolbox_connect", "home_status", "home_voice_heard", plus each tool's button tag.
 */
@Composable
private fun ToolboxPanel(
    hub: ToolHub,
    isStreaming: Boolean,
    isConnecting: Boolean,
    pushToTalk: Boolean,
    onConnect: () -> Unit,
    onOpenTool: (ToolId) -> Unit,
) {
  val status by hub.homeStatus.collectAsStateWithLifecycle()
  val heard by hub.homeHeard.collectAsStateWithLifecycle()
  Column(
      modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("toolbox_panel"),
      verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Column(
        modifier =
            Modifier.fillMaxWidth()
                .clip(MaterialTheme.shapes.medium)
                .background(SpeakUpColors.Dusk.copy(alpha = 0.94f))
                .border(1.dp, SpeakUpColors.DuskLine, MaterialTheme.shapes.medium)
                .padding(SpeakUpDimens.CardPadding),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            painter = painterResource(R.drawable.speakup_mark),
            contentDescription = null,
            tint = SpeakUpColors.SignalYellow,
            modifier = Modifier.size(28.dp),
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = stringResource(R.string.hf_toolbox_heading),
            color = SpeakUpColors.Paper,
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.semantics { heading() },
        )
      }
      Text(
          text = stringResource(R.string.hf_toolbox_intro),
          color = SpeakUpColors.PaperMuted,
          style = MaterialTheme.typography.bodyMedium,
      )
      PushToTalkButton(listening = pushToTalk, onClick = { hub.pushToTalk() })
      if (status.isNotEmpty()) {
        Text(
            text = status,
            color = ToolAccent,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.testTag("home_status"),
        )
      }
      if (heard.isNotEmpty()) {
        Text(
            text = stringResource(R.string.voice_heard, heard),
            color = SpeakUpColors.PaperMuted,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.testTag("home_voice_heard"),
        )
      }
      if (!isStreaming) {
        val connectDescription = stringResource(R.string.hf_connect_button_description)
        SpeakUpButton(
            label = stringResource(R.string.hf_connect_button),
            onClick = onConnect,
            icon = Icons.Filled.Link,
            kind = ButtonKind.SECONDARY,
            enabled = !isConnecting,
            modifier =
                Modifier.fillMaxWidth().testTag("toolbox_connect").semantics {
                  contentDescription = connectDescription
                },
        )
      }
    }

    HandsFreeSwitch(on = false, onChange = { hub.setHandsFree(it) })

    Text(
        text = stringResource(R.string.tools_heading),
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    for (spec in ToolRegistry.all) {
      ToolboxToolRow(
          name = stringResource(spec.nameRes),
          description = stringResource(toolDescription(spec.id)),
          icon = spec.icon,
          tag = spec.buttonTag,
          onClick = { onOpenTool(spec.id) },
      )
    }

    Text(
        text = stringResource(R.string.hf_sdk_heading),
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    SpeakUpCard(modifier = Modifier.fillMaxWidth()) {
      for (line in listOf(R.string.hf_sdk_camera, R.string.hf_sdk_speech, R.string.hf_sdk_health, R.string.hf_sdk_display)) {
        Text(text = stringResource(line), color = SpeakUpColors.Paper, style = MaterialTheme.typography.bodyMedium)
      }
    }
  }
}

private fun toolDescription(id: ToolId): Int =
    when (id) {
      ToolId.BOOK -> R.string.hf_tool_book
      ToolId.MAIL -> R.string.hf_tool_mail
      ToolId.WATCH -> R.string.hf_tool_watch
      ToolId.LABELS -> R.string.hf_tool_labels
      ToolId.LIGHT -> R.string.hf_tool_light
    }

/** One tool in the toolbox: a large button with its name and one line about what it does. */
@Composable
private fun ToolboxToolRow(
    name: String,
    description: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tag: String,
    onClick: () -> Unit,
) {
  Row(
      modifier =
          Modifier.fillMaxWidth()
              .heightIn(min = SpeakUpDimens.HeroButtonHeight)
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk)
              .border(2.dp, SpeakUpColors.PaperMuted, MaterialTheme.shapes.medium)
              .clickable(onClick = onClick)
              .padding(horizontal = 16.dp, vertical = 10.dp)
              .testTag(tag),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(14.dp),
  ) {
    Icon(imageVector = icon, contentDescription = null, tint = SpeakUpColors.SignalYellow, modifier = Modifier.size(30.dp))
    Column(modifier = Modifier.weight(1f)) {
      Text(text = name, color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium)
      Text(text = description, color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
    }
  }
}

// MARK: - Preview background

@Composable
private fun PreviewBackground(
    ui: CameraUiState,
    hasActiveDevice: Boolean,
    isUpdateRequired: Boolean,
    onSurfaceChanged: (android.view.Surface?) -> Unit,
) {
  val liveDescription = stringResource(R.string.live_preview)
  Box(modifier = Modifier.fillMaxSize()) {
    if (ui.hasStream) {
      AndroidExternalSurface(
          modifier =
              Modifier.align(Alignment.Center)
                  .wrapContentWidth(align = Alignment.CenterHorizontally, unbounded = true)
                  .fillMaxHeight()
                  .aspectRatio(PREVIEW_ASPECT_RATIO, matchHeightConstraintsFirst = true)
                  .semantics { contentDescription = liveDescription },
      ) {
        onSurface { surface, _, _ ->
          onSurfaceChanged(surface)
          surface.onDestroyed { onSurfaceChanged(null) }
        }
      }
    } else if (!ui.isBusy) {
      StatusPlaceholder(
          ui = ui,
          hasActiveDevice = hasActiveDevice,
          isUpdateRequired = isUpdateRequired,
      )
    }

    // Paused (device-initiated): the surface stays mounted (hasStream is true) so the last frame
    // freezes; dim it and badge it so a held frame reads as intentionally paused, not stalled.
    if (ui.isPaused) {
      Box(
          modifier =
              Modifier.fillMaxSize()
                  .background(SpeakUpColors.Night.copy(alpha = 0.6f))
                  .testTag("paused_overlay"),
          contentAlignment = Alignment.Center,
      ) {
        Column(
            modifier = Modifier.padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
          Icon(
              imageVector = Icons.Filled.Pause,
              contentDescription = null,
              tint = SpeakUpColors.SignalYellow,
              modifier = Modifier.size(48.dp),
          )
          Spacer(modifier = Modifier.height(8.dp))
          Text(
              text = stringResource(R.string.paused_title),
              color = SpeakUpColors.Paper,
              style = MaterialTheme.typography.headlineSmall,
          )
          Spacer(modifier = Modifier.height(4.dp))
          Text(
              text = stringResource(R.string.paused_subtitle),
              color = SpeakUpColors.Paper,
              style = MaterialTheme.typography.bodyLarge,
              textAlign = TextAlign.Center,
          )
        }
      }
    }

    if ((ui.isBusy || (ui.hasStream && !ui.hasReceivedFirstFrame)) && !ui.isPaused) {
      Box(
          modifier = Modifier.fillMaxSize().background(SpeakUpColors.Night.copy(alpha = 0.5f)),
          contentAlignment = Alignment.Center,
      ) {
        CircularProgressIndicator(color = SpeakUpColors.SignalYellow, strokeWidth = 5.dp)
      }
    }
  }
}

@Composable
private fun StatusPlaceholder(
    ui: CameraUiState,
    hasActiveDevice: Boolean,
    isUpdateRequired: Boolean,
) {
  val title: String
  val subtitle: String?
  val showWaitingRow: Boolean
  when {
    !hasActiveDevice -> {
      title = stringResource(R.string.placeholder_put_on_glasses)
      subtitle = null
      showWaitingRow = true
    }
    isUpdateRequired -> {
      title = stringResource(R.string.update_required_title)
      subtitle = stringResource(R.string.update_required_subtitle)
      showWaitingRow = false
    }
    !ui.hasSession -> {
      title = stringResource(R.string.placeholder_ready_title)
      subtitle = stringResource(R.string.placeholder_ready_subtitle)
      showWaitingRow = false
    }
    else -> {
      title = stringResource(R.string.placeholder_session_started_title)
      subtitle = stringResource(R.string.placeholder_session_started_subtitle)
      showWaitingRow = false
    }
  }

  Column(
      modifier = Modifier.fillMaxSize().padding(24.dp),
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.Center,
  ) {
    Icon(
        painter = painterResource(id = R.drawable.camera_access_icon),
        contentDescription = stringResource(R.string.camera_access_icon_description),
        tint = SpeakUpColors.SignalYellow,
        modifier = Modifier.size(88.dp),
    )
    Spacer(modifier = Modifier.height(16.dp))
    Text(
        text = title,
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.headlineMedium,
        textAlign = TextAlign.Center,
    )
    if (subtitle != null) {
      Spacer(modifier = Modifier.height(8.dp))
      Text(
          text = subtitle,
          color = SpeakUpColors.PaperMuted,
          style = MaterialTheme.typography.bodyLarge,
          textAlign = TextAlign.Center,
      )
    }
    if (showWaitingRow) {
      Spacer(modifier = Modifier.height(12.dp))
      Text(
          text = stringResource(R.string.waiting_for_active_device),
          color = SpeakUpColors.PaperMuted,
          style = MaterialTheme.typography.bodyMedium,
          textAlign = TextAlign.Center,
      )
    }
  }
}

// MARK: - Top bar

@Composable
private fun TopBar(
    modifier: Modifier = Modifier,
    ui: CameraUiState,
    isDisconnectEnabled: Boolean,
    showSettingsMenu: Boolean,
    onToggleSettings: () -> Unit,
    onDisconnect: () -> Unit,
    settings: (@Composable () -> Unit)? = null,
) {
  Row(
      modifier =
          modifier.fillMaxWidth()
              .background(TopScrimBrush)
              .statusBarsPadding()
              .padding(horizontal = 16.dp, vertical = 12.dp),
      verticalAlignment = Alignment.Top,
  ) {
    Column(
        modifier =
            Modifier.weight(1f, fill = false)
                .clip(MaterialTheme.shapes.small)
                .background(SpeakUpColors.Night.copy(alpha = 0.7f))
                .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      StatusChip(
          label = stringResource(R.string.status_session),
          value = ui.sessionStateText,
          active = ui.isSessionActive,
          present = ui.hasSession,
      )
      StatusChip(
          label = stringResource(R.string.status_stream),
          value = ui.streamStateText,
          active = ui.isStreaming,
          present = ui.hasStream,
      )
    }

    Spacer(modifier = Modifier.width(12.dp))

    Box {
      // Pinned to TopEnd so it stays put when the Disconnect popover below widens this Box.
      Box(
          modifier =
              Modifier.align(Alignment.TopEnd)
                  .size(SpeakUpDimens.MinTouchTarget)
                  .clip(CircleShape)
                  .background(SpeakUpColors.Dusk)
                  .border(2.dp, SpeakUpColors.DuskLine, CircleShape)
                  .clickable(onClick = onToggleSettings),
          contentAlignment = Alignment.Center,
      ) {
        Icon(
            imageVector = Icons.Filled.LinkOff,
            contentDescription = stringResource(R.string.unregister_button_title),
            tint = SpeakUpColors.Paper,
            modifier = Modifier.size(28.dp),
        )
      }
      if (showSettingsMenu) {
        // Settings (the mode switches) above Disconnect.
        Column(
            modifier =
                Modifier.align(Alignment.TopEnd)
                    .offset(y = 64.dp)
                    .width(300.dp)
                    .clip(MaterialTheme.shapes.medium)
                    .background(SpeakUpColors.Night.copy(alpha = 0.96f))
                    .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
          if (settings != null) {
            Text(
                text = stringResource(R.string.hf_settings_heading),
                color = SpeakUpColors.Paper,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            settings()
          }
          SwitchButton(
              label = stringResource(R.string.unregister_button_title),
              onClick = onDisconnect,
              isDestructive = true,
              enabled = isDisconnectEnabled,
          )
        }
      }
    }
  }
}

@Composable
private fun StatusChip(label: String, value: String, active: Boolean, present: Boolean) {
  // The value is in words; the dot repeats it: filled cyan = active, yellow ring = present,
  // grey ring = none.
  StateDotLabel(
      text = "$label: $value",
      dot =
          if (active) SpeakUpColors.ListenCyan
          else if (present) SpeakUpColors.SignalYellow else SpeakUpColors.PaperMuted,
      filled = active,
  )
}

// MARK: - Bottom bar

@Composable
private fun BottomBar(
    ui: CameraUiState,
    isUpdateRequired: Boolean,
    hasActiveDevice: Boolean,
    onStartSession: () -> Unit,
    onEndSession: () -> Unit,
    onStartPreview: () -> Unit,
    onStopPreview: () -> Unit,
    onCapturePhoto: () -> Unit,
    onToggleRecording: () -> Unit,
    onToggleMic: () -> Unit,
    onOpenTool: (ToolId) -> Unit,
    onUpdateFirmware: () -> Unit,
    showTools: Boolean = true,
) {
  Column(
      modifier =
          Modifier.fillMaxWidth()
              .background(BottomScrimBrush)
              .navigationBarsPadding()
              .padding(horizontal = 16.dp, vertical = 20.dp),
      verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    if (isUpdateRequired) {
      UpdateRequiredMessage()
      SwitchButton(
          label = stringResource(R.string.update_firmware_button_title),
          onClick = onUpdateFirmware,
      )
    } else {
      // Tools need a live stream (they capture photos or read frames). The book reader keeps its
      // full-width button; the others share rows of two.
      if (showTools) ToolButtons(ui = ui, onOpenTool = onOpenTool)
      CaptureRow(
          ui = ui,
          onStartPreview = onStartPreview,
          onStopPreview = onStopPreview,
          onCapturePhoto = onCapturePhoto,
          onToggleRecording = onToggleRecording,
          onToggleMic = onToggleMic,
      )
      AnchoredPrimaryButton(
          ui = ui,
          hasActiveDevice = hasActiveDevice,
          onStartSession = onStartSession,
          onEndSession = onEndSession,
      )
    }
  }
}

@Composable
private fun ToolButtons(ui: CameraUiState, onOpenTool: (ToolId) -> Unit) {
  val visible = Modifier.alpha(if (ui.hasSession) 1f else 0f)
  val (book, others) = ToolRegistry.all.partition { it.id == ToolId.BOOK }
  Column(modifier = visible, verticalArrangement = Arrangement.spacedBy(10.dp)) {
    Text(
        text = stringResource(R.string.tools_heading),
        color = SpeakUpColors.Paper,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    for (spec in book) {
      CapturePill(
          modifier = Modifier.fillMaxWidth().testTag(spec.buttonTag),
          icon = spec.icon,
          label = stringResource(spec.buttonRes),
          contentDescription = stringResource(spec.buttonDescriptionRes),
          enabled = ui.isStreaming,
          primary = true,
          onClick = { onOpenTool(spec.id) },
      )
    }
    for (row in others.chunked(2)) {
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (spec in row) {
          CapturePill(
              modifier = Modifier.weight(1f).testTag(spec.buttonTag),
              icon = spec.icon,
              label = stringResource(spec.buttonRes),
              contentDescription = stringResource(spec.buttonDescriptionRes),
              enabled = ui.isStreaming,
              primary = true,
              onClick = { onOpenTool(spec.id) },
          )
        }
      }
    }
  }
}

@Composable
private fun CaptureRow(
    ui: CameraUiState,
    onStartPreview: () -> Unit,
    onStopPreview: () -> Unit,
    onCapturePhoto: () -> Unit,
    onToggleRecording: () -> Unit,
    onToggleMic: () -> Unit,
) {
  // previewActive mirrors iOS `previewIsActive`: live, recording, or tearing down. PAUSED is
  // excluded, so while paused the pill reverts to the (inert) start affordance instead of a live
  // stop button — the paused stream can't be torn down from here.
  val previewActive = ui.isStreaming || ui.isRecording || ui.streamState == StreamState.STOPPING
  val previewDisabled =
      if (previewActive) ui.isRecording || ui.isBusy else !ui.isSessionActive || ui.isBusy
  val captureEnabled = ui.isStreaming
  val micEnabled = ui.isStreaming && !ui.isRecording
  val recordEnabled = ui.isStreaming || ui.isRecording

  Row(
      modifier = Modifier.fillMaxWidth().alpha(if (ui.hasSession) 1f else 0f),
      horizontalArrangement = Arrangement.spacedBy(10.dp),
      verticalAlignment = Alignment.CenterVertically,
  ) {
    // Preview pill (gateway).
    CapturePill(
        modifier =
            Modifier.weight(1f)
                .testTag(if (previewActive) "stop_preview_button" else "start_preview_button"),
        icon = if (previewActive) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
        label = stringResource(R.string.preview_label),
        contentDescription =
            if (previewActive) stringResource(R.string.stop_preview)
            else stringResource(R.string.start_preview),
        enabled = !previewDisabled,
        onClick = { if (previewActive) onStopPreview() else onStartPreview() },
    )

    // Photo capture.
    CircleIconButton(
        modifier = Modifier.testTag("capture_button"),
        icon = Icons.Filled.PhotoCamera,
        contentDescription = stringResource(R.string.capture_photo),
        enabled = captureEnabled,
        onClick = onCapturePhoto,
    )

    // Record / stop, morphing into a live timer.
    RecordPill(
        modifier = Modifier.weight(1f).testTag("record_button"),
        isRecording = ui.isRecording,
        elapsedSeconds = ui.recordingElapsedSeconds,
        enabled = recordEnabled,
        onClick = onToggleRecording,
    )

    // Sound-in-video toggle.
    CircleIconButton(
        modifier = Modifier.testTag("mic_toggle"),
        icon = if (ui.includeAudioInStream) Icons.Filled.Mic else Icons.Filled.MicOff,
        contentDescription =
            if (ui.includeAudioInStream) stringResource(R.string.mic_on)
            else stringResource(R.string.mic_off),
        enabled = micEnabled,
        tint = if (ui.includeAudioInStream) SpeakUpColors.ListenCyan else SpeakUpColors.PaperMuted,
        onClick = onToggleMic,
    )
  }
}

@Composable
private fun AnchoredPrimaryButton(
    ui: CameraUiState,
    hasActiveDevice: Boolean,
    onStartSession: () -> Unit,
    onEndSession: () -> Unit,
) {
  // One persistent button so it holds a fixed Y — only its label/style/action change. Start needs
  // an active device; End stays available mid-stream (the SDK cascades the stop), so only an
  // in-flight transition disables it.
  val hasSession = ui.hasSession
  val enabled = if (hasSession) !ui.isBusy else !ui.isBusy && hasActiveDevice
  SwitchButton(
      label =
          if (hasSession) stringResource(R.string.end_session_button)
          else stringResource(R.string.start_session_button),
      onClick = { if (hasSession) onEndSession() else onStartSession() },
      modifier = Modifier.testTag(if (hasSession) "end_session_button" else "start_session_button"),
      isDestructive = hasSession,
      enabled = enabled,
  )
}

@Composable
private fun CapturePill(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
) {
  val container =
      when {
        !enabled -> SpeakUpColors.Dusk.copy(alpha = 0.85f)
        primary -> SpeakUpColors.SignalYellow
        else -> SpeakUpColors.Dusk
      }
  val content =
      when {
        !enabled -> SpeakUpColors.DisabledContent
        primary -> SpeakUpColors.OnAccent
        else -> SpeakUpColors.Paper
      }
  Row(
      modifier =
          modifier
              .heightIn(min = SpeakUpDimens.MinTouchTarget)
              .clip(PillShape)
              .background(container)
              .border(2.dp, if (primary && enabled) container else pillEdge(enabled), PillShape)
              .clickable(enabled = enabled, onClick = onClick)
              .semantics { this.contentDescription = contentDescription }
              .padding(horizontal = 14.dp, vertical = 8.dp),
      horizontalArrangement = Arrangement.Center,
      verticalAlignment = Alignment.CenterVertically,
  ) {
    Icon(
        imageVector = icon,
        contentDescription = null,
        tint = content,
        modifier = Modifier.size(24.dp),
    )
    Spacer(modifier = Modifier.width(8.dp))
    Text(
        text = label,
        color = content,
        style = MaterialTheme.typography.labelMedium,
        textAlign = TextAlign.Center,
    )
  }
}

/** Pill outline: light when it can be pressed, quiet when it can't. */
private fun pillEdge(enabled: Boolean): Color =
    if (enabled) SpeakUpColors.PaperMuted else SpeakUpColors.DuskLine

@Composable
private fun RecordPill(
    isRecording: Boolean,
    elapsedSeconds: Long,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
  // Recording: Voice Coral with Night content, a stop icon and the running time.
  val background =
      when {
        isRecording -> SpeakUpColors.VoiceCoral
        enabled -> SpeakUpColors.Dusk
        else -> SpeakUpColors.Dusk.copy(alpha = 0.85f)
      }
  Row(
      modifier =
          modifier
              .heightIn(min = SpeakUpDimens.MinTouchTarget)
              .clip(PillShape)
              .background(background)
              .border(2.dp, if (isRecording) background else pillEdge(enabled), PillShape)
              .clickable(enabled = enabled, onClick = onClick)
              .padding(horizontal = 14.dp, vertical = 8.dp),
      horizontalArrangement = Arrangement.Center,
      verticalAlignment = Alignment.CenterVertically,
  ) {
    if (isRecording) {
      Icon(
          imageVector = Icons.Filled.Stop,
          contentDescription = stringResource(R.string.stop_recording),
          tint = SpeakUpColors.OnAccent,
          modifier = Modifier.size(24.dp),
      )
      Spacer(modifier = Modifier.width(8.dp))
      val minutes = elapsedSeconds / 60
      val seconds = elapsedSeconds % 60
      Text(
          text = String.format(java.util.Locale.ROOT, "%02d:%02d", minutes, seconds),
          color = SpeakUpColors.OnAccent,
          style = MaterialTheme.typography.labelMedium,
          fontFamily = FontFamily.Monospace,
          modifier = Modifier.testTag("recording_indicator"),
      )
    } else {
      Icon(
          imageVector = Icons.Filled.Videocam,
          contentDescription = stringResource(R.string.record_video),
          tint = if (enabled) SpeakUpColors.VoiceCoral else SpeakUpColors.DisabledContent,
          modifier = Modifier.size(24.dp),
      )
      Spacer(modifier = Modifier.width(8.dp))
      Text(
          text = stringResource(R.string.record_label),
          color = if (enabled) SpeakUpColors.Paper else SpeakUpColors.DisabledContent,
          style = MaterialTheme.typography.labelMedium,
      )
    }
  }
}

@Composable
private fun CircleIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = SpeakUpColors.Paper,
) {
  Box(
      modifier =
          modifier
              .size(SpeakUpDimens.MinTouchTarget)
              .clip(CircleShape)
              .background(if (enabled) SpeakUpColors.Dusk else SpeakUpColors.Dusk.copy(alpha = 0.85f))
              .border(2.dp, pillEdge(enabled), CircleShape)
              .clickable(enabled = enabled, onClick = onClick),
      contentAlignment = Alignment.Center,
  ) {
    Icon(
        imageVector = icon,
        contentDescription = contentDescription,
        tint = if (enabled) tint else SpeakUpColors.DisabledContent,
        modifier = Modifier.size(26.dp),
    )
  }
}

@Composable
private fun UpdateRequiredMessage(modifier: Modifier = Modifier) {
  Row(
      modifier =
          modifier
              .fillMaxWidth()
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk)
              .border(2.dp, SpeakUpColors.VoiceCoral, MaterialTheme.shapes.medium)
              .padding(SpeakUpDimens.CardPadding),
      horizontalArrangement = Arrangement.spacedBy(12.dp),
      verticalAlignment = Alignment.Top,
  ) {
    Icon(
        imageVector = Icons.Filled.Warning,
        contentDescription = null,
        tint = SpeakUpColors.VoiceCoral,
        modifier = Modifier.size(28.dp),
    )
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
      Text(
          text = stringResource(R.string.update_required_title),
          color = SpeakUpColors.Paper,
          style = MaterialTheme.typography.titleMedium,
      )
      Text(
          text = stringResource(R.string.update_required_firmware_message),
          color = SpeakUpColors.Paper,
          style = MaterialTheme.typography.bodyLarge,
      )
    }
  }
}
