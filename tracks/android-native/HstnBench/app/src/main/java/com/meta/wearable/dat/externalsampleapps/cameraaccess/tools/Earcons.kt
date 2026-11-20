// Earcons - short tones for tool events (shared by every tool; started in the book reader)
//
// ROADMAP ground rule: every action plays an earcon within 100 ms, and silence never reports a
// failure. ToneGenerator plays immediately with no asset loading. It's on the accessibility stream
// to sit with the TTS (USAGE_ASSISTANCE_ACCESSIBILITY). Placeholder tones; a designed earcon set is
// part of ROADMAP step 4.
//
// Make it your own (sounds and ears settings, via [configure]):
//   - off: nothing plays (every problem is still spoken, so silence still never reports a failure);
//   - volume: the ToneGenerator is rebuilt at the new level;
//   - panned (balance, or earcons in one ear): ToneGenerator can't pan, so the same earcon is played
//     from PCM (AudioMath.EARCON_NOTES) on a small static stereo AudioTrack, or on the audio bus;
//   - speak instead: [speakInstead] says the earcon's meaning ("found", "problem") while learning.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.AudioMath

enum class Earcon(val tone: Int, val durationMs: Int) {
  /** A control was pressed. */
  ACK(ToneGenerator.TONE_PROP_BEEP, 60),
  /** Motion that looks like a page turn started. */
  TURN_DETECTED(ToneGenerator.TONE_PROP_BEEP2, 120),
  /** A page was captured and recognised; reading follows. */
  PAGE_CAPTURED(ToneGenerator.TONE_PROP_ACK, 150),
  /** The capture is the page already read. */
  SAME_PAGE(ToneGenerator.TONE_PROP_NACK, 200),
  /** Finished reading everything captured; turn the page. */
  PAGE_DONE(ToneGenerator.TONE_PROP_PROMPT, 150),
  /** Couldn't capture or read. A spoken explanation follows. */
  ERROR(ToneGenerator.TONE_SUP_ERROR, 250),
  /** Soft tick every few seconds while capturing or recognising, so waiting is never silence. */
  WORKING(ToneGenerator.TONE_PROP_BEEP, 30),

  // Generic names for the other tools. Same tone set; pick by meaning.
  /** Connected / ready for the user (the glasses camera came up). */
  READY(ToneGenerator.TONE_PROP_PROMPT, 150),
  /** Something the user asked for was found or recognised (a watched-for word, a barcode). */
  FOUND(ToneGenerator.TONE_PROP_ACK, 150),
  /** Moved to another tool. */
  SWITCH(ToneGenerator.TONE_PROP_BEEP2, 120),
}

class Earcons {

  /** How earcons should play now (from the sounds and ears settings). */
  data class Config(
      val enabled: Boolean = true,
      val volume: Float = 0.8f,
      val gains: AudioMath.Gains = AudioMath.CENTRE,
      val speakInstead: Boolean = false,
      val bus: AudioBus? = null,
  )

  private var config = Config()
  private var generator: ToneGenerator? = makeGenerator(config.volume)
  private val pcm = PcmPlayer()

  /** Set by ToolHub: says an earcon's meaning instead of playing it. Returns false if it can't. */
  var speakInstead: ((Earcon, String) -> Boolean)? = null

  fun configure(next: Config) {
    val old = config
    config = next
    if (next.volume != old.volume) {
      generator?.release()
      generator = makeGenerator(next.volume)
    }
  }

  fun play(earcon: Earcon) {
    val c = config
    Log.i(TAG, "earcon=${earcon.name.lowercase()}" + if (!c.enabled) " (off)" else "")
    if (!c.enabled) return
    if (c.speakInstead) {
      val word = AudioMath.EARCON_WORDS[earcon.name]
      if (word != null && speakInstead?.invoke(earcon, word) == true) return
    }
    val notes = AudioMath.EARCON_NOTES[earcon.name]
    when {
      c.bus != null && notes != null -> c.bus.play(AudioMath.tones(notes, c.bus.sampleRate), c.gains, c.volume)
      c.gains != AudioMath.CENTRE && notes != null -> pcm.play(AudioMath.tones(notes, PcmPlayer.RATE), c.gains, c.volume)
      else -> generator?.startTone(earcon.tone, earcon.durationMs)
    }
  }

  fun release() {
    generator?.release()
    pcm.release()
  }

  private fun makeGenerator(volume: Float): ToneGenerator? =
      try {
        ToneGenerator(AudioManager.STREAM_ACCESSIBILITY, (volume * 100).toInt().coerceIn(0, 100))
      } catch (e: RuntimeException) {
        // No audio device (e.g. a headless emulator); earcons are skipped, speech still reports.
        Log.w(TAG, "ToneGenerator unavailable", e)
        null
      }

  companion object {
    const val TAG = "BookReader"
  }
}
