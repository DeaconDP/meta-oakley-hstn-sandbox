// PageCamera - what the tools need from a camera (the glasses or the phone)
//
// A tool only needs a still for OCR, a cheap motion score for page-turn detection, decoded frames
// for tools that look continuously (watch for text, light and colour), and whether the camera is
// streaming. Two cameras implement it: CameraViewModel (the glasses, over DAT) and PhoneCamera
// (CameraX). Tools see CameraSourceSelector, which forwards to whichever is in use and can switch
// at runtime (notes/phone-camera.md). This interface has no DAT types: the glasses-only parts (the
// DeviceSession for on-glasses speech, connecting with a Meta AI permission callback) are in
// GlassesLink. (It started as the book reader's seam, hence the name.)

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.graphics.Bitmap
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
  /** True while the camera is streaming (capture is only possible then). */
  val isStreaming: StateFlow<Boolean>

  /** Where the link is, for narration. The phone goes DISCONNECTED -> CONNECTING -> STREAMING. */
  val link: StateFlow<CameraLink>

  /**
   * A 0..1 change score per frame while streaming (0 = same as the last frame), for page-turn
   * detection. The glasses derive it from compressed frame sizes (FrameSizeMotion), the phone from
   * small luma grids (FrameDifferenceMotion). Cold: each collector gets its own baseline.
   */
  val motion: Flow<Float>

  /**
   * A still for OCR. Glasses: the GA in-stream `Stream.capturePhoto()` (960x1440 on the mock).
   * Phone: CameraX ImageCapture, about 1920 px on the long side or more. Null if not streaming or
   * the capture failed. Doesn't open the photo preview.
   */
  suspend fun capturePage(): Bitmap?

  /**
   * Frames, at most [maxFps] per second, for as long as the flow is collected. ARGB_8888, upright.
   * Glasses: the decoded picture's size (540x960 for plant.mp4), copied off the preview Surface
   * (PixelCopy) or decoded by a second decoder (notes/tools-layer.md > Frames). Phone: about 960 px
   * on the long side. Emits nothing while not streaming. Each Bitmap is new; the receiver may keep it.
   */
  fun frames(maxFps: Float = 2f): Flow<Bitmap>

  /**
   * The newest frame if one is under [maxAgeMs] old; otherwise waits for one (up to [timeoutMs]),
   * and as a last resort captures a photo (capturePage). Null if not streaming.
   */
  suspend fun latestFrame(maxAgeMs: Long = 1_000L, timeoutMs: Long = 2_500L): Bitmap?

  /**
   * Hold exposure and white balance still (the light and colour tool measures brightness, so the
   * camera mustn't compensate). Optional: the glasses ignore it; the phone applies it once its
   * auto exposure has settled. Every tool that locks must unlock when it leaves.
   */
  fun lockExposure(locked: Boolean) = Unit
}
