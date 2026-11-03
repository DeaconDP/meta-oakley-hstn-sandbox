// PageTurnDetector - hands-free "next page" from per-frame signals
//
// READING --(big change for minTurnFrames frames)--> TURNING --(change drops below still)-->
// SETTLING --(settleFrames still frames with text in view)--> CAPTURE --captureDone()--> READING
//
// A big change during SETTLING goes back to TURNING; small jitter just restarts the still count.
// nextPage() is the manual fallback (phone button, screen-reader action) and jumps straight to
// CAPTURE. Requiring consecutive high frames filters single-frame spikes such as a stream keyframe.
// A head bump that settles back on the same page still ends in CAPTURE; PageDedup catches that.
//
// Signals are plain numbers so the machine is unit-testable and the source can change: today the
// Android glue derives `change` from compressed HEVC frame sizes (FrameSizeMotion), which needs no
// decode. A pixel-difference score from decoded frames would slot in the same way.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.book

enum class TurnState {
  READING,
  TURNING,
  SETTLING,
  CAPTURE,
}

/**
 * One frame's worth of evidence. [change] is 0..1 (0 = identical to the last frame). [textPresent]
 * is null when unknown (no per-frame OCR), which counts as present.
 */
data class FrameSignal(val change: Float, val textPresent: Boolean? = null)

sealed interface TurnEvent {
  data object TurnStarted : TurnEvent

  data object Settling : TurnEvent

  data class Capture(val manual: Boolean) : TurnEvent
}

class PageTurnDetector(private val config: Config = Config()) {

  data class Config(
      val turnThreshold: Float = 0.35f,
      val stillThreshold: Float = 0.1f,
      val minTurnFrames: Int = 2,
      val settleFrames: Int = 5,
  )

  var state: TurnState = TurnState.READING
    private set

  private var highFrames = 0
  private var stillFrames = 0

  fun onFrame(signal: FrameSignal): TurnEvent? {
    val big = signal.change >= config.turnThreshold
    val still = signal.change < config.stillThreshold
    return when (state) {
      TurnState.READING -> {
        highFrames = if (big) highFrames + 1 else 0
        if (highFrames >= config.minTurnFrames) {
          enter(TurnState.TURNING)
          TurnEvent.TurnStarted
        } else {
          null
        }
      }
      TurnState.TURNING ->
          if (still) {
            enter(TurnState.SETTLING)
            stillFrames = if (signal.textPresent != false) 1 else 0
            settleIfDone() ?: TurnEvent.Settling
          } else {
            null
          }
      TurnState.SETTLING ->
          when {
            big -> {
              enter(TurnState.TURNING)
              null
            }
            !still -> {
              stillFrames = 0
              null
            }
            signal.textPresent == false -> null // hand or blank page in view: wait, don't count
            else -> {
              stillFrames++
              settleIfDone()
            }
          }
      TurnState.CAPTURE -> null // a capture is in flight; frames are ignored until captureDone()
    }
  }

  private fun settleIfDone(): TurnEvent? =
      if (stillFrames >= config.settleFrames) {
        enter(TurnState.CAPTURE)
        TurnEvent.Capture(manual = false)
      } else {
        null
      }

  /** Manual "next page": capture now, whatever the frames say. */
  fun nextPage(): TurnEvent.Capture {
    enter(TurnState.CAPTURE)
    return TurnEvent.Capture(manual = true)
  }

  /** The capture (and its OCR) finished; watch for the next turn. */
  fun captureDone() = enter(TurnState.READING)

  fun reset() = enter(TurnState.READING)

  private fun enter(next: TurnState) {
    state = next
    highFrames = 0
    stillFrames = 0
  }
}

/**
 * Motion score from compressed frame sizes. A still scene encodes to tiny P-frames; head or page
 * motion makes them several times bigger. The baseline tracks the still level, dropping quickly and
 * rising slowly so a long turn doesn't become the new normal.
 */
class FrameSizeMotion(
    private val riseRate: Float = 0.05f,
    private val fallRate: Float = 0.3f,
    /** A frame this many times the baseline (plus one) scores 1.0. */
    private val scale: Float = 3f,
) {
  private var baseline: Float? = null

  /** Returns 0..1, or null for frames that say nothing about motion (codec config, empty). */
  fun onFrame(bytes: Int, isCodecConfig: Boolean = false): Float? {
    if (isCodecConfig || bytes <= 0) return null
    val b = baseline
    if (b == null) {
      baseline = bytes.toFloat()
      return 0f
    }
    val ratio = bytes / b
    baseline = if (bytes < b) b + fallRate * (bytes - b) else b + riseRate * (bytes - b)
    return ((ratio - 1f) / scale).coerceIn(0f, 1f)
  }

  fun reset() {
    baseline = null
  }
}
