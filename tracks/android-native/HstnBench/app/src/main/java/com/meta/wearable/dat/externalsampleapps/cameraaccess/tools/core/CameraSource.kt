// CameraSource - which camera the tools look through, and what the phone camera says
//
// notes/phone-camera.md. SpeakUp runs on the phone alone; glasses are an upgrade. The saved setting
// (HandsFreeStore) is AUTO, PHONE or GLASSES. AUTO means the glasses when the app is registered with
// Meta AI, else the phone; if the glasses don't come up within the link wait, AUTO falls back to the
// phone for the rest of the run ("Glasses not connected. Using the phone camera."). A voice switch
// ("use the phone", "use the glasses") overrides the setting until the next switch or the next run.
//
// Also here: what the phone camera says when something is wrong (PhoneCameraWording, pinned by
// JVM tests like AskWording), and DarkWatch, which suggests "torch on" once when the phone sees
// only darkness. Pure Kotlin, JVM-tested (CameraSourceTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core

/** Where frames come from right now. */
enum class CameraSource {
  PHONE,
  GLASSES;

  companion object {
    fun fromName(name: String?): CameraSource? = entries.firstOrNull { it.name == name }
  }
}

/** The saved choice. */
enum class CameraSourceSetting {
  AUTO,
  PHONE,
  GLASSES;

  companion object {
    fun fromName(name: String?): CameraSourceSetting = entries.firstOrNull { it.name == name } ?: AUTO
  }
}

object CameraSourceRules {

  /** The source for [setting] with no voice switch: AUTO follows registration. */
  fun base(setting: CameraSourceSetting, registered: Boolean): CameraSource =
      when (setting) {
        CameraSourceSetting.PHONE -> CameraSource.PHONE
        CameraSourceSetting.GLASSES -> CameraSource.GLASSES
        CameraSourceSetting.AUTO -> if (registered) CameraSource.GLASSES else CameraSource.PHONE
      }

  /**
   * The source in use. [override] is a voice switch or the AUTO fallback. The glasses can't be used
   * before registration unless the setting insists on them (then setup explains what to do).
   */
  fun resolve(setting: CameraSourceSetting, registered: Boolean, override: CameraSource?): CameraSource {
    val wanted = override ?: base(setting, registered)
    return if (wanted == CameraSource.GLASSES && !registered && setting != CameraSourceSetting.GLASSES) {
      CameraSource.PHONE
    } else {
      wanted
    }
  }

  /**
   * The glasses didn't stream within the link wait: fall back to the phone? Only for AUTO with no
   * voice switch: "use the glasses" or the GLASSES setting means the user wants the glasses, so the
   * app says why they can't be reached instead.
   */
  fun fallBackToPhone(
      setting: CameraSourceSetting,
      override: CameraSource?,
      current: CameraSource,
      glassesStreaming: Boolean,
  ): Boolean =
      setting == CameraSourceSetting.AUTO &&
          override == null &&
          current == CameraSource.GLASSES &&
          !glassesStreaming

  /**
   * The setup screen (Meta AI registration) shows only while the user still has to choose: not
   * registered, and neither the phone setting nor "use my phone" on the setup screen.
   */
  fun showSetup(registered: Boolean, setting: CameraSourceSetting, phoneChosen: Boolean): Boolean =
      !registered &&
          when (setting) {
            CameraSourceSetting.PHONE -> false
            CameraSourceSetting.GLASSES -> true
            CameraSourceSetting.AUTO -> !phoneChosen
          }

  /**
   * Ask for Nearby devices (Bluetooth) at launch? Only on the glasses path: the GLASSES setting, or
   * the user asked to connect glasses. A first run asks only for the microphone, so choosing the
   * phone never meets a Bluetooth dialog. (Registered users granted it when they registered.)
   */
  fun needsBluetooth(setting: CameraSourceSetting, connectAsked: Boolean): Boolean =
      connectAsked || setting == CameraSourceSetting.GLASSES
}

/** What can stop the phone camera. */
enum class PhoneCameraProblem {
  /** Camera permission refused; Android can still ask. */
  PERMISSION_DENIED,
  /** Refused and Android won't ask again: only Settings can fix it. */
  PERMISSION_BLOCKED,
  /** Another app has the camera. */
  IN_USE,
  /** No back camera (or the camera is disabled by policy). */
  NO_CAMERA,
  /** It opened and then failed. */
  FAILED,
}

/** Everything the phone camera path says. Kotlin, not strings.xml, so JVM tests pin it. */
object PhoneCameraWording {
  const val USING_PHONE = "Using the phone camera."
  const val USING_GLASSES = "Using the glasses."
  const val ALREADY_PHONE = "Already using the phone camera."
  const val ALREADY_GLASSES = "Already using the glasses."
  const val FELL_BACK = "Glasses not connected. Using the phone camera."
  const val GLASSES_NOT_SET_UP =
      "Your glasses aren't set up with SpeakUp yet. Say connect my glasses to set them up, or keep using the phone."
  const val OPENING_META_AI = "Opening Meta AI to connect your glasses. Approve it there, then come back."
  const val HOLD_HINT = "Hold the phone about 30 centimetres above the page."
  const val CAMERA_ON = "Camera on."
  const val PHONE_ON_SAY_GLASSES = "The phone camera is on. Say use the glasses to switch."
  const val CAMERA_OFF = "Camera off. Say connect to turn it back on."
  const val ALREADY_OFF = "The camera is already off."
  const val CAMERA_BACK = "The camera is back."
  const val ASK_PERMISSION = "Android will ask to use the camera, so I can see for you. Choose Allow."
  const val TOO_DARK = "It's very dark. Say torch on to use the phone's light."
  const val TORCH_ON = "Torch on."
  const val TORCH_OFF = "Torch off."
  const val NO_TORCH = "This phone has no torch."
  const val TORCH_GLASSES = "The torch is on the phone camera. Say use the phone first."

  /**
   * The phone camera came up for a tool launched or reconnected by voice (in place of "Your glasses
   * are ready."). Reading tools add where to hold the phone.
   */
  fun ready(tool: ToolId?): String =
      when (tool) {
        ToolId.BOOK, ToolId.MAIL -> "Phone camera on. $HOLD_HINT Say help at any time."
        null -> CAMERA_ON
        else -> "Phone camera on. Say help at any time."
      }

  /** The camera part of "settings". */
  fun setting(setting: CameraSourceSetting, current: CameraSource): String {
    val now = if (current == CameraSource.PHONE) "the phone" else "the glasses"
    return when (setting) {
      CameraSourceSetting.AUTO -> "Camera: automatic, using $now."
      CameraSourceSetting.PHONE -> "Camera: phone" + (if (current == CameraSource.PHONE) "." else ", using the glasses for now.")
      CameraSourceSetting.GLASSES -> "Camera: glasses" + (if (current == CameraSource.GLASSES) "." else ", using the phone for now.")
    }
  }

  /** "which camera". */
  fun which(source: CameraSource, streaming: Boolean): String =
      when (source) {
        CameraSource.PHONE -> if (streaming) "Using the phone camera. It's on." else "Using the phone camera. It's off."
        CameraSource.GLASSES -> if (streaming) "Using the glasses camera. It's on." else "Using the glasses. They're not connected yet."
      }

  /** One sentence for the status report. */
  fun connection(streaming: Boolean): String =
      if (streaming) "Phone camera on." else "Phone camera off. Say connect to turn it on."

  /** The most specific reason the phone camera isn't streaming. */
  fun problem(problem: PhoneCameraProblem?): String =
      when (problem) {
        PhoneCameraProblem.PERMISSION_DENIED ->
            "Camera access wasn't allowed, so I can't see anything. Say use the phone to be asked again."
        PhoneCameraProblem.PERMISSION_BLOCKED ->
            "Camera access is off for SpeakUp, and Android won't ask again. Open Android Settings, Apps, SpeakUp, Permissions, Camera, and choose Allow."
        PhoneCameraProblem.IN_USE ->
            "Another app is using the camera. Close it, then say use the phone."
        PhoneCameraProblem.NO_CAMERA ->
            "I can't find a camera I can use on this phone."
        PhoneCameraProblem.FAILED ->
            "The phone camera stopped. Say use the phone to start it again."
        null -> "The phone camera isn't on. Say use the phone to start it."
      }
}

/**
 * Suggests "torch on" once when the phone has seen only darkness for [holdMs]. Fed the mean luma
 * (0..255) of each analysed frame. Re-arms after a bright spell, a torch change or [reset].
 */
class DarkWatch(
    private val darkLuma: Float = 18f,
    private val brightLuma: Float = 40f,
    private val holdMs: Long = 3_000L,
) {
  private var darkSince: Long? = null
  private var said = false

  /** True when the suggestion should be spoken now (at most once until re-armed). */
  fun update(meanLuma: Float, nowMs: Long, torchOn: Boolean): Boolean {
    if (torchOn) {
      darkSince = null
      return false
    }
    if (meanLuma >= brightLuma) {
      darkSince = null
      said = false
      return false
    }
    if (meanLuma > darkLuma) {
      darkSince = null
      return false
    }
    val since = darkSince ?: nowMs.also { darkSince = it }
    if (!said && nowMs - since >= holdMs) {
      said = true
      return true
    }
    return false
  }

  fun reset() {
    darkSince = null
    said = false
  }
}
