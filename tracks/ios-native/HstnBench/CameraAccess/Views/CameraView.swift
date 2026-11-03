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
// The main screen: voice status, reading progress, the live state of the glasses, the camera in a
// rounded card, then a vertical path of big tiles for the real actions. Walks the SDK's camera
// lifecycle as explicit steps (Start Session → Start Streaming → Capture / Record → Stop Streaming →
// End Session). The tile that is the next step is the biggest. Styled from A11y/Theme.
//
// Accessibility (notes/a11y-onboarding.md): every state change is heard (CameraNarrator), Magic
// Tap runs the primary action for the current state, and every control has a 60 pt target and
// Dynamic Type text. It is all one scroll, so nothing overlaps or clips at any text size, and the
// reading order is the visual order: status, the camera, then the controls.
//
// "Read it aloud" (TextReader): a Read tile, a reading card above the tiles while there is something
// read, and the reader's actions on every element's VoiceOver actions. The view model is the
// reader's frame source while this screen is up.
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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self._viewModel = State(wrappedValue: CameraViewModel(wearables: wearables))
    self._wearablesVM = Bindable(wearablesVM)
  }

  private var isUpdateRequired: Bool {
    wearablesVM.requiresFirmwareUpdate
  }

  /// Accessibility text sizes: tiles lose their zigzag and stack their parts.
  private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

  /// Whether the preview is live or tearing down — drives the in-row Preview
  /// toggle's icon, id, and action. (Recording implies a live preview.)
  private var previewIsActive: Bool {
    viewModel.isStreaming || viewModel.isRecording || viewModel.streamState == .stopping
  }

  var body: some View {
    ZStack {
      Theme.page
        .ignoresSafeArea()
        .accessibilityHidden(true)

      VStack(spacing: 0) {
        PinnedVoiceIndicator()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            FlowingVoiceIndicator()
            ReadingProgressCard()
            topBar
            if showSettingsMenu {
              settingsPanel
            }
            cameraArea
            bottomBarContent
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .frame(maxWidth: 700, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      // Fully covered by the capture preview while that's up, so out of the tree too.
      .accessibilityHidden(viewModel.activePreview != nil)

      if let preview = viewModel.activePreview {
        CapturePreviewView(
          preview: preview,
          onDismiss: { viewModel.dismissCapturePreview() }
        )
        .transition(.opacity)
        .zIndex(1)
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
      VoiceControl.shared.setScreen(.camera, handler: handleVoice)
    }
    .onDisappear {
      VoiceControl.shared.clearScreen { $0 == .camera }
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

  /// A voice command: the same calls as Siri, Magic Tap and the actions rotor. Returns false for
  /// what VoiceControl handles the same way on every screen (help, faster, slower).
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    let reader = TextReader.shared
    switch command {
    case .read: runLaunchAction(.read)
    case .status: runLaunchAction(.status)
    case .stop:
      // Stopping the reader also stops the voice; otherwise just cut what is being said.
      if reader.isActive { reader.stop() } else { Announcer.shared.stop() }
    case .repeatLast:
      if reader.hasSentences { reader.repeatSentence() } else { runLaunchAction(.repeatLast) }
    case .takePhoto:
      // A running read would make Magic Tap's action "stop reading", not take the photo.
      if reader.isActive { reader.stop() }
      runLaunchAction(.look)
    case .connect:
      // One step towards a running camera, like the reader's own nudge. Starting is narrated by
      // CameraNarrator; only "nothing to do" and "can't" need a line here.
      switch viewModel.prepareStreamForReading() {
      case .ready: speakStatus()
      case .starting, .blocked: break
      case .unavailable(let reason): Announcer.shared.announce(reason, earcon: .attention)
      }
    case .continueOn: reader.next()
    case .back: reader.previous()
    default: return false
    }
    return true
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

  // MARK: - Camera area

  /// The rounded camera card while there's something to show or wait for, otherwise the mascot
  /// saying what's happening.
  @ViewBuilder
  private var cameraArea: some View {
    if viewModel.showsLivePreview || viewModel.isBusy {
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
        }

        // Loader overlays whatever is behind it during any in-flight transition.
        if viewModel.isBusy {
          loadingOverlay
        }
      }
      .frame(height: 200)
      .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
          .strokeBorder(Theme.stroke, lineWidth: 2)
          .accessibilityHidden(true)
      }
      if viewModel.isPaused, isLargeText {
        // At large text the badge wouldn't fit on the card, so it follows it.
        pausedOverlay
          .frame(maxWidth: .infinity)
      }
    } else {
      statusPlaceholder
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
        .font(.rounded(.title3, weight: .heavy))
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      Text("Tap your glasses to resume.")
        .font(.rounded(.body, weight: .medium))
        .multilineTextAlignment(.center)
        .foregroundStyle(Color(white: 0.85))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    // Solid backing: the frozen frame behind can be any brightness.
    .background(Color.black.opacity(reduceTransparency ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .padding(.horizontal, 24)
    .accessibilityIdentifier("paused_overlay")
  }

  /// Dimmed spinner shown over the preview (or placeholder) while a session/stream
  /// start or stop is in flight. The working tick says the same thing by ear.
  private var loadingOverlay: some View {
    ZStack {
      Color.black.opacity(reduceTransparency ? 0.8 : 0.35)
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
      placeholder(title: "Put on your glasses", subtitle: nil, showWaitingRow: true, mood: .idle)
    } else if isUpdateRequired {
      placeholder(title: updateRequiredTitle, subtitle: "Apply the update to start your camera.", showWaitingRow: false, mood: .confused)
    } else if !viewModel.hasSession {
      placeholder(title: "Ready", subtitle: "Start a session to connect to your glasses.", showWaitingRow: false, mood: .happy)
    } else if viewModel.isPaused {
      placeholder(title: "Paused", subtitle: "Tap your glasses to resume.", showWaitingRow: false, mood: .idle)
    } else {
      placeholder(title: "Session started", subtitle: "Start the preview to see the live camera feed.", showWaitingRow: false, mood: .happy)
    }
  }

  private func placeholder(title: String, subtitle: String?, showWaitingRow: Bool, mood: MascotMood) -> some View {
    MascotSays(mood: mood) {
      Text(title)
        .font(.rounded(.title3, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .cameraQuickActions(status: speakStatus)

      if let subtitle {
        Text(subtitle)
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }

      if showWaitingRow {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "hourglass")
            .font(.rounded(.subheadline))
            .foregroundStyle(Theme.inkSoft)
            .a11yDecorative()
          Text("Waiting for an active device")
            .font(.rounded(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Top bar

  /// Live SDK state, so the lifecycle is legible, with settings beside it. Stacks at large text.
  private var topBar: some View {
    let layout = isLargeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout {
      VStack(alignment: .leading, spacing: 6) {
        statusChip(label: "Glasses", value: glassesStatusText, active: glassesReady, present: viewModel.hasActiveDevice)
        statusChip(label: "Session", value: viewModel.sessionStateText, active: viewModel.isSessionActive, present: viewModel.hasSession)
        statusChip(label: "Stream", value: viewModel.streamStateText, active: viewModel.isStreaming, present: viewModel.hasStream)
      }
      .themeCard(padding: 12)

      // Top bar carries only the app-level settings/Disconnect control.
      iconButton("gearshape.fill", id: "settings_button") {
        setSettingsMenu(open: !showSettingsMenu)
      }
      .accessibilityLabel("Settings")
      .accessibilityValue(showSettingsMenu ? "Open" : "Closed")
      .accessibilityHint("Shows voice control, voice, Replay setup and Disconnect.")
    }
  }

  /// In the page, not floating over it: the menu is tall, and this way it scrolls at any text size.
  private var settingsPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      VoiceSettingsRows()
      CustomButton(title: "Replay setup", style: .secondary, isDisabled: false) {
        setSettingsMenu(open: false)
        A11yPreferences.shared.resetOnboarding()
      }
      .accessibilityHint("Goes through the sounds, speaker test and detail level again.")
      CustomButton(
        title: "Disconnect",
        style: .destructive,
        isDisabled: wearablesVM.registrationState != .registered
      ) {
        wearablesVM.disconnectGlasses()
        setSettingsMenu(open: false)
      }
      .accessibilityHint("Disconnects this app from your glasses. You'd connect again through Meta AI.")
    }
    .themeCard()
    .transition(.opacity)
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

  /// A symbol plus the words: the symbol's shape and colour are only cues, the text carries the
  /// state. Read by VoiceOver as one element, e.g. "Glasses: connected, battery 80%".
  private func statusChip(label: String, value: String, active: Bool, present: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: active ? "checkmark.circle.fill" : (present ? "circle.lefthalf.filled" : "circle"))
        .foregroundStyle(active ? Theme.lip(.green) : (present ? Theme.lip(.orange) : Theme.stroke))
      Text("\(label): \(value)")
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.rounded(.footnote, weight: .bold))
    // It carries VoiceOver actions, so it needs a target's height, not just a line's.
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label): \(value)")
    .cameraQuickActions(status: speakStatus)
  }

  private func iconButton(_ systemName: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.rounded(.title3, weight: .heavy))
    }
    .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5, radius: 33))
    .frame(width: 66)
    .accessibilityIdentifier(id)
  }

  // MARK: - The path

  private var bottomBarContent: some View {
    VStack(spacing: 14) {
      if isUpdateRequired {
        updateControls
      } else {
        if TextReader.shared.phase != .idle {
          ReadPanel(isLargeText: isLargeText, onStatus: speakStatus)
        }
        path
      }
    }
  }

  /// The tiles, one after another, in the order things happen. The next step is the biggest, and
  /// exactly one tile is. Tiles that need a session aren't in the tree without one (not hidden, not
  /// disabled), so they can't overlap Start session or be found by VoiceOver.
  private var path: some View {
    VStack(spacing: 0) {
      if viewModel.hasSession {
        previewPill().pathSide(primaryTile == .preview ? .center : .left)
        PathDots()
        photoButton().pathSide(.right)
        PathDots()
        readButton().pathSide(primaryTile == .read ? .center : .left)
        PathDots()
        recordPill().pathSide(.right)
        PathDots()
        micToggle().pathSide(.left)
        PathDots()
      }
      anchoredPrimaryButton
      PathDots()
      if !viewModel.hasSession {
        upcomingTiles
        PathDots()
      }
      statusButton().pathSide(.right)
    }
  }

  private enum PrimaryTile {
    case session, preview, read
  }

  /// The one thing to do next.
  private var primaryTile: PrimaryTile {
    if !viewModel.hasSession { return .session }
    return previewIsActive ? .read : .preview
  }

  /// What the path leads to, for anyone looking ahead. Words, not controls: one element.
  private var upcomingTiles: some View {
    HStack(spacing: 10) {
      TileCoin(icon: "lock.fill", tone: .neutral, size: 40)
      Text("Next: start the preview, then read text, take photos and record video.")
        .font(.rounded(.subheadline, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private func tileStyle(big: Bool, tone: Tone = .green) -> ChunkyButtonStyle {
    big ? ChunkyButtonStyle(tone: tone, lipHeight: 8, radius: 30) : ChunkyButtonStyle(tone: .neutral, lipHeight: 6, radius: 26)
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

  private let needsPreviewNote = "Start the preview first."

  /// Photo capture. Enabled while streaming, including during a recording.
  private func photoButton() -> some View {
    Button {
      viewModel.capturePhoto()
    } label: {
      PathTileLabel(icon: "camera.fill", title: "Take photo", coin: .orange, say: .takePhoto, lockedNote: needsPreviewNote)
    }
    .buttonStyle(tileStyle(big: false))
    .accessibilityIdentifier("capture_button")
    .accessibilityLabel("Take photo")
    .accessibilityHint(captureControlsEnabled ? "" : "Available when the preview is on.")
    .cameraQuickActions(status: speakStatus)
    .disabled(!captureControlsEnabled)
  }

  /// Read text aloud, word for word. Needs the live stream, like Take photo. (VoiceOver's "Read
  /// text" action and Siri also work before the preview is on: they start it first.)
  private func readButton() -> some View {
    let big = primaryTile == .read && captureControlsEnabled
    return Button {
      TextReader.shared.read()
    } label: {
      PathTileLabel(icon: "text.viewfinder", title: "Read text", coin: big ? .neutral : .green, isBig: big, say: .read, lockedNote: needsPreviewNote)
    }
    .buttonStyle(tileStyle(big: big))
    .accessibilityIdentifier("read_button")
    .accessibilityLabel("Read text")
    .accessibilityHint(captureControlsEnabled ? "Reads the text in front of you aloud, word for word." : "Available when the preview is on.")
    .cameraQuickActions(status: speakStatus)
    .disabled(!captureControlsEnabled)
  }

  /// Preview on/off — the gateway for capture. The eye icon flips (shape, not only dimming) when
  /// off; locked mid-recording so a recording can't lose its feed.
  private func previewPill() -> some View {
    let big = primaryTile == .preview && !previewToggleDisabled
    return Button {
      if previewIsActive {
        viewModel.stopStreaming()
      } else {
        Task { await viewModel.startStreaming() }
      }
    } label: {
      PathTileLabel(
        icon: previewIsActive ? "eye.fill" : "eye.slash.fill",
        title: previewIsActive ? "Stop preview" : "Start preview",
        coin: big ? .neutral : .blue,
        isBig: big,
        say: previewIsActive ? nil : .connect,
        lockedNote: viewModel.isRecording ? "Stop the recording first." : "One moment.")
    }
    .buttonStyle(tileStyle(big: big))
    .accessibilityIdentifier(previewIsActive ? "stop_preview_button" : "start_preview_button")
    .cameraQuickActions(status: speakStatus)
    .accessibilityLabel(previewIsActive ? "Stop preview" : "Start preview")
    .accessibilityHint(previewHint)
    .disabled(previewToggleDisabled)
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

  /// The session tile: Start session, the biggest on the screen, or End session (destructive) once
  /// a session exists. One instance, never branched, so VoiceOver focus stays on it across the
  /// change — only its title / style / id / action change.
  private var anchoredPrimaryButton: some View {
    let starting = !viewModel.hasSession
    return Button {
      if viewModel.hasSession {
        viewModel.endSession()
      } else {
        viewModel.startSession()
      }
    } label: {
      PathTileLabel(
        icon: starting ? "eyeglasses" : "xmark",
        title: starting ? "Start session" : "End session",
        coin: starting ? .neutral : .red,
        isBig: starting,
        say: starting ? .connect : nil,
        lockedNote: viewModel.hasActiveDevice ? "One moment." : "Put on your glasses first.")
    }
    .buttonStyle(tileStyle(big: starting))
    .disabled(primaryDisabled)
    .accessibilityLabel(starting ? "Start session" : "End session")
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

  /// Hears the status line: the same one as Siri's Status, the voice command and the rotor action.
  private func statusButton() -> some View {
    Button(action: speakStatus) {
      PathTileLabel(icon: "waveform", title: "Status", coin: .purple, say: .status)
    }
    .buttonStyle(tileStyle(big: false))
    .accessibilityLabel("Status")
    .accessibilityHint("Says how the glasses and camera are doing.")
    .cameraQuickActions(status: speakStatus)
    .accessibilityIdentifier("status_button")
  }

  /// Record/Stop. While recording it says "Stop" with a square and the running time, so the state
  /// doesn't depend on the red tint.
  private func recordPill() -> some View {
    RecordPill(viewModel: viewModel, lockedNote: needsPreviewNote, onStatus: speakStatus)
      .disabled(!recordControlEnabled)
  }

  /// Sound-in-video toggle. Slashed icon and "off" in words when muted; locked until streaming and
  /// during recording. Denied reads as off and, since iOS won't re-prompt, tapping it opens Settings
  /// instead of toggling.
  private func micToggle() -> some View {
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
      PathTileLabel(
        icon: isOn ? "mic.fill" : "mic.slash.fill",
        title: isOn ? "Glasses mic: on" : "Glasses mic: off",
        coin: isOn ? .blue : .neutral,
        lockedNote: viewModel.isRecording ? "Can't change during a recording." : needsPreviewNote)
    }
    .buttonStyle(tileStyle(big: false))
    .disabled(!micEnabled)
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

// MARK: - Record pill

/// Record/Stop tile. While recording it shows a stop square, "Stop" and the live timer, and
/// its VoiceOver value is the elapsed time. Isolated so the once-a-second timer re-renders only
/// this control.
private struct RecordPill: View {
  var viewModel: CameraViewModel
  let lockedNote: String
  let onStatus: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
      if let elapsed {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
          TileCoin(icon: "stop.fill", tone: .neutral, size: 52)
          Text("Stop")
            .font(.rounded(.title3, weight: .heavy))
          Text(elapsed.formattedRecordingTime)
            .font(.rounded(.title3, weight: .heavy))
            .monospacedDigit()
            // A time read across two lines isn't a time.
            .fixedSize()
            // Identifier on the Text so UI tests find it regardless of the time value.
            .accessibilityIdentifier("recording_indicator")
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        PathTileLabel(icon: "video.fill", title: "Record video", coin: .red, lockedNote: lockedNote)
      }
    }
    .buttonStyle(elapsed != nil ? ChunkyButtonStyle(tone: .red, lipHeight: 6, radius: 26) : ChunkyButtonStyle(tone: .neutral, lipHeight: 6, radius: 26))
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
        .font(.rounded(.title3, weight: .bold))
        .foregroundStyle(Theme.onFace(.orange))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(updateRequiredTitle)
          .font(.rounded(.headline, weight: .heavy))
          .foregroundStyle(Theme.onFace(.orange))
          .accessibilityAddTraits(.isHeader)

        Text(message)
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.onFace(.orange))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.all, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.face(.orange), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.lip(.orange), lineWidth: 2)
    }
    .accessibilityElement(children: .combine)
  }
}
