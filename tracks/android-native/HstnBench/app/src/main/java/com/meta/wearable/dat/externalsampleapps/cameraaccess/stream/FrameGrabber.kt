// FrameGrabber - decoded stream frames as Bitmaps, for tools that look continuously
//
// The preview decoder (HevcDecoder) renders straight to the screen's Surface, so the app never sees
// the pixels. Tools like "watch for text" and "light and colour" need them several times a second,
// and the in-stream photo (capturePhoto, ~1 s, interrupts glasses speech) is too slow for that.
// This runs a second HevcDecoder with no Surface: the codec hands each decoded frame over as a YUV
// Image (MediaCodec.getOutputImage), and at most [maxFps] frames a second are converted to ARGB.
// The Image has the picture's real size (DAT's VideoFrame reports the MEDIUM preset, 504x896, even
// for a 540x960 feed; an ImageReader sized from that crashed the hardware decoder). It uses the
// phone's hardware HEVC decoder when there is one (the preview keeps the SDK's software choice; a
// bad hardware decoder here costs frames, not the preview). Decoding is the expensive part (software HEVC, 24-30 frames a second on
// top of the preview's own decode), so it decodes as little as it can: when keyframes come at least as often as frames are wanted (every 0.4 s on the
// mock), only keyframes are decoded, each on its own (they don't depend on other frames). Only
// when a tool wants frames faster than that does it decode every frame (P-frames depend on the
// ones before). The choice is made at each keyframe, from the measured keyframe interval.
// CameraViewModel only runs it while some tool is collecting frames, and stops it when the last one
// stops. The decoder starts on the next keyframe, primed with the stream's cached parameter sets.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.stream

import android.graphics.Bitmap
import android.media.Image
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** [width] x [height] is what the stream says; the frames come out at the decoded picture's size. */
class FrameGrabber(private val width: Int, private val height: Int) {

  /** A converted frame and when it was decoded (elapsedRealtime ms). */
  class Frame(val bitmap: Bitmap, val atMs: Long)

  private val _latest = MutableStateFlow<Frame?>(null)
  val latest: StateFlow<Frame?> = _latest.asStateFlow()

  /** At most this many conversions a second. Volatile: set from collectors' threads. */
  @Volatile var maxFps: Float = 2f

  /** Frames decoded and frames converted, for the cost measurement in notes/tools-layer.md. */
  @Volatile var decodedCount = 0
    private set
  @Volatile var convertedCount = 0
    private set
  /** Total time spent converting YUV to ARGB, ms. */
  @Volatile var convertMs = 0L
    private set

  private val decoder = HevcDecoder(preferHardware = true, onImage = ::onImage)
  private var nextDueMs = 0L
  private var lastKeyMs = 0L
  /** Smoothed time between keyframes, ms; 0 until two have been seen. */
  @Volatile var keyIntervalMs = 0L
    private set
  /** Decoding keyframes only (see the header). */
  @Volatile var keyframesOnly = false
    private set
  // Reused between conversions (only the decoder's thread touches these).
  private var argb = IntArray(0)
  private var yBytes = ByteArray(0)
  private var uBytes = ByteArray(0)
  private var vBytes = ByteArray(0)

  @Volatile private var running = true

  /** Starts decoding. [parameterSets] is the stream's VPS/SPS/PPS, if known. */
  fun start(parameterSets: ByteArray?) {
    decoder.start(width, height, null)
    parameterSets?.let { decoder.decodeFrame(it, 0) }
  }

  /** One compressed HEVC frame from the stream, in order. Called on the stream's frame thread. */
  fun feed(data: ByteArray, presentationTimeUs: Long) {
    if (!running) return
    val kind = HevcNal.kind(data)
    if (kind == HevcNal.Kind.KEY) {
      val now = SystemClock.elapsedRealtime()
      if (lastKeyMs > 0) {
        val gap = now - lastKeyMs
        keyIntervalMs = if (keyIntervalMs == 0L) gap else (keyIntervalMs * 7 + gap * 3) / 10
      }
      lastKeyMs = now
      val wantedGap = 1000f / maxFps.coerceIn(0.1f, 30f)
      keyframesOnly = keyIntervalMs in 1..(wantedGap * 1.15f).toLong()
    }
    if (kind != HevcNal.Kind.OTHER || !keyframesOnly) decoder.decodeFrame(data, presentationTimeUs)
  }

  fun stop() {
    running = false
    decoder.stop()
  }

  /** On the decoder's thread, for every decoded frame. [image] is only valid during the call. */
  private fun onImage(image: Image) {
    try {
      decodedCount++
      if (!running) return
      val now = SystemClock.elapsedRealtime()
      val gap = (1000f / maxFps.coerceIn(0.1f, 30f)).toLong()
      // Paced on average, so frames arriving every 400 ms still give 2 a second when 2 are wanted.
      if (now < nextDueMs) return
      nextDueMs = maxOf(nextDueMs + gap, now - gap / 2)
      val started = SystemClock.elapsedRealtime()
      val bitmap = toBitmap(image)
      convertMs += SystemClock.elapsedRealtime() - started
      convertedCount++
      _latest.value = Frame(bitmap, now)
    } catch (e: Exception) {
      Log.w(TAG, "frame conversion failed", e)
    }
  }

  /** YUV_420_888 (any strides) to an ARGB_8888 Bitmap the size of the image's crop. BT.601. */
  private fun toBitmap(image: Image): Bitmap {
    val crop = image.cropRect
    val w = crop.width()
    val h = crop.height()
    val (yp, up, vp) = image.planes
    yBytes = copy(yp.buffer, yBytes)
    uBytes = copy(up.buffer, uBytes)
    vBytes = copy(vp.buffer, vBytes)
    if (argb.size != w * h) argb = IntArray(w * h)
    val yRow = yp.rowStride
    val yPix = yp.pixelStride
    val uvRow = up.rowStride
    val uvPix = up.pixelStride
    var o = 0
    for (row in 0 until h) {
      val sy = row + crop.top
      val yBase = sy * yRow
      val uvBase = (sy shr 1) * uvRow
      for (col in 0 until w) {
        val sx = col + crop.left
        val y = (yBytes[yBase + sx * yPix].toInt() and 0xff) - 16
        val uvi = uvBase + (sx shr 1) * uvPix
        val u = (uBytes[uvi].toInt() and 0xff) - 128
        val v = (vBytes[uvi].toInt() and 0xff) - 128
        val y1 = 1192 * (if (y < 0) 0 else y)
        var r = (y1 + 1634 * v) shr 10
        var g = (y1 - 833 * v - 400 * u) shr 10
        var b = (y1 + 2066 * u) shr 10
        r = if (r < 0) 0 else if (r > 255) 255 else r
        g = if (g < 0) 0 else if (g > 255) 255 else g
        b = if (b < 0) 0 else if (b > 255) 255 else b
        argb[o++] = (0xff shl 24) or (r shl 16) or (g shl 8) or b
      }
    }
    return Bitmap.createBitmap(argb, w, h, Bitmap.Config.ARGB_8888)
  }

  private fun copy(buffer: java.nio.ByteBuffer, into: ByteArray): ByteArray {
    val n = buffer.remaining()
    val out = if (into.size >= n) into else ByteArray(n)
    buffer.get(out, 0, n)
    return out
  }

  private companion object {
    const val TAG = "FrameGrabber"
  }
}

/** Just enough HEVC NAL parsing to tell parameter sets and keyframes from other frames. */
internal object HevcNal {
  enum class Kind {
    /** VPS/SPS/PPS only. */
    CONFIG,
    /** Contains an IRAP picture (IDR, CRA, BLA): decodable on its own. */
    KEY,
    OTHER,
  }

  fun kind(data: ByteArray): Kind {
    var sawConfig = false
    var i = 0
    while (i + 3 < data.size) {
      // Start code 00 00 01 (a 4-byte 00 00 00 01 ends in the same three bytes).
      if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
        val type = (data[i + 3].toInt() and 0x7E) shr 1
        if (type in 16..21) return Kind.KEY
        if (type in 32..34) sawConfig = true
        i += 3
      } else {
        i++
      }
    }
    return if (sawConfig) Kind.CONFIG else Kind.OTHER
  }
}
