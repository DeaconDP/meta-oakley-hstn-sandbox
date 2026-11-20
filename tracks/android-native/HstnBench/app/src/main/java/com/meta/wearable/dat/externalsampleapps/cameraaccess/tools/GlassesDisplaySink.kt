// GlassesDisplaySink - the hands-free card on glasses that have a display (Ray-Ban Display)
//
// notes/hands-free-mode.md > Display is optional. Uses mwdat-display (GA in DAT 1.0.1) on the same
// DeviceSession the camera uses, as Meta's BirdSpotter sample does: no manifest change (DAM is
// always on since DAT 0.9; the old DAM_ENABLED key is ignored), and the capability is only attached
// when the connected device says it has a display (Device.isDisplayCapable()). HSTN has none, so on
// HSTN this never touches the session and the camera path is unchanged.
//
// It only shows anything in hands-free mode, with "glasses display" on (HandsFreeStore). The card:
// the screen name (heading), one line of state, what was heard (shortened), and up to three hint
// phrases as buttons. A button press is the same as saying the phrase ([onHint]).
//
// Every call is defensive: a display that won't attach, start or take content returns false (and
// HandsFreeSurface says so once); nothing here can stop speech or the mic.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.util.Log
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.display.Display
import com.meta.wearable.dat.display.addDisplay
import com.meta.wearable.dat.display.removeDisplay
import com.meta.wearable.dat.display.types.DisplayState
import com.meta.wearable.dat.display.views.ButtonStyle
import com.meta.wearable.dat.display.views.ContentScope
import com.meta.wearable.dat.display.views.Direction
import com.meta.wearable.dat.display.views.FlexBoxBackground
import com.meta.wearable.dat.display.views.TextColor
import com.meta.wearable.dat.display.views.TextStyle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlassesCard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class GlassesDisplaySink(
    /** The running DAT session (PageCamera.deviceSession), or null. */
    private val session: () -> DeviceSession?,
    /** Hands-free on and "glasses display" on. */
    private val wanted: () -> Boolean,
    /** "Heard: " prefix for the heard line. */
    private val heardLabel: String,
    /** A hint button was pressed on the glasses: run it as if said. Called on any thread. */
    private val onHint: (String) -> Unit,
) : CardSink {

  private companion object {
    const val TAG = "GlassesDisplay"
    const val START_TIMEOUT_MS = 3_000L
  }

  private var display: Display? = null
  private var displaySession: DeviceSession? = null

  /** The connected glasses have a display (false for HSTN, or with no session). */
  fun supported(): Boolean = session()?.let(::hasDisplay) == true

  override fun canShow(): Boolean {
    if (!wanted()) return false
    val s = session() ?: return false
    return s.state.value == DeviceSessionState.STARTED && hasDisplay(s)
  }

  override suspend fun show(card: GlassesCard): Boolean {
    val s = session() ?: return false
    if (s.state.value != DeviceSessionState.STARTED || !hasDisplay(s)) return false
    val d = attach(s) ?: return false
    val started = withTimeoutOrNull(START_TIMEOUT_MS) { d.state.first { it == DisplayState.STARTED } }
    if (started == null) {
      Log.w(TAG, "display didn't start (state=${d.state.value})")
      return false
    }
    return withContext(Dispatchers.IO) {
      d.sendContent { render(card) }
          .fold(
              onSuccess = { true },
              onFailure = { error, _ ->
                Log.w(TAG, "send failed: ${error.description}")
                false
              },
          )
    }
  }

  override suspend fun release() {
    val d = display ?: return
    val s = displaySession
    display = null
    displaySession = null
    try {
      withContext(Dispatchers.IO) { d.clearDisplay() }
      s?.removeDisplay()
    } catch (e: Exception) {
      Log.w(TAG, "release failed", e)
    }
  }

  private fun hasDisplay(s: DeviceSession): Boolean =
      try {
        s.deviceInfo.value.isDisplayCapable()
      } catch (e: Exception) {
        false
      }

  /** The display capability on [s], attaching it once per session. */
  private fun attach(s: DeviceSession): Display? {
    if (displaySession === s) display?.let { return it }
    // A new session (reconnect): the old capability went with the old one.
    display = null
    displaySession = null
    var attached: Display? = null
    s.addDisplay()
        .onSuccess { attached = it }
        .onFailure { error, _ -> Log.w(TAG, "display would not attach: ${error.description}") }
    attached?.let {
      display = it
      displaySession = s
      Log.i(TAG, "display attached")
    }
    return attached
  }

  /** The card: one root flexBox (each send replaces the whole screen). */
  private fun ContentScope.render(card: GlassesCard) {
    flexBox(direction = Direction.COLUMN, gap = 8, padding = 16, background = FlexBoxBackground.CARD) {
      text(card.screen, style = TextStyle.HEADING)
      if (card.state.isNotEmpty()) text(card.state, style = TextStyle.BODY)
      if (card.heard.isNotEmpty()) {
        text(heardLabel + card.heard, style = TextStyle.META, color = TextColor.SECONDARY)
      }
      if (card.hints.isNotEmpty()) {
        buttonGroup {
          for (hint in card.hints) {
            button(label = hint, style = ButtonStyle.SECONDARY, onClick = { onHint(hint) })
          }
        }
      }
    }
  }
}
