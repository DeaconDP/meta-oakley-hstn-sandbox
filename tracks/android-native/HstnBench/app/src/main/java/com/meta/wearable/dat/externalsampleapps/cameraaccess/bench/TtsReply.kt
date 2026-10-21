// TtsReply - spoken reply through the glasses speakers
//
// DAT has no audio-output API of its own. Glasses speakers are a normal Bluetooth A2DP sink, so
// media-usage audio follows the system route to them once they're connected (see the DAT
// "Microphones and speakers" guide). This wraps the platform TextToSpeech with media attributes and
// logs which output the reply played on, so a benchmark run shows whether it reached the glasses.
// On the Mock Device Kit there is no Bluetooth sink, so the reply plays on the phone speaker.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bench

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID

class TtsReply(context: Context) {

  private val audioManager = context.getSystemService(AudioManager::class.java)

  // Guarded by [pending].
  private var ready = false
  private val pending = mutableListOf<String>()

  private val tts: TextToSpeech =
      TextToSpeech(context.applicationContext) { status -> onInit(status) }

  private fun onInit(status: Int) {
    if (status != TextToSpeech.SUCCESS) {
      BenchClock.note("tts_init=failed status=$status")
      return
    }
    tts.language = Locale.US
    tts.setAudioAttributes(
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build(),
    )
    tts.setOnUtteranceProgressListener(
        object : UtteranceProgressListener() {
          override fun onStart(utteranceId: String) {
            BenchClock.end("tts_to_audio_start", "route=${outputRoute()}")
          }

          override fun onDone(utteranceId: String) {
            BenchClock.end("tts_total")
          }

          @Deprecated("Deprecated in Java")
          override fun onError(utteranceId: String) {
            BenchClock.note("tts_error utterance=$utteranceId")
          }
        },
    )
    val queued =
        synchronized(pending) {
          ready = true
          pending.toList().also { pending.clear() }
        }
    BenchClock.note("tts_init=ok")
    queued.forEach(::speakNow)
  }

  /** Speaks [text]; queued until the engine finishes initializing. */
  fun speak(text: String) {
    BenchClock.start("tts_to_audio_start")
    BenchClock.start("tts_total")
    synchronized(pending) {
      if (!ready) {
        pending += text
        return
      }
    }
    speakNow(text)
  }

  private fun speakNow(text: String) {
    tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
  }

  /** "a2dp" when a Bluetooth A2DP sink (the glasses) is connected, otherwise the fallback output. */
  private fun outputRoute(): String {
    val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
    return when {
      outputs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP } -> "a2dp"
      outputs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO } -> "sco"
      else -> "phone"
    }
  }

  fun shutdown() {
    tts.shutdown()
  }
}
