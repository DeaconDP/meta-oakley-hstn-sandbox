// ProbeTone - the light probe's continuous tone, gliding smoothly from pitch to pitch
//
// hub.tones (ToneSynth) plays separate short beeps; the probe needs one unbroken tone whose pitch
// slides as the user turns their head, without clicks between updates. This keeps a streaming
// AudioTrack on the accessibility stream (USAGE_ASSISTANCE_ACCESSIBILITY, like speech and earcons)
// and a writer thread that renders 20 ms of sine at a time, with a phase that carries over and the
// frequency and volume gliding towards their targets (~60 ms time constant). [stop] silences it at
// once: pause + flush drop whatever is buffered, so the tone ends within a few milliseconds of
// "quiet", closing, switching tools or the glasses coming off. Never throws.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

class ProbeTone {

  @Volatile private var targetHz = 440f
  @Volatile private var targetVolume = 0f
  @Volatile private var running = false
  private var track: AudioTrack? = null
  private var thread: Thread? = null

  /** True while the tone is playing (or starting). */
  val isPlaying: Boolean
    get() = running

  /** Starts (or retargets) the tone at [hz] and [volume] 0..1. */
  @Synchronized
  fun play(hz: Float, volume: Float = DEFAULT_VOLUME) {
    targetHz = hz
    targetVolume = volume.coerceIn(0f, 1f)
    if (running) return
    try {
      val min = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
      val t =
          AudioTrack.Builder()
              .setAudioAttributes(
                  AudioAttributes.Builder()
                      .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                      .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                      .build(),
              )
              .setAudioFormat(
                  AudioFormat.Builder()
                      .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                      .setSampleRate(SAMPLE_RATE)
                      .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                      .build(),
              )
              .setTransferMode(AudioTrack.MODE_STREAM)
              .setBufferSizeInBytes(maxOf(min, CHUNK * 2 * 3))
              .build()
      track = t
      running = true
      t.play()
      thread = Thread({ render(t) }, "ProbeTone").apply {
        priority = Thread.MAX_PRIORITY
        start()
      }
    } catch (e: Exception) {
      Log.w(TAG, "tone failed to start", e)
      running = false
      track?.release()
      track = null
    }
  }

  /** Glides to [hz] (if playing). */
  fun setFrequency(hz: Float) {
    targetHz = hz
  }

  fun setVolume(volume: Float) {
    targetVolume = volume.coerceIn(0f, 1f)
  }

  /** Silences the tone now and frees the audio track. */
  @Synchronized
  fun stop() {
    if (!running && track == null) return
    running = false
    track?.let {
      runCatching {
        it.pause()
        it.flush()
        it.stop()
      }
    }
    thread?.join(300)
    thread = null
    track?.release()
    track = null
  }

  private fun render(t: AudioTrack) {
    val buf = ShortArray(CHUNK)
    var phase = 0.0
    var hz = targetHz.toDouble()
    var vol = 0.0
    val k = 1 - exp(-1.0 / (GLIDE_S * SAMPLE_RATE))
    try {
      while (running) {
        val th = targetHz.toDouble()
        val tv = targetVolume.toDouble()
        for (i in 0 until CHUNK) {
          hz += (th - hz) * k
          vol += (tv - vol) * k
          phase += 2 * PI * hz / SAMPLE_RATE
          if (phase > 2 * PI) phase -= 2 * PI
          buf[i] = (sin(phase) * vol * Short.MAX_VALUE).toInt().toShort()
        }
        if (!running) break
        if (t.write(buf, 0, CHUNK, AudioTrack.WRITE_BLOCKING) < 0) break
      }
    } catch (e: Exception) {
      Log.w(TAG, "tone render stopped", e)
    }
  }

  companion object {
    private const val TAG = "ProbeTone"
    const val SAMPLE_RATE = 22_050
    private const val CHUNK = SAMPLE_RATE / 50
    private const val GLIDE_S = 0.06
    const val DEFAULT_VOLUME = 0.35f
  }
}
