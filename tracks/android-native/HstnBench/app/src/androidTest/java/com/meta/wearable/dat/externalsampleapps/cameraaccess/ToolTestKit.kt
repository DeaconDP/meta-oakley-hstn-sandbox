// ToolTestKit - what a tool's instrumented test needs on the Mock Device Kit
//
// One place for the setup every tool test repeats (see notes/tools-layer.md > How to test a tool on
// the mock):
//   - pair a mock Oakley Meta HSTN that is on, worn and unfolded, with camera/mic permissions set;
//   - what the glasses' camera sees: [showImage] sets the in-stream photo (capturePage) to a
//     rendered Bitmap; [playFrames] encodes Bitmaps into an HEVC MP4 (MockVideo) and makes it the
//     live stream (frames / latestFrame); [playAsset] uses a bundled clip (plant.mp4);
//   - [say]: the glasses' speech recogniser "hears" text (mwdat-speech simulateTranscription),
//     which goes through ToolHub exactly like real speech;
//   - [launch]: start the app straight into a tool, voice-first, as the launcher alias would;
//   - reach the activity's ToolHub and CameraViewModel ([hub], [camera]) to check what was said
//     (ToolHub.recentSpeech), the active tool, or to read frames;
//   - read Compose nodes by test tag ([text], [exists]).
// MockDeviceKit must be disabled after each test ([tearDown]).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.camera.CameraViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import java.io.File
import java.io.FileOutputStream

object ToolTestKit {

  private const val TAG = "ToolTestKit"

  val context: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

  /** Android permissions the app needs, granted; saved tool and book state cleared. Call in @Before. */
  fun setUp() {
    listOf("BLUETOOTH", "BLUETOOTH_CONNECT", "CAMERA", "INTERNET", "RECORD_AUDIO").forEach {
      InstrumentationRegistry.getInstrumentation()
          .uiAutomation
          .executeShellCommand("pm grant ${context.packageName} android.permission.$it")
    }
    for (prefs in listOf("book_reader", "tools")) {
      context.getSharedPreferences(prefs, Context.MODE_PRIVATE).edit().clear().commit()
    }
  }

  /** Call in @After. */
  fun tearDown(scenario: ActivityScenario<MainActivity>?) {
    scenario?.close()
    MockDeviceKit.getInstance(context).disable()
  }

  /**
   * Mock HSTN glasses: paired, powered, worn, unfolded, streaming [feed] (plant.mp4 by default).
   * With [cameraGranted] the stream starts without the Meta AI permission step; with [micGranted]
   * voice uses the glasses' recogniser, so [say] works.
   */
  fun pairHstn(
      cameraGranted: Boolean = true,
      micGranted: Boolean = true,
      feed: Uri = assetUri("plant.mp4"),
  ): MockGlasses {
    val kit = MockDeviceKit.getInstance(context)
    kit.enable(MockDeviceKitConfig(initialPermissionsGranted = cameraGranted))
    kit.permissions.set(Permission.CAMERA, if (cameraGranted) PermissionStatus.Granted else PermissionStatus.Denied)
    if (micGranted) kit.permissions.set(Permission.MICROPHONE, PermissionStatus.Granted)
    val glasses = kit.pairGlasses(GlassesModel.OAKLEY_META_HSTN).getOrThrow()
    glasses.powerOn()
    glasses.don()
    glasses.unfold()
    glasses.services.camera.setCameraFeed(feed)
    return glasses
  }

  /** The in-stream photo (PageCamera.capturePage) becomes [bitmap]. */
  fun showImage(glasses: MockGlasses, bitmap: Bitmap, name: String = "mock_capture.png") {
    val file = File(context.cacheDir, name)
    FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    glasses.services.camera.setCapturedImage(Uri.fromFile(file))
  }

  /**
   * The live stream (PageCamera.frames, latestFrame, the preview) shows [frames], each for [holdMs],
   * looping. Encoded on the phone (MockVideo); takes a second or two. Call before the stream starts,
   * or expect the mock to switch clips on its next loop.
   */
  fun playFrames(glasses: MockGlasses, frames: List<Bitmap>, holdMs: Long = 1_000L, name: String = "mock_feed.mp4"): Uri {
    val started = System.currentTimeMillis()
    val file = MockVideo.encode(frames, File(context.cacheDir, name), holdMs = holdMs)
    Log.i(TAG, "encoded ${frames.size} frames to ${file.length()} bytes in ${System.currentTimeMillis() - started} ms")
    val uri = Uri.fromFile(file)
    glasses.services.camera.setCameraFeed(uri)
    return uri
  }

  /** A clip from the test APK's assets as the live stream. */
  fun playAsset(glasses: MockGlasses, assetName: String) = glasses.services.camera.setCameraFeed(assetUri(assetName))

  /** The glasses' recogniser "hears" [text] (a final result). */
  fun say(glasses: MockGlasses, text: String, isFinal: Boolean = true) {
    Log.i(TAG, "say \"$text\"")
    glasses.services.speech.simulateTranscription(text, isFinal, 0.9f)
  }

  /** Launches straight into [request]'s tool, voice-first (no taps), like its launcher entry. */
  fun launch(request: ToolRequest): ActivityScenario<MainActivity> =
      ActivityScenario.launch(
          Intent(context, MainActivity::class.java)
              .putExtra(MainActivity.EXTRA_TOOL, request.tool.id)
              .apply {
                request.mode?.let { putExtra(MainActivity.EXTRA_TOOL_MODE, it) }
                request.argument?.let { putExtra(MainActivity.EXTRA_TOOL_ARG, it) }
              }
              .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
      )

  /** Launches with a deep link, e.g. "hstnbench://light?mode=colour". */
  fun launchDeepLink(uri: String): ActivityScenario<MainActivity> =
      ActivityScenario.launch(
          Intent(Intent.ACTION_VIEW, Uri.parse(uri), context, MainActivity::class.java)
              .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
      )

  /**
   * The activity's ToolHub. The same instance the screens use: they ask the activity's
   * ViewModelStore with the same key, so if the test asks first, the screens get this one.
   */
  fun hub(scenario: ActivityScenario<MainActivity>): ToolHub {
    val camera = camera(scenario)
    var hub: ToolHub? = null
    scenario.onActivity { hub = ViewModelProvider(it, ToolHub.Factory(it.application, camera))[ToolHub::class.java] }
    return hub!!
  }

  /** The activity's CameraViewModel, which implements PageCamera (frames, capturePage). */
  fun camera(scenario: ActivityScenario<MainActivity>): CameraViewModel {
    var camera: CameraViewModel? = null
    scenario.onActivity {
      camera =
          ViewModelProvider(it, CameraViewModel.Factory(it.application, it.viewModel))[CameraViewModel::class.java]
    }
    return camera!!
  }

  /** True if something on screen has test tag [tag]. */
  fun exists(rule: ComposeTestRule, tag: String): Boolean =
      rule.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes().isNotEmpty()

  /** The text of the node tagged [tag], or null if it isn't on screen. */
  fun text(rule: ComposeTestRule, tag: String): String? =
      rule
          .onAllNodes(hasTestTag(tag), useUnmergedTree = true)
          .fetchSemanticsNodes()
          .firstOrNull()
          ?.config
          ?.getOrNull(SemanticsProperties.Text)
          ?.joinToString("") { it.text }

  /** Copies an asset from the test APK to the app's cache and returns its file URI. */
  fun assetUri(assetName: String): Uri {
    val outFile = File(context.cacheDir, assetName)
    InstrumentationRegistry.getInstrumentation().context.assets.open(assetName).use { input ->
      FileOutputStream(outFile).use { output -> input.copyTo(output) }
    }
    return Uri.fromFile(outFile)
  }
}
