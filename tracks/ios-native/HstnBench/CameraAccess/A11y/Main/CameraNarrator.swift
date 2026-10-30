/*
 * CameraNarrator - earcons and spoken lines for state changes on the camera screen
 *
 * CameraView forwards its view model's changes here; this decides what is heard. Rules
 * (ROADMAP "Ground rules", notes/a11y-onboarding.md):
 * - Every change gets an earcon; waits get the working tick until they settle.
 * - Errors: the error earcon always. Speech only without VoiceOver, because VoiceOver already
 *   reads the alert (title, message and its one action) and would otherwise say it twice.
 * - The photo reply is TtsReply's (bench), so nothing here speaks on a photo.
 * - The same line within a couple of seconds is said once (a pause can arrive as both a session
 *   and a stream change, and a doff as both a pause and a DeviceState change).
 */

import MWDATCore
import UIKit

@MainActor
final class CameraNarrator {
  private let earcons = EarconPlayer.shared
  private let announcer = Announcer.shared

  /// False until the screen's first status line has been spoken, so the settle-down changes right
  /// after appearing (device found, permission checked) don't each get announced.
  private var settled = false
  private var lastLine: (text: String, at: Date)?
  /// The lowest battery threshold already announced, so a reading that hovers doesn't repeat.
  private var announcedBatteryThreshold: Int?

  /// True once the appear sequence has run. Launch actions arriving before then are left for it.
  var isSettled: Bool { settled }

  /// The appear sequence, in order:
  /// 1. Wait for the device stream to report, so the status isn't a false "not connected".
  /// 2. Take a launch action parked by Siri / Back Tap. With one, it is the feedback (Status speaks
  ///    the status line, Look acts); without one, speak the status line.
  /// 3. Then the one-time disclaimer, if setup was skipped.
  /// Everything is queued (interrupt: false), so it doesn't cut what onboarding is still saying
  /// ("Connected to …", "Setup finished").
  func screenAppeared(
    _ viewModel: CameraViewModel,
    updateRequired: @escaping @MainActor () -> Bool,
    takeLaunchAction: @MainActor () -> LaunchAction?,
    runLaunchAction: @MainActor (LaunchAction) -> Void
  ) async {
    await viewModel.waitForDeviceReport()
    guard !Task.isCancelled else { return }
    let action = takeLaunchAction()
    switch action {
    case nil, .status:
      viewModel.speakStatus(updateRequired: updateRequired(), interrupt: false)
    case .some(let action):
      runLaunchAction(action)
    }
    settled = true
    speakDisclaimerIfNeeded()
  }

  /// Skipping setup skips the disclaimer, so it is said once here, after the status line. Marked
  /// heard only when it was spoken to the end, so an interruption brings it back next time.
  private func speakDisclaimerIfNeeded() {
    let preferences = A11yPreferences.shared
    guard !preferences.disclaimerHeard, !LaunchOptions.isUITesting else { return }
    announcer.say(SpokenMessage.disclaimer, interrupt: false) { finished in
      if finished { A11yPreferences.shared.disclaimerHeard = true }
    }
  }

  func screenDisappeared() {
    earcons.stopWorkingTick(owner: Self.tickOwner)
  }

  private static let tickOwner = "camera"

  // MARK: Session and stream

  func phaseChanged(from old: CameraPhase, to new: CameraPhase, viewModel: CameraViewModel) {
    if new.isWaiting { earcons.startWorkingTick(owner: Self.tickOwner) } else { earcons.stopWorkingTick(owner: Self.tickOwner) }
    guard settled, old != new else { return }

    switch new {
    case .noDevice:
      say(SpokenMessage.glassesNotConnected, earcon: .disconnected)
    case .idle:
      if old == .noDevice {
        say(SpokenMessage.glassesConnected, earcon: .connected)
      } else {
        // The session ended; folding is the common cause, so name it when DAT says so.
        say(viewModel.hingeState == .closed ? SpokenMessage.glassesFolded : SpokenMessage.sessionEnded, earcon: .disconnected)
      }
    case .sessionStarting:
      say(SpokenMessage.sessionStarting, earcon: .working)
    case .sessionReady:
      if old == .sessionStarting {
        say(SpokenMessage.sessionStarted, earcon: .ready)
      } else {
        say(SpokenMessage.cameraOff, earcon: .disconnected)
      }
    case .previewStarting:
      // Queued: right after Meta AI returns, the permission result is still being spoken.
      say(SpokenMessage.cameraStarting, earcon: .working, interrupt: false)
    case .waitingForDevice:
      say(SpokenMessage.waitingForGlasses, earcon: .working)
    case .streaming:
      // Queued, so it doesn't cut "Camera access allowed" when the stream comes up quickly.
      say(old == .paused ? SpokenMessage.resumed : SpokenMessage.cameraOn, earcon: .ready, interrupt: false)
    case .paused:
      say(viewModel.donState == .doffed ? SpokenMessage.glassesRemoved : SpokenMessage.paused, earcon: .attention)
    case .stopping:
      break  // the tick covers it; what comes next is announced when it settles
    }
  }

  // MARK: Device state

  func donStateChanged(from old: DonState, to new: DonState, viewModel: CameraViewModel) {
    // Only matters while there is a session to pause; otherwise the status line covers it.
    // From .unknown is the first reading, not something that happened.
    guard settled, old != .unknown, viewModel.hasSession else { return }
    if new == .doffed {
      say(SpokenMessage.glassesRemoved, earcon: .attention)
    } else if new == .donned, old == .doffed {
      say(SpokenMessage.glassesOn, earcon: .connected)
    }
  }

  func hingeStateChanged(from old: HingeState, to new: HingeState, viewModel: CameraViewModel) {
    guard settled, old != .unknown, new == .closed, viewModel.hasSession else { return }
    say(SpokenMessage.glassesFolded, earcon: .disconnected)
  }

  func batteryChanged(from old: Int?, to level: Int?) {
    guard let level else { return }
    // Re-arm once the glasses have been charged back above the warning level.
    if level > cameraBatteryWarningPercent {
      announcedBatteryThreshold = nil
      return
    }
    let threshold = level <= 10 ? 10 : cameraBatteryWarningPercent
    guard announcedBatteryThreshold.map({ threshold < $0 }) ?? true else { return }
    announcedBatteryThreshold = threshold
    // The first reading, or before the first status line: that line mentions the battery itself.
    guard settled, old != nil else { return }
    say(SpokenMessage.batteryLow(percent: level), earcon: .attention, interrupt: false)
  }

  // MARK: Capture and recording

  /// Start only. The stop is announced by the view model once the recorder has released the
  /// audio session ("Recording stopped. Video ready…"); announcing on the flag would land while
  /// the recorder is still tearing the session down.
  func recordingChanged(to isRecording: Bool) {
    guard isRecording else { return }
    say(SpokenMessage.recordingStarted, earcon: .capturing)
  }

  /// The recorder turned the mic off because the glasses mic isn't available: say so, since the
  /// video would otherwise silently have no sound.
  func micChanged(to isOn: Bool, isRecording: Bool) {
    guard isRecording, !isOn else { return }
    say(SpokenMessage.recordingNoSound, earcon: .attention, interrupt: false)
  }

  func previewChanged(hadPreview: Bool, to new: CapturePreview?) {
    switch new {
    case .video:
      break  // part of the view model's "Recording stopped. Video ready…"
    case .photo:
      break  // TtsReply speaks the photo reply and the view model plays the "done" earcon
    case nil:
      // With VoiceOver, focus landing back on the screen says where the user is.
      if hadPreview, !UIAccessibility.isVoiceOverRunning {
        say(SpokenMessage.backToCamera, earcon: nil)
      }
    }
  }

  // MARK: Errors and prompts

  func errorShown(_ viewModel: CameraViewModel) {
    earcons.stopWorkingTick(owner: Self.tickOwner)
    speakUnlessVoiceOver(viewModel.errorMessage, earcon: .error)
  }

  func cameraPermissionPromptShown() {
    speakUnlessVoiceOver(SpokenMessage.cameraPermissionBeforeRedirect, earcon: .attention)
  }

  func cameraPermissionPromptCancelled() {
    say(SpokenMessage.cameraPermissionCancelled, earcon: nil)
  }

  // MARK: Speaking

  /// For content VoiceOver reads by itself (alerts): earcon always, words only without it.
  private func speakUnlessVoiceOver(_ text: String, earcon: Earcon) {
    if UIAccessibility.isVoiceOverRunning {
      earcons.play(earcon)
    } else {
      say(text, earcon: earcon)
    }
  }

  private func say(_ text: String, earcon: Earcon?, interrupt: Bool = true) {
    let now = Date()
    if let lastLine, lastLine.text == text, now.timeIntervalSince(lastLine.at) < 2 { return }
    lastLine = (text, now)
    announcer.announce(text, earcon: earcon, interrupt: interrupt)
  }
}
