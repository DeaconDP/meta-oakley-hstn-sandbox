/*
 * PhoneFrameSource - the iPhone's back camera as the reader's frame source (V0 "Glasses optional")
 *
 * AVCaptureSession with the back wide camera: AVCaptureVideoDataOutput for the latest frame (kept
 * as a pixel buffer and turned into an image only when the reader asks), AVCapturePhotoOutput for
 * a full-resolution still when the text is small or the cloud path wants a photo. The same steps
 * as the glasses (CameraViewModel+Read): a Read trigger starts it, the reader waits for "ready".
 *
 * Pitfalls, each a spoken line (PhoneCameraProblem): camera access refused or restricted (says how
 * to fix it in Settings), no camera (the Simulator), set-up failure, the camera taken by another
 * app or split view (interruption), and runtime errors. "Too dark" is the reader's framing check;
 * for the phone its guidance suggests "torch on".
 *
 * Nothing runs until the first read: no permission prompt at launch. Going to the background stops
 * the session (iOS would interrupt it anyway); the next read starts it again.
 */

@preconcurrency import AVFoundation
import CoreImage
import Observation
import UIKit

/// What the source router needs from the phone camera beyond reading. A fake stands in for it in
/// tests, since the Simulator has no camera.
@MainActor
protocol PhoneCamera: ReadFrameSource {
  var problem: PhoneCameraProblem? { get }
  var isRunning: Bool { get }
  var hasTorch: Bool { get }
  var isTorchOn: Bool { get }
  func setTorch(_ on: Bool) -> TorchResult
  /// EV at ISO 100 from the running camera's exposure (DarkWatch), nil when unknown.
  var sceneEV: Double? { get }
}

extension PhoneCamera {
  var sceneEV: Double? { nil }
}

@MainActor
@Observable
final class PhoneFrameSource: NSObject, PhoneCamera {
  enum State: Equatable {
    case idle
    /// Asking for permission, or configuring and starting the session.
    case starting
    case running
    case failed(PhoneCameraProblem)
  }

  private(set) var state: State = .idle
  private(set) var isTorchOn = false
  /// For the preview layer. Configured on `sessionQueue`.
  @ObservationIgnored let session = AVCaptureSession()

  var problem: PhoneCameraProblem? {
    if case .failed(let problem) = state { return problem }
    return nil
  }

  var isRunning: Bool { state == .running }

  var hasTorch: Bool { device?.hasTorch ?? false }

  var cameraKind: CameraKind { .phone }

  /// From the camera's auto exposure: ISO, shutter time and aperture (DarkWatch). The device's
  /// exposure properties are key-value observable and safe to read from the main thread.
  var sceneEV: Double? {
    guard state == .running, let device else { return nil }
    return SceneLight.ev100(
      aperture: Double(device.lensAperture), exposureSeconds: CMTimeGetSeconds(device.exposureDuration), iso: Double(device.iso))
  }

  // Injected so tests and the Simulator path don't depend on hardware.
  @ObservationIgnored private let findDevice: () -> AVCaptureDevice?
  @ObservationIgnored private let authorization: () -> AVAuthorizationStatus
  @ObservationIgnored private let requestAccess: () async -> Bool

  @ObservationIgnored private var device: AVCaptureDevice?
  @ObservationIgnored private let sessionQueue = DispatchQueue(label: "speakup.phonecamera.session")
  @ObservationIgnored private let frameQueue = DispatchQueue(label: "speakup.phonecamera.frames")
  @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
  @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
  @ObservationIgnored private let frameStore = PhoneFrameStore()
  @ObservationIgnored private var isConfigured = false
  @ObservationIgnored private var photoDelegate: PhotoCaptureDelegate?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init(
    findDevice: @escaping () -> AVCaptureDevice? = { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) },
    authorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
    requestAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }
  ) {
    self.findDevice = findDevice
    self.authorization = authorization
    self.requestAccess = requestAccess
    super.init()
    observeSession()
  }

  isolated deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  // MARK: ReadFrameSource

  var latestReadFrame: ReadFrame? {
    guard state == .running else { return nil }
    return frameStore.latestFrame()
  }

  func prepareStreamForReading() -> ReadStreamReadiness {
    switch state {
    case .running: return .ready
    case .starting: return .starting
    case .failed(let problem) where problem == .noCamera || problem == .permissionRestricted:
      // Won't change by trying again.
      return .unavailable(problem.spokenLine)
    case .idle, .failed:
      return begin()
    }
  }

  func captureStillForReading() async -> UIImage? {
    guard state == .running, photoDelegate == nil else { return nil }
    EarconPlayer.shared.play(.capturing)
    BenchClock.shared.start("read_photo")
    let output = photoOutput
    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
    settings.maxPhotoDimensions = output.maxPhotoDimensions
    settings.flashMode = .off
    let image: UIImage? = await withCheckedContinuation { continuation in
      let delegate = PhotoCaptureDelegate { [weak self] data in
        Task { @MainActor in
          self?.photoDelegate = nil
          continuation.resume(returning: data.flatMap(UIImage.init(data:)))
        }
      }
      photoDelegate = delegate
      sessionQueue.async { output.capturePhoto(with: settings, delegate: delegate) }
      // Never wait forever on a stuck capture.
      Task { @MainActor [weak delegate] in
        try? await Task.sleep(for: .seconds(8))
        delegate?.finish(nil)
      }
    }
    if let image {
      BenchClock.shared.end("read_photo", detail: "size=\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale)) camera=phone")
    }
    return image
  }

  func stopReadingStream() {
    stop()
  }

  // MARK: Start and stop

  /// Moves towards running, one step: permission, then configure and start. Returns at once.
  private func begin() -> ReadStreamReadiness {
    if device == nil { device = findDevice() }
    guard device != nil else {
      state = .failed(.noCamera)
      return .unavailable(PhoneCameraProblem.noCamera.spokenLine)
    }
    switch authorization() {
    case .authorized:
      state = .starting
      startSession()
      return .starting
    case .notDetermined:
      state = .starting
      Announcer.shared.say(SpokenMessage.phoneCameraPermissionAsk, interrupt: false)
      Task {
        let granted = await requestAccess()
        guard state == .starting else { return }
        if granted {
          startSession()
        } else {
          state = .failed(.permissionDenied)
        }
      }
      return .starting
    case .denied:
      state = .failed(.permissionDenied)
      return .unavailable(PhoneCameraProblem.permissionDenied.spokenLine)
    case .restricted:
      state = .failed(.permissionRestricted)
      return .unavailable(PhoneCameraProblem.permissionRestricted.spokenLine)
    @unknown default:
      state = .failed(.permissionDenied)
      return .unavailable(PhoneCameraProblem.permissionDenied.spokenLine)
    }
  }

  private func startSession() {
    guard let device else { return }
    let session = session
    let videoOutput = videoOutput
    let photoOutput = photoOutput
    let frameStore = frameStore
    let frameQueue = frameQueue
    let needsConfiguring = !isConfigured
    BenchClock.shared.start("phone_camera_start")
    sessionQueue.async { [weak self] in
      if needsConfiguring {
        let ok = Self.configure(session, device: device, videoOutput: videoOutput, photoOutput: photoOutput, frameStore: frameStore, frameQueue: frameQueue)
        guard ok else {
          Task { @MainActor in self?.state = .failed(.setupFailed) }
          return
        }
      }
      if !session.isRunning { session.startRunning() }
      let running = session.isRunning
      Task { @MainActor in
        guard let self else { return }
        self.isConfigured = self.isConfigured || needsConfiguring
        guard self.state == .starting else { return }
        if running {
          BenchClock.shared.end("phone_camera_start")
          self.state = .running
          if self.isTorchOn { _ = self.applyTorch(true) }
        } else {
          self.state = .failed(.setupFailed)
        }
      }
    }
  }

  /// Stops the camera (background, or the glasses took over). The next read starts it again.
  func stop() {
    if isTorchOn { _ = applyTorch(false) }
    isTorchOn = false
    if state == .running || state == .starting { state = .idle }
    frameStore.clear()
    let session = session
    sessionQueue.async { if session.isRunning { session.stopRunning() } }
  }

  nonisolated private static func configure(
    _ session: AVCaptureSession, device: AVCaptureDevice, videoOutput: AVCaptureVideoDataOutput,
    photoOutput: AVCapturePhotoOutput, frameStore: PhoneFrameStore, frameQueue: DispatchQueue
  ) -> Bool {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    // Full-resolution stills for small print; the video frames are whatever this preset gives.
    session.sessionPreset = session.canSetSessionPreset(.photo) ? .photo : .high
    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
    session.addInput(input)

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.setSampleBufferDelegate(frameStore, queue: frameQueue)
    guard session.canAddOutput(videoOutput) else { return false }
    session.addOutput(videoOutput)

    guard session.canAddOutput(photoOutput) else { return false }
    session.addOutput(photoOutput)
    if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
      photoOutput.maxPhotoDimensions = largest
    }
    photoOutput.maxPhotoQualityPrioritization = .quality

    // Portrait, as the phone is held over a page.
    for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 })
    where connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }

    // Pages are close: favour near focus where the camera allows it.
    if (try? device.lockForConfiguration()) != nil {
      if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
      if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
      device.unlockForConfiguration()
    }
    return true
  }

  // MARK: Torch

  /// Turns the torch on or off. Remembered while the camera is starting and applied when it runs.
  func setTorch(_ on: Bool) -> TorchResult {
    if device == nil { device = findDevice() }
    guard let device, device.hasTorch else { return .noTorch }
    if state != .running {
      // Applied once the camera runs; iOS only lights it with a running session on some models.
      isTorchOn = on
      return on ? .on : .off
    }
    return applyTorch(on)
  }

  private func applyTorch(_ on: Bool) -> TorchResult {
    guard let device, device.hasTorch else { return .noTorch }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if on {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
      isTorchOn = on
      return on ? .on : .off
    } catch {
      return .failed
    }
  }

  // MARK: Interruptions and errors

  private func observeSession() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.interrupted() }
      })
    observers.append(
      center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.interruptionEnded() }
      })
    observers.append(
      center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.failedWhileRunning(.stoppedWithError) }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.stop() }
      })
  }

  private func interrupted() {
    // Backgrounding interrupts too; that is a stop, not a problem to announce.
    guard UIApplication.shared.applicationState != .background else { return }
    failedWhileRunning(.interrupted)
  }

  private func interruptionEnded() {
    guard state == .failed(.interrupted) else { return }
    state = session.isRunning ? .running : .idle
  }

  private func failedWhileRunning(_ problem: PhoneCameraProblem) {
    guard state == .running || state == .starting else { return }
    frameStore.clear()
    isTorchOn = false
    state = .failed(problem)
  }
}

/// The latest video frame, written on the frame queue and read on the main actor. Converting to
/// an image only on demand keeps 30 frames a second cheap.
private final class PhoneFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: CVPixelBuffer?
  private var arrivedAt: UInt64 = 0
  private let context = CIContext()

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let now = BenchClock.uptimeNanoseconds()
    lock.withLock {
      buffer = pixels
      arrivedAt = now
    }
  }

  func latestFrame() -> ReadFrame? {
    let (pixels, at) = lock.withLock { (buffer, arrivedAt) }
    guard let pixels else { return nil }
    let image = CIImage(cvPixelBuffer: pixels)
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
    return ReadFrame(image: UIImage(cgImage: cgImage), arrivedAt: at)
  }

  func clear() {
    lock.withLock { buffer = nil }
  }
}

/// One still. Calls back once, with the JPEG data or nil.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var completion: ((Data?) -> Void)?

  init(completion: @escaping (Data?) -> Void) {
    self.completion = completion
  }

  func finish(_ data: Data?) {
    let done = lock.withLock { () -> ((Data?) -> Void)? in
      defer { completion = nil }
      return completion
    }
    done?(data)
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
    finish(error == nil ? photo.fileDataRepresentation() : nil)
  }
}
