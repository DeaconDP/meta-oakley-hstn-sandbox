/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// CameraAccessScaffold - DAT Application Navigation Orchestrator
//
// This scaffold demonstrates a typical DAT application navigation pattern based on device
// registration state from the DAT API.
//
// Navigation (glasses optional, notes/phone-camera.md):
// - HomeScreen (setup): not registered and the user hasn't chosen yet. Offers "Use my phone's
//   camera" next to "Connect my glasses" (Wearables.startRegistration()).
// - CameraScreen: registered, or the phone was chosen (setup's "use my phone", or the camera source
//   setting PHONE). On the glasses it walks the SDK lifecycle: start session, start preview,
//   capture/record, stop, end session; on the phone it shows the CameraX preview.
//
// The scaffold also provides a debug menu (in DEBUG builds) that gives access to
// MockDeviceKitScreen for testing DAT functionality without physical devices.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import android.content.Context
import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.BuildConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupVoice
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.HandsFreeStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CameraAccessScaffold(
    viewModel: WearablesViewModel,
    onRequestWearablesPermission: suspend (Permission) -> PermissionStatus,
    onRequestRecordAudioPermission: suspend () -> Boolean,
    modifier: Modifier = Modifier,
    launchTool: ToolRequest? = null,
) {
  val uiState by viewModel.uiState.collectAsStateWithLifecycle()
  val snackbarHostState = remember { SnackbarHostState() }
  val bottomSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

  val context = LocalContext.current
  val setupVoice: SetupVoice = viewModel()
  val modeStore = remember { HandsFreeStore.get(context) }
  val mode by modeStore.settings.collectAsStateWithLifecycle()
  val showSetup = CameraSourceRules.showSetup(uiState.isRegistered, mode.cameraSource, mode.phoneChosen)

  // Observe recent errors and show snackbar. In hands-free mode errors are also spoken (SetupVoice
  // .announce only speaks then): with TalkBack on, TalkBack reads the snackbar (a polite live
  // region), so we don't speak it a second time.
  LaunchedEffect(uiState.recentError?.id) {
    uiState.recentError?.let { error ->
      if (!isTouchExplorationOn(context)) setupVoice.announce(error.message)
      snackbarHostState.showSnackbar(error.message)
      viewModel.clearRecentError(error.id)
    }
  }

  Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    Box(modifier = Modifier.fillMaxSize()) {
      if (!showSetup) {
        CameraScreen(
            wearablesViewModel = viewModel,
            onRequestWearablesPermission = onRequestWearablesPermission,
            onRequestRecordAudioPermission = onRequestRecordAudioPermission,
            launchTool = launchTool,
        )
      } else {
        // First run (not registered, no camera chosen): the setup screen talks and listens
        // (setup/SetupVoice). A voice-first launch into a tool names the tool in the welcome.
        HomeScreen(
            viewModel = viewModel,
            setupVoice = setupVoice,
        )
      }

      SnackbarHost(
          hostState = snackbarHostState,
          modifier =
              Modifier.align(Alignment.BottomCenter)
                  .navigationBarsPadding()
                  .padding(horizontal = 16.dp, vertical = 32.dp),
          snackbar = { data ->
            // Dusk card with a Voice Coral edge and warning icon: the error is in words and an
            // icon, not colour alone.
            Snackbar(
                modifier =
                    Modifier.semantics { liveRegion = LiveRegionMode.Polite }
                        .border(2.dp, SpeakUpColors.VoiceCoral, RoundedCornerShape(24.dp)),
                shape = RoundedCornerShape(24.dp),
                containerColor = SpeakUpColors.Dusk,
                contentColor = SpeakUpColors.Paper,
            ) {
              Row(
                  verticalAlignment = Alignment.CenterVertically,
                  modifier = Modifier.padding(vertical = 8.dp),
              ) {
                Icon(
                    imageVector = Icons.Default.Error,
                    contentDescription = stringResource(R.string.scaffold_error_icon_description),
                    tint = SpeakUpColors.VoiceCoral,
                    modifier = Modifier.size(28.dp),
                )
                Spacer(modifier = Modifier.width(12.dp))
                Text(
                    text = data.visuals.message,
                    style = MaterialTheme.typography.bodyLarge,
                    color = SpeakUpColors.Paper,
                )
              }
            }
          },
      )

      if (BuildConfig.DEBUG) {
        FloatingActionButton(
            onClick = { viewModel.showDebugMenu() },
            modifier = Modifier.align(Alignment.CenterEnd),
            containerColor = SpeakUpColors.Dusk,
            contentColor = SpeakUpColors.Paper,
        ) {
          Icon(
              Icons.Default.BugReport,
              contentDescription = stringResource(R.string.debug_menu_description),
          )
        }

        if (uiState.isDebugMenuVisible) {
          ModalBottomSheet(
              onDismissRequest = { viewModel.hideDebugMenu() },
              sheetState = bottomSheetState,
              modifier = Modifier.fillMaxSize(),
          ) {
            MockDeviceKitScreen(modifier = Modifier.fillMaxSize())
          }
        }
      }
    }
  }
}

/** TalkBack (or another touch-exploration screen reader) is on: it reads live regions itself. */
private fun isTouchExplorationOn(context: Context): Boolean =
    (context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager)
        ?.isTouchExplorationEnabled == true
