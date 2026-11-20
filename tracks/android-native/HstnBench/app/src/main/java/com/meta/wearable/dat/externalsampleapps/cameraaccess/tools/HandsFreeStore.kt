// HandsFreeStore - the one persisted, observable mode setting (and the settings hands-free changes)
//
// Also the camera source (AUTO / PHONE / GLASSES) and whether the setup screen's "use my phone" was
// chosen (notes/phone-camera.md).
//
// notes/hands-free-mode.md. One per process (the setup screen, the camera screen and MainActivity
// share it). `handsFree` defaults to false: SpeakUp is a toolbox unless the user turns hands-free on
// (switch, voice, speakup://handsfree, the "Hands-free" shortcut, `--ez handsfree true`), or TalkBack
// was running on first run (HandsFreeRules.firstRun), which is announced once.
//
// Its own preferences file ("mode"), so tests that clear the tools' preferences don't reset it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceSetting
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.FirstRun
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreePolicy
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.HandsFreeRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ModeSettings
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Verbosity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

class HandsFreeStore private constructor(context: Context) {

  companion object {
    private const val TAG = "HandsFree"
    const val PREFS = "mode"
    private const val KEY_HANDS_FREE = "hands_free"
    private const val KEY_DISPLAY = "glasses_display"
    private const val KEY_VERBOSITY = "verbosity"
    private const val KEY_CAMERA_SOURCE = "camera_source"
    private const val KEY_PHONE_CHOSEN = "phone_chosen"

    @Volatile private var instance: HandsFreeStore? = null

    fun get(context: Context): HandsFreeStore =
        instance ?: synchronized(this) { instance ?: HandsFreeStore(context.applicationContext).also { instance = it } }
  }

  private val prefs: SharedPreferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private val _settings =
      MutableStateFlow(
          ModeSettings(
              handsFree = prefs.getBoolean(KEY_HANDS_FREE, false),
              glassesDisplay = prefs.getBoolean(KEY_DISPLAY, true),
              verbosity = Verbosity.fromName(prefs.getString(KEY_VERBOSITY, null)),
              cameraSource = CameraSourceSetting.fromName(prefs.getString(KEY_CAMERA_SOURCE, null)),
              phoneChosen = prefs.getBoolean(KEY_PHONE_CHOSEN, false),
          ),
      )
  val settings: StateFlow<ModeSettings> = _settings.asStateFlow()

  private val _announcement = MutableStateFlow(false)

  /** True until someone has said "Hands-free is on. Say hands-free off for touch only." */
  val announcementPending: StateFlow<Boolean> = _announcement.asStateFlow()

  val handsFree: Boolean
    get() = _settings.value.handsFree

  val policy: HandsFreePolicy
    get() = HandsFreePolicy(handsFree)

  /**
   * Call once per launch before anything speaks. On the very first run, a running screen reader
   * turns hands-free on and queues the one-time announcement.
   */
  fun firstRun(screenReaderOn: Boolean): FirstRun {
    val stored = if (prefs.contains(KEY_HANDS_FREE)) prefs.getBoolean(KEY_HANDS_FREE, false) else null
    val result = HandsFreeRules.firstRun(stored, screenReaderOn)
    if (stored == null) {
      Log.i(TAG, "first run: screenReader=$screenReaderOn handsFree=${result.handsFree}")
      write(result.handsFree)
      if (result.announce) _announcement.value = true
    }
    return result
  }

  /** Switches the mode. Returns true if it changed. */
  fun setHandsFree(on: Boolean): Boolean {
    val changed = handsFree != on
    write(on)
    if (!on) _announcement.value = false
    return changed
  }

  /** A launch switched hands-free on: say so once, as on the first run. */
  fun queueAnnouncement() {
    _announcement.value = true
  }

  /** Takes the one-time first-run announcement (true once). */
  fun takeAnnouncement(): Boolean {
    if (!_announcement.value) return false
    _announcement.value = false
    return true
  }

  fun setGlassesDisplay(on: Boolean) {
    prefs.edit().putBoolean(KEY_DISPLAY, on).apply()
    _settings.update { it.copy(glassesDisplay = on) }
  }

  fun setVerbosity(v: Verbosity) {
    prefs.edit().putString(KEY_VERBOSITY, v.name).apply()
    _settings.update { it.copy(verbosity = v) }
  }

  /** The saved camera choice (settings menu): AUTO, PHONE or GLASSES. */
  fun setCameraSource(setting: CameraSourceSetting) {
    prefs.edit().putString(KEY_CAMERA_SOURCE, setting.name).commit()
    _settings.update { it.copy(cameraSource = setting) }
  }

  /** "Use my phone's camera" on the setup screen (true), or back to choosing (false, tests). */
  fun setPhoneChosen(chosen: Boolean) {
    // commit: the scaffold reads it at once to leave the setup screen.
    prefs.edit().putBoolean(KEY_PHONE_CHOSEN, chosen).commit()
    _settings.update { it.copy(phoneChosen = chosen) }
  }

  private fun write(on: Boolean) {
    // commit: a launch that switches it on is followed at once by the screens reading it.
    prefs.edit().putBoolean(KEY_HANDS_FREE, on).commit()
    _settings.update { it.copy(handsFree = on) }
  }
}
