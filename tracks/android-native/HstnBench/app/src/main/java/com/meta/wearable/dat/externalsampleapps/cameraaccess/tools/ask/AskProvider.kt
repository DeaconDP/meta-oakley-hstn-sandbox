// AskProvider - which AskAboutText the app uses
//
// The one place the "ask about the text" feature plugs in: ToolHub calls [create] once. It returns
// the not-ready stub for now; the ask feature agent replaces the body (and adds files in this package
// and res/values/strings_ask.xml) without touching ToolHub or GlobalGrammar.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import android.content.Context
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskAboutText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.NotReadyAskAboutText

object AskProvider {
  @Suppress("UNUSED_PARAMETER")
  fun create(context: Context): AskAboutText = NotReadyAskAboutText
}
