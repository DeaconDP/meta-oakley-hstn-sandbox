// VoiceControl - picks the microphone and keeps listening for as long as the reader is open
//
// Glasses first (on-glasses recognition keeps the reading voice in stereo); the phone's on-device
// recogniser if the glasses can't: no session, permission refused, speech won't attach, or the
// glasses report no recogniser, either at start or later. See VoiceInput.kt.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.content.Context
import android.util.Log
import com.meta.wearable.dat.core.session.DeviceSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

enum class Microphone {
  NONE,
  GLASSES,
  PHONE,
}

class VoiceControl(private val context: Context, private val scope: CoroutineScope) {

  private val _utterances = MutableSharedFlow<Utterance>(extraBufferCapacity = 16)
  val utterances: SharedFlow<Utterance> = _utterances.asSharedFlow()

  private val _microphone = MutableStateFlow(Microphone.NONE)
  val microphone: StateFlow<Microphone> = _microphone.asStateFlow()

  private var input: VoiceInput? = null
  private val jobs = mutableListOf<Job>()
  private var phoneAllowed: (suspend () -> Boolean)? = null

  /**
   * Starts listening. [glassesAllowed] and [phoneAllowed] check (and if needed request) the DAT
   * microphone permission and Android RECORD_AUDIO. Returns which mic is live.
   */
  suspend fun start(
      session: DeviceSession?,
      glassesAllowed: suspend () -> Boolean,
      phoneAllowed: suspend () -> Boolean,
  ): Microphone {
    if (input != null) return _microphone.value
    this.phoneAllowed = phoneAllowed
    if (session != null && glassesAllowed()) {
      val glasses = GlassesSpeechInput(session, scope)
      use(glasses, Microphone.GLASSES)
      glasses.start()
      val settled =
          withTimeoutOrNull(GLASSES_START_TIMEOUT_MS) {
            glasses.state.first { it == VoiceState.LISTENING || it == VoiceState.UNAVAILABLE }
          }
      if (settled == VoiceState.LISTENING) {
        // If the glasses give up later, move to the phone.
        jobs += scope.launch {
          glasses.state.first { it == VoiceState.UNAVAILABLE }
          Log.w(TAG, "glasses speech became unavailable; falling back to the phone")
          // Not in [jobs]: release() cancels those, and this has to outlive it.
          scope.launch { fallBackToPhone() }
        }
        return Microphone.GLASSES
      }
      Log.w(TAG, "glasses speech didn't start (state=$settled); using the phone")
      release()
    }
    return startPhone()
  }

  private suspend fun startPhone(): Microphone {
    val allowed = phoneAllowed?.invoke() ?: false
    if (!allowed) {
      _microphone.value = Microphone.NONE
      return Microphone.NONE
    }
    val phone = PhoneSpeechInput(context, scope)
    use(phone, Microphone.PHONE)
    phone.start()
    if (phone.state.value == VoiceState.UNAVAILABLE) {
      release()
      return Microphone.NONE
    }
    return Microphone.PHONE
  }

  private suspend fun fallBackToPhone() {
    release()
    startPhone()
  }

  private fun use(source: VoiceInput, mic: Microphone) {
    input = source
    _microphone.value = mic
    jobs += scope.launch { source.utterances.collect { _utterances.emit(it) } }
  }

  private fun release() {
    jobs.forEach { it.cancel() }
    jobs.clear()
    input?.stop()
    input = null
    _microphone.value = Microphone.NONE
  }

  fun stop() {
    phoneAllowed = null
    release()
  }

  private companion object {
    const val TAG = "BookReaderVoice"
    const val GLASSES_START_TIMEOUT_MS = 5_000L
  }
}
