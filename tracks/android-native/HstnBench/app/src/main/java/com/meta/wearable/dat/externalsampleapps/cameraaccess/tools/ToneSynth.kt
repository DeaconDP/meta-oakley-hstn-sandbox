// ToneSynth - a sine tone at any pitch, for tools whose sound carries information
//
// Earcons are fixed ToneGenerator beeps. Some tools need the pitch itself to mean something: the
// light probe's tone rises with brightness, and a direction cue could follow where text is. This plays
// a short sine tone at [play]'s frequency on the accessibility stream (USAGE_ASSISTANCE_ACCESSIBILITY,
// like the speech), with a 5 ms fade in and out so it doesn't click. Each call replaces the tone
// still playing. Cheap: one small static AudioTrack per tone, released when the next one starts.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

class ToneSynth {

  private var track: AudioTrack? = null

  /** Plays [frequencyHz] for [durationMs] at [volume] (0..1). Thread-safe; never throws. */
  @Synchronized
  fun play(frequencyHz: Float, durationMs: Int = 120, volume: Float = 0.6f) {
    try {
      stopLocked()
      val samples = (SAMPLE_RATE * durationMs / 1000).coerceAtLeast(64)
      val fade = min(SAMPLE_RATE * 5 / 1000, samples / 2)
      val pcm = ShortArray(samples) { i ->
        val envelope = when {
          i < fade -> i / fade.toFloat()
          i > samples - fade -> (samples - i) / fade.toFloat()
          else -> 1f
        }
        (sin(2 * PI * frequencyHz * i / SAMPLE_RATE) * envelope * volume.coerceIn(0f, 1f) * Short.MAX_VALUE).toInt().toShort()
      }
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
              .setTransferMode(AudioTrack.MODE_STATIC)
              .setBufferSizeInBytes(samples * 2)
              .build()
      t.write(pcm, 0, pcm.size)
      t.play()
      track = t
    } catch (e: Exception) {
      Log.w(TAG, "tone failed", e)
    }
  }

  @Synchronized
  fun release() = stopLocked()

  private fun stopLocked() {
    track?.let {
      runCatching { it.stop() }
      it.release()
    }
    track = null
  }

  private companion object {
    const val TAG = "ToneSynth"
    const val SAMPLE_RATE = 22_050
  }
}
