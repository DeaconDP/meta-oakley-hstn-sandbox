// AudioMath - balance, which ear, mono, earcon sounds and mixing, as plain arithmetic
//
// Everything SpeakUp plays is mono at the source (TTS, earcons, tones). Where it lands is decided
// here, from the ears settings:
//
//   position   which ear the kind of sound goes to: both = 0, left = -1, right = +1 (a direction cue
//              uses where the thing is instead, when routed to both ears);
//   balance    then shifts everything: -1 all left ... +1 all right;
//   gains      "balance law": the near side stays at full level and only the far side is turned
//              down, so a centred sound is exactly as loud as before this existed (1, 1);
//   mono       "I use mono": no panning at all (1, 1), and direction cues become pitch.
//
// The same numbers drive the Android TTS pan parameter (KEY_PARAM_PAN), the earcon/tone
// AudioTracks and, with the audio bus on, the mixer. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

object AudioMath {

  enum class Kind { SPEECH, EARCON, CUE }

  data class Gains(val left: Float, val right: Float)

  val CENTRE = Gains(1f, 1f)

  /** Where [kind] sits, -1..1, before balance. [cue] is the direction of a cue (-1 left .. 1 right). */
  fun position(kind: Kind, ears: Ears, cue: Float = 0f): Float {
    if (ears.mono) return 0f
    val ear =
        when (kind) {
          Kind.SPEECH -> ears.speech
          Kind.EARCON -> ears.earcons
          Kind.CUE -> ears.cues
        }
    return when (ear) {
      Ear.LEFT -> -1f
      Ear.RIGHT -> 1f
      Ear.BOTH -> if (kind == Kind.CUE) cue.coerceIn(-1f, 1f) else 0f
    }
  }

  /** The pan value, -1..1, after balance. 0 when mono. */
  fun pan(kind: Kind, ears: Ears, cue: Float = 0f): Float =
      if (ears.mono) 0f else (position(kind, ears, cue) + ears.balance).coerceIn(-1f, 1f)

  /** Balance law: the far side is turned down, the near side stays at 1. */
  fun gains(pan: Float): Gains {
    val p = pan.coerceIn(-1f, 1f)
    return Gains(left = min(1f, 1f - p), right = min(1f, 1f + p))
  }

  fun gains(kind: Kind, ears: Ears, cue: Float = 0f): Gains = gains(pan(kind, ears, cue))

  /** A direction cue for a mono listener: pitch says where (low left, middle ahead, high right). */
  fun cueFrequency(side: Float): Float =
      when {
        side < -0.33f -> 440f
        side > 0.33f -> 880f
        else -> 660f
      }

  /** Mono [src] (16-bit) added into interleaved stereo [dst] (floats, -1..1) at [gains] x [volume]. */
  fun mixInto(dst: FloatArray, dstFrame: Int, src: ShortArray, srcFrom: Int, frames: Int, gains: Gains, volume: Float = 1f) {
    val l = gains.left * volume / Short.MAX_VALUE
    val r = gains.right * volume / Short.MAX_VALUE
    var d = dstFrame * 2
    for (i in srcFrom until srcFrom + frames) {
      val s = src[i].toFloat()
      dst[d++] += s * l
      dst[d++] += s * r
    }
  }

  /** Floats to 16-bit with hard clipping (the mixer's last step). */
  fun toPcm16(src: FloatArray, dst: ShortArray, samples: Int = src.size) {
    for (i in 0 until samples) {
      val v = (src[i].coerceIn(-1f, 1f) * Short.MAX_VALUE).toInt()
      dst[i] = v.toShort()
    }
  }

  /** Mono 16-bit to interleaved stereo at [gains] (for a static earcon/tone AudioTrack). */
  fun toStereo(mono: ShortArray, gains: Gains, volume: Float = 1f): ShortArray {
    val out = ShortArray(mono.size * 2)
    for (i in mono.indices) {
      out[2 * i] = (mono[i] * gains.left * volume).toInt().coerceIn(-32768, 32767).toShort()
      out[2 * i + 1] = (mono[i] * gains.right * volume).toInt().coerceIn(-32768, 32767).toShort()
    }
    return out
  }

  /** A sine [notes] sequence ((Hz, ms) pairs), 5 ms fades, mono 16-bit at [sampleRate]. */
  fun tones(notes: List<Pair<Float, Int>>, sampleRate: Int, level: Float = 0.6f): ShortArray {
    val chunks =
        notes.map { (hz, ms) ->
          val n = (sampleRate * ms / 1000).coerceAtLeast(16)
          val fade = min(sampleRate * 5 / 1000, n / 2)
          ShortArray(n) { i ->
            val env =
                when {
                  hz <= 0f -> 0f
                  i < fade -> i / fade.toFloat()
                  i > n - fade -> (n - i) / fade.toFloat()
                  else -> 1f
                }
            (sin(2 * PI * hz * i / sampleRate) * env * level * Short.MAX_VALUE).toInt().toShort()
          }
        }
    val out = ShortArray(chunks.sumOf { it.size })
    var at = 0
    for (c in chunks) {
      c.copyInto(out, at)
      at += c.size
    }
    return out
  }

  /**
   * The earcon set as notes, for when earcons must be panned (ToneGenerator can't be): same
   * meanings and lengths as the ToneGenerator tones. Keyed by Earcon name.
   */
  val EARCON_NOTES: Map<String, List<Pair<Float, Int>>> =
      mapOf(
          "ACK" to listOf(880f to 60),
          "TURN_DETECTED" to listOf(660f to 50, 0f to 20, 660f to 50),
          "PAGE_CAPTURED" to listOf(660f to 70, 880f to 80),
          "SAME_PAGE" to listOf(440f to 100, 330f to 100),
          "PAGE_DONE" to listOf(523f to 50, 659f to 50, 784f to 60),
          "ERROR" to listOf(311f to 120, 233f to 130),
          "WORKING" to listOf(1000f to 30),
          "READY" to listOf(523f to 50, 659f to 50, 784f to 60),
          "FOUND" to listOf(880f to 70, 1175f to 80),
          "SWITCH" to listOf(587f to 60, 784f to 60),
      )

  /** Words for "say what the sounds mean" (ACK is always followed by speech, so it stays a sound). */
  val EARCON_WORDS: Map<String, String> =
      mapOf(
          "TURN_DETECTED" to "turning",
          "PAGE_CAPTURED" to "got the page",
          "SAME_PAGE" to "same page",
          "PAGE_DONE" to "done",
          "ERROR" to "problem",
          "WORKING" to "working",
          "READY" to "ready",
          "FOUND" to "found",
          "SWITCH" to "switching",
      )

  /** 16-bit little-endian PCM bytes (what TTS hands over) to samples, mono (first channel). */
  fun pcm16le(bytes: ByteArray, channels: Int = 1): ShortArray {
    val frame = 2 * channels.coerceAtLeast(1)
    return ShortArray(bytes.size / frame) { i ->
      val b = i * frame
      ((bytes[b].toInt() and 0xFF) or (bytes[b + 1].toInt() shl 8)).toShort()
    }
  }

  /** Linear resampling from [from] Hz to [to] Hz (TTS engines speak at 16-24 kHz; the bus runs at one rate). */
  fun resample(src: ShortArray, from: Int, to: Int): ShortArray {
    if (from == to || src.isEmpty()) return src
    val n = ((src.size.toLong() * to) / from).toInt().coerceAtLeast(1)
    val step = from.toDouble() / to
    return ShortArray(n) { i ->
      val x = i * step
      val a = x.toInt().coerceAtMost(src.lastIndex)
      val b = (a + 1).coerceAtMost(src.lastIndex)
      val f = x - a
      (src[a] * (1 - f) + src[b] * f).toInt().toShort()
    }
  }

  /** Audio bus latency added before a sound reaches the output: one mix block plus the track buffer. */
  fun busLatencyMs(blockFrames: Int, bufferFrames: Int, sampleRate: Int): Float =
      (blockFrames + bufferFrames) * 1000f / sampleRate
}

/**
 * Clear speech: what the audio effects do to SpeakUp's own voice. Not hearing correction: a gentle
 * compressor so quiet syllables come up, +6 dB of loudness under a limiter, and a lift in the
 * 2-4 kHz band where consonants live. Values for Android DynamicsProcessing.
 */
object ClearSpeechTuning {
  /** Pre-EQ bands: (cutoff Hz, gain dB). */
  val EQ: List<Pair<Float, Float>> = listOf(250f to -3f, 1000f to 0f, 2000f to 3f, 4000f to 5f, 8000f to 2f, 20000f to 0f)
  const val COMPRESSOR_THRESHOLD_DB = -30f
  const val COMPRESSOR_RATIO = 3f
  const val COMPRESSOR_ATTACK_MS = 5f
  const val COMPRESSOR_RELEASE_MS = 80f
  const val POST_GAIN_DB = 6f
  const val LIMITER_THRESHOLD_DB = -2f
  /** Clear speech never reads faster than this. */
  const val MAX_RATE = 1f
}
