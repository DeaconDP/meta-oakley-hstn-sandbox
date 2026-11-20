// SettingsPrefs - where the settings store keeps its JSON on the phone, and the one-time migration
//
// One SharedPreferences file ("speakup_settings") with one key holding the whole document
// (SetupJson). DataStore would add a dependency and a coroutine hop on every read for a document a
// few kilobytes long that changes a few times a session; a synchronous read at start-up is what
// ToolSpeaker and the book reader need anyway.
//
// Migration map (read once, when the document doesn't exist yet; the old keys are left in place
// but no longer read):
//   tools/speech_rate          -> speech.rate (main rate)
//   book_reader/speech_rate    -> speech.tools.book.rate, only if it differs from the main rate
//   book_reader/read_furniture -> speech.tools.book.pageNumbers
//   book_reader/auto_turn      -> speech.tools.book.autoTurn
//   tools/watch_tick_seconds   -> sounds.watchTickSeconds
// The bookmark (book_reader/bookmark) and the setup-flow prefs stay where they are.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import android.content.Context
import android.content.SharedPreferences

class SettingsPrefs(context: Context) : SetupStorage {
  private val app = context.applicationContext
  private val prefs: SharedPreferences = app.getSharedPreferences(FILE, Context.MODE_PRIVATE)

  override fun read(): String? = prefs.getString(KEY, null)

  override fun write(json: String) {
    prefs.edit().putString(KEY, json).apply()
  }

  /** Device-only switches that are never exported (the experimental audio bus). */
  var audioBus: Boolean
    get() = prefs.getBoolean(KEY_BUS, false)
    set(v) {
      prefs.edit().putBoolean(KEY_BUS, v).apply()
    }

  /** The values kept before the store, or null on a fresh install. */
  fun oldPrefs(): OldPrefs? {
    val tools = app.getSharedPreferences("tools", Context.MODE_PRIVATE)
    val book = app.getSharedPreferences("book_reader", Context.MODE_PRIVATE)
    val any =
        tools.contains("speech_rate") || tools.contains("watch_tick_seconds") || book.contains("speech_rate") ||
            book.contains("read_furniture") || book.contains("auto_turn")
    if (!any) return null
    return OldPrefs(
        toolsRate = if (tools.contains("speech_rate")) tools.getFloat("speech_rate", 1f) else null,
        bookRate = if (book.contains("speech_rate")) book.getFloat("speech_rate", 1f) else null,
        pageNumbers = if (book.contains("read_furniture")) book.getBoolean("read_furniture", false) else null,
        autoTurn = if (book.contains("auto_turn")) book.getBoolean("auto_turn", true) else null,
        watchTickSeconds = if (tools.contains("watch_tick_seconds")) tools.getInt("watch_tick_seconds", 10) else null,
    )
  }

  companion object {
    const val FILE = "speakup_settings"
    const val KEY = "setup_json"
    const val KEY_BUS = "audio_bus"

    @Volatile private var shared: SettingsStore? = null
    @Volatile private var sharedPrefs: SettingsPrefs? = null

    /** The one store for the app process (ToolHub, the book reader and the screen share it). */
    fun store(context: Context): SettingsStore =
        shared ?: synchronized(this) {
          shared ?: SettingsPrefs(context).let { p ->
            sharedPrefs = p
            SettingsStore(p) { p.oldPrefs() }.also { shared = it }
          }
        }

    fun prefs(context: Context): SettingsPrefs {
      store(context)
      return sharedPrefs!!
    }

    /** Tests: forget the in-memory store so the next [store] call reads the prefs again. */
    fun resetForTests() {
      synchronized(this) {
        shared = null
        sharedPrefs = null
      }
    }
  }
}
