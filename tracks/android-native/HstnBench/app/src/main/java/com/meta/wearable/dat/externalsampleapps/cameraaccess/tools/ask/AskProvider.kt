// AskProvider - which AskAboutText the app uses
//
// The one place "Ask about the text" plugs in: ToolHub calls [create] once per activity. It returns
// OnDeviceAsk (dictionary + text search, no network), with:
//  - the dictionary loading in the background on IO as soon as the app starts (~3.5 MB asset,
//    about 10 MB in memory), so the first question doesn't wait for it;
//  - the last session's text from AskMemory, read now, before this session's reading replaces it;
//  - ClaudeAsk only if BuildConfig.ANTHROPIC_API_KEY is set (local.properties anthropic_api_key).
//    Without a key there is no network path at all.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.BuildConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskAboutText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async

object AskProvider {
  private const val TAG = "AskAboutText"
  const val DICTIONARY_ASSET = "ask/wordnet.wnask"

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  @Volatile private var loading: Deferred<Dictionary?>? = null

  /** The dictionary, loaded once per process in the background. */
  fun dictionary(context: Context): Deferred<Dictionary?> =
      loading ?: synchronized(this) {
        loading ?: scope.async {
          try {
            val t0 = SystemClock.elapsedRealtime()
            val d = context.assets.open(DICTIONARY_ASSET).use(Dictionary::load)
            Log.i(TAG, "metric=ask_dictionary_load ms=${SystemClock.elapsedRealtime() - t0} lemmas=${d.lemmaCount}")
            d
          } catch (e: Exception) {
            Log.e(TAG, "dictionary failed to load", e)
            null
          }
        }.also { loading = it }
      }

  val onlineConfigured: Boolean
    get() = BuildConfig.ANTHROPIC_API_KEY.isNotBlank()

  fun create(context: Context): AskAboutText {
    val app = context.applicationContext
    val dict = dictionary(app)
    val previous = AskMemory.load(app)
    val online = if (onlineConfigured) ClaudeAsk(BuildConfig.ANTHROPIC_API_KEY) else null
    Log.i(TAG, "on-device answers; previous session text=${previous?.length ?: 0} chars; online=${online != null}")
    return OnDeviceAsk(dictionary = { dict.await() }, previousSession = { previous }, online = online)
  }
}
