/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraView.swift
//
// The capture screen: a full-bleed camera preview with controls overlaid on a
// scrim. Walks the SDK's camera lifecycle as explicit steps (Start Session →
// Start Streaming → Capture / Record → Stop Streaming → End Session) and shows the
// live DeviceSessionState / StreamState so the state machine is legible.
//
// Accessibility (notes/a11y-onboarding.md): every state change is heard (CameraNarrator), Magic
// Tap runs the primary action for the current state, and every control has a solid backing, a
// 60 pt target and Dynamic Type text. At accessibility text sizes the controls stack vertically
// in a scroll view instead of overlaying the preview.
//
// "Read it aloud" (TextReader): a Read control next to Take photo, a reading card above the
// controls while there is something read, and the reader's actions on every element's VoiceOver
// actions. The view model is the reader's frame source while this screen is up.
//

import MWDATCore
import SwiftUI
import UIKit

private let updateRequiredTitle = "Update required"

struct CameraView: View {
  @State private var viewModel: CameraViewModel
  @Bindable var wearablesVM: WearablesViewModel
  @State private var showSettingsMenu: Bool = false
  @State private var isLaunchingUpdate: Bool = false
  @State private var narrator = CameraNarrator()

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self._viewModel = State(wrappedValue: CameraViewModel(wearables: wearables))
    self._wearablesVM = Bindable(wearablesVM)
  }

  private var isUpdateRequired: Bool {
    wearablesVM.requiresFirmwareUpdate
  }

  /// Accessibility text sizes: controls move into a vertical scroll so nothing truncates or covers
  /// the status text.
  private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

  /// Whether the preview is live or tearing down — drives the in-row Preview
  /// toggle's icon, id, and action. (Recording implies a live preview.)
  private var previewIsActive: Bool {
    viewModel.isStreaming || viewModel.isRecording || viewModel.streamState == .stopping
  }

  var body: some View {
    ZStack {
      // Full-bleed preview (or a dark placeholder) fills the screen so overlaying
      // the controls never reflows it.
      previewBackground
        .edgesIgnoringSafeArea(.all)
        .accessibilitySortPriority(2)

      if let preview = viewModel.activePreview {
        CapturePreviewView(
          preview: preview,
          onDismiss: { viewModel.dismissCapturePreview() }
        )
        .transition(.opacity)
        .zIndex(1)
      }

      // Tap outside the open top-bar settings menu dismisses it.
      if showSettingsMenu {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { setSettingsMenu(open: false) }
          .edgesIgnoringSafeArea(.all)
          .accessibilityHidden(true)
      }

      if isLargeText {
        largeTextControls
          .accessibilitySortPriority(3)
      } else {
        // Separate top and bottom layers so VoiceOver reads status, then the preview, then the
        // controls (sort priorities), matching the visual order.
        VStack(spacing: 0) {
          topBar
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .background(
              LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .edgesIgnoringSafeArea(.top)
                .accessibilityHidden(true)
            )
          Spacer(minLength: 0)
        }
        // An explicit container: a sort priority on a bare stack hands the stack's whole frame to
        // the element inside it, so the button's hit point lands in empty space.
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(3)

        VStack(spacing: 0) {
          Spacer(minLength: 0)
          bottomBar
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
      }
    }
    .accessibilityElement(children: .contain)
    // Two-finger double-tap: the one thing most likely wanted right now.
    .accessibilityAction(.magicTap) { performPrimaryAction() }
    // Two-finger scrub closes the settings menu (the capture preview handles its own).
    .accessibilityAction(.escape) { setSettingsMenu(open: false) }
    .animation(motion(.spring(response: 0.42, dampingFraction: 0.86)), value: viewModel.hasSession)
    .animation(motion(.easeInOut(duration: 0.2)), value: previewIsActive)
    .animation(motion(.easeInOut(duration: 0.2)), value: viewModel.isStreaming)
    .animation(motion(.easeInOut(duration: 0.2)), value: viewModel.isPaused)
    .animation(motion(.easeInOut(duration: 0.2)), value: viewModel.includeAudioInStream)
    .animation(motion(.easeInOut(duration: 0.2)), value: viewModel.isRecording)
    .alert(viewModel.errorTitle.isEmpty ? "Couldn't do that" : viewModel.errorTitle, isPresented: $viewModel.showError) {
      // One next step, then OK. VoiceOver reads title, message and both buttons.
      if let action = viewModel.errorAction {
        Button(action.title) {
          viewModel.dismissError()
          perform(action)
        }
      }
      Button("OK", role: .cancel) { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
    .alert("Allow camera access", isPresented: $viewModel.showCameraPermissionRedirectConfirm) {
      Button("Continue") { Task { await viewModel.confirmCameraPermissionRedirect() } }
      Button("Cancel", role: .cancel) { narrator.cameraPermissionPromptCancelled() }
    } message: {
      Text(SpokenMessage.cameraPermissionBeforeRedirect)
    }
    .modifier(CameraNarration(viewModel: viewModel, narrator: narrator, updateRequired: { wearablesVM.requiresFirmwareUpdate }))
    // Siri / Shortcuts / Back Tap. Cold launch: the intent parked the action before this view existed.
    // The appear sequence (CameraNarrator.screenAppeared) waits for the device stream first, so a
    // cold-launch "Look" or "Status" sees the real glasses state; it then speaks the status line
    // (unless the action was Status, which is that line) and the one-time disclaimer.
    .task {
      await narrator.screenAppeared(
        viewModel,
        updateRequired: { wearablesVM.requiresFirmwareUpdate },
        takeLaunchAction: { LaunchActionRouter.shared.consume() },
        runLaunchAction: { runLaunchAction($0) }
      )
    }
    // Warm: the app was already up when the intent ran. Before the appear sequence has run, it
    // takes the action itself.
    .onChange(of: LaunchActionRouter.shared.pending) { _, action in
      guard action != nil, narrator.isSettled else { return }
      runLaunchAction(LaunchActionRouter.shared.consume())
    }
    // Lets StatusIntent answer through Siri without opening the app.
    .onAppear {
      LaunchActionRouter.shared.statusProvider = { [viewModel, wearablesVM] in
        viewModel.statusLine(updateRequired: wearablesVM.requiresFirmwareUpdate)
      }
      TextReader.shared.source = viewModel
    }
    .onDisappear {
      LaunchActionRouter.shared.statusProvider = nil
      let reader = TextReader.shared
      if reader.source === viewModel {
        if reader.isActive { reader.stop() }
        reader.source = nil
      }
    }
    .navigationBarHidden(true)
  }

  // MARK: - Actions

  private func motion(_ animation: Animation) -> Animation? {
    reduceMotion ? nil : animation
  }

  private func setSettingsMenu(open: Bool) {
    guard showSettingsMenu != open else { return }
    withAnimation(motion(.spring(response: 0.3, dampingFraction: 0.7))) {
      showSettingsMenu = open
    }
  }

  private func speakStatus() {
    viewModel.speakStatus(updateRequired: isUpdateRequired)
  }

  /// Magic Tap: take a photo while the camera is on, otherwise the next step towards that. When
  /// nothing can be done from here (a wait, glasses missing, paused), says the status instead.
  /// While the reader is reading (or working towards it), it stops it instead: Magic Tap is
  /// iOS's play/pause gesture, and a photo mid-sentence would cut the reading anyway.
  private func performPrimaryAction() {
    if viewModel.activePreview != nil {
      viewModel.dismissCapturePreview()
      return
    }
    if TextReader.shared.isActive {
      TextReader.shared.stop()
      return
    }
    if viewModel.isBusy || isUpdateRequired {
      speakStatus()
    } else if viewModel.isStreaming {
      viewModel.capturePhoto()
    } else if viewModel.isRecording {
      // Paused mid-recording: stopping is the only thing that works.
      viewModel.toggleRecording()
    } else if viewModel.isSessionActive {
      Task { await viewModel.startStreaming() }
    } else if !viewModel.hasSession, viewModel.hasActiveDevice {
      viewModel.startSession()
    } else {
      speakStatus()
    }
  }

  /// "Look" runs the Magic Tap action, so a launch from Siri moves one step towards a photo (or
  /// takes it when the camera is already on) instead of failing when no session is up yet.
  private func runLaunchAction(_ action: LaunchAction?) {
    switch action {
    case .look: performPrimaryAction()
    case .read: TextReader.shared.read()
    case .status: speakStatus()
    case .repeatLast: Announcer.shared.repeatLast()
    case nil: break
    }
  }

  private func perform(_ action: CameraErrorAction) {
    switch action {
    case .startSession:
      viewModel.startSession()
    case .startPreview, .allowCamera:
      if viewModel.isSessionActive {
        Task { await viewModel.startStreaming() }
      } else {
        viewModel.startSession()
      }
    case .updateGlassesApp:
      Task { await wearablesVM.openDATGlassesAppUpdate() }
    case .openSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
    }
  }

  // MARK: - Preview background

  @ViewBuilder
  private var previewBackground: some View {
    ZStack {
      Color.black
        .accessibilityHidden(true)
      if viewModel.showsLivePreview {
        // Live preview, the frozen last frame while paused, or the last frame held
        // while the stream tears down — so the paused badge / stop loader overlays
        // the preview rather than the start-streaming screen.
        LivePreviewView(viewModel: viewModel, onStatus: speakStatus)
        if viewModel.isPaused {
          // Dim the frozen frame so the badge reads as intentionally paused.
          Color.black.opacity(0.35)
            .accessibilityHidden(true)
          if !isLargeText {
            pausedOverlay
          }
        }
      } else if !viewModel.isBusy, !isLargeText {
        statusPlaceholder
      }

      // Loader overlays whatever is behind it during any in-flight transition.
      if viewModel.isBusy {
        loadingOverlay
      }
    }
  }

  /// Label over the frozen preview while paused, so a held frame reads as
  /// intentionally paused (with how to resume) rather than a stalled feed. A
  /// `pause.fill` status glyph (not a circled/button shape) — resume is a glasses
  /// gesture, not an on-screen control.
  private var pausedOverlay: some View {
    VStack(spacing: 8) {
      Image(systemName: "pause.fill")
        .font(.largeTitle)
        .foregroundStyle(.white)
        .a11yDecorative()
      Text("Paused")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      Text("Tap your glasses to resume.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color(white: 0.85))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    // Solid backing: the frozen frame behind can be any brightness.
    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .padding(.horizontal, 24)
    .accessibilityIdentifier("paused_overlay")
  }

  /// Dimmed spinner shown over the preview (or placeholder) while a session/stream
  /// start or stop is in flight. The working tick says the same thing by ear.
  private var loadingOverlay: some View {
    ZStack {
      Color.black.opacity(0.35)
        .accessibilityHidden(true)
      ProgressView()
        .scaleEffect(1.5)
        .tint(.white)
        .accessibilityLabel(busyLabel)
    }
  }

  private var busyLabel: String {
    switch viewModel.a11yPhase {
    case .sessionStarting: "Starting session"
    case .previewStarting: "Starting the camera"
    case .waitingForDevice: "Waiting for the glasses"
    case .stopping: "Stopping"
    default: "Working"
    }
  }

  @ViewBuilder
  private var statusPlaceholder: some View {
    if !viewModel.hasActiveDevice {
      placeholder(title: "Put on your glasses", subtitle: nil, showWaitingRow: true)
    } else if isUpdateRequired {
      placeholder(title: updateRequiredTitle, subtitle: "Apply the update to start your camera.", showWaitingRow: false)
    } else if !viewModel.hasSession {
      placeholder(title: "Ready", subtitle: "Start a session to connect to your glasses.", showWaitingRow: false)
    } else if viewModel.isPaused {
      placeholder(title: "Paused", subtitle: "Tap your glasses to resume.", showWaitingRow: false)
    } else {
      placeholder(title: "Session started", subtitle: "Start the preview to see the live camera feed.", showWaitingRow: false)
    }
  }

  private func placeholder(title: String, subtitle: String?, showWaitingRow: Bool) -> some View {
    VStack(spacing: 12) {
      Image(.cameraAccessIcon)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.white)
        .aspectRatio(contentMode: .fit)
        .frame(width: isLargeText ? 56 : 88)
        .a11yDecorative()

      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
        .cameraQuickActions(status: speakStatus)

      if let subtitle {
        Text(subtitle)
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color(white: 0.85))
          .fixedSize(horizontal: false, vertical: true)
      }

      if showWaitingRow {
        HStack(spacing: 8) {
          Image(systemName: "hourglass")
            .font(.subheadline)
            .foregroundStyle(Color(white: 0.85))
            .a11yDecorative()
          Text("Waiting for an active device")
            .font(.subheadline)
            .foregroundStyle(Color(white: 0.85))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, 24)
  }

  // MARK: - Accessibility text sizes

  /// Everything in one vertical scroll: status, then what the placeholder or pause badge would
  /// say, then the controls. Nothing overlaps the preview's text or truncates.
  private var largeTextControls: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        topBar
        if viewModel.isPaused {
          pausedOverlay
            .padding(.horizontal, -24)
            .frame(maxWidth: .infinity)
        } else if !viewModel.showsLivePreview, !viewModel.isBusy {
          statusPlaceholder
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        bottomBarContent
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
    }
  }

  // MARK: - Top bar

  /// Top bar: compact live SDK state stacked on the left so the lifecycle is
  /// legible without heavy chrome, settings/disconnect on the right.
  private var topBar: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        statusChip(label: "Glasses", value: glassesStatusText, active: glassesReady, present: viewModel.hasActiveDevice)
        statusChip(label: "Session", value: viewModel.sessionStateText, active: viewModel.isSessionActive, present: viewModel.hasSession)
        statusChip(label: "Stream", value: viewModel.streamStateText, active: viewModel.isStreaming, present: viewModel.hasStream)
      }

      Spacer(minLength: 0)

      // Top bar carries only the app-level settings/Disconnect control.
      iconButton("gearshape", id: "settings_button") {
        setSettingsMenu(open: !showSettingsMenu)
      }
      .accessibilityLabel("Settings")
      .accessibilityValue(showSettingsMenu ? "Open" : "Closed")
      .accessibilityHint("Shows Replay setup and Disconnect.")
      .overlay(alignment: .topTrailing) {
        if showSettingsMenu {
          VStack(alignment: .trailing, spacing: 12) {
            CustomButton(title: "Replay setup", style: .primary, isDisabled: false) {
              setSettingsMenu(open: false)
              A11yPreferences.shared.resetOnboarding()
            }
            .accessibilityHint("Goes through the sounds, speaker test and detail level again.")
            .fixedSize()
            CustomButton(
              title: "Disconnect",
              style: .destructive,
              isDisabled: wearablesVM.registrationState != .registered
            ) {
              wearablesVM.disconnectGlasses()
              setSettingsMenu(open: false)
            }
            .accessibilityHint("Disconnects this app from your glasses. You'd connect again through Meta AI.")
            .fixedSize()
          }
          .offset(y: 68)
          .transition(reduceMotion ? .opacity : .scale(scale: 0.01, anchor: .topTrailing).combined(with: .opacity))
        }
      }
    }
  }

  private var glassesReady: Bool {
    viewModel.hasActiveDevice && viewModel.hingeState != .closed && viewModel.donState != .doffed
  }

  private var glassesStatusText: String {
    guard viewModel.hasActiveDevice else { return "not connected" }
    var text = "connected"
    if viewModel.hingeState == .closed {
      text = "folded"
    } else if viewModel.donState == .doffed {
      text = "not worn"
    }
    if let battery = viewModel.batteryLevel {
      text += ", battery \(battery)%"
    }
    return text
  }

  /// A dot plus the words: the dot's colour is only a cue, the text carries the state. Read by
  /// VoiceOver as one element, e.g. "Glasses: connected, battery 80%".
  private func statusChip(label: String, value: String, active: Bool, present: Bool) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(active ? Color.green : (present ? Color.yellow : Color.gray))
        .frame(width: 8, height: 8)
      Text("\(label): \(value)")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.black.opacity(0.8), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label): \(value)")
    .cameraQuickActions(status: speakStatus)
  }

  private func iconButton(_ systemName: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 60, height: 60)
        .background(Circle().fill(Color.black.opacity(0.8)))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
    }
    .accessibilityIdentifier(id)
  }

  // MARK: - Bottom bar

  private var bottomBar: some View {
    bottomBarContent
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.top, 48)
      .padding(.bottom, 28)
      .background(
        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
          .edgesIgnoringSafeArea(.bottom)
          .accessibilityHidden(true)
      )
  }

  private var bottomBarContent: some View {
    VStack(spacing: 14) {
      if isUpdateRequired {
        updateControls
      } else {
        if TextReader.shared.phase != .idle {
          ReadPanel(isLargeText: isLargeText, onStatus: speakStatus)
        }
        // Reserved capture-row space + a single persistent button hold the button at
        // a fixed Y across every state.
        captureRow
        anchoredPrimaryButton
      }
    }
  }

  /// In-session toolbar (Preview / Photo / Read / Record / Mic), kept laid out so the
  /// session button below holds a fixed Y. Hidden without a session; Preview leads as
  /// the gateway and is the lone enabled control in session-ready, the rest enabling
  /// once streaming. One row when it fits, else two rows in the same reading order, and one
  /// control per row only at large text, so the controls don't cover most of the preview.
  @ViewBuilder
  private var captureRow: some View {
    // `.hidden()` keeps the space but removes the controls from VoiceOver and touch.
    // accessibilityHidden on the row left them exposed as invisible, disabled buttons.
    if viewModel.hasSession {
      captureRowContent
    } else {
      captureRowContent.hidden()
    }
  }

  private var captureRowContent: some View {
    VStack(spacing: 0) {
      if isLargeText {
        verticalCaptureRow
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            previewPill(compact: true)
            photoButton(compact: true)
            readButton(compact: true)
            recordPill(compact: true)
            micToggle(compact: true)
          }
          VStack(spacing: 10) {
            HStack(spacing: 10) {
              previewPill(compact: true)
              photoButton(compact: true)
              readButton(compact: true)
            }
            HStack(spacing: 10) {
              recordPill(compact: true)
              micToggle(compact: true)
            }
          }
          verticalCaptureRow
        }
      }
    }
  }

  private var verticalCaptureRow: some View {
    VStack(spacing: 10) {
      previewPill(compact: false)
      photoButton(compact: false)
      readButton(compact: false)
      recordPill(compact: false)
      micToggle(compact: false)
    }
  }

  /// Photo and Record need a live stream.
  private var captureControlsEnabled: Bool { viewModel.isStreaming }
  /// Record/Stop stays available while recording even if the stream is paused, so a
  /// pause can't trap an in-progress recording; starting still needs a live stream.
  private var recordControlEnabled: Bool {
    (viewModel.isStreaming && !viewModel.isFinishingRecording) || viewModel.isRecording
  }
  /// Mic additionally locks once recording starts — the audio setting can't change
  /// mid-take.
  private var micEnabled: Bool { viewModel.isStreaming && !viewModel.isRecording }

  /// Photo capture: an icon in the row (so the Preview and Record pills keep room for text), a
  /// labelled row when stacked. Enabled while streaming, including during a recording.
  private func photoButton(compact: Bool) -> some View {
    Button {
      viewModel.capturePhoto()
    } label: {
      ControlLabel(icon: "camera.fill", title: compact ? nil : "Take photo")
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("capture_button")
    .accessibilityLabel("Take photo")
    .accessibilityHint(captureControlsEnabled ? "" : "Available when the preview is on.")
    .cameraQuickActions(status: speakStatus)
    .disabled(!captureControlsEnabled)
    .opacity(captureControlsEnabled ? 1 : 0.4)
  }

  /// Read text aloud, word for word: an icon beside Take photo in the row, a labelled row when
  /// stacked. Needs the live stream, like Take photo. (VoiceOver's "Read text" action and Siri also
  /// work before the preview is on: they start it first.)
  private func readButton(compact: Bool) -> some View {
    Button {
      TextReader.shared.read()
    } label: {
      ControlLabel(icon: "text.viewfinder", title: compact ? nil : "Read text")
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("read_button")
    .accessibilityLabel("Read text")
    .accessibilityHint(captureControlsEnabled ? "Reads the text in front of you aloud, word for word." : "Available when the preview is on.")
    .cameraQuickActions(status: speakStatus)
    .disabled(!captureControlsEnabled)
    .opacity(captureControlsEnabled ? 1 : 0.4)
  }

  /// Preview on/off — the gateway for capture. The eye icon flips (shape, not only dimming) when
  /// off; locked mid-recording so a recording can't lose its feed.
  private func previewPill(compact: Bool) -> some View {
    capturePill(
      icon: previewIsActive ? "eye.fill" : "eye.slash.fill",
      title: compact ? "Preview" : (previewIsActive ? "Stop preview" : "Start preview"),
      id: previewIsActive ? "stop_preview_button" : "start_preview_button"
    ) {
      if previewIsActive {
        viewModel.stopStreaming()
      } else {
        Task { await viewModel.startStreaming() }
      }
    }
    .accessibilityLabel(previewIsActive ? "Stop preview" : "Start preview")
    .accessibilityHint(previewHint)
    .disabled(previewToggleDisabled)
    .opacity(previewToggleDisabled ? 0.4 : 1)
  }

  private var previewHint: String {
    if previewIsActive {
      return viewModel.isRecording ? "Stop the recording first." : "Turns the glasses camera off. The session stays connected."
    }
    return "Turns on the glasses camera so you can take photos and record."
  }

  private var previewToggleDisabled: Bool {
    if previewIsActive {
      return viewModel.isRecording || viewModel.isBusy
    }
    return !viewModel.isSessionActive || viewModel.isBusy
  }

  /// The single full-width session button: Start Session, or End Session
  /// (destructive) once a session exists. One instance, never branched, so it never
  /// remounts and holds a fixed Y — only its title / style / id / action change.
  private var anchoredPrimaryButton: some View {
    CustomButton(
      title: viewModel.hasSession ? "End session" : "Start session",
      style: viewModel.hasSession ? .destructive : .primary,
      isDisabled: primaryDisabled
    ) {
      if viewModel.hasSession {
        viewModel.endSession()
      } else {
        viewModel.startSession()
      }
    }
    .accessibilityHint(primaryHint)
    .cameraQuickActions(status: speakStatus)
    .accessibilityIdentifier(viewModel.hasSession ? "end_session_button" : "start_session_button")
  }

  private var primaryHint: String {
    if viewModel.hasSession { return "Disconnects the camera from your glasses." }
    if !viewModel.hasActiveDevice { return "Put on your glasses first." }
    return "Connects to your glasses so you can use the camera."
  }

  /// Start needs an active device; End stays available mid-stream/record — the SDK
  /// cascades the stop, so only an in-flight transition disables it.
  private var primaryDisabled: Bool {
    if viewModel.hasSession {
      return viewModel.isBusy
    }
    return viewModel.isBusy || !viewModel.hasActiveDevice
  }

  private func primaryButton(_ title: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
    CustomButton(title: title, style: .primary, isDisabled: disabled, action: action)
      .accessibilityIdentifier(id)
  }

  /// Icon+label capsule for the capture actions, on a solid backing so it reads over any frame.
  private func capturePill(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      ControlLabel(icon: icon, title: title)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
    .cameraQuickActions(status: speakStatus)
  }

  /// Record/Stop. While recording it says "Stop" with a square and the running time, so the state
  /// doesn't depend on the red tint.
  private func recordPill(compact: Bool) -> some View {
    RecordPill(viewModel: viewModel, compact: compact, onStatus: speakStatus)
      .disabled(!recordControlEnabled)
      .opacity(recordControlEnabled ? 1 : 0.4)
  }

  /// Sound-in-video toggle. Slashed icon (and "off" in words when stacked) when muted; locked
  /// until streaming and during recording. Denied reads as off and, since iOS won't re-prompt,
  /// tapping it opens Settings instead of toggling.
  private func micToggle(compact: Bool) -> some View {
    let isOn = !viewModel.micDenied && viewModel.includeAudioInStream
    return Button {
      if viewModel.micDenied {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      } else {
        viewModel.includeAudioInStream.toggle()
      }
    } label: {
      ControlLabel(
        icon: isOn ? "mic.fill" : "mic.slash.fill",
        title: compact ? nil : (isOn ? "Glasses mic: on" : "Glasses mic: off"),
        dimmedIcon: !isOn
      )
    }
    .buttonStyle(.plain)
    .disabled(!micEnabled)
    .opacity(micEnabled ? 1 : 0.4)
    .accessibilityLabel("Glasses microphone")
    .accessibilityValue(viewModel.micDenied ? "Off, not allowed" : (isOn ? "On" : "Off"))
    .accessibilityHint(micHint)
    .accessibilityAddTraits(.isToggle)
    .cameraQuickActions(status: speakStatus)
    .accessibilityIdentifier("mic_toggle")
  }

  private var micHint: String {
    if viewModel.micDenied { return "Opens Settings to allow the microphone." }
    if viewModel.isRecording { return "Can't change during a recording." }
    return "Records sound from the glasses into videos."
  }

  // MARK: - Update controls

  @ViewBuilder
  private var updateControls: some View {
    UpdateRequiredMessage()
    // Gate the button while the external update flow launches so a double-tap can't
    // fire it twice; re-enabled once the await returns.
    primaryButton("Update firmware", id: "update_firmware_button", disabled: isLaunchingUpdate) {
      isLaunchingUpdate = true
      Task {
        await wearablesVM.openFirmwareUpdate()
        isLaunchingUpdate = false
      }
    }
    .accessibilityHint("Opens the Meta AI app to update your glasses.")
  }
}

// MARK: - Control label

/// Shared look for the capture controls: icon, optional text, a near-opaque dark fill (text
/// contrast over any frame) and a light outline (boundary contrast over dark frames), at least
/// 60 pt tall. Icon-only renders as a 60 pt circle.
struct ControlLabel: View {
  let icon: String
  var title: String?
  var iconTint: Color = .white
  var dimmedIcon: Bool = false

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 60

  var body: some View {
    let height = max(60, minHeight)
    Group {
      if let title {
        HStack(spacing: 8) {
          Image(systemName: icon)
            .foregroundStyle(iconTint.opacity(dimmedIcon ? 0.6 : 1))
            .accessibilityHidden(true)
          Text(title)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
      } else {
        Image(systemName: icon)
          .font(.title3.weight(.semibold))
          .foregroundStyle(iconTint.opacity(dimmedIcon ? 0.6 : 1))
          .frame(width: height, height: height)
          .background(Circle().fill(fill))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
      }
    }
    .contentShape(Rectangle())
  }

  private var fill: Color {
    Color(white: 0.08).opacity(reduceTransparency ? 1 : 0.85)
  }
}

// MARK: - Record pill

/// Record/Stop capsule. While recording it shows a stop square, "Stop" and the live timer, and
/// its VoiceOver value is the elapsed time. Isolated so the once-a-second timer re-renders only
/// this control.
private struct RecordPill: View {
  var viewModel: CameraViewModel
  let compact: Bool
  let onStatus: () -> Void

  var body: some View {
    // Counts from the actual recording start (first written frame), so it tracks the
    // saved clip and keeps advancing through a pause; shows 00:00 until that frame.
    if viewModel.isRecording, let start = viewModel.recordingStartDate {
      TimelineView(.periodic(from: start, by: 1)) { context in
        button(elapsed: context.date.timeIntervalSince(start))
      }
    } else {
      button(elapsed: viewModel.isRecording ? 0 : nil)
    }
  }

  private func button(elapsed: TimeInterval?) -> some View {
    Button {
      viewModel.toggleRecording()
    } label: {
      Group {
        if let elapsed {
          HStack(spacing: 8) {
            Image(systemName: "stop.fill")
              .foregroundStyle(Color.recordAccent)
              .accessibilityHidden(true)
            Text("Stop")
              .foregroundStyle(.white)
            Text(elapsed.formattedRecordingTime)
              .monospacedDigit()
              .foregroundStyle(.white)
              // Identifier on the Text so UI tests find it regardless of the time value.
              .accessibilityIdentifier("recording_indicator")
          }
        } else {
          HStack(spacing: 8) {
            Image(systemName: "video.fill")
              .foregroundStyle(Color.recordAccent)
              .accessibilityHidden(true)
            Text(compact ? "Record" : "Record video")
              .foregroundStyle(.white)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .font(.headline)
      .lineLimit(compact ? 1 : nil)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 60)
      .background {
        ZStack {
          Capsule().fill(Color(white: 0.08).opacity(0.85))
          if elapsed != nil {
            Capsule().fill(Color.recordAccent.opacity(0.45))
          }
        }
      }
      // A thicker outline while recording: a shape cue alongside the tint and the word "Stop".
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: elapsed != nil ? 3 : 1.5))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("record_button")
    .accessibilityLabel(elapsed != nil ? "Stop recording" : "Record video")
    .accessibilityValue(elapsed.map { "Recording, " + CameraViewModel.spokenDuration($0) } ?? "")
    .accessibilityHint(elapsed != nil ? "" : "Records video from the glasses camera.")
    .cameraQuickActions(status: onStatus)
  }
}

// MARK: - Live preview

/// The streaming preview image. Isolated from `CameraView` so frequent
/// (~24fps) `currentVideoFrame` updates re-render only this view, not the
/// surrounding controls. One VoiceOver element with a short label; not a focus trap.
private struct LivePreviewView: View {
  var viewModel: CameraViewModel
  let onStatus: () -> Void

  var body: some View {
    Group {
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.white)
      }
    }
    // A camera feed must not be colour-inverted by Smart Invert.
    .accessibilityIgnoresInvertColors()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityAddTraits(.isImage)
    .cameraQuickActions(status: onStatus)
  }

  private var label: String {
    if viewModel.isPaused { return "Camera view, paused" }
    if !viewModel.hasReceivedFirstFrame { return "Camera view, starting" }
    return "Live camera view"
  }
}

// MARK: - Update banner

struct UpdateRequiredMessage: View {
  private let message = "Your glasses need a firmware update before HSTN Reader can start."

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.title3)
        .foregroundStyle(Color.updateRequiredForeground)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(updateRequiredTitle)
          .font(.headline)
          .foregroundStyle(Color.updateRequiredForeground)
          .accessibilityAddTraits(.isHeader)

        Text(message)
          .font(.body)
          .foregroundStyle(Color.updateRequiredForeground)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.all, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.updateRequiredBackground)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
