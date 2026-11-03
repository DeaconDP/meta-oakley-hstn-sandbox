// PageCamera - what the book reader needs from the glasses camera
//
// CameraViewModel owns the DAT session and stream; the reader only needs a still for OCR, a cheap
// per-frame signal for page-turn detection, the session (to attach on-glasses speech recognition),
// and a way to bring the stream up with no taps when the app is launched straight into the reader.
// Keeping it to this interface leaves the reader independent of the camera screen's lifecycle code.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

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
   * Starts the session if needed, then the stream, with no confirmation dialogs: a blind user
   * launching straight into the reader can't see them. If camera access isn't granted yet,
   * [requestPermission] is called (it opens the Meta AI app).
   */
  fun connectAndStream(requestPermission: suspend (Permission) -> PermissionStatus)
}
