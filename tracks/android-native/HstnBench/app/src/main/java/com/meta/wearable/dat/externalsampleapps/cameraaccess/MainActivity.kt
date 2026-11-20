/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// CameraAccess Sample App - Main Activity
//
// This is the main entry point for the CameraAccess sample application that demonstrates how to use
// the Meta Wearables Device Access Toolkit (DAT) to:
// - Initialize the DAT SDK (only on the glasses path: the phone camera needs no Bluetooth, no Meta
//   AI; notes/phone-camera.md)
// - Handle device permissions (Bluetooth, Internet; Camera for the phone camera)
// - Request camera permissions from wearable devices (Ray-Ban Meta glasses)
// - Stream video and capture photos from connected wearable devices

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.Manifest.permission.BLUETOOTH
import android.Manifest.permission.BLUETOOTH_CONNECT
import android.Manifest.permission.CAMERA
import android.Manifest.permission.INTERNET
import android.Manifest.permission.RECORD_AUDIO
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.PermState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.setup.SetupVoice
import android.view.accessibility.AccessibilityManager
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.HandsFreeStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolRegistry
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeIntent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeLaunch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.LaunchIntent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolLaunch
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.CameraAccessScaffold
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.SpeakUpTheme
import com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables.WearablesViewModel
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MainActivity : ComponentActivity(), SetupVoice.Host {
  companion object {
    private const val TAG = "CameraAccessMain"
    // Intent boolean extra that activates the MockDevice test server for out-of-process MCP
    // control.
    private const val EXTRA_UI_TESTING = "mwdat_ui_testing"
    // Fixed loopback port the test server binds so the MCP host can reach it with a
    // deterministic `adb forward`. Must match _DEFAULT_ANDROID_TEST_SERVER_PORT in the
    // plugin's mcp/target_resolver.py.
    private const val MOCK_TEST_SERVER_PORT = 8237

    // Hands-free: speakup://handsfree, the "Hands-free" launcher shortcut, `--ez handsfree true`.
    const val EXTRA_HANDS_FREE = HandsFreeLaunch.EXTRA

    // Voice-first tools ("Hey Google, open Book Reader" / "Mail Reader" / ...): each has a launcher
    // alias, a deep link hstnbench://<id> (?mode=..&arg=..) and an intent extra `--es tool <id>`
    // (plus `--es tool_mode`, `--es tool_arg`). The book reader also keeps `--ez book_reader true`.
    // Parsed by ToolLaunch (tools/core/ToolId.kt).
    const val EXTRA_BOOK_READER = ToolLaunch.EXTRA_BOOK_READER
    const val EXTRA_TOOL = ToolLaunch.EXTRA_TOOL
    const val EXTRA_TOOL_MODE = ToolLaunch.EXTRA_MODE
    const val EXTRA_TOOL_ARG = ToolLaunch.EXTRA_ARG

    // Required Android permissions for the DAT SDK to function properly
    val PERMISSIONS: Array<String> = arrayOf(BLUETOOTH, BLUETOOTH_CONNECT, INTERNET)
    private const val SETUP_PREFS = "setup_voice"
  }

  val viewModel: WearablesViewModel by viewModels()
  val setupVoice: SetupVoice by viewModels()

  // Permissions refused in this run: not asked again on every onStart (each return from Meta AI or
  // Settings is an onStart). Saying "connect" asks again; Android itself stops asking after two.
  private val refusedThisRun = mutableSetOf<String>()

  // The user asked for the glasses this run ("connect my glasses", the button): Nearby devices is
  // asked for from now on. Until then a launch only asks for the microphone, so choosing the phone
  // never meets a Bluetooth dialog.
  private var glassesAsked = false
  // Registration waits for Nearby devices to be granted (asked for by the connect button).
  private var registrationPending = false

  /** Launch permissions: the mic (voice), plus Nearby devices on the glasses path. */
  private fun launchPermissions(): List<String> {
    val mode = HandsFreeStore.get(this).settings.value
    val glasses = CameraSourceRules.needsBluetooth(mode.cameraSource, glassesAsked)
    return (if (glasses) PERMISSIONS.toList() else emptyList()) + RECORD_AUDIO
  }

  private val permissionCheckLauncher =
      registerForActivityResult(RequestMultiplePermissions()) { permissionsResult ->
        permissionsResult.forEach { (permission, granted) -> if (!granted) refusedThisRun += permission }
        deliverPermissions()
      }

  private var permissionContinuation: CancellableContinuation<PermissionStatus>? = null
  private val permissionMutex = Mutex()
  // Requesting wearable device permissions via the Meta AI app
  private val permissionsResultLauncher =
      registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        val permissionStatus = result.getOrDefault(PermissionStatus.Denied)
        permissionContinuation?.resume(permissionStatus)
        permissionContinuation = null
      }

  // Convenience method to make a permission request in a sequential manner
  // Uses a Mutex to ensure requests are processed one at a time, preventing race conditions
  suspend fun requestWearablesPermission(permission: Permission): PermissionStatus {
    return permissionMutex.withLock {
      suspendCancellableCoroutine { continuation ->
        permissionContinuation = continuation
        continuation.invokeOnCancellation { permissionContinuation = null }
        permissionsResultLauncher.launch(permission)
      }
    }
  }

  private var audioPermissionContinuation: CancellableContinuation<Boolean>? = null
  // Phone microphone permission, requested in context when recording with sound-in-video on.
  private val recordAudioPermissionLauncher =
      registerForActivityResult(RequestPermission()) { granted ->
        audioPermissionContinuation?.resume(granted)
        audioPermissionContinuation = null
      }

  private var cameraPermissionContinuation: CancellableContinuation<Boolean>? = null
  private val cameraPermissionLauncher =
      registerForActivityResult(RequestPermission()) { granted ->
        cameraPermissionContinuation?.resume(granted)
        cameraPermissionContinuation = null
      }

  /**
   * The phone camera's permission (ToolHub says why first, in hands-free mode). A permanent refusal
   * isn't asked again: BLOCKED, and ToolHub says how to fix it in Settings.
   */
  suspend fun requestCameraPermission(): PermState {
    if (isGranted(CAMERA)) return PermState.GRANTED
    if (isBlocked(CAMERA)) return PermState.BLOCKED
    getSharedPreferences(SETUP_PREFS, MODE_PRIVATE).edit().putBoolean("asked_$CAMERA", true).apply()
    val granted =
        permissionMutex.withLock {
          suspendCancellableCoroutine { continuation ->
            cameraPermissionContinuation = continuation
            continuation.invokeOnCancellation { cameraPermissionContinuation = null }
            cameraPermissionLauncher.launch(CAMERA)
          }
        }
    return if (granted) PermState.GRANTED else permState(CAMERA)
  }

  // Requests RECORD_AUDIO for sound-in-video. Returns true if granted (already or just now); false
  // if denied, so recording can proceed video-only instead of being blocked.
  suspend fun requestRecordAudioPermission(): Boolean {
    if (
        ContextCompat.checkSelfPermission(this, RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    ) {
      return true
    }
    return permissionMutex.withLock {
      suspendCancellableCoroutine { continuation ->
        audioPermissionContinuation = continuation
        continuation.invokeOnCancellation { audioPermissionContinuation = null }
        recordAudioPermissionLauncher.launch(RECORD_AUDIO)
      }
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    maybeStartMockDeviceTestServer()
    // SpeakUp is dark-first: light system-bar icons over the Night page.
    enableEdgeToEdge(
        statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
    )
    val launchTool =
        ToolLaunch.parse(
            LaunchIntent(
                componentClass = intent.component?.className,
                toolExtra = intent.getStringExtra(EXTRA_TOOL),
                modeExtra = intent.getStringExtra(EXTRA_TOOL_MODE),
                argExtra = intent.getStringExtra(EXTRA_TOOL_ARG),
                bookReaderExtra = intent.getBooleanExtra(EXTRA_BOOK_READER, false),
                scheme = intent.data?.scheme,
                host = intent.data?.host,
                queryMode = intent.data?.getQueryParameter(ToolLaunch.QUERY_MODE),
                queryArg = intent.data?.getQueryParameter(ToolLaunch.QUERY_ARG),
            ),
        )
    Log.i(TAG, "launch tool=$launchTool")
    setupVoice.setLaunchedTool(launchTool?.let { getString(ToolRegistry.spec(it.tool).nameRes) })
    applyHandsFreeLaunch()
    setContent {
      SpeakUpTheme {
        CameraAccessScaffold(
            viewModel = viewModel,
            onRequestWearablesPermission = ::requestWearablesPermission,
            onRequestRecordAudioPermission = ::requestRecordAudioPermission,
            launchTool = launchTool,
        )
      }
    }
  }

  /**
   * Hands-free mode (notes/hands-free-mode.md): the first run decides the default (TalkBack on ->
   * hands-free on, said once), and speakup://handsfree, the "Hands-free" launcher shortcut and
   * `--ez handsfree true` open straight into hands-free mode and switch it on.
   */
  private fun applyHandsFreeLaunch() {
    val mode = HandsFreeStore.get(this)
    mode.firstRun(screenReaderOn = isScreenReaderOn())
    val launched =
        HandsFreeLaunch.isHandsFree(
            HandsFreeIntent(
                handsFreeExtra = intent.getBooleanExtra(HandsFreeLaunch.EXTRA, false),
                scheme = intent.data?.scheme,
                host = intent.data?.host,
            ),
        )
    if (launched) {
      // Switched on by the launch: say so once, like the first run.
      if (mode.setHandsFree(true)) mode.queueAnnouncement()
      setupVoice.setVoiceFirstVisit(true)
    }
    Log.i(TAG, "hands-free=${mode.handsFree} launched=$launched")
  }

  private fun isScreenReaderOn(): Boolean =
      (getSystemService(ACCESSIBILITY_SERVICE) as? AccessibilityManager)?.isTouchExplorationEnabled == true

  override fun onStart() {
    super.onStart()
    // First, ensure the app has necessary Android permissions
    checkPermissions(fromVoice = false)
  }

  /**
   * Asks for the launch permissions that are missing and can still be asked for, after saying out
   * loud what Android's dialog is about (unless the user just asked by voice and heard it already).
   * Permanently refused ones aren't asked: the setup screen says how to fix them in Settings.
   */
  private fun checkPermissions(fromVoice: Boolean) {
    val askable =
        launchPermissions().filter {
          !isGranted(it) && !isBlocked(it) && (fromVoice || it !in refusedThisRun)
        }
    // Normal (install-time) permissions are always granted; only the runtime ones need a dialog.
    if (askable.isEmpty()) {
      deliverPermissions()
      return
    }
    val prefs = getSharedPreferences(SETUP_PREFS, MODE_PRIVATE).edit()
    askable.forEach { prefs.putBoolean("asked_$it", true) }
    prefs.apply()
    val launch = { permissionCheckLauncher.launch(askable.toTypedArray()) }
    // The toolbox doesn't talk first: Android's dialog explains itself.
    if (fromVoice || !setupVoice.talksFirst) {
      launch()
      return
    }
    val needsBluetooth = BLUETOOTH_CONNECT in askable
    val needsMic = RECORD_AUDIO in askable
    val line =
        when {
          needsBluetooth && needsMic -> R.string.setup_ask_both
          needsBluetooth -> R.string.setup_ask_bluetooth
          else -> R.string.setup_ask_mic
        }
    setupVoice.speakThen(getString(line), launch)
  }

  private fun deliverPermissions() {
    val bluetooth = PERMISSIONS.all { isGranted(it) }
    // On the phone path with Nearby devices off, the DAT SDK isn't started and nothing complains:
    // the app isn't registered, so AUTO uses the phone camera.
    if (bluetooth || CameraSourceRules.needsBluetooth(HandsFreeStore.get(this).settings.value.cameraSource, glassesAsked)) {
      viewModel.onPermissionsResult(PERMISSIONS.associateWith { isGranted(it) }) {
        // Initialize the DAT SDK once the permissions are granted
        // This is REQUIRED before using any Wearables APIs
        Wearables.initialize(this)
      }
    }
    if (bluetooth && registrationPending) {
      registrationPending = false
      viewModel.startRegistration(this)
    }
    setupVoice.onPermissions(
        bluetooth = permState(BLUETOOTH_CONNECT),
        mic = permState(RECORD_AUDIO),
    )
  }

  private fun isGranted(permission: String): Boolean =
      ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

  // Asked before, refused, and Android no longer shows a rationale: it won't show the dialog again.
  private fun isBlocked(permission: String): Boolean =
      !isGranted(permission) &&
          getSharedPreferences(SETUP_PREFS, MODE_PRIVATE).getBoolean("asked_$permission", false) &&
          !shouldShowRequestPermissionRationale(permission)

  private fun permState(permission: String): PermState =
      when {
        isGranted(permission) -> PermState.GRANTED
        isBlocked(permission) -> PermState.BLOCKED
        else -> PermState.ASKABLE
      }

  // SetupVoice.Host: what the spoken setup screen can do.

  /** The connect button or "connect": Nearby devices first if it isn't granted yet, then Meta AI. */
  override fun startRegistration() {
    glassesAsked = true
    if (PERMISSIONS.all { isGranted(it) }) {
      if (!viewModel.uiState.value.canRegister) deliverPermissions()
      viewModel.startRegistration(this)
    } else {
      registrationPending = true
      checkPermissions(fromVoice = true)
    }
  }

  /** "Use my phone's camera" on the setup screen: the tools open on the phone camera. */
  override fun usePhone() {
    Log.i(TAG, "setup: use the phone camera")
    HandsFreeStore.get(this).setPhoneChosen(true)
  }

  override fun quitApp() {
    moveTaskToBack(true)
  }

  override fun openAppSettings() {
    startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
    )
  }

  override fun askAppPermissions(forGlasses: Boolean) {
    if (forGlasses) glassesAsked = true
    checkPermissions(fromVoice = true)
  }

  // Debug-only: when launched with `--ez mwdat_ui_testing true`, enable MockDeviceKit and start its
  // local HTTP test server so an out-of-process MCP client can drive the app without real glasses.
  private fun maybeStartMockDeviceTestServer() {
    if (!BuildConfig.DEBUG || !intent.getBooleanExtra(EXTRA_UI_TESTING, false)) {
      return
    }
    val mockDeviceKit = MockDeviceKit.getInstance(applicationContext)
    mockDeviceKit.enable(MockDeviceKitConfig(initiallyRegistered = false))
    mockDeviceKit
        .startTestServer(MOCK_TEST_SERVER_PORT)
        .fold(
            onSuccess = { Log.i(TAG, "MockDevice test server started") },
            onFailure = { error, _ ->
              Log.w(TAG, "Failed to start MockDevice test server: ${error.description}")
            },
        )
  }
}
