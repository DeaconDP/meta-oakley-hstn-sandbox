// GlassesControls - the glasses' buttons and swipes, mapped to your commands (Experimental)
//
// DAT Inputs (mwdat-inputs, dev and beta channels only) reports the capture button (short press,
// hold, double press), a touchpad tap (Select), swipes (Nav) and the action button while a session
// runs. Each event becomes its key in the controls settings ("captureShort", "navUp", ...) and the
// command mapped to it is run as if spoken (ToolHub.runControl), so any phrase, shortcut or routine
// can sit on a button. Touch-and-hold on the temple is Meta's (pause / end session) and never
// reaches the app.
//
// Following BirdSpotter: attach only on a started session; a capability that went INACTIVE after
// being ACTIVE (a photo capture can do that) is removed and attached again. Needs Inputs enabled
// for the app in Wearables Developer Center; PERMISSION_DENIED otherwise (logged, not spoken).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.util.Log
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.inputs.Inputs
import com.meta.wearable.dat.inputs.addInputs
import com.meta.wearable.dat.inputs.removeInputs
import com.meta.wearable.dat.inputs.types.ButtonType
import com.meta.wearable.dat.inputs.types.CapturePressType
import com.meta.wearable.dat.inputs.types.InputEvent
import com.meta.wearable.dat.inputs.types.InputSource
import com.meta.wearable.dat.inputs.types.InputsConfiguration
import com.meta.wearable.dat.inputs.types.InputsState
import com.meta.wearable.dat.inputs.types.NavDirection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class GlassesControls(private val scope: CoroutineScope, private val onEvent: (String) -> Unit) {

  private var session: DeviceSession? = null
  private var inputs: Inputs? = null
  private var job: Job? = null
  private var wasActive = false

  val attached: Boolean
    get() = inputs != null

  /** Starts listening on [s] (a started session). No-op if already attached to it. */
  fun attach(s: DeviceSession) {
    if (session === s && inputs != null) return
    detach()
    session = s
    s.addInputs(
            InputsConfiguration(
                sources = setOf(InputSource.CAPTOUCH, InputSource.CAPTURE_BUTTON, InputSource.ACTION_BUTTON),
                consumeBack = false,
            ),
        )
        .fold(
            onSuccess = { i ->
              inputs = i
              wasActive = false
              job =
                  scope.launch {
                    launch {
                      i.state.collect { st ->
                        Log.i(TAG, "inputs state=$st")
                        if (st == InputsState.ACTIVE) wasActive = true
                        if (st == InputsState.INACTIVE && wasActive) revive()
                      }
                    }
                    launch { i.errors.collect { e -> e?.let { Log.w(TAG, "inputs error: ${it.description}") } } }
                    i.events.collect { e -> keyFor(e)?.let { key -> Log.i(TAG, "control=$key"); onEvent(key) } }
                  }
            },
            onFailure = { error, _ -> Log.w(TAG, "inputs would not attach: ${error.description}") },
        )
  }

  fun detach() {
    job?.cancel()
    job = null
    if (inputs != null) runCatching { session?.removeInputs() }
    inputs = null
    session = null
  }

  private fun revive() {
    val s = session ?: return
    scope.launch {
      delay(1_000)
      Log.i(TAG, "inputs went quiet; attaching again")
      detach()
      attach(s)
    }
  }

  companion object {
    private const val TAG = "GlassesControls"

    /** The controls-settings key for an Inputs event, or null for the ones we don't map. */
    fun keyFor(e: InputEvent): String? =
        when (e) {
          is InputEvent.Capture ->
              when (e.pressType) {
                CapturePressType.SHORT_PRESS -> "captureShort"
                CapturePressType.HOLD -> "captureHold"
                CapturePressType.DOUBLE_PRESS -> "captureDouble"
                else -> null
              }
          is InputEvent.Select -> "select"
          is InputEvent.Nav ->
              when (e.direction) {
                NavDirection.UP -> "navUp"
                NavDirection.DOWN -> "navDown"
                NavDirection.LEFT -> "navLeft"
                NavDirection.RIGHT -> "navRight"
                else -> null
              }
          is InputEvent.Button -> if (e.button == ButtonType.ACTION) "action" else null
          else -> null
        }
  }
}
