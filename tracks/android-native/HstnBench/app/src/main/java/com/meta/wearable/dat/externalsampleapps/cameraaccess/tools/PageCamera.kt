// PageCamera - what the tools need from the glasses camera
//
// CameraViewModel owns the DAT session and stream; a tool only needs a still for OCR, a cheap
// per-frame signal for page-turn detection, decoded stream frames for tools that look continuously
// (watch for text, light and colour), the session (to attach on-glasses speech recognition), and a
// way to bring the stream up with no taps when the app is launched straight into a tool. Keeping it
// to this interface leaves the tools independent of the camera screen's lifecycle code. (It started
// as the book reader's seam, hence the name.)

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.graphics.Bitmap
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** Size of one compressed stream frame. Motion makes HEVC P-frames bigger. */
data class StreamFrameSize(val bytes: Int, val isCodecConfig: Boolean)

/** How far the glasses link has got, for the spoken start-up narration. */
enum class CameraLink {
  /** No session. */
  DISCONNECTED,
  /** Session starting (finding and connecting to the glasses). */
  CONNECTING,
  /** Session up, stream not yet. */
  CONNECTED,
  /** Waiting on the camera permission in the Meta AI app. */
  NEEDS_PERMISSION,
  /** Camera permission was refused. */
  CAMERA_DENIED,
  /** Stream starting. */
  STARTING_STREAM,
  /** The glasses paused the stream (e.g. a tap on the frame); it resumes by itself. */
  PAUSED,
  /** Frames flowing; pages can be captured. */
  STREAMING,
}

interface PageCamera {
  /** True while the glasses stream is live (capture is only possible then). */
  val isStreaming: StateFlow<Boolean>

  /** Where the link is, for narration. */
  val link: StateFlow<CameraLink>

  /** Every compressed frame's size while streaming. Hot; frames are dropped if not collected. */
  val frameSizes: Flow<StreamFrameSize>

  /** The running DAT session, or null. The reader attaches speech recognition to it. */
  val deviceSession: DeviceSession?

  /**
   * A still for OCR, using the GA in-stream `Stream.capturePhoto()` (960x1440 on the mock). Null if
   * not streaming or the capture failed. Doesn't open the photo preview.
   */
  suspend fun capturePage(): Bitmap?

  /**
   * Stream frames, at most [maxFps] per second, for as long as the flow is collected. ARGB_8888 at
   * the decoded picture's size (the mock streams its feed video's size: 540x960 for plant.mp4,
   * 480x864 for MockVideo feeds). Normally copied off the preview Surface (PixelCopy: no extra
   * decode); with no preview Surface (screen off, app in the background) a second, hardware HEVC
   * decoder runs only while collected; if neither works, capturePage() at most once a second.
   * Measured cost: notes/tools-layer.md > Frames. Emits nothing while not streaming. Each Bitmap is
   * new; the receiver may keep it.
   */
  fun frames(maxFps: Float = 2f): Flow<Bitmap>

  /**
   * The newest decoded frame if one is under [maxAgeMs] old; otherwise decodes until one arrives
   * (up to [timeoutMs]), and as a last resort captures a photo (capturePage). Null if not streaming.
   */
  suspend fun latestFrame(maxAgeMs: Long = 1_000L, timeoutMs: Long = 2_500L): Bitmap?

  /**
   * Starts the session if needed, then the stream, with no confirmation dialogs: a blind user
   * launching straight into the reader can't see them. If camera access isn't granted yet,
   * [requestPermission] is called (it opens the Meta AI app).
   */
  fun connectAndStream(requestPermission: suspend (Permission) -> PermissionStatus)
}
