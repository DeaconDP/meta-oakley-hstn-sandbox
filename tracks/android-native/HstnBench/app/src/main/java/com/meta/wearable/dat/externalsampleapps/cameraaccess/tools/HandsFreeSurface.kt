// HandsFreeSurface - where ToolHub's output goes besides the speaker
//
// notes/hands-free-mode.md > Shape in code. Speech is always the source of truth (ToolHub speaks).
// This fans the same state out to:
//   - the phone screen: [card] is a StateFlow the camera screen can mirror (always);
//   - the glasses display: a CardSink (GlassesDisplaySink), only while it says it can show.
// Tools never talk to a display: they publish a status line and hints through ToolHub, which builds
// the GlassesCard and calls [publish].
//
// Glasses sends are throttled (CardThrottle: on change only, at most ~2 a second, newest wins).
// A sink failure is logged, reported once through [onSinkError] (ToolHub says it once), and never
// reaches the audio path: sends run off the main thread and every exception stops here.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.os.SystemClock
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CardDecision
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CardThrottle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesCard
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Something that can show a GlassesCard (a glasses display). */
interface CardSink {
  /** True if a card sent now would be shown (device has a display, user wants it, session up). */
  fun canShow(): Boolean

  /** Shows [card], replacing what's there. True if it was shown. May throw; the surface catches. */
  suspend fun show(card: GlassesCard): Boolean

  /** Blank the display and let it go (session ending, display switched off). Must not throw. */
  suspend fun release()
}

class HandsFreeSurface(
    private val scope: CoroutineScope,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
) {
  private companion object {
    const val TAG = "HandsFreeSurface"
  }

  private val _card = MutableStateFlow(GlassesCard())
  /** The card as it stands: the phone screen mirrors it. */
  val card: StateFlow<GlassesCard> = _card.asStateFlow()

  /** The glasses display, if the app has one wired up. */
  var sink: CardSink? = null

  /** Called once per run of failures (not per failed send) with what went wrong. */
  var onSinkError: ((String) -> Unit)? = null

  private val throttle = CardThrottle()
  private var later: Job? = null
  private var sending: Job? = null
  private var failing = false
  /** Bumped by [releaseSink]: sends queued before it are dropped, so a cleared display stays clear. */
  private var generation = 0

  /** Number of cards sent to the sink (tests and logs). */
  var sentCount = 0
    private set

  /** The latest state of the screen. Main thread. */
  fun publish(card: GlassesCard) {
    _card.value = card
    val s = sink ?: return
    if (!s.canShow()) return
    when (val d = throttle.offer(card, clock())) {
      CardDecision.Send -> send(s, card)
      CardDecision.Unchanged -> Unit
      is CardDecision.Later -> {
        later?.cancel()
        later = scope.launch {
          delay(d.delayMs)
          throttle.takePending(clock())?.let { send(s, it) }
        }
      }
    }
  }

  /** Re-send the current card (the display just came up or was switched back on). */
  fun refresh() {
    throttle.reset()
    publish(_card.value)
  }

  /** The display is going away (switched off, session ended): blank it, start afresh next time. */
  fun releaseSink() {
    later?.cancel()
    throttle.reset()
    generation++
    val s = sink ?: return
    // After any send in flight, so the card can't land on the display after it was cleared.
    val previous = sending
    sending = scope.launch {
      previous?.join()
      try {
        s.release()
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        Log.w(TAG, "display release failed", e)
      }
    }
  }

  private fun send(s: CardSink, card: GlassesCard) {
    throttle.sent(card, clock())
    // One transfer at a time, in order: a send isn't cut off mid-transfer by the next one.
    val gen = generation
    val previous = sending
    sending = scope.launch {
      previous?.join()
      if (gen != generation || !s.canShow()) return@launch
      val ok =
          try {
            s.show(card)
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            Log.w(TAG, "display send failed", e)
            false
          }
      if (ok) {
        sentCount++
        failing = false
      } else {
        // Try again with the next change rather than believing the glasses show this one.
        throttle.reset()
        if (!failing) {
          failing = true
          onSinkError?.invoke("send failed")
        }
      }
    }
  }
}
