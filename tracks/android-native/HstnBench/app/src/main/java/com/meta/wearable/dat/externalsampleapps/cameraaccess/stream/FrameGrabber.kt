// FrameGrabber - decoded stream frames as Bitmaps, for tools that look continuously
//
// The preview decoder (HevcDecoder) renders straight to the screen's Surface, so the app never sees
// the pixels. Tools like "watch for text" and "light and colour" need them several times a second,
// and the in-stream photo (capturePhoto, ~1 s, interrupts glasses speech) is too slow for that.
// This runs a second HevcDecoder into an ImageReader (YUV_420_888). Every frame has to be decoded
// (HEVC P-frames depend on the ones before), but only [maxFps] frames a second are converted to
// ARGB; the rest are released straight away. CameraViewModel only runs it while some tool is
// collecting frames, and stops it when the last one stops. The decoder starts on the next keyframe
// (twice a second on the mock's plant clip), primed with the stream's cached parameter sets.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.stream

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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

  private val thread = HandlerThread("FrameGrabber").apply { start() }
  private val handler = Handler(thread.looper)
  private val reader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 3)
  private val decoder = HevcDecoder()
  private var lastConvertMs = 0L
  // Reused between conversions (only the grabber thread touches these).
  private var argb = IntArray(0)
  private var yBytes = ByteArray(0)
  private var uBytes = ByteArray(0)
  private var vBytes = ByteArray(0)

  @Volatile private var running = true

  init {
    reader.setOnImageAvailableListener({ r -> onImage(r) }, handler)
  }

  /** Starts decoding into the reader. [parameterSets] is the stream's VPS/SPS/PPS, if known. */
  fun start(parameterSets: ByteArray?) {
    decoder.start(width, height, reader.surface)
    parameterSets?.let { decoder.decodeFrame(it, 0) }
  }

  /** One compressed HEVC frame from the stream, in order. */
  fun feed(data: ByteArray, presentationTimeUs: Long) {
    if (running) decoder.decodeFrame(data, presentationTimeUs)
  }

  fun stop() {
    running = false
    decoder.stop()
    handler.post {
      reader.close()
      thread.quitSafely()
    }
  }

  private fun onImage(r: ImageReader) {
    val image = try {
      r.acquireLatestImage()
    } catch (e: IllegalStateException) {
      null
    } ?: return
    try {
      decodedCount++
      if (!running) return
      val now = SystemClock.elapsedRealtime()
      val gap = (1000f / maxFps.coerceIn(0.1f, 30f)).toLong()
      if (now - lastConvertMs < gap) return
      lastConvertMs = now
      val started = SystemClock.elapsedRealtime()
      val bitmap = toBitmap(image)
      convertMs += SystemClock.elapsedRealtime() - started
      convertedCount++
      _latest.value = Frame(bitmap, now)
    } catch (e: Exception) {
      Log.w(TAG, "frame conversion failed", e)
    } finally {
      image.close()
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
