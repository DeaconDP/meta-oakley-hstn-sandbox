// CameraSourceSelector - the PageCamera the tools see, forwarding to the glasses or the phone
//
// notes/phone-camera.md. ToolHub owns one; tools use it as `hub.camera` and don't know which camera
// is behind it. The source comes from CameraSourceRules: the saved setting (AUTO, PHONE, GLASSES),
// whether the app is registered with Meta AI, and a runtime override (a voice switch, or AUTO
// falling back to the phone when the glasses didn't come up). Flows (isStreaming, link, motion,
// frames) follow the switch, so a tool collecting frames keeps going on the new camera; stills go
// to whichever camera is in use when asked. Starting and stopping the cameras is ToolHub's job.
//
// No Android types beyond the PageCamera signature: JVM-tested with fake cameras (CameraSourceTest).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.graphics.Bitmap
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSource
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceRules
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.CameraSourceSetting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

@OptIn(ExperimentalCoroutinesApi::class)
class CameraSourceSelector(
    scope: CoroutineScope,
    /** The glasses (CameraViewModel), which is also the GlassesLink. */
    val glasses: PageCamera,
    val phone: PageCamera,
    private val setting: StateFlow<CameraSourceSetting>,
    private val registered: StateFlow<Boolean>,
) : PageCamera {

  /** How waiting for the camera ended. */
  enum class Outcome {
    /** Streaming. */
    UP,
    /** The glasses didn't come up and AUTO switched to the phone (start it and say so). */
    FELL_BACK,
    /** Not streaming, and nothing to fall back to (explain why). */
    DOWN,
  }

  private val override = MutableStateFlow<CameraSource?>(null)

  /** The voice switch or fallback in force, or null when the setting decides. */
  val runtimeOverride: CameraSource?
    get() = override.value

  /** True once AUTO has fallen back to the phone this run. */
  var fellBack = false
    private set

  /** The camera in use. */
  val source: StateFlow<CameraSource> =
      combine(setting, registered, override) { s, r, o -> CameraSourceRules.resolve(s, r, o) }
          .stateIn(scope, SharingStarted.Eagerly, CameraSourceRules.resolve(setting.value, registered.value, null))

  /** The glasses-only half (session, permission-aware connect), or null in tests. */
  val glassesLink: GlassesLink?
    get() = glasses as? GlassesLink

  val usingPhone: Boolean
    get() = source.value == CameraSource.PHONE

  /** The DAT session for on-glasses speech and the display card: none while on the phone. */
  val deviceSession
    get() = if (usingPhone) null else glassesLink?.deviceSession

  fun camera(of: CameraSource): PageCamera = if (of == CameraSource.PHONE) phone else glasses

  val current: PageCamera
    get() = camera(source.value)

  override val isStreaming: StateFlow<Boolean> =
      source.flatMapLatest { camera(it).isStreaming }
          .stateIn(scope, SharingStarted.Eagerly, camera(source.value).isStreaming.value)

  override val link: StateFlow<CameraLink> =
      source.flatMapLatest { camera(it).link }
          .stateIn(scope, SharingStarted.Eagerly, camera(source.value).link.value)

  override val motion: Flow<Float> = source.flatMapLatest { camera(it).motion }

  override fun frames(maxFps: Float): Flow<Bitmap> = source.flatMapLatest { camera(it).frames(maxFps) }

  override suspend fun capturePage(): Bitmap? = current.capturePage()

  override suspend fun latestFrame(maxAgeMs: Long, timeoutMs: Long): Bitmap? =
      current.latestFrame(maxAgeMs, timeoutMs)

  private var exposureLocked = false

  override fun lockExposure(locked: Boolean) {
    exposureLocked = locked
    current.lockExposure(locked)
  }

  init {
    // The saved setting changed (settings menu): it wins over any voice switch.
    scope.launch { setting.drop(1).collect { override.value = null; fellBack = false } }
    // An exposure lock moves with the source.
    scope.launch {
      var before = source.value
      source.drop(1).collect { now ->
        if (now != before && exposureLocked) {
          camera(before).lockExposure(false)
          camera(now).lockExposure(true)
        }
        before = now
      }
    }
  }

  /** "Use the phone" / "use the glasses": until the next switch, setting change or run. */
  fun use(target: CameraSource) {
    override.value = target
    if (target == CameraSource.GLASSES) fellBack = false
  }

  /**
   * Waits up to [timeoutMs] for the camera in use to stream. If it's the glasses under AUTO and they
   * don't come up, switches to the phone (FELL_BACK); the caller starts it and says so.
   */
  suspend fun awaitStreaming(timeoutMs: Long): Outcome {
    val up = withTimeoutOrNull(timeoutMs) { isStreaming.first { it } }
    if (up == true) return Outcome.UP
    val fallBack =
        CameraSourceRules.fallBackToPhone(setting.value, override.value, source.value, glasses.isStreaming.value)
    if (!fallBack) return Outcome.DOWN
    fellBack = true
    override.value = CameraSource.PHONE
    return Outcome.FELL_BACK
  }
}
