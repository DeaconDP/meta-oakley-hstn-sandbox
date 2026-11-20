// AudioBus - one stereo output for speech, earcons and tones (Experimental, off by default)
//
// The roadmap's "one audio bus": everything SpeakUp says or plays is mixed here into a single
// AudioTrack, so balance, which-ear routing and the clear-speech effects apply to all of it the
// same way. Speech arrives as PCM from TextToSpeech.synthesizeToFile (onAudioAvailable streams it
// while it's being made), earcons and tones as short PCM buffers.
//
//   mixer   a thread writes 5 ms blocks (120 frames at 24 kHz) into a low-latency streaming track;
//           earcons and tones mix on top of speech; speech utterances play strictly in order.
//   idle    after 2 s with nothing to play the track pauses (no busy loop); the next sound wakes it.
//   effects clear speech = DynamicsProcessing on the track's audio session (EQ, compressor, gain,
//           limiter; values in settings/ClearSpeechTuning).
//
// Why it's behind a flag (SettingsPrefs.audioBus, "Experimental" on the settings screen):
//   - speech reaches the ear only after the engine has synthesised the first chunk, and engines
//     differ in how early onAudioAvailable fires; with the flag off TTS plays itself as before;
//   - the 100 ms earcon rule: the mixer adds one block plus the track buffer (AudioMath.busLatencyMs,
//     about 25 ms at 24 kHz), but over A2DP the Bluetooth delay dominates either way and neither has
//     been measured on the A26 + HSTN yet. Each earcon logs its own request-to-mix delay
//     ("bus_earcon_ms") so the first device run answers it.
// Without the bus, balance and routing still work: TTS uses KEY_PARAM_PAN and the earcons and tones
// play panned PCM on their own tracks (Earcons, ToneSynth).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.audiofx.DynamicsProcessing
import android.os.SystemClock
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.AudioMath
import java.util.concurrent.ConcurrentLinkedQueue

class AudioBus(val sampleRate: Int = SAMPLE_RATE) {

  /** A short sound: an earcon or a tone. */
  private class Sound(val pcm: ShortArray, val gains: AudioMath.Gains, val volume: Float, val kind: String, val requestedAt: Long) {
    var pos = 0
  }

  /** One speech utterance, filled while the engine synthesises it. */
  inner class SpeechStream(val gains: AudioMath.Gains, private val onStart: () -> Unit, private val onDone: () -> Unit) {
    internal val chunks = ConcurrentLinkedQueue<ShortArray>()
    @Volatile internal var ended = false
    @Volatile internal var cancelled = false
    internal var head: ShortArray? = null
    internal var headPos = 0
    internal var started = false

    /** Mono PCM at the bus rate. */
    fun write(pcm: ShortArray) {
      if (!cancelled && pcm.isNotEmpty()) {
        chunks.add(pcm)
        wake()
      }
    }

    /** Synthesis finished; play out what's left, then [onDone]. */
    fun end() {
      ended = true
      wake()
    }

    internal fun started() {
      if (!started) {
        started = true
        onStart()
      }
    }

    internal fun done() = onDone()
  }

  private val lock = Object()
  private val sounds = ArrayList<Sound>()
  private val speech = ArrayDeque<SpeechStream>()
  @Volatile private var running = true
  private var dynamics: DynamicsProcessing? = null

  private val track: AudioTrack? =
      try {
        val minBytes = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setBufferSizeInBytes(maxOf(minBytes, BLOCK_FRAMES * 4 * 4))
            .build()
      } catch (e: Exception) {
        Log.w(TAG, "bus track unavailable", e)
        null
      }

  /** Frames of buffering in the track (for the latency estimate). */
  val bufferFrames: Int
    get() = track?.bufferSizeInFrames ?: 0

  val available: Boolean
    get() = track != null

  private val thread =
      Thread({ loop() }, "AudioBus").apply {
        priority = Thread.MAX_PRIORITY
        start()
      }

  init {
    Log.i(TAG, "bus rate=$sampleRate block=$BLOCK_FRAMES buffer=$bufferFrames latency≈${AudioMath.busLatencyMs(BLOCK_FRAMES, bufferFrames, sampleRate)} ms")
  }

  /** Plays a short mono sound now, over whatever else is playing. [kind] "tone" replaces the last tone. */
  fun play(pcm: ShortArray, gains: AudioMath.Gains, volume: Float, kind: String = "earcon") {
    synchronized(lock) {
      if (kind == "tone") sounds.removeAll { it.kind == "tone" }
      sounds += Sound(pcm, gains, volume, kind, SystemClock.elapsedRealtime())
    }
    wake()
  }

  /** A new speech utterance, played after the ones before it. */
  fun openSpeech(gains: AudioMath.Gains, onStart: () -> Unit, onDone: () -> Unit): SpeechStream {
    val s = SpeechStream(gains, onStart, onDone)
    synchronized(lock) { speech.addLast(s) }
    wake()
    return s
  }

  /** Cut speech off now (stop()); earcons carry on. */
  fun stopSpeech() {
    synchronized(lock) {
      speech.forEach { it.cancelled = true }
      speech.clear()
    }
  }

  fun stopTones() {
    synchronized(lock) { sounds.removeAll { it.kind == "tone" } }
  }

  /** Clear speech on or off for everything on the bus. */
  fun setClearSpeech(on: Boolean) {
    val t = track ?: return
    try {
      dynamics?.release()
      dynamics = if (on) ClearSpeechEffect.create(t.audioSessionId)?.also { it.enabled = true } else null
    } catch (e: Exception) {
      Log.w(TAG, "clear speech effect failed", e)
      dynamics = null
    }
  }

  fun release() {
    running = false
    wake()
    runCatching { thread.join(200) }
    dynamics?.release()
    track?.let {
      runCatching { it.stop() }
      it.release()
    }
  }

  private fun wake() = synchronized(lock) { lock.notifyAll() }

  private fun loop() {
    val t = track ?: return
    val mix = FloatArray(BLOCK_FRAMES * 2)
    val out = ShortArray(BLOCK_FRAMES * 2)
    var idleSince = SystemClock.elapsedRealtime()
    var playing = false
    while (running) {
      val now = SystemClock.elapsedRealtime()
      val busy = synchronized(lock) { sounds.isNotEmpty() || speech.isNotEmpty() }
      if (!busy && now - idleSince > IDLE_PAUSE_MS) {
        if (playing) {
          runCatching { t.pause() }
          playing = false
        }
        synchronized(lock) {
          if (sounds.isEmpty() && speech.isEmpty() && running) lock.wait(1000)
        }
        continue
      }
      if (busy) idleSince = now
      if (!playing) {
        runCatching { t.play() }
        playing = true
      }
      mix.fill(0f)
      mixSounds(mix)
      mixSpeech(mix)
      AudioMath.toPcm16(mix, out)
      t.write(out, 0, out.size) // blocks: this is the clock
    }
  }

  private fun mixSounds(mix: FloatArray) {
    val list = synchronized(lock) { sounds.toList() }
    for (s in list) {
      if (s.pos == 0 && s.kind == "earcon") Log.i(TAG, "bus_earcon_ms=${SystemClock.elapsedRealtime() - s.requestedAt}")
      val n = minOf(BLOCK_FRAMES, s.pcm.size - s.pos)
      AudioMath.mixInto(mix, 0, s.pcm, s.pos, n, s.gains, s.volume)
      s.pos += n
    }
    synchronized(lock) { sounds.removeAll { it.pos >= it.pcm.size } }
  }

  private fun mixSpeech(mix: FloatArray) {
    var frame = 0
    while (frame < BLOCK_FRAMES) {
      val s = synchronized(lock) { speech.firstOrNull() } ?: return
      if (s.cancelled) {
        synchronized(lock) { speech.remove(s) }
        continue
      }
      val head = s.head ?: s.chunks.poll()?.also {
        s.head = it
        s.headPos = 0
      }
      if (head == null) {
        if (s.ended) {
          synchronized(lock) { speech.remove(s) }
          s.done()
          continue
        }
        return // still synthesising: an underrun, silence for the rest of this block
      }
      s.started()
      val n = minOf(BLOCK_FRAMES - frame, head.size - s.headPos)
      AudioMath.mixInto(mix, frame, head, s.headPos, n, s.gains)
      s.headPos += n
      frame += n
      if (s.headPos >= head.size) s.head = null
    }
  }

  companion object {
    private const val TAG = "AudioBus"
    const val SAMPLE_RATE = 24_000
    const val BLOCK_FRAMES = 120
    private const val IDLE_PAUSE_MS = 2_000L
  }
}

/** DynamicsProcessing set up from ClearSpeechTuning, for a TTS session or the bus. */
object ClearSpeechEffect {
  fun create(sessionId: Int): DynamicsProcessing? =
      try {
        val tuning = com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.ClearSpeechTuning
        val bands = tuning.EQ.size
        val config =
            DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                    2,
                    true, bands,
                    true, 1,
                    false, 0,
                    true,
                )
                .build()
        val dp = DynamicsProcessing(0, sessionId, config)
        for (ch in 0 until 2) {
          val eq = DynamicsProcessing.Eq(true, true, bands)
          tuning.EQ.forEachIndexed { i, (hz, db) -> eq.setBand(i, DynamicsProcessing.EqBand(true, hz, db)) }
          dp.setPreEqByChannelIndex(ch, eq)
          val mbc = DynamicsProcessing.Mbc(true, true, 1)
          mbc.setBand(
              0,
              DynamicsProcessing.MbcBand(
                  true, 20000f,
                  tuning.COMPRESSOR_ATTACK_MS, tuning.COMPRESSOR_RELEASE_MS, tuning.COMPRESSOR_RATIO,
                  tuning.COMPRESSOR_THRESHOLD_DB, 0f, -90f, 1f, 0f, tuning.POST_GAIN_DB,
              ),
          )
          dp.setMbcByChannelIndex(ch, mbc)
          dp.setLimiterByChannelIndex(ch, DynamicsProcessing.Limiter(true, true, 0, 1f, 60f, 10f, tuning.LIMITER_THRESHOLD_DB, 0f))
        }
        dp
      } catch (e: Exception) {
        Log.w("ClearSpeech", "DynamicsProcessing unavailable", e)
        null
      }
}
