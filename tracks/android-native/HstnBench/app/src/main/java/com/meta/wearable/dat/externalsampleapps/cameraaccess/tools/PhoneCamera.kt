// PhoneCamera - the phone's back camera as a PageCamera (CameraX), so SpeakUp works without glasses
//
// notes/phone-camera.md. Three CameraX use cases on the back camera:
//   Preview       the camera screen's PreviewView, when one is attached (setSurfaceProvider);
//   ImageAnalysis YUV frames at about 960x720, KEEP_ONLY_LATEST. Every frame is averaged into a
//                 32x24 luma grid (FrameDifferenceMotion -> motion, and the mean brightness for the
//                 "torch on" hint). Only while someone collects frames() is a frame also turned
//                 into an upright ARGB Bitmap, at the highest rate asked for;
//   ImageCapture  stills for OCR, about 1920x1440 or more (the glasses give 960x1440).
// It binds to its own lifecycle, which is RESUMED only while the camera is wanted (start) and the
// host (the activity) is started: Android closes the camera in the background anyway, and coming
// back reopens it with no help. `link` goes DISCONNECTED -> CONNECTING -> STREAMING on the first
// frame; there is no session, no Meta AI and no Bluetooth. Camera permission is asked by ToolHub
// (it says why first); start() without it reports CAMERA_DENIED.
//
// Main thread for start/stop/attach; frames are analysed on a single background thread.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CaptureRequest
import android.os.SystemClock
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.lifecycle.awaitInstance
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.Observer
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FrameDifferenceMotion
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.PhoneCameraProblem
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

class PhoneCamera(context: Context, private val scope: CoroutineScope) : PageCamera, LifecycleOwner {

  companion object {
    private const val TAG = "PhoneCamera"
    /** Analysis frames: enough for continuous tools, cheap to average. Landscape sensor size. */
    private val ANALYSIS_SIZE = Size(960, 720)
    /** Stills for OCR: at least the glasses' 1440 on the long side; 1920 or more when offered. */
    private val STILL_SIZE = Size(1920, 1440)
    /** Frames handed to tools are scaled to at most this on the long side. */
    private const val FRAME_LONG_SIDE = 1024
    /** Let auto exposure settle before a requested lock takes hold. */
    private const val AE_SETTLE_MS = 1_000L
    private const val GRID_COLS = 32
    private const val GRID_ROWS = 24
    private const val CAPTURE_TIMEOUT_MS = 8_000L
  }

  private val appContext = context.applicationContext
  private val registry = LifecycleRegistry(this).apply { currentState = Lifecycle.State.CREATED }
  override val lifecycle: Lifecycle
    get() = registry

  private val _link = MutableStateFlow(CameraLink.DISCONNECTED)
  override val link: StateFlow<CameraLink> = _link.asStateFlow()
  private val _streaming = MutableStateFlow(false)
  override val isStreaming: StateFlow<Boolean> = _streaming.asStateFlow()

  private val _problem = MutableStateFlow<PhoneCameraProblem?>(null)
  /** Why the camera isn't streaming, when something went wrong (null otherwise). */
  val problem: StateFlow<PhoneCameraProblem?> = _problem.asStateFlow()

  private val _torch = MutableStateFlow(false)
  val torchOn: StateFlow<Boolean> = _torch.asStateFlow()

  private val _meanLuma = MutableStateFlow(-1f)
  /** Mean brightness (0..255) of the newest analysed frame, -1 before the first. */
  val meanLuma: StateFlow<Float> = _meanLuma.asStateFlow()

  /** Wanted (started, not stopped) by ToolHub. */
  var wanted = false
    private set

  /** Wanted, but the app is in the background, so Android has the camera closed. Not a fault. */
  val pausedInBackground: Boolean
    get() = wanted && !hostStarted

  /** The back camera has a flash unit (null until bound). */
  val hasTorch: Boolean?
    get() = camera?.cameraInfo?.hasFlashUnit()

  private var hostLifecycle: Lifecycle? = null
  private val hostObserver = LifecycleEventObserver { _, _ -> updateLifecycle() }
  private val hostStarted: Boolean
    get() = hostLifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true

  private var provider: ProcessCameraProvider? = null
  private var camera: Camera? = null
  private var preview: Preview? = null
  private var analysis: ImageAnalysis? = null
  private var capture: ImageCapture? = null
  private var surfaceProvider: Preview.SurfaceProvider? = null
  private var bindJob: Job? = null
  private val stateObserver = Observer<CameraState> { onCameraState(it) }

  private val analysisExecutor = Executors.newSingleThreadExecutor { Thread(it, "PhoneCameraAnalysis") }
  private val captureExecutor = Executors.newSingleThreadExecutor { Thread(it, "PhoneCameraCapture") }
  private val captureMutex = Mutex()

  // Frames for tools: converted only while demanded, at the highest rate any collector asked for.
  private class TimedFrame(val bitmap: Bitmap, val atMs: Long)

  private val frameDemand = ConcurrentHashMap<Any, Float>()
  private val latest = MutableStateFlow<TimedFrame?>(null)
  @Volatile private var lastConvertAt = 0L
  private val grids =
      MutableSharedFlow<FloatArray>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)

  override val motion: Flow<Float> = flow {
    val m = FrameDifferenceMotion()
    grids.collect { g -> m.onGrid(g)?.let { emit(it) } }
  }

  // Measurements (notes/phone-camera.md).
  private var startedAt = 0L
  @Volatile private var firstFrameLogged = false
  @Volatile var lastCaptureMs = 0L
    private set
  @Volatile var lastConvertMs = 0f
    private set
  @Volatile var analysedFrames = 0
    private set

  private var exposureLockWanted = false
  private var exposureJob: Job? = null

  // MARK: - Host, preview, start and stop (main thread)

  /** The activity's lifecycle: the camera only runs while it's started. */
  fun attachHost(host: Lifecycle) {
    if (hostLifecycle === host) return
    hostLifecycle?.removeObserver(hostObserver)
    hostLifecycle = host
    host.addObserver(hostObserver)
    updateLifecycle()
  }

  fun detachHost(host: Lifecycle) {
    if (hostLifecycle !== host) return
    host.removeObserver(hostObserver)
    hostLifecycle = null
    updateLifecycle()
  }

  /** The camera screen's PreviewView (or null when it goes away). */
  fun setSurfaceProvider(provider: Preview.SurfaceProvider?) {
    surfaceProvider = provider
    preview?.surfaceProvider = provider
  }

  fun hasPermission(): Boolean =
      ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

  /** Camera permission was refused (ToolHub asked). */
  fun reportPermissionRefused(blocked: Boolean) {
    _problem.value = if (blocked) PhoneCameraProblem.PERMISSION_BLOCKED else PhoneCameraProblem.PERMISSION_DENIED
    _link.value = CameraLink.CAMERA_DENIED
    _streaming.value = false
  }

  /** Bring the camera up. Streaming follows within about a second. */
  fun start() {
    if (!hasPermission()) {
      reportPermissionRefused(blocked = false)
      return
    }
    wanted = true
    _problem.value = null
    if (!_streaming.value) _link.value = CameraLink.CONNECTING
    startedAt = SystemClock.elapsedRealtime()
    firstFrameLogged = false
    if (camera == null) bind() else updateLifecycle()
  }

  /** Close the camera (switching to the glasses, "disconnect", leaving the app). */
  fun stop() {
    if (!wanted && camera == null) return
    wanted = false
    if (_torch.value) camera?.cameraControl?.enableTorch(false)
    _torch.value = false
    updateLifecycle()
    _streaming.value = false
    _link.value = CameraLink.DISCONNECTED
    latest.value = null
  }

  /** Torch on or off. Returns false if there's no torch (or no camera yet). */
  fun setTorch(on: Boolean): Boolean {
    val cam = camera ?: return false
    if (!cam.cameraInfo.hasFlashUnit()) return false
    cam.cameraControl.enableTorch(on)
    _torch.value = on
    return true
  }

  @OptIn(ExperimentalCamera2Interop::class)
  override fun lockExposure(locked: Boolean) {
    exposureLockWanted = locked
    exposureJob?.cancel()
    val cam = camera
    if (!locked) {
      cam?.let { Camera2CameraControl.from(it.cameraControl).clearCaptureRequestOptions() }
      return
    }
    exposureJob =
        scope.launch {
          // Let auto exposure find the scene first, then hold it.
          isStreaming.first { it }
          delay(AE_SETTLE_MS)
          val c = camera ?: return@launch
          if (!exposureLockWanted) return@launch
          Camera2CameraControl.from(c.cameraControl)
              .setCaptureRequestOptions(
                  CaptureRequestOptions.Builder()
                      .setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, true)
                      .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, true)
                      .build(),
              )
          Log.i(TAG, "exposure and white balance locked")
        }
  }

  fun release() {
    stop()
    hostLifecycle?.removeObserver(hostObserver)
    hostLifecycle = null
    camera?.cameraInfo?.cameraState?.removeObserver(stateObserver)
    provider?.let { p -> listOfNotNull(preview, analysis, capture).forEach { runCatching { p.unbind(it) } } }
    camera = null
    if (registry.currentState != Lifecycle.State.INITIALIZED) registry.currentState = Lifecycle.State.DESTROYED
    analysisExecutor.shutdown()
    captureExecutor.shutdown()
  }

  private fun updateLifecycle() {
    if (registry.currentState == Lifecycle.State.DESTROYED) return
    val target = if (wanted && hostStarted) Lifecycle.State.RESUMED else Lifecycle.State.CREATED
    if (registry.currentState != target) registry.currentState = target
    if (target == Lifecycle.State.CREATED) {
      _streaming.value = false
      if (wanted && _problem.value == null) _link.value = CameraLink.CONNECTING
    }
  }

  private fun bind() {
    if (bindJob?.isActive == true) return
    bindJob =
        scope.launch {
          try {
            val p = provider ?: ProcessCameraProvider.awaitInstance(appContext).also { provider = it }
            val selector = CameraSelector.DEFAULT_BACK_CAMERA
            if (!p.hasCamera(selector)) {
              fail(PhoneCameraProblem.NO_CAMERA, "no back camera")
              return@launch
            }
            val cam = bindUseCases(p, selector) ?: return@launch
            camera = cam
            cam.cameraInfo.cameraState.observeForever(stateObserver)
            Log.i(TAG, "bound: preview=${preview != null} capture=${capture != null} torch=${cam.cameraInfo.hasFlashUnit()}")
            if (exposureLockWanted) lockExposure(true)
            updateLifecycle()
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            Log.e(TAG, "bind failed", e)
            fail(PhoneCameraProblem.FAILED, "bind failed: ${e.message}")
          }
        }
  }

  /** All three use cases if the camera can take them, else without the preview, else analysis only. */
  private fun bindUseCases(p: ProcessCameraProvider, selector: CameraSelector): Camera? {
    val fourThree =
        AspectRatioStrategy(androidx.camera.core.AspectRatio.RATIO_4_3, AspectRatioStrategy.FALLBACK_RULE_AUTO)
    fun sized(size: Size) =
        ResolutionSelector.Builder()
            .setAspectRatioStrategy(fourThree)
            .setResolutionStrategy(ResolutionStrategy(size, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
            .build()
    val a =
        ImageAnalysis.Builder()
            .setResolutionSelector(sized(ANALYSIS_SIZE))
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setTargetRotation(Surface.ROTATION_0)
            .build()
            .also { it.setAnalyzer(analysisExecutor, ::analyze) }
    val c =
        ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .setResolutionSelector(sized(STILL_SIZE))
            .setTargetRotation(Surface.ROTATION_0)
            .build()
    val pv =
        Preview.Builder()
            .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(fourThree).build())
            .setTargetRotation(Surface.ROTATION_0)
            .build()
            .also { it.surfaceProvider = surfaceProvider }
    val attempts: List<List<UseCase>> = listOf(listOf(pv, a, c), listOf(a, c), listOf(a))
    for (cases in attempts) {
      try {
        val cam = p.bindToLifecycle(this, selector, *cases.toTypedArray())
        analysis = a
        capture = c.takeIf { it in cases }
        preview = pv.takeIf { it in cases }
        return cam
      } catch (e: IllegalArgumentException) {
        Log.w(TAG, "can't bind ${cases.size} use cases: ${e.message}")
        p.unbind(*cases.toTypedArray())
      }
    }
    fail(PhoneCameraProblem.FAILED, "no use case combination binds")
    return null
  }

  private fun fail(problem: PhoneCameraProblem, why: String) {
    Log.w(TAG, "problem=$problem ($why)")
    _problem.value = problem
    _streaming.value = false
    _link.value = CameraLink.DISCONNECTED
  }

  private fun onCameraState(state: CameraState) {
    val error = state.error
    Log.i(TAG, "camera state=${state.type} error=${error?.code}")
    if (error != null) {
      val problem =
          when (error.code) {
            CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE -> PhoneCameraProblem.IN_USE
            CameraState.ERROR_CAMERA_DISABLED -> PhoneCameraProblem.NO_CAMERA
            else -> PhoneCameraProblem.FAILED
          }
      // Recoverable errors while opening clear themselves; say nothing unless it stays closed.
      if (state.type == CameraState.Type.CLOSED || state.type == CameraState.Type.PENDING_OPEN ||
          error.type == CameraState.ErrorType.CRITICAL) {
        if (wanted) fail(problem, "camera error ${error.code}")
      }
      return
    }
    when (state.type) {
      CameraState.Type.OPEN -> if (_problem.value != null) _problem.value = null
      CameraState.Type.CLOSING, CameraState.Type.CLOSED -> _streaming.value = false
      else -> Unit
    }
  }

  // MARK: - Analysis (background thread)

  private fun analyze(image: ImageProxy) {
    try {
      val y = image.planes[0]
      val buffer = y.buffer
      val stride = y.rowStride
      val grid =
          FrameDifferenceMotion.lumaGrid(
              luma = { i -> buffer.get(i).toInt() and 0xFF },
              width = image.width,
              height = image.height,
              rowStride = stride,
              cols = GRID_COLS,
              rows = GRID_ROWS,
          )
      grids.tryEmit(grid)
      _meanLuma.value = grid.average().toFloat()
      analysedFrames++
      if (!firstFrameLogged) {
        firstFrameLogged = true
        Log.i(TAG, "first frame ${SystemClock.elapsedRealtime() - startedAt} ms after start, ${image.width}x${image.height} rot=${image.imageInfo.rotationDegrees}")
      }
      if (wanted && !_streaming.value) {
        _streaming.value = true
        _link.value = CameraLink.STREAMING
        _problem.value = null
      }
      val fps = frameDemand.values.maxOrNull()
      val now = SystemClock.elapsedRealtime()
      if (fps != null && now - lastConvertAt >= (1000f / fps.coerceIn(0.1f, 30f)).toLong()) {
        lastConvertAt = now
        val t0 = System.nanoTime()
        val bmp = upright(image.toBitmap(), image.imageInfo.rotationDegrees, FRAME_LONG_SIDE)
        lastConvertMs = (System.nanoTime() - t0) / 1e6f
        latest.value = TimedFrame(bmp, now)
      }
    } catch (e: Exception) {
      Log.w(TAG, "analyse failed", e)
    } finally {
      image.close()
    }
  }

  /** Rotates to upright and scales so the long side is at most [maxLong] (0 = no limit). */
  private fun upright(src: Bitmap, rotation: Int, maxLong: Int): Bitmap {
    val long = maxOf(src.width, src.height)
    val scale = if (maxLong > 0 && long > maxLong) maxLong.toFloat() / long else 1f
    if (rotation == 0 && scale == 1f) return src
    val m = Matrix().apply {
      if (scale != 1f) postScale(scale, scale)
      if (rotation != 0) postRotate(rotation.toFloat())
    }
    return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true).also { if (it !== src) src.recycle() }
  }

  // MARK: - PageCamera

  override suspend fun capturePage(): Bitmap? =
      captureMutex.withLock {
        if (!_streaming.value) return@withLock null
        val c = capture ?: return@withLock latestFrame(maxAgeMs = 0L, timeoutMs = 2_000L)
        val t0 = SystemClock.elapsedRealtime()
        // A camera service that died never calls back: give up rather than hang the tool.
        val bmp =
            withTimeoutOrNull(CAPTURE_TIMEOUT_MS) {
            suspendCancellableCoroutine<Bitmap?> { cont ->
              c.takePicture(
                  captureExecutor,
                  object : ImageCapture.OnImageCapturedCallback() {
                    override fun onCaptureSuccess(image: ImageProxy) {
                      val out =
                          try {
                            upright(image.toBitmap(), image.imageInfo.rotationDegrees, 0)
                          } catch (e: Exception) {
                            Log.w(TAG, "still decode failed", e)
                            null
                          } finally {
                            image.close()
                          }
                      if (cont.isActive) cont.resume(out)
                    }

                    override fun onError(exception: ImageCaptureException) {
                      Log.w(TAG, "still failed: ${exception.imageCaptureError} ${exception.message}")
                      if (cont.isActive) cont.resume(null)
                    }
                  },
              )
            }
            }
        lastCaptureMs = SystemClock.elapsedRealtime() - t0
        Log.i(TAG, "capture ${lastCaptureMs} ms size=${bmp?.width}x${bmp?.height}")
        bmp
      }

  override fun frames(maxFps: Float): Flow<Bitmap> = channelFlow {
    val token = Any()
    val gapMs = (1000f / maxFps.coerceIn(0.1f, 30f)).toLong()
    frameDemand[token] = maxFps
    try {
      var lastSent = 0L
      latest.collect { f ->
        if (f != null && f.atMs > lastSent && f.atMs - lastSent >= gapMs * 9 / 10) {
          lastSent = f.atMs
          send(f.bitmap)
        }
      }
    } finally {
      frameDemand.remove(token)
    }
  }

  override suspend fun latestFrame(maxAgeMs: Long, timeoutMs: Long): Bitmap? {
    if (!_streaming.value) return null
    val now = SystemClock.elapsedRealtime()
    latest.value?.takeIf { now - it.atMs <= maxAgeMs }?.let { return it.bitmap }
    val token = Any()
    frameDemand[token] = 5f
    try {
      withTimeoutOrNull(timeoutMs) { latest.filterNotNull().first { it.atMs > now } }?.let { return it.bitmap }
    } finally {
      frameDemand.remove(token)
    }
    return if (capture != null && !captureMutex.isLocked) capturePage() else null
  }
}
