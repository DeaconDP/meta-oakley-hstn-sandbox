/*
 * CameraViewModel+Read - the camera screen as the reader's frame source
 *
 * The frame itself (latestReadFrame) and the read-only photo (captureStillForReading) live in
 * CameraViewModel, next to the stream code they hook into. This is the "get the camera going"
 * step: a Read trigger with no stream moves one step at a time towards streaming, the same steps
 * Magic Tap takes, and says the status line when nothing can be done from here.
 */

extension CameraViewModel: ReadFrameSource {
  func prepareStreamForReading() -> ReadStreamReadiness {
    if isStreaming { return .ready }
    if showError || showCameraPermissionRedirectConfirm { return .blocked }
    if isPaused { return .unavailable(statusLine()) }
    if isBusy || isStreamStartInFlight { return .starting }
    if isSessionActive, !hasStream {
      Task { await startStreaming() }
      return .starting
    }
    if !hasSession, hasActiveDevice, hingeState != .closed {
      startSession()
      return .starting
    }
    return .unavailable(statusLine())
  }
}
