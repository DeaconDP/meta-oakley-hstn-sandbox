/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import MWDATCamera
import MWDATCore
import Observation
import SwiftUI
import UIKit

extension TimeInterval {
  /// Formats a duration as `mm:ss`.
  var formattedRecordingTime: String {
    let minutes = Int(self) / 60
    let seconds = Int(self) % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

/// A capture awaiting preview/share — a still photo or a recorded video file.
/// Drives a single `.sheet(item:)` so photo and video share one presentation.
enum CapturePreview: Identifiable {
  case photo(UIImage)
  case video(URL)

  var id: String {
    switch self {
    case .photo: return "photo"
    case .video(let url): return "video:\(url.absoluteString)"
    }
  }
}

/// Drives the camera screen by exercising the SDK's camera lifecycle as explicit
/// steps: create/start a `DeviceSession`, add and start a `Stream`, capture or
/// record, stop the stream, end the session. Owns the screen-scoped pieces —
/// active-device monitoring, the `DeviceSession`, and its `Stream`. The UI binds to
/// the SDK's own `DeviceSessionState` / `StreamState` so the sample shows the real
/// state machine.
@Observable
@MainActor
final class CameraViewModel {
  // MARK: - Device

  /// Whether an eligible device is currently active. Drives the "Put on your
  /// glasses" placeholder. Sourced from the auto device selector.
  private(set) var hasActiveDevice: Bool = false

  /// Physical state of the active glasses (DAT `DeviceState`), for the spoken status line and the
  /// "removed / folded / battery" announcements. Battery is nil until the glasses report it.
  private(set) var batteryLevel: Int?
  private(set) var donState: DonState = .unknown
  private(set) var hingeState: HingeState = .unknown
  /// Last known camera permission (a query, never a redirect). nil until checked.
  private(set) var cameraPermission: PermissionStatus?
  /// The device stream has reported at least once, so `hasActiveDevice` is real, not the
  /// initial false. Spoken status and launch actions wait for this.
  private(set) var hasDeviceReport: Bool = false

  // MARK: - Session state (bound directly to the SDK)

  /// The device session's state, mirrored from `DeviceSession.statePublisher`.
  /// `.idle`/`.stopped` mean no live session.
  var sessionState: DeviceSessionState = .idle

  // MARK: - Preview

  /// The latest decoded preview frame. Read only by the isolated `LivePreviewView`
  /// so the ~24fps updates don't re-render the whole screen.
  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false

  /// The stream's state, mirrored from `Stream.statePublisher`. `.stopped` means
  /// no live stream.
  var streamState: StreamState = .stopped

  // MARK: - Capture preview

  /// The capture currently shown in the preview/share sheet (photo or video).
  var activePreview: CapturePreview?
  var isCapturingPhoto: Bool = false

  // MARK: - Video recording

  var isRecording: Bool = false
  /// Wall-clock start of the active recording (first written frame), mirrored from the
  /// recorder. Drives the isolated `RecordingTimerLabel`'s `TimelineView`, so the timer
  /// counts continuously — including through a stream pause. `nil` when not recording.
  var recordingStartDate: Date?
  /// A stop is finalizing the file. Record stays disabled until it's done, so a new recording
  /// can't start under a recorder (and audio session) that is still being released.
  private(set) var isFinishingRecording: Bool = false
  /// Whether to record the glasses-microphone (Bluetooth HFP) audio into videos
  /// (sound-in-video). Toggled from the mic button shown while streaming.
  var includeAudioInStream: Bool = true
  /// Mic denied — iOS won't re-prompt. Drives the toggle's disabled look + tap-to-Settings.
  /// Still required for glasses audio: iOS gates HFP capture behind mic permission too.
  var micDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

  // MARK: - Errors

  /// Drives the single error alert. Uses the SDK's own `localizedDescription`
  /// rather than an app-maintained error map.
  var showError: Bool = false
  var errorMessage: String = ""
  /// Short alert title and the one next step for the current error (a11y: no generic
  /// "something went wrong", every failure offers one action).
  var errorTitle: String = ""
  var errorAction: CameraErrorAction?

  /// Drives the confirm prompt shown before the camera-permission redirect to the
  /// Meta AI app — surfaced only when permission isn't already granted.
  var showCameraPermissionRedirectConfirm: Bool = false

  // MARK: - Derived session state

  var isSessionStarting: Bool { sessionState == .starting }
  var isSessionActive: Bool { sessionState == .started }
  /// A session exists and is connected (or connecting); a stream can be started.
  var hasSession: Bool {
    switch sessionState {
    case .starting, .started, .paused, .stopping: return true
    case .idle, .stopped: return false
    }
  }

  /// Human-readable session state for the status line.
  var sessionStateText: String { sessionState.description }

  // MARK: - Derived stream state

  var isStreaming: Bool { streamState == .streaming }
  /// A stream is attached (in any non-terminal state).
  var hasStream: Bool { streamState != .stopped }

  /// A session or stream start/stop is in flight. The UI shows a spinner and
  /// disables the controls until the SDK settles on a stable state, so transient
  /// states never need their own controls or labels.
  var isBusy: Bool {
    isSessionStarting || sessionState == .stopping
      || streamState == .starting || streamState == .waitingForDevice || streamState == .stopping
  }

  /// Human-readable stream state for the status line. `StreamState` has no
  /// `description`, so map it here.
  var streamStateText: String {
    switch streamState {
    case .streaming: return "streaming"
    case .starting: return "starting"
    case .waitingForDevice: return "waiting for device"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    case .paused: return "paused"
    }
  }

  /// The stream is paused (device-initiated, e.g. a single cap-touch tap). The
  /// last frame is retained, so the preview can stay on screen frozen.
  var isPaused: Bool { streamState == .paused }

  /// The preview surface (live frames, or the last held frame) should fill the
  /// screen: while streaming, while paused (frozen on the last frame), or while
  /// tearing down with a last frame so the stop loader overlays the preview.
  var showsLivePreview: Bool {
    isStreaming
      || ((streamState == .paused || streamState == .stopping) && currentVideoFrame != nil)
  }

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var isStoppingForBackground: Bool = false
  @ObservationIgnored private var backgroundStopSuppressionTask: Task<Void, Never>?

  @ObservationIgnored private let videoRecorder = VideoRecorder()
  // Decodes compressed hvc1 frames for on-screen preview. Not required for
  // recording — the passthrough writer handles compressed frames directly.
  @ObservationIgnored private let videoFrameDecoder = VideoFrameDecoder()

  // Step-2 benchmark: timings and the spoken reply after each photo.
  @ObservationIgnored private let benchClock = BenchClock.shared
  @ObservationIgnored private let ttsReply = TtsReply()
  /// Set when a stream starts; the first frame to arrive clears it and ends `stream_to_first_frame`.
  @ObservationIgnored private let awaitingFirstFrame = FirstFrameLatch()

  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var appLifecycleTask: Task<Void, Never>?
  @ObservationIgnored private let sessionTokenBag = ListenerTokenBag()
  @ObservationIgnored private let streamTokenBag = ListenerTokenBag()
  @ObservationIgnored private let deviceStateTokenBag = ListenerTokenBag()
  /// Bumped per recording start, so a slow stop of an older recording doesn't release the audio
  /// session while a newer one owns it.
  @ObservationIgnored private var recordingGeneration = 0

  @ObservationIgnored private let photoCaptureFailureMessage =
    "Couldn't capture photo. There may not be enough storage, or another capture is in progress. Try again in a few moments."
  @ObservationIgnored private let backgroundStopErrorSuppressionTimeout: Duration

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    backgroundStopErrorSuppressionTimeout: Duration = .seconds(5)
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.backgroundStopErrorSuppressionTimeout = backgroundStopErrorSuppressionTimeout
    startDeviceMonitoring()
    startAppLifecycleMonitoring()
  }

  isolated deinit {
    deviceMonitorTask?.cancel()
    appLifecycleTask?.cancel()
    backgroundStopSuppressionTask?.cancel()
    deviceSession?.stop()
    // Never leave earcons locked out of the audio session if the screen goes away mid-recording.
    if isRecording { A11yAudioSession.recordingOwnsSession = false }
  }

  // MARK: - Lifecycle step 1: session

  /// Creates and starts a `DeviceSession` (no stream yet). This is the first
  /// explicit step — a session can stay connected with no active stream. The
  /// state observer drives `sessionState`; we only seed an optimistic
  /// `.starting` so the UI reflects the in-flight request immediately.
  func startSession() {
    guard !hasSession else { return }
    benchClock.start("session_start")
    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no initial state transitions are missed.
      observeSession(session)
      // Reflect the in-flight request immediately; the observer drives it onward.
      sessionState = .starting
      try session.start()
    } catch {
      handleSessionError(error)
      sessionState = .idle
      cleanupSession()
    }
  }

  /// Stops the stream (if any) and ends the device session. `stop()` is terminal;
  /// the SDK cascades the stop to the stream and the state observers clean up
  /// when `.stopped` arrives.
  func endSession() {
    guard let session = deviceSession else { return }
    // Reflect the in-flight stop immediately so the controls disable at once; the
    // state observer drives it onward to `.stopped`.
    sessionState = .stopping
    session.stop()
  }

  // MARK: - Lifecycle step 2: stream

  /// Adds a `Stream` to the started session and starts it. Requires a session in
  /// `.started`. Camera permission is checked first (a query, no redirect); if it
  /// isn't already granted, the actual request — which redirects to the Meta AI
  /// app — is deferred to `confirmCameraPermissionRedirect()` so the app-switch is
  /// confirmed, not a surprise.
  func startStreaming() async {
    guard let session = deviceSession, session.state == .started else {
      showError(.plain(SpokenMessage.startSessionFirst, action: hasSession ? nil : .startSession))
      return
    }
    guard camera == nil else { return }

    do {
      let status = try await wearables.checkPermissionStatus(.camera)
      cameraPermission = status
      if status == .granted {
        beginStream(on: session)
      } else {
        showCameraPermissionRedirectConfirm = true
      }
    } catch {
      showError(.permission(error))
    }
  }

  /// Confirmed from the permission prompt: requests camera access — this opens the
  /// Meta AI app and resumes when the user returns — then starts the stream if
  /// access was granted.
  func confirmCameraPermissionRedirect() async {
    showCameraPermissionRedirectConfirm = false
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    do {
      let status = try await wearables.requestPermission(.camera)
      cameraPermission = status
      guard status == .granted else {
        showError(.plain(SpokenMessage.cameraPermissionNotGranted, title: "Camera access not allowed", action: .allowCamera))
        return
      }
    } catch {
      showError(.permission(error))
      return
    }
    // Back from Meta AI: say the result before the camera's own "starting" lines.
    Announcer.shared.announce(SpokenMessage.cameraPermissionGranted, earcon: .done)
    beginStream(on: session)
  }

  /// Creates the camera `Stream` on the started session and starts it. Callers
  /// must have ensured camera permission is granted first.
  private func beginStream(on session: DeviceSession) {
    guard camera == nil else { return }
    // hvc1 (compressed HEVC) so frames can be written to file in passthrough mode.
    // Glasses-mic (Bluetooth HFP) audio for sound-in-video is captured app-side by
    // AudioCaptureHandler, so the SDK stream needs only the public video config (no audio codec).
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      // Add the consolidated `Camera` capability and stream through `camera.stream`.
      benchClock.start("stream_to_first_frame")
      guard let newCamera = try session.addCamera(config: config) else {
        showError(.plain(SpokenMessage.cameraStreamFailed, action: .startPreview))
        return
      }
      camera = newCamera
      awaitingFirstFrame.arm()
      // Subscribe before start() so no initial state transitions are missed.
      setupStreamListeners(for: newCamera.stream)
      // Reflect the in-flight request immediately; the observer drives it onward.
      streamState = .starting
      newCamera.stream.start()
    } catch {
      camera = nil
      showError(.plain(error.localizedDescription, action: .startPreview))
    }
  }

  /// Stops the camera stream but keeps the `DeviceSession` connected, so
  /// streaming can be started again without re-creating the session. The stream
  /// `.stopped` observer performs the teardown — we don't eagerly reset here.
  func stopStreaming() {
    guard let activeCamera = camera else { return }
    videoRecorder.prepareToStop()
    // Reflect the in-flight request immediately; the observer drives it onward.
    streamState = .stopping
    // Stopping the camera cascades to its stream child and detaches the camera from the
    // session, so streaming can be started again with a fresh `addCamera()`.
    activeCamera.stop()
  }

  // MARK: - Capture

  func capturePhoto() {
    // A second press (or Magic Tap) while the first photo is on its way isn't an error.
    if isCapturingPhoto {
      Announcer.shared.say(SpokenMessage.photoInProgress)
      return
    }
    guard !isCapturingPhoto, isStreaming else {
      showError(photoCaptureFailureMessage)
      return
    }
    isCapturingPhoto = true
    // Cut the narrator, so TtsReply's reply isn't spoken over it.
    Announcer.shared.stop()
    // Shutter earcon on the press itself, well inside the 100 ms budget.
    EarconPlayer.shared.play(.capturing)
    benchClock.start("capture_to_photo")
    let success = camera?.stream.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showError(photoCaptureFailureMessage)
    }
  }

  func toggleRecording() {
    if isRecording {
      Task { await stopVideoRecording() }
    } else {
      startVideoRecording()
    }
  }

  func startVideoRecording() {
    guard isStreaming, !isRecording, !isFinishingRecording else { return }
    // Flip the intent flag synchronously so the toggle and UI don't lag the
    // frame-driven recorder; the file starts on the next frame.
    isRecording = true
    recordingGeneration += 1
    // Before the recorder takes the session (play-and-record for the glasses mic), so earcons and
    // speech from here on play into it instead of switching it back to playback.
    A11yAudioSession.recordingOwnsSession = true
    // If the glasses mic isn't available, flip the mic off so the button reflects that this
    // recording is video-only (the phone mic is never used). Left off afterward — the user can
    // re-tap the mic to turn it back on.
    videoRecorder.prepareToStart(includeAudio: includeAudioInStream) { [weak self] in
      Task { @MainActor in self?.includeAudioInStream = false }
    }
  }

  func stopVideoRecording() async {
    guard isRecording else { return }
    isRecording = false
    recordingStartDate = nil
    let generation = recordingGeneration
    isFinishingRecording = true
    // The writer starts on the first frame after the shutter opens. If stop lands
    // before that frame arrives, wait briefly (shutter still open) so even a quick
    // recording finalizes to a file and reliably opens the preview.
    var elapsedNanos: UInt64 = 0
    while !videoRecorder.isRecording, elapsedNanos < 500_000_000 {
      try? await Task.sleep(nanoseconds: 25_000_000)
      elapsedNanos += 25_000_000
    }
    // Show a preview/share sheet (mirrors the photo flow) for the finalized file.
    let result = await videoRecorder.stopRecording()
    // Released only once the recorder has finished with the session, on every outcome, and only
    // if no newer recording has taken it since.
    if recordingGeneration == generation, !isRecording {
      A11yAudioSession.recordingOwnsSession = false
    }
    isFinishingRecording = false
    switch result {
    case .completed(let url):
      // Announced here, not when isRecording flips: by now the recorder has released the session,
      // so the earcon and speech get a clean playback session.
      Announcer.shared.announce(SpokenMessage.recordingSaved, earcon: .done)
      activePreview = .video(url)
    case .noRecording:
      // Reached only after the intent guard + start wait, so while streaming this
      // means the recording never started (e.g. the writer failed to start).
      showError(.plain(SpokenMessage.recordingNotStarted))
    case .failed:
      showError(.plain(SpokenMessage.recordingNotSaved))
    }
  }

  // MARK: - Dismissers

  func dismissError() {
    showError = false
  }

  func dismissCapturePreview() {
    guard let preview = activePreview else { return }
    activePreview = nil
    discardPreview(preview)
  }

  /// Deletes a finished video capture's temporary file. Photos are held in
  /// memory, so there's nothing on disk to remove for them.
  func discardPreview(_ preview: CapturePreview) {
    if case .video(let url) = preview {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - Device monitoring

  /// Monitors device availability only — does NOT create sessions. Session
  /// creation is deferred to `startSession()` to avoid races.
  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await deviceId in deviceSelector.activeDeviceStream() {
        hasActiveDevice = deviceId != nil
        observeDeviceState(deviceId)
        hasDeviceReport = true
      }
    }
  }

  /// Follows battery, worn and folded state of the active glasses, and refreshes the camera
  /// permission status (a query only) so the status line can name it as the blocker.
  private func observeDeviceState(_ deviceId: DeviceIdentifier?) {
    deviceStateTokenBag.clear()
    guard let deviceId, let device = wearables.deviceForIdentifier(deviceId) else {
      batteryLevel = nil
      donState = .unknown
      hingeState = .unknown
      return
    }
    // Current values first: the listener may not replay them.
    batteryLevel = device.batteryLevel
    donState = device.donState
    hingeState = device.hingeState
    device.addDeviceStateListener { [weak self] state in
      Task { @MainActor in self?.handleDeviceState(state) }
    }.store(in: deviceStateTokenBag)
    Task { [weak self] in
      guard let self else { return }
      if let status = try? await wearables.checkPermissionStatus(.camera) {
        cameraPermission = status
      }
    }
  }

  /// Waits until the device stream has reported (or `timeout`), and, if it reported no glasses,
  /// a little longer for them to appear (they often connect just after launch).
  func waitForDeviceReport(timeout: Duration = .seconds(2)) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline, !Task.isCancelled, !(hasDeviceReport && hasActiveDevice) {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func handleDeviceState(_ state: DeviceState) {
    if batteryLevel != state.batteryLevel { batteryLevel = state.batteryLevel }
    if donState != state.donState { donState = state.donState }
    if hingeState != state.hingeState { hingeState = state.hingeState }
  }

  private func startAppLifecycleMonitoring() {
    appLifecycleTask = Task { [weak self] in
      guard let self else { return }
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
        self.handleDidEnterBackground()
      }
    }
  }

  private func handleDidEnterBackground() {
    guard hasSession, hasStream, sessionState != .stopping else { return }

    beginBackgroundStopErrorSuppression()
    endSession()
  }

  private func beginBackgroundStopErrorSuppression() {
    isStoppingForBackground = true
    backgroundStopSuppressionTask?.cancel()
    let timeout = backgroundStopErrorSuppressionTimeout
    backgroundStopSuppressionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled else { return }
      // Bound the suppression window so a stalled teardown cannot hide
      // unrelated later errors indefinitely.
      self.isStoppingForBackground = false
      self.backgroundStopSuppressionTask = nil
    }
  }

  private func endBackgroundStopErrorSuppression() {
    backgroundStopSuppressionTask?.cancel()
    backgroundStopSuppressionTask = nil
    isStoppingForBackground = false
  }

  // MARK: - Session observation

  private func observeSession(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionStateChange(state) }
    }.store(in: sessionTokenBag)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleSessionError(error) }
    }.store(in: sessionTokenBag)
  }

  private func handleSessionStateChange(_ state: DeviceSessionState) {
    sessionState = state
    if state == .started {
      benchClock.end("session_start")
    }
    if state == .stopped {
      endBackgroundStopErrorSuppression()
      cleanupSession()
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    // Backgrounding the app intentionally ends the preview session; the SDK can
    // still emit teardown errors while that stop converges, and surfacing those
    // would show a false "something went wrong" alert on return.
    guard !isStoppingForBackground else { return }
    // All session errors surface through the single alert, including
    // `datAppOnTheGlassesUpdateRequired`, which the SDK delivers as a one-shot event.
    showError(.session(error))
  }

  /// Terminal session cleanup — drop the reference and observers so the next
  /// `startSession()` creates a fresh session.
  private func cleanupSession() {
    sessionTokenBag.clear()
    deviceSession = nil
  }

  // MARK: - Stream observation

  private func setupStreamListeners(for stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStreamStateChange(state) }
    }.store(in: streamTokenBag)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let self else { return }

      if self.awaitingFirstFrame.take() {
        self.benchClock.end("stream_to_first_frame", detail: "size=\(Self.frameSize(frame))")
      }

      // Append to the recorder (no-op unless recording) off the main actor so it
      // keeps writing while the app is backgrounded.
      self.appendVideoFrame(frame)

      // Decode the compressed hvc1 frame for preview off the main actor.
      let previewImage = self.videoFrameDecoder.decode(frame.sampleBuffer)

      Task { @MainActor [weak self] in
        guard let self else { return }
        // Keep the live surface stable while a capture preview is onscreen.
        if UIApplication.shared.applicationState != .background,
          activePreview == nil,
          !isCapturingPhoto,
          let image = previewImage
        {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
        // Capture the actual recording start (first written frame) once, so the timer
        // anchors to the clip's start and matches its duration.
        if self.isRecording, self.recordingStartDate == nil {
          self.recordingStartDate = self.videoRecorder.recordingStartDate
        }
      }
    }.store(in: streamTokenBag)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleStreamError(error) }
    }.store(in: streamTokenBag)

    stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }.store(in: streamTokenBag)
  }

  private func handleStreamStateChange(_ state: StreamState) {
    streamState = state
    if state == .stopped {
      // Terminal — finalize any recording, then converge teardown. Covers both
      // user-initiated stop and SDK auto-stop (disconnect, error, session end).
      Task { await stopVideoRecording() }
      clearStreamResources()
    }
  }

  /// Single stream-teardown convergence point.
  private func clearStreamResources() {
    streamTokenBag.clear()
    // Detach the camera (idempotent) so a subsequent addCamera() can register a new one. On the
    // user-stop and session-end paths the camera is already stopped, so this is a no-op; it is
    // load-bearing only when the stream terminates on its own (a stream-level error while the
    // session stays connected), since teardown cascades parent->child but not child->parent.
    camera?.stop()
    camera = nil
    streamState = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
  }

  /// Appends a frame to the recorder. `nonisolated` so it keeps writing while the
  /// app is backgrounded (the recorder is thread-safe).
  nonisolated private func appendVideoFrame(_ frame: VideoFrame) {
    videoRecorder.appendVideoFrame(frame.sampleBuffer)
  }

  private func handleStreamError(_ error: StreamError) {
    // Same bounded suppression window as `handleSessionError`: hide only the
    // expected teardown noise from an intentional background-driven stop.
    guard !isStoppingForBackground else { return }
    showError(.stream(error))
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      let pixels = image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
      benchClock.end("capture_to_photo", detail: "size=\(Int(pixels.width))x\(Int(pixels.height))")
      // Earcon only: TtsReply speaks the reply, so the Announcer stays quiet (one voice).
      EarconPlayer.shared.play(.done)
      ttsReply.speak("Photo captured.", isRecording: isRecording)
      activePreview = .photo(image)
    }
  }

  /// Encoded width x height of a stream frame, read from its format description.
  nonisolated private static func frameSize(_ frame: VideoFrame) -> String {
    guard let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer) else { return "unknown" }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return "\(dimensions.width)x\(dimensions.height)"
  }

  private func showError(_ message: String) {
    showError(.plain(message))
  }

  private func showError(_ problem: CameraProblem) {
    errorTitle = problem.title
    errorMessage = problem.message
    errorAction = problem.action
    showError = true
  }
}

/// One-shot flag shared between the main actor (which arms it when a stream starts) and the frame
/// listener (which takes it on the first frame).
private final class FirstFrameLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false

  func arm() { lock.withLock { armed = true } }

  /// Returns true exactly once per `arm()`.
  func take() -> Bool {
    lock.withLock {
      defer { armed = false }
      return armed
    }
  }
}
