// BookSpeaker - chunked TTS for the book reader
//
// Same idea as bench/TtsReply (platform TextToSpeech, route follows the system, so the glasses'
// A2DP speakers when connected), but built for long reading: one chunk per utterance so pause,
// "back a sentence" and rate changes take effect at the next chunk, and accessibility audio
// attributes (USAGE_ASSISTANCE_ACCESSIBILITY) so it coexists with TalkBack as the ROADMAP asks.
// TtsReply stays as is: it's the step-2 benchmark's timing probe and uses media attributes.
//
// Every utterance carries a generation number. stop() bumps it, so the onDone of an utterance cut
// off by stop() can't advance the reader. If the engine fails to initialise, utterances "finish"
// immediately so the reading loop (and the on-screen text) still moves; the failure is reported.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

import android.content.Context
import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bench.BenchClock
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

class BookSpeaker(context: Context, private val listener: Listener) {

  interface Listener {
    /** [tag] is what the caller passed to [speak]. Called on the main thread. */
    fun onSpoken(tag: String)

    fun onEngineState(available: Boolean)

    /** [text] has started playing (feeds the voice echo guard). Main thread. */
    fun onUtteranceStarted(text: String) = Unit
  }

  private val main = Handler(Looper.getMainLooper())
  private val generation = AtomicInteger(0)
  private val sequence = AtomicInteger(0)
  private val texts = java.util.concurrent.ConcurrentHashMap<String, String>()

  // Main thread only.
  private var state = State.INITIALIZING
  private val pending = mutableListOf<Pair<String, String>>()
  private var rate = 1f

  private enum class State {
    INITIALIZING,
    READY,
    FAILED,
  }

  private val tts: TextToSpeech =
      TextToSpeech(context.applicationContext) { status -> main.post { onInit(status) } }

  private fun onInit(status: Int) {
    if (status != TextToSpeech.SUCCESS) {
      BenchClock.note("book_tts_init=failed status=$status")
      state = State.FAILED
      listener.onEngineState(false)
      pending.toList().also { pending.clear() }.forEach { (text, tag) -> speak(text, tag) }
      return
    }
    tts.language = Locale.US
    tts.setAudioAttributes(
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build(),
    )
    tts.setSpeechRate(rate)
    tts.setOnUtteranceProgressListener(
        object : UtteranceProgressListener() {
          override fun onStart(utteranceId: String) {
            val text = texts[utteranceId] ?: return
            val gen = utteranceId.substringBefore('|').toIntOrNull() ?: return
            main.post { if (gen == generation.get()) listener.onUtteranceStarted(text) }
          }

          override fun onDone(utteranceId: String) = finished(utteranceId)

          @Deprecated("Deprecated in Java")
          override fun onError(utteranceId: String) = finished(utteranceId)

          override fun onError(utteranceId: String, errorCode: Int) = finished(utteranceId)

          // onStop (from stop()) is deliberately not treated as done.
        },
    )
    state = State.READY
    listener.onEngineState(true)
    pending.toList().also { pending.clear() }.forEach { (text, tag) -> speak(text, tag) }
  }

  private fun finished(utteranceId: String) {
    texts.remove(utteranceId)
    // "<generation>|<sequence>|<tag>"
    val parts = utteranceId.split('|', limit = 3)
    if (parts.size < 3) return
    val gen = parts[0].toIntOrNull() ?: return
    val tag = parts[2]
    main.post { if (gen == generation.get()) listener.onSpoken(tag) }
  }

  /** Queues [text]; [Listener.onSpoken] fires with [tag] when it finishes (not when stopped). */
  fun speak(text: String, tag: String) {
    when (state) {
      State.INITIALIZING -> pending += text to tag
      State.FAILED -> {
        val gen = generation.get()
        main.postDelayed({ if (gen == generation.get()) listener.onSpoken(tag) }, 30)
      }
      State.READY -> {
        val id = "${generation.get()}|${sequence.incrementAndGet()}|$tag"
        texts[id] = text
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, id)
      }
    }
  }

  /** Cuts speech off now and drops everything queued. */
  fun stop() {
    generation.incrementAndGet()
    pending.clear()
    texts.clear()
    if (state == State.READY) tts.stop()
  }

  /** 1.0 is normal. Experienced screen-reader users often listen at 2-3x. */
  fun setRate(value: Float) {
    rate = value
    if (state == State.READY) tts.setSpeechRate(value)
  }

  fun shutdown() {
    stop()
    tts.shutdown()
  }
}
