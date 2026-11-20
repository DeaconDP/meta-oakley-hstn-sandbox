/*
 * PhoneExposureLock - holds the iPhone camera's exposure and white balance still while the light
 * probe measures
 *
 * Auto exposure fights a light meter: point the phone at a window and the camera darkens the frame
 * back towards mid-grey, so the tone would barely rise. While the probe runs on the phone camera,
 * this locks exposure and white balance (after the camera has had a moment to settle on the scene),
 * so brightness from one direction can be compared with another. Unlocked again when the probe
 * stops, the tool closes, or colour mode starts (colour wants a well exposed object).
 *
 * It doesn't touch PhoneFrameSource: it locks the same back wide camera through AVCaptureDevice,
 * which is one shared object per physical camera. PhoneFrameSource only sets focus, so the two
 * don't overlap. The glasses' camera can't be locked (DAT exposes no exposure control); there the
 * levels stay relative, as on Android.
 */

import AVFoundation

@MainActor
final class PhoneExposureLock {
  private let findDevice: () -> AVCaptureDevice?
  private(set) var isLocked = false

  init(findDevice: @escaping () -> AVCaptureDevice? = { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) }) {
    self.findDevice = findDevice
  }

  /// Locks exposure and white balance at their current values. False if the camera can't (no
  /// camera, no permission yet, or the modes aren't supported); the probe still works, relative.
  @discardableResult
  func lock() -> Bool {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let device = findDevice() else { return false }
    guard device.isExposureModeSupported(.locked) else { return false }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.exposureMode = .locked
      if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
      isLocked = true
      return true
    } catch {
      return false
    }
  }

  /// Back to continuous auto exposure and white balance.
  func unlock() {
    guard isLocked else { return }
    isLocked = false
    guard let device = findDevice() else { return }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
      if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    } catch {}
  }
}
