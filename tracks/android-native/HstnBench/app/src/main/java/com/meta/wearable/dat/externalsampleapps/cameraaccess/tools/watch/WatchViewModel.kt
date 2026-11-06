// WatchViewModel - the watch tool (stub)
//
// Registered and reachable everywhere a tool can be opened from (launcher, hstnbench://watch, the
// intent extra, the camera screen, and by voice from any tool), so the feature work only has to fill
// this package in. For now it opens, connects (ToolHub does that), and says it isn't ready yet.
// ToolViewModel provides voice, pitfalls, reminders, global commands and switching; see
// notes/tools-layer.md.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest

class WatchViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.WATCH) {

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.watch_name, R.string.watch_help)

  override fun onOpened(request: ToolRequest, reason: OpenReason) {
    say(str(R.string.tool_not_ready, str(R.string.watch_name)))
  }

  override fun onCommand(text: String): Boolean = WatchGrammar.parse(Phrases.normalize(text)) != null

  class Factory(private val application: Application, private val hub: ToolHub) :
      ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      @Suppress("UNCHECKED_CAST")
      return WatchViewModel(application, hub) as T
    }
  }
}
