// VoiceInput - hearing the reader's user, hands-free
//
// Two sources, one shape (a flow of transcripts):
//
//   GlassesSpeechInput  DAT on-glasses speech recognition (mwdat-speech, Experimental in DAT 1.0).
//                       Recognition runs on the glasses and only text crosses the link, so glasses
//                       audio stays on A2DP stereo for the reading voice. Needs the DAT MICROPHONE
//                       permission, granted once in the Meta AI app.
//   PhoneSpeechInput    Android's on-device SpeechRecognizer (API 31+) on the phone's own mic.
//                       Shippable today and offline. It deliberately doesn't open Bluetooth SCO: the
//                       hands-free mic would drop all glasses audio to mono call quality for a whole
//                       chapter. The phone has to be within earshot (on the table, in a pocket).
//
// VoiceControl prefers the glasses and falls back to the phone if speech won't attach, isn't
// permitted, or the glasses report no recogniser. Understanding is on-device either way
// (book/VoiceCommands.kt); nothing is sent to a server by this app.
//
// A photo capture puts the glasses' recogniser down (seen in Meta's BirdSpotter sample), and the
// reader captures a photo every page, so GlassesSpeechInput restarts it whenever it stops on its own.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.speech.Speech
import com.meta.wearable.dat.speech.addSpeech
import com.meta.wearable.dat.speech.removeSpeech
import com.meta.wearable.dat.speech.types.SpeechError
import com.meta.wearable.dat.speech.types.SpeechState
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Something the user said. [isFinal] = the utterance is over; partials come first. */
data class Utterance(val text: String, val isFinal: Boolean, val confidence: Float? = null)

enum class VoiceState {
  OFF,
  STARTING,
  LISTENING,
  /** This source can't work here (no recogniser, refused to attach, no permission). */
  UNAVAILABLE,
}

interface VoiceInput {
  val utterances: SharedFlow<Utterance>
  val state: StateFlow<VoiceState>

  fun start()

  fun stop()
}

// MARK: - Glasses

class GlassesSpeechInput(
    private val session: DeviceSession,
    private val scope: CoroutineScope,
) : VoiceInput {

  private val _utterances = MutableSharedFlow<Utterance>(extraBufferCapacity = 16)
  override val utterances: SharedFlow<Utterance> = _utterances.asSharedFlow()
  private val _state = MutableStateFlow(VoiceState.OFF)
  override val state: StateFlow<VoiceState> = _state.asStateFlow()

  private var speech: Speech? = null
  private val jobs = mutableListOf<Job>()
  private var revive: Job? = null
  private var hasStarted = false
  private var stopping = false

  override fun start() {
    if (speech != null) return
    stopping = false
    _state.value = VoiceState.STARTING
    session
        .addSpeech()
        .onSuccess { added ->
          speech = added
          jobs +=
              scope.launch {
                added.transcriptions.collect { result ->
                  val heard = result ?: return@collect
                  if (heard.text.isBlank()) return@collect
                  _utterances.tryEmit(
                      Utterance(heard.text, heard.isFinal, heard.confidence.takeIf { it >= 0f }),
                  )
                }
              }
          jobs +=
              scope.launch {
                added.state.collect { state ->
                  Log.i(TAG, "glasses speech state=$state")
                  when (state) {
                    SpeechState.STARTED -> {
                      hasStarted = true
                      _state.value = VoiceState.LISTENING
                    }
                    // STOPPED is also the initial state; only restart one that was listening.
                    SpeechState.STOPPED -> if (hasStarted && !stopping) reviveLater()
                    else -> Unit
                  }
                }
              }
          jobs +=
              scope.launch {
                added.errors.collect { error ->
                  if (error == null) return@collect
                  Log.w(TAG, "glasses speech error=${error.description}")
                  if (error == SpeechError.UNAVAILABLE) _state.value = VoiceState.UNAVAILABLE
                }
              }
          added.start().onFailure { error, _ ->
            Log.w(TAG, "glasses speech would not start: ${error.description}")
            _state.value = VoiceState.UNAVAILABLE
          }
        }
        .onFailure { error, _ ->
          Log.w(TAG, "glasses speech would not attach: ${error.description}")
          _state.value = VoiceState.UNAVAILABLE
        }
  }

  private fun reviveLater() {
    if (revive?.isActive == true) return
    revive =
        scope.launch {
          repeat(REVIVE_ATTEMPTS) {
            delay(REVIVE_DELAY_MS)
            val s = speech ?: return@launch
            if (s.state.value != SpeechState.STOPPED) return@launch
            Log.i(TAG, "glasses speech stopped on its own (photo capture?); restarting")
            s.start()
          }
          delay(REVIVE_DELAY_MS)
          // Still down: the glasses are gone (disconnected, folded). Let VoiceControl fall back
          // to the phone; the reader re-attaches when the glasses come back.
          if (speech?.state?.value == SpeechState.STOPPED) {
            Log.w(TAG, "glasses speech won't restart; marking unavailable")
            _state.value = VoiceState.UNAVAILABLE
          }
        }
  }

  override fun stop() {
    stopping = true
    revive?.cancel()
    jobs.forEach { it.cancel() }
    jobs.clear()
    speech?.stop()
    if (speech != null) session.removeSpeech()
    speech = null
    hasStarted = false
    _state.value = VoiceState.OFF
  }

  private companion object {
    const val TAG = "BookReaderVoice"
    const val REVIVE_ATTEMPTS = 5
    const val REVIVE_DELAY_MS = 600L
  }
}

// MARK: - Phone

/**
 * Continuous listening on top of Android's one-utterance-at-a-time recogniser: start again after
 * every result or timeout. Main thread only (SpeechRecognizer's rule).
 */
class PhoneSpeechInput(context: Context, private val scope: CoroutineScope) : VoiceInput {

  private val appContext = context.applicationContext
  private val _utterances = MutableSharedFlow<Utterance>(extraBufferCapacity = 16)
  override val utterances: SharedFlow<Utterance> = _utterances.asSharedFlow()
  private val _state = MutableStateFlow(VoiceState.OFF)
  override val state: StateFlow<VoiceState> = _state.asStateFlow()

  private var recognizer: SpeechRecognizer? = null
  private var running = false
  private var restart: Job? = null
  private var consecutiveErrors = 0

  override fun start() {
    if (running) return
    val onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(appContext)
    if (!onDevice && !SpeechRecognizer.isRecognitionAvailable(appContext)) {
      Log.w(TAG, "no speech recogniser on this phone")
      _state.value = VoiceState.UNAVAILABLE
      return
    }
    recognizer =
        (if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        else SpeechRecognizer.createSpeechRecognizer(appContext))
            .also { it.setRecognitionListener(listener) }
    Log.i(TAG, "phone speech onDevice=$onDevice")
    running = true
    _state.value = VoiceState.STARTING
    listen()
  }

  private fun listen() {
    if (!running) return
    val intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
          putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
          putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.US.toLanguageTag())
          putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
          putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
          putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
    recognizer?.startListening(intent)
  }

  private fun listenAgain(afterMs: Long) {
    restart?.cancel()
    restart =
        scope.launch {
          delay(afterMs)
          listen()
        }
  }

  private val listener =
      object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
          _state.value = VoiceState.LISTENING
        }

        override fun onPartialResults(partialResults: Bundle?) {
          best(partialResults)?.let { _utterances.tryEmit(Utterance(it, isFinal = false)) }
        }

        override fun onResults(results: Bundle?) {
          consecutiveErrors = 0
          val confidence =
              results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)?.firstOrNull()?.takeIf {
                it >= 0f
              }
          best(results)?.let { _utterances.tryEmit(Utterance(it, isFinal = true, confidence)) }
          listenAgain(0)
        }

        override fun onError(error: Int) {
          when (error) {
            // Silence or nothing recognisable: normal, listen again.
            SpeechRecognizer.ERROR_NO_MATCH,
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> listenAgain(0)
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
              Log.w(TAG, "phone speech: no RECORD_AUDIO")
              running = false
              _state.value = VoiceState.UNAVAILABLE
            }
            else -> {
              consecutiveErrors++
              Log.w(TAG, "phone speech error=$error (x$consecutiveErrors)")
              // Busy/client/server hiccups: back off, don't spin.
              listenAgain((250L * consecutiveErrors).coerceAtMost(3_000L))
            }
          }
        }

        override fun onBeginningOfSpeech() = Unit

        override fun onRmsChanged(rmsdB: Float) = Unit

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
      }

  private fun best(bundle: Bundle?): String? =
      bundle
          ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
          ?.firstOrNull()
          ?.takeIf { it.isNotBlank() }

  override fun stop() {
    running = false
    restart?.cancel()
    recognizer?.cancel()
    recognizer?.destroy()
    recognizer = null
    _state.value = VoiceState.OFF
  }

  private companion object {
    const val TAG = "BookReaderVoice"
  }
}
