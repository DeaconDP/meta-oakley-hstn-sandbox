// ToolViewModel - the base class for a voice-first tool's ViewModel
//
// Extend this and a tool gets everything ToolHub provides (connect and narrate, mic and echo guard,
// spoken pitfalls, silence reminders, global commands, switching tools, asking about the text) plus
// a ToolUiState for the screen (status, last heard, which mic). A minimal tool overrides [texts] and
// [onOpened], and [onCommand] once it has its own grammar. Through [hub] it speaks (say, reply, warn,
// speak), plays earcons and tones, reads frames from the glasses camera (hub.camera.frames /
// latestFrame / capturePage), and publishes what it read (hub.recentText). The pitfall lines that
// in the book reader say "say read to carry on" get tool-neutral wording here.
// See notes/tools-layer.md for the full API and an example.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.app.Application
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalGrammar
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HealthAlert
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What every tool screen shows. Tools keep their own extra state in their own flows. */
data class ToolUiState(
    /** The status line: the last thing said about what's going on. */
    val status: String = "",
    /** The last thing the user said. */
    val heard: String = "",
    val microphone: Microphone = Microphone.NONE,
    /** The request the tool was opened with (mode, argument). */
    val request: ToolRequest? = null,
)

abstract class ToolViewModel(
    application: Application,
    protected val hub: ToolHub,
    final override val toolId: ToolId,
) : AndroidViewModel(application), ToolHost {

  protected val _ui = MutableStateFlow(ToolUiState())
  val ui: StateFlow<ToolUiState> = _ui.asStateFlow()

  /** The request this tool was last opened with. */
  protected var request: ToolRequest = ToolRequest(toolId)
    private set

  init {
    viewModelScope.launch { hub.microphone.collect { m -> _ui.update { it.copy(microphone = m) } } }
  }

  override fun onAttached(request: ToolRequest) {
    this.request = request
    _ui.update { it.copy(request = request, heard = "") }
  }

  override fun onRequest(request: ToolRequest) {
    this.request = request
    _ui.update { it.copy(request = request) }
  }

  override fun onHeard(text: String) {
    _ui.update { it.copy(heard = text) }
  }

  override fun onStatus(text: String) {
    _ui.update { it.copy(status = text) }
  }

  /** Barge-in: "stop" cuts speech off on the partial result, without waiting for the final one. */
  override fun onPartial(text: String): Boolean {
    if (!GlobalGrammar.isBargeIn(text)) return false
    hub.hush()
    return true
  }

  /** True while the tool is reading something out: unknown speech is then probably the room. */
  open fun isBusy(): Boolean = false

  override fun onNotUnderstood(text: String) = hub.sayNotUnderstood(text, busy = isBusy())

  /** Tool-neutral wording for the pitfalls whose book reader lines mention reading. */
  override fun onHealthAlert(alert: HealthAlert): String? =
      when (alert) {
        HealthAlert.GlassesRemoved -> str(R.string.tool_removed)
        HealthAlert.GlassesDisconnected -> str(R.string.tool_disconnected)
        HealthAlert.GlassesWornAgain -> str(R.string.tool_worn_again)
        HealthAlert.GlassesTooHot -> str(R.string.tool_too_hot)
        else -> null
      }

  /** Says [text] and shows it on the status line. */
  protected fun say(text: String) = hub.say(text)

  protected fun str(@StringRes id: Int): String = getApplication<Application>().getString(id)

  protected fun str(@StringRes id: Int, vararg args: Any): String =
      getApplication<Application>().getString(id, *args)
}
