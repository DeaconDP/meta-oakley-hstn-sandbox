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

/// The glasses camera for the reader: creates and starts a `DeviceSession`, adds and starts a
/// `Stream`, keeps the latest decoded frame, and takes a still when the reader asks for one. Nobody
/// drives these steps by hand: a Read trigger takes them (CameraViewModel+Read), and backgrounding
/// ends the session. Owns active-device monitoring, the `DeviceSession` and its `Stream`.
@Observable
@MainActor
final class CameraViewModel {
  // MARK: - Device

  /// Whether an eligible device is currently active. Sourced from the auto device selector.
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

  // MARK: - Stream

  /// The most recent decoded stream frame and when it arrived, for "Read it aloud". Not observed,
  /// so ~24 updates a second don't re-render anything.
  @ObservationIgnored private(set) var latestReadFrame: ReadFrame?

  /// The stream's state, mirrored from `Stream.statePublisher`. `.stopped` means
  /// no live stream.
  var streamState: StreamState = .stopped

  /// A still for the reader is on its way.
  private(set) var isCapturingPhoto: Bool = false

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

  // MARK: - Derived stream state

  var isStreaming: Bool { streamState == .streaming }
  /// A stream is attached (in any non-terminal state).
  var hasStream: Bool { streamState != .stopped }

  /// A session or stream start/stop is in flight.
  var isBusy: Bool {
    isSessionStarting || sessionState == .stopping
      || streamState == .starting || streamState == .waitingForDevice || streamState == .stopping
  }

  /// The stream is paused (device-initiated, e.g. a single cap-touch tap).
  var isPaused: Bool { streamState == .paused }

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private var isStoppingForBackground: Bool = false
  @ObservationIgnored private var backgroundStopSuppressionTask: Task<Void, Never>?

  // Decodes compressed hvc1 frames into images for the reader.
  @ObservationIgnored private let videoFrameDecoder = VideoFrameDecoder()

  // Step-2 benchmark timings.
  @ObservationIgnored private let benchClock = BenchClock.shared
  /// Set when a stream starts; the first frame to arrive clears it and ends `stream_to_first_frame`.
  @ObservationIgnored private let awaitingFirstFrame = FirstFrameLatch()

  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var appLifecycleTask: Task<Void, Never>?
  @ObservationIgnored private let sessionTokenBag = ListenerTokenBag()
  @ObservationIgnored private let streamTokenBag = ListenerTokenBag()
  @ObservationIgnored private let deviceStateTokenBag = ListenerTokenBag()
  /// A startStreaming() call is between its permission check and adding the camera, so a
  /// second caller (the reader nudging the stream along) doesn't start another one.
  @ObservationIgnored private(set) var isStreamStartInFlight = false
  /// Waiting for an in-stream photo taken for reading.
  @ObservationIgnored private var readPhotoContinuation: CheckedContinuation<UIImage?, Never>?
  @ObservationIgnored private var readPhotoToken = 0

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
    VoiceControl.shared.detachGlasses()
  }

  // MARK: - Lifecycle step 1: session

  /// Creates and starts a `DeviceSession` (no stream yet). The state observer drives
  /// `sessionState`; we only seed an optimistic `.starting` so the in-flight request shows at once.
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
      showError(.plain(SpokenMessage.cameraStreamFailed, action: .tryAgain))
      return
    }
    guard camera == nil, !isStreamStartInFlight else { return }
    isStreamStartInFlight = true
    defer { isStreamStartInFlight = false }

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
  /// access was granted. `then` runs once "Camera access allowed" has ended (the main screen
  /// reads, so the Read that asked for permission carries on by itself). Heard to the end or cut
  /// short, it runs either way: a cut line (the Local Network dialog, a route change) used to drop
  /// the read silently while the stream started anyway.
  func confirmCameraPermissionRedirect(then: (@MainActor () -> Void)? = nil) async {
    showCameraPermissionRedirectConfirm = false
    guard let session = deviceSession, session.state == .started, camera == nil else {
      benchClock.note("camera permission confirm skipped: no started session, or a camera already")
      return
    }
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
    Announcer.shared.announce(SpokenMessage.cameraPermissionGranted, earcon: .done) { [benchClock] finished in
      benchClock.note("camera permission granted, line finished=\(finished)")
      then?()
    }
    beginStream(on: session)
  }

  /// Creates the camera `Stream` on the started session and starts it. Callers
  /// must have ensured camera permission is granted first.
  private func beginStream(on session: DeviceSession) {
    guard camera == nil else { return }
    // hvc1 (compressed HEVC), decoded by VideoFrameDecoder.
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      // Add the consolidated `Camera` capability and stream through `camera.stream`.
      benchClock.start("stream_to_first_frame")
      guard let newCamera = try session.addCamera(config: config) else {
        showError(.plain(SpokenMessage.cameraStreamFailed, action: .tryAgain))
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
      showError(.plain(error.localizedDescription, action: .tryAgain))
    }
  }

  /// Stops the camera stream but keeps the `DeviceSession` connected, so
  /// streaming can be started again without re-creating the session. The stream
  /// `.stopped` observer performs the teardown — we don't eagerly reset here.
  func stopStreaming() {
    guard let activeCamera = camera else { return }
    // Reflect the in-flight request immediately; the observer drives it onward.
    streamState = .stopping
    // Stopping the camera cascades to its stream child and detaches the camera from the
    // session, so streaming can be started again with a fresh `addCamera()`.
    activeCamera.stop()
  }

  // MARK: - Capture

  /// An in-stream photo for "Read it aloud", used when there's no recent frame or the text is too
  /// small in one. Times out after 8 s; nil on any failure.
  func captureStillForReading() async -> UIImage? {
    guard isStreaming, !isCapturingPhoto, readPhotoContinuation == nil, let camera else { return nil }
    isCapturingPhoto = true
    EarconPlayer.shared.play(.capturing)
    benchClock.start("read_photo")
    guard camera.stream.capturePhoto(format: .jpeg) else {
      isCapturingPhoto = false
      return nil
    }
    readPhotoToken += 1
    let token = readPhotoToken
    return await withCheckedContinuation { continuation in
      readPhotoContinuation = continuation
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(8))
        self?.resolveReadPhoto(nil, token: token)
      }
    }
  }

  /// Hands the read photo (or nil) to the waiting reader. `token` limits a timeout to its own
  /// request.
  private func resolveReadPhoto(_ image: UIImage?, token: Int? = nil) {
    guard let continuation = readPhotoContinuation, token.map({ $0 == readPhotoToken }) ?? true else { return }
    readPhotoContinuation = nil
    isCapturingPhoto = false
    continuation.resume(returning: image)
  }

  func dismissError() {
    showError = false
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
    benchClock.note("camera session state=\(state)")
    sessionState = state
    if state == .started {
      benchClock.end("session_start")
      if let deviceSession { VoiceControl.shared.attachGlasses(session: deviceSession, wearables: wearables) }
    }
    if state == .stopped {
      VoiceControl.shared.detachGlasses()
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
      let arrivedAt = BenchClock.uptimeNanoseconds()

      if self.awaitingFirstFrame.take() {
        self.benchClock.end("stream_to_first_frame", detail: "size=\(Self.frameSize(frame))")
      }

      // Decode the compressed hvc1 frame off the main actor.
      let image = self.videoFrameDecoder.decode(frame.sampleBuffer)

      Task { @MainActor [weak self] in
        guard let self, UIApplication.shared.applicationState != .background, let image else { return }
        self.latestReadFrame = ReadFrame(image: image, arrivedAt: arrivedAt)
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
    benchClock.note("camera stream state=\(state)")
    streamState = state
    if state == .stopped {
      // Terminal: covers both a stop we asked for and SDK auto-stop (disconnect, error, session end).
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
    latestReadFrame = nil
    resolveReadPhoto(nil)
  }

  private func handleStreamError(_ error: StreamError) {
    // Same bounded suppression window as `handleSessionError`: hide only the
    // expected teardown noise from an intentional background-driven stop.
    guard !isStoppingForBackground else { return }
    // A failed photo for reading is the reader's to say ("The photo for reading wasn't taken").
    if case .photoCaptureFailed = error {
      resolveReadPhoto(nil)
      return
    }
    showError(.stream(error))
  }

  private func handlePhotoData(_ data: PhotoData) {
    let image = UIImage(data: data.data)
    if let image {
      let pixels = image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
      benchClock.end("read_photo", detail: "size=\(Int(pixels.width))x\(Int(pixels.height))")
    }
    resolveReadPhoto(image)
  }

  /// Encoded width x height of a stream frame, read from its format description.
  nonisolated private static func frameSize(_ frame: VideoFrame) -> String {
    guard let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer) else { return "unknown" }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return "\(dimensions.width)x\(dimensions.height)"
  }

  private func showError(_ problem: CameraProblem) {
    benchClock.note("camera error title=\(problem.title)")
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
