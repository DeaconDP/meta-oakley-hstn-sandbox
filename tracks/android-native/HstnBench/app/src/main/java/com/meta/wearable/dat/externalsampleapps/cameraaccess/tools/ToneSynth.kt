// ToneSynth - a sine tone at any pitch, for tools whose sound carries information
//
// Earcons are fixed ToneGenerator beeps. Some tools need the pitch itself to mean something: the
// light probe's tone rises with brightness, and a direction cue could follow where text is. This plays
// a short sine tone at [play]'s frequency on the accessibility stream (USAGE_ASSISTANCE_ACCESSIBILITY,
// like the speech), with a 5 ms fade in and out so it doesn't click. Each call replaces the tone
// still playing. Cheap: one small static AudioTrack per tone, released when the next one starts.
//
// Make it your own: tones follow the earcons' ear and the balance ([gains]); [cue] plays a
// direction cue on its side, or, for a mono listener, as a pitch (low left, high right). With the
// audio bus on, tones are mixed there instead.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.AudioMath
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Ears

class ToneSynth {

  private val player = PcmPlayer()

  /** Where tones sit (earcon ear + balance), set by ToolHub. */
  @Volatile var gains: AudioMath.Gains = AudioMath.CENTRE

  @Volatile var ears: Ears = Ears()

  @Volatile var bus: AudioBus? = null

  /** Plays [frequencyHz] for [durationMs] at [volume] (0..1). Thread-safe; never throws. */
  fun play(frequencyHz: Float, durationMs: Int = 120, volume: Float = 0.6f) = playAt(frequencyHz, durationMs, volume, gains)

  /**
   * A direction cue: [side] -1 left .. 1 right. In stereo it plays on that side (after balance and
   * the cue ear setting); in mono it's a pitch: 440 Hz left, 660 ahead, 880 right.
   */
  fun cue(side: Float, durationMs: Int = 90, volume: Float = 0.5f) {
    val e = ears
    val hz = if (e.mono) AudioMath.cueFrequency(side) else 660f
    playAt(hz, durationMs, volume, AudioMath.gains(AudioMath.Kind.CUE, e, side))
  }

  private fun playAt(frequencyHz: Float, durationMs: Int, volume: Float, g: AudioMath.Gains) {
    val b = bus
    if (b != null) {
      b.play(AudioMath.tones(listOf(frequencyHz to durationMs), b.sampleRate, 1f), g, volume.coerceIn(0f, 1f), kind = "tone")
      return
    }
    player.play(AudioMath.tones(listOf(frequencyHz to durationMs), PcmPlayer.RATE, 1f), g, volume.coerceIn(0f, 1f))
  }

  fun release() = player.release()
}

/** Plays one short mono sound at a time, panned, on a static stereo AudioTrack. Never throws. */
class PcmPlayer {
  private var track: AudioTrack? = null

  @Synchronized
  fun play(mono: ShortArray, gains: AudioMath.Gains, volume: Float) {
    try {
      stopLocked()
      val pcm = AudioMath.toStereo(mono, gains, volume)
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
                      .setSampleRate(RATE)
                      .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                      .build(),
              )
              .setTransferMode(AudioTrack.MODE_STATIC)
              .setBufferSizeInBytes(pcm.size * 2)
              .build()
      t.write(pcm, 0, pcm.size)
      t.play()
      track = t
    } catch (e: Exception) {
      Log.w("PcmPlayer", "sound failed", e)
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

  companion object {
    const val RATE = 22_050
  }
}
