// ToolSpeaker - chunked TTS for every tool (it started as the book reader's BookSpeaker)
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
//
// Make it your own (notes/customisation-android.md): [configure] applies the speech settings:
// language (the device's, falling back to US English), the chosen voice, pitch, a pause after each
// sentence of tool content, the pan (balance and which ear: KEY_PARAM_PAN), and clear speech
// (DynamicsProcessing on our own audio session, KEY_PARAM_SESSION_ID). With an [AudioBus] the
// engine synthesises to PCM (synthesizeToFile + onAudioAvailable) and the bus plays it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bench.BenchClock
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.AudioMath
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.VoiceChoice
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class ToolSpeaker(context: Context, private val listener: Listener) {

  interface Listener {
    /** [tag] is what the caller passed to [speak]. Called on the main thread. */
    fun onSpoken(tag: String)

    fun onEngineState(available: Boolean)

    /** [text] has started playing (feeds the voice echo guard). Main thread. */
    fun onUtteranceStarted(text: String) = Unit
  }

  /** The speech settings, as ToolHub works them out from the settings store. */
  data class Config(
      val pitch: Float = 1f,
      /** Silence after each piece of tool content (not after short notes). */
      val pauseMs: Int = 0,
      val voice: String? = null,
      /** BCP-47, null = the device language. */
      val locale: String? = null,
      /** -1..1 (balance and which ear). */
      val pan: Float = 0f,
      val clearSpeech: Boolean = false,
      /** Speech through the experimental audio bus instead of the engine's own output. */
      val bus: AudioBus? = null,
  )

  private val app = context.applicationContext
  private val main = Handler(Looper.getMainLooper())
  private val generation = AtomicInteger(0)
  private val sequence = AtomicInteger(0)
  private val texts = ConcurrentHashMap<String, String>()
  private val streams = ConcurrentHashMap<String, AudioBus.SpeechStream>()
  private val streamRates = ConcurrentHashMap<String, Int>()

  // Main thread only.
  private var state = State.INITIALIZING
  private val pending = mutableListOf<Pair<String, String>>()
  private var rate = 1f
  private var config = Config()
  private var appliedLocale: Locale? = null
  private var appliedVoice: String? = null
  private val sessionId: Int = (app.getSystemService(Context.AUDIO_SERVICE) as AudioManager).generateAudioSessionId()
  private var clearEffect: DynamicsProcessing? = null

  private enum class State {
    INITIALIZING,
    READY,
    FAILED,
  }

  private val tts: TextToSpeech =
      TextToSpeech(app) { status -> main.post { onInit(status) } }

  private fun onInit(status: Int) {
    if (status != TextToSpeech.SUCCESS) {
      BenchClock.note("book_tts_init=failed status=$status")
      state = State.FAILED
      listener.onEngineState(false)
      pending.toList().also { pending.clear() }.forEach { (text, tag) -> speak(text, tag) }
      return
    }
    tts.setAudioAttributes(
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build(),
    )
    state = State.READY
    applyLanguageAndVoice()
    tts.setSpeechRate(rate)
    tts.setPitch(config.pitch)
    if (config.clearSpeech && config.bus == null) clearEffect = ClearSpeechEffect.create(sessionId)?.also { it.enabled = true }
    tts.setOnUtteranceProgressListener(
        object : UtteranceProgressListener() {
          override fun onStart(utteranceId: String) {
            if (streams.containsKey(utteranceId)) return // the bus says when it's audible
            val text = texts[utteranceId] ?: return
            val gen = utteranceId.substringBefore('|').toIntOrNull() ?: return
            main.post { if (gen == generation.get()) listener.onUtteranceStarted(text) }
          }

          override fun onBeginSynthesis(utteranceId: String, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
            streamRates[utteranceId] = sampleRateInHz * 10 + channelCount.coerceIn(1, 9)
          }

          override fun onAudioAvailable(utteranceId: String, audio: ByteArray) {
            val s = streams[utteranceId] ?: return
            val packed = streamRates[utteranceId] ?: return
            val bus = config.bus ?: return
            val pcm = AudioMath.pcm16le(audio, packed % 10)
            s.write(AudioMath.resample(pcm, packed / 10, bus.sampleRate))
          }

          override fun onDone(utteranceId: String) = finished(utteranceId)

          @Deprecated("Deprecated in Java")
          override fun onError(utteranceId: String) = finished(utteranceId)

          override fun onError(utteranceId: String, errorCode: Int) = finished(utteranceId)

          // onStop (from stop()) is deliberately not treated as done.
        },
    )
    listener.onEngineState(true)
    pending.toList().also { pending.clear() }.forEach { (text, tag) -> speak(text, tag) }
  }

  private fun finished(utteranceId: String) {
    // On the bus, synthesis finishing isn't the end: the bus says when it has played out.
    streams.remove(utteranceId)?.let { s ->
      streamRates.remove(utteranceId)
      val pause = config.pauseMs
      config.bus?.let { bus -> if (pause > 0 && !utteranceId.endsWith("|aside")) s.write(ShortArray(bus.sampleRate * pause / 1000)) }
      s.end()
      return
    }
    texts.remove(utteranceId)
    // "<generation>|<sequence>|<tag>"
    val parts = utteranceId.split('|', limit = 3)
    if (parts.size < 3) return
    val gen = parts[0].toIntOrNull() ?: return
    val tag = parts[2]
    if (tag == "~pause") return // silence between sentences, not speech
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
        val gen = generation.get()
        val id = "$gen|${sequence.incrementAndGet()}|$tag"
        texts[id] = text
        val params = Bundle()
        val bus = config.bus
        if (bus != null) {
          val stream =
              bus.openSpeech(
                  AudioMath.gains(config.pan),
                  onStart = { main.post { if (gen == generation.get()) listener.onUtteranceStarted(text) } },
                  onDone = {
                    texts.remove(id)
                    main.post { if (gen == generation.get()) listener.onSpoken(tag) }
                  },
              )
          streams[id] = stream
          val file = File(app.cacheDir, "tts-bus-${sequence.get() % 2}.wav")
          if (tts.synthesizeToFile(text, params, file, id) != TextToSpeech.SUCCESS) {
            streams.remove(id)
            stream.end()
          }
          return
        }
        params.putFloat(TextToSpeech.Engine.KEY_PARAM_PAN, config.pan)
        params.putInt(TextToSpeech.Engine.KEY_PARAM_SESSION_ID, sessionId)
        tts.speak(text, TextToSpeech.QUEUE_ADD, params, id)
        if (config.pauseMs > 0 && tag != "aside") {
          tts.playSilentUtterance(config.pauseMs.toLong(), TextToSpeech.QUEUE_ADD, "$gen|${sequence.incrementAndGet()}|~pause")
        }
      }
    }
  }

  /** Cuts speech off now and drops everything queued. */
  fun stop() {
    generation.incrementAndGet()
    pending.clear()
    texts.clear()
    streams.values.forEach { it.end() }
    streams.clear()
    config.bus?.stopSpeech()
    if (state == State.READY) tts.stop()
  }

  /** 1.0 is normal. Experienced screen-reader users often listen at 2-3x. */
  fun setRate(value: Float) {
    rate = value
    if (state == State.READY) tts.setSpeechRate(value)
  }

  /** Applies the speech settings from the next utterance on. */
  fun configure(next: Config) {
    val old = config
    config = next
    if (old.bus != null && next.bus == null) old.bus.stopSpeech()
    if (state != State.READY) return
    if (next.pitch != old.pitch) tts.setPitch(next.pitch)
    if (next.locale != old.locale || next.voice != old.voice) applyLanguageAndVoice()
    if (next.clearSpeech != old.clearSpeech || clearEffect == null && next.clearSpeech) {
      clearEffect?.release()
      clearEffect = if (next.clearSpeech && next.bus == null) ClearSpeechEffect.create(sessionId)?.also { it.enabled = true } else null
    }
  }

  /** The speech language: the setting, else the device's, else US English. */
  private fun language(): Locale {
    val wanted = config.locale?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()
    return if (tts.isLanguageAvailable(wanted) >= TextToSpeech.LANG_AVAILABLE) wanted else Locale.US
  }

  private fun applyLanguageAndVoice() {
    val lang = language()
    if (lang != appliedLocale) {
      tts.language = lang
      appliedLocale = lang
    }
    val wanted = config.voice
    if (wanted != appliedVoice) {
      val v = if (wanted == null) tts.defaultVoice else tts.voices?.firstOrNull { it.name == wanted }
      if (v != null) runCatching { tts.voice = v }
      if (wanted == null) runCatching { tts.language = lang }
      appliedVoice = wanted
    }
  }

  /** Installed voices for the speech language, offline ones and higher quality first. */
  fun voices(): List<VoiceChoice> {
    if (state != State.READY) return emptyList()
    val lang = language()
    val all: Set<Voice> = runCatching { tts.voices }.getOrNull() ?: return emptyList()
    val sorted =
        all.filter { it.locale.language == lang.language && !it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }
            .sortedWith(
                compareBy<Voice>({ it.isNetworkConnectionRequired }, { it.locale.country != lang.country }, { -it.quality }, { it.name }),
            )
    return sorted.mapIndexed { i, v ->
      val where = v.locale.getDisplayCountry(Locale.UK).ifEmpty { v.locale.getDisplayLanguage(Locale.UK) }
      val online = if (v.isNetworkConnectionRequired) ", needs the internet" else ""
      VoiceChoice(v.name, "$where voice ${i + 1}$online")
    }
  }

  fun languageName(): String = (appliedLocale ?: Locale.getDefault()).getDisplayName(Locale.UK)

  fun shutdown() {
    stop()
    clearEffect?.release()
    tts.shutdown()
  }

  private companion object {
    const val TAG = "ToolSpeaker"
  }
}
