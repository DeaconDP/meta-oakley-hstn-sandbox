// MockVideo - builds a camera feed for the mock glasses from rendered Bitmaps, on the phone
//
// MockCameraKit.setCameraFeed(uri) takes an MP4. The mock reads it with MediaExtractor and sends
// the compressed samples to the app as they are (it checks for video/hevc or video/avc, but the
// app's decoders are HEVC-only), so the feed has to be HEVC in an MP4, portrait like the glasses
// (plant.mp4 is HEVC Main 540x960, 30 fps, a keyframe every 12 frames). The stream frames the app
// receives are the video's own size. Samples over 10 MB are skipped.
//
// This encodes such a file from a list of Bitmaps with the phone's HEVC encoder (MediaCodec +
// MediaMuxer), so a tool's instrumented test needs no prebuilt assets: render the scenes you want
// the glasses to see, call [encode], then setCameraFeed. Each frame is held for [holdMs]; the video
// loops on the mock. Width and height should be multiples of 16 (480x864 is the default, 9:16).
// On a Mac, ffmpeg makes the same kind of file from PNGs (see notes/tools-layer.md).

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

object MockVideo {

  const val WIDTH = 480
  const val HEIGHT = 864

  /**
   * Writes an HEVC MP4 to [out] showing each of [frames] (scaled to [width]x[height]) for [holdMs],
   * at [fps]. Returns [out].
   */
  fun encode(
      frames: List<Bitmap>,
      out: File,
      holdMs: Long = 1_000L,
      fps: Int = 15,
      width: Int = WIDTH,
      height: Int = HEIGHT,
  ): File {
    require(frames.isNotEmpty())
    val format =
        MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
          setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
          setInteger(MediaFormat.KEY_BIT_RATE, 1_500_000)
          setInteger(MediaFormat.KEY_FRAME_RATE, fps)
          setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 0.5f)
        }
    val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    codec.start()
    out.delete()
    val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    var track = -1
    var muxing = false
    val info = MediaCodec.BufferInfo()
    val perFrame = (holdMs * fps / 1000).coerceAtLeast(1)
    val scaled = frames.map { Bitmap.createScaledBitmap(it, width, height, true) }
    val total = scaled.size * perFrame
    var queued = 0L
    var inputDone = false
    var outputDone = false
    try {
      while (!outputDone) {
        if (!inputDone) {
          val inIndex = codec.dequeueInputBuffer(10_000)
          if (inIndex >= 0) {
            if (queued == total) {
              codec.queueInputBuffer(inIndex, 0, 0, ptsUs(queued, fps), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              val image = codec.getInputImage(inIndex)!!
              writeYuv(scaled[(queued / perFrame).toInt()], image)
              codec.queueInputBuffer(inIndex, 0, width * height * 3 / 2, ptsUs(queued, fps), 0)
              queued++
            }
          }
        }
        val outIndex = codec.dequeueOutputBuffer(info, 10_000)
        when {
          outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            track = muxer.addTrack(codec.outputFormat)
            muxer.start()
            muxing = true
          }
          outIndex >= 0 -> {
            val buffer = codec.getOutputBuffer(outIndex)!!
            val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
            if (muxing && !isConfig && info.size > 0) {
              buffer.position(info.offset)
              buffer.limit(info.offset + info.size)
              muxer.writeSampleData(track, buffer, info)
            }
            codec.releaseOutputBuffer(outIndex, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
          }
        }
      }
    } finally {
      codec.stop()
      codec.release()
      if (muxing) muxer.stop()
      muxer.release()
    }
    return out
  }

  private fun ptsUs(frame: Long, fps: Int): Long = frame * 1_000_000L / fps

  /** ARGB -> YUV 4:2:0 (BT.601, limited range) into the codec's input image, any layout. */
  private fun writeYuv(bitmap: Bitmap, image: android.media.Image) {
    val w = image.width
    val h = image.height
    val argb = IntArray(w * h)
    bitmap.getPixels(argb, 0, w, 0, 0, w, h)
    val (yp, up, vp) = image.planes
    for (row in 0 until h) {
      for (col in 0 until w) {
        val c = argb[row * w + col]
        val r = (c shr 16) and 0xff
        val g = (c shr 8) and 0xff
        val b = c and 0xff
        val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
        yp.buffer.put(row * yp.rowStride + col * yp.pixelStride, y.toByte())
        if (row % 2 == 0 && col % 2 == 0) {
          val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
          val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
          val uvRow = row / 2
          val uvCol = col / 2
          up.buffer.put(uvRow * up.rowStride + uvCol * up.pixelStride, u.toByte())
          vp.buffer.put(uvRow * vp.rowStride + uvCol * vp.pixelStride, v.toByte())
        }
      }
    }
  }
}
