// Earcons - short tones for tool events (shared by every tool; started in the book reader)
//
// ROADMAP ground rule: every action plays an earcon within 100 ms, and silence never reports a
// failure. ToneGenerator plays immediately with no asset loading. It's on the accessibility stream
// to sit with the TTS (USAGE_ASSISTANCE_ACCESSIBILITY). Placeholder tones; a designed earcon set is
// part of ROADMAP step 4.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Log

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
  private val generator: ToneGenerator? =
      try {
        ToneGenerator(AudioManager.STREAM_ACCESSIBILITY, 80)
      } catch (e: RuntimeException) {
        // No audio device (e.g. a headless emulator); earcons are skipped, speech still reports.
        Log.w(TAG, "ToneGenerator unavailable", e)
        null
      }

  fun play(earcon: Earcon) {
    Log.i(TAG, "earcon=${earcon.name.lowercase()}")
    generator?.startTone(earcon.tone, earcon.durationMs)
  }

  fun release() {
    generator?.release()
  }

  companion object {
    const val TAG = "BookReader"
  }
}
