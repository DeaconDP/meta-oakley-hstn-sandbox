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
// The main screen, and the only one after setup: what the glasses are doing, one big Read text
// button, the reading card while there is something read, and Settings. There are no camera
// steps to take by hand. Reading starts the session and the stream itself (TextReader asks
// CameraViewModel+Read), and going to the background ends them.
//
// Accessibility (notes/a11y-onboarding.md): every state change is heard (CameraNarrator), Magic
// Tap reads (or stops reading), every control has a 60 pt target and Dynamic Type text, and it is
// all one scroll in reading order: status, Read text, the reading card. The reader's actions are
// also VoiceOver actions on every element (cameraQuickActions).
//
// Glasses optional (V0, notes/phone-camera-ios.md): the reader reads through CameraSourceRouter,
// which picks the iPhone's camera or the glasses. With the phone, the screen shows its preview, a
// labelled camera switch and the torch, the status line is the phone's, and the glasses' folded /
// removed / battery narration is skipped.
//
// Hands-free (notes/hands-free-mode.md): the switch and, in the toolbox, the push-to-talk button sit
// under the status, and a short tools list follows Read text. In hands-free the alerts are replaced
// by spoken lines and yes/no questions (CameraNarrator), and the screen publishes its card to
// HandsFreeSurface for a glasses display.
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
  private var router: CameraSourceRouter { CameraSourceRouter.shared }

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self._viewModel = State(wrappedValue: CameraViewModel(wearables: wearables))
    self._wearablesVM = Bindable(wearablesVM)
  }

  private var isUpdateRequired: Bool {
    wearablesVM.requiresFirmwareUpdate
  }

  /// Accessibility text sizes: the status card and the reading card stack their parts.
  private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

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
            topBar
            // Settings has its own copy of the switch.
            if showSettingsMenu {
              settingsPanel
            } else {
              HandsFreeControls()
            }
            CameraSourceCard(router: router, connectGlasses: connectGlasses)
            if isUpdateRequired, !usingPhone {
              updateControls
            } else {
              readButton
              if TextReader.shared.phase != .idle {
                ReadPanel(isLargeText: isLargeText, onStatus: speakStatus)
              }
              ToolboxList(tools: [.status, .settings], perform: performTool)
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .frame(maxWidth: 700, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .accessibilityElement(children: .contain)
    // Two-finger double-tap: read, or stop reading.
    .accessibilityAction(.magicTap) { performPrimaryAction() }
    // Two-finger scrub closes the settings menu.
    .accessibilityAction(.escape) { setSettingsMenu(open: false) }
    // No dialogs in hands-free: CameraNarrator says the error and "try again" runs its action.
    .alert(viewModel.errorTitle.isEmpty ? "Couldn't do that" : viewModel.errorTitle, isPresented: unlessHandsFree($viewModel.showError)) {
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
    .alert("Allow camera access", isPresented: unlessHandsFree($viewModel.showCameraPermissionRedirectConfirm)) {
      // The Read that asked for access carries on once it's allowed.
      Button("Continue") {
        VoiceControl.shared.clearQuestion()
        confirmCameraPermission()
      }
      Button("Cancel", role: .cancel) {
        VoiceControl.shared.clearQuestion()
        narrator.cameraPermissionPromptCancelled()
      }
    } message: {
      Text(SpokenMessage.cameraPermissionBeforeRedirect)
    }
    .modifier(
      CameraNarration(
        viewModel: viewModel, narrator: narrator, updateRequired: { wearablesVM.requiresFirmwareUpdate },
        permissionYes: confirmCameraPermission, permissionNo: declineCameraPermission))
    // The router follows the glasses' link and presence to pick the camera.
    .onChange(of: wearablesVM.registrationState) { _, state in router.registered = state == .registered }
    .onChange(of: viewModel.hasActiveDevice) { _, connected in router.glassesConnected = connected }
    // Problems while the phone camera is in use: said in both modes, like the glasses' pauses.
    .onChange(of: router.phoneProblem) { old, new in
      guard usingPhone else { return }
      narrator.phoneProblemChanged(from: old, to: new)
    }
    // The card a glasses display shows (HandsFreeSurface), from the same state the screen shows.
    .task(id: cardState) {
      HandsFreeSurface.shared.publish(screen: .camera, state: cardState, hints: cardHints)
    }
    .onChange(of: A11yPreferences.shared.handsFree) { _, _ in viewModel.hostDisplaySessionIfNeeded() }
    // Siri / Shortcuts / Back Tap. Cold launch: the intent parked the action before this view existed.
    // The appear sequence (CameraNarrator.screenAppeared) waits for the device stream first, so a
    // cold-launch "Read" or "Status" sees the real glasses state; it then speaks the status line
    // (unless the action was Status, which is that line) and the one-time disclaimer.
    .task {
      await narrator.screenAppeared(
        viewModel,
        router: router,
        speakStatus: { interrupt in speakStatus(interrupt: interrupt) },
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
      router.glasses = viewModel
      router.registered = wearablesVM.registrationState == .registered
      router.glassesConnected = viewModel.hasActiveDevice
      narrator.glassesInUse = { [router] in router.active == .glasses }
      LaunchActionRouter.shared.statusProvider = { [viewModel, wearablesVM, router] in
        router.phoneStatusLine ?? viewModel.statusLine(updateRequired: wearablesVM.requiresFirmwareUpdate)
      }
      TextReader.shared.source = router
      VoiceControl.shared.setScreen(.camera, describe: describeForVoice, handler: handleVoice)
      // Spoken tips after a quiet spell ("Hold some text in front of you and say read").
      VoiceCoach.shared.provide(for: .camera) { [viewModel, wearablesVM, router] in
        if router.active == .phone {
          return CoachSituation.forPhone(problem: router.phoneProblem, hasReadSentences: TextReader.shared.hasSentences)
        }
        return viewModel.coachSituation(
          updateRequired: wearablesVM.requiresFirmwareUpdate, hasReadSentences: TextReader.shared.hasSentences)
      }
    }
    .onDisappear {
      VoiceControl.shared.clearScreen { $0 == .camera }
      VoiceCoach.shared.stopProviding(for: .camera)
      LaunchActionRouter.shared.statusProvider = nil
      let reader = TextReader.shared
      if reader.source === router {
        if reader.isActive { reader.stop() }
        reader.source = nil
      }
      router.screenDisappeared()
      if router.glasses === viewModel { router.glasses = nil }
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

  private var usingPhone: Bool { router.active == .phone }

  /// The phone's status line while it is the camera, otherwise the glasses'.
  private func speakStatus() {
    speakStatus(interrupt: true)
  }

  private func speakStatus(interrupt: Bool) {
    if let line = router.phoneStatusLine {
      let earcon: Earcon = router.phoneProblem == nil ? .ready : .attention
      Announcer.shared.announce(line, earcon: earcon, interrupt: interrupt)
    } else {
      viewModel.speakStatus(updateRequired: isUpdateRequired, interrupt: interrupt)
    }
  }

  /// From the camera card, or "connect" by voice without linked glasses. Once linked, auto uses
  /// them, so a phone choice goes back to auto.
  private func connectGlasses() {
    if A11yPreferences.shared.cameraSource == .phone { A11yPreferences.shared.cameraSource = .auto }
    wearablesVM.connectGlasses()
  }

  /// Magic Tap: iOS's play/pause gesture. Stops a read in progress, otherwise reads. With an update
  /// pending nothing can be read, so it says the status instead.
  private func performPrimaryAction() {
    let reader = TextReader.shared
    if reader.isActive {
      reader.stop()
    } else if isUpdateRequired, !usingPhone {
      speakStatus()
    } else {
      reader.read()
    }
  }

  private func runLaunchAction(_ action: LaunchAction?) {
    switch action {
    case .read: TextReader.shared.read()
    case .status: speakStatus()
    case .repeatLast: Announcer.shared.repeatLast()
    case nil: break
    }
  }

  /// A voice command: the same calls as Siri, Magic Tap and the actions rotor. Returns false for
  /// what VoiceControl handles the same way on every screen (help, faster, slower, settings by
  /// voice, tools, where am I).
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
    case .continueOn: reader.next()
    case .back:
      // Sentences first, as before; then out of settings; then the main menu line.
      if reader.hasSentences {
        reader.previous()
      } else if showSettingsMenu {
        closeSettings()
      } else {
        return false
      }
    case .close:
      guard showSettingsMenu else { return false }
      closeSettings()
    case .mainMenu:
      setSettingsMenu(open: false)
      if reader.isActive { reader.stop() }
      return false  // VoiceControl says where that is
    case .openSettings:
      setSettingsMenu(open: true)
      Announcer.shared.say(SpokenMessage.settingsOpened)
    case .openReader:
      setSettingsMenu(open: false)
      return false
    case .tryAgain:
      if let action = viewModel.errorAction {
        viewModel.errorAction = nil
        perform(action)
      } else {
        TextReader.shared.read()
      }
    case .connect:
      if wearablesVM.registrationState == .registered {
        Announcer.shared.say(SpokenMessage.alreadyConnected)
      } else {
        connectGlasses()
      }
    case .usePhone: router.choose(.phone)
    case .useGlasses: router.choose(.glasses)
    case .whichCamera: Announcer.shared.say(router.whichCameraLine)
    case .torchOn: router.setTorch(true)
    case .torchOff: router.setTorch(false)
    case .disconnect:
      wearablesVM.disconnectGlasses()
    default: return false
    }
    return true
  }

  private func closeSettings() {
    setSettingsMenu(open: false)
    Announcer.shared.say(SpokenMessage.settingsClosed)
  }

  /// "Where am I": settings if open, then the status line.
  private func describeForVoice() -> String? {
    let status = router.phoneStatusLine ?? viewModel.statusLine(updateRequired: isUpdateRequired)
    return showSettingsMenu ? "Settings are open. \(status)" : status
  }

  private func performTool(_ tool: HandsFreeTool) {
    switch tool {
    case .reader: TextReader.shared.read()
    case .status: speakStatus()
    case .settings: setSettingsMenu(open: !showSettingsMenu)
    }
  }

  private func confirmCameraPermission() {
    Task { await viewModel.confirmCameraPermissionRedirect { TextReader.shared.read() } }
  }

  private func declineCameraPermission() {
    viewModel.showCameraPermissionRedirectConfirm = false
    narrator.cameraPermissionPromptCancelled()
  }

  /// An alert binding that stays down in hands-free, where the narrator speaks instead.
  private func unlessHandsFree(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue && !A11yPreferences.shared.handsFree }, set: { binding.wrappedValue = $0 })
  }

  // MARK: - The glasses display card

  /// One line: what the reader is doing, else the status title.
  private var cardState: String {
    let reader = TextReader.shared
    if reader.phase != .idle { return reader.statusText }
    if showSettingsMenu { return "Settings" }
    return status.title
  }

  private var cardHints: [VoiceCommand] {
    if TextReader.shared.isActive { return [.stop, .continueOn, .mainMenu] }
    if TextReader.shared.hasSentences { return [.read, .continueOn, .back] }
    if showSettingsMenu { return [.faster, .slower, .close] }
    return [.read, .status, .help]
  }

  private func perform(_ action: CameraErrorAction) {
    switch action {
    case .tryAgain:
      TextReader.shared.read()
    case .allowCamera:
      // Starting the stream checks permission and explains the Meta AI switch first.
      if viewModel.isSessionActive {
        Task { await viewModel.startStreaming() }
      } else {
        TextReader.shared.read()
      }
    case .updateGlassesApp:
      Task { await wearablesVM.openDATGlassesAppUpdate() }
    case .openSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
    }
  }

  // MARK: - Status

  /// The mascot saying what the glasses are doing, with Settings beside it. Stacks at large text.
  private var topBar: some View {
    let layout = isLargeText ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout {
      statusCard
      Button {
        setSettingsMenu(open: !showSettingsMenu)
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.rounded(.title3, weight: .heavy))
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5, radius: 33))
      .frame(width: 66)
      .accessibilityIdentifier("settings_button")
      .accessibilityLabel("Settings")
      .accessibilityValue(showSettingsMenu ? "Open" : "Closed")
      .accessibilityHint("Shows voice control, voice, reading voice, Replay setup and Disconnect.")
    }
  }

  private struct Status {
    var title: String
    var subtitle: String?
    var mood: MascotMood
  }

  /// What the user needs to know, in the order it matters. The spoken status line
  /// (CameraViewModel.statusLine) says the same things.
  private var status: Status {
    if usingPhone {
      if let problem = router.phoneProblem {
        return Status(title: problem.title, subtitle: problem == .noCamera ? nil : "See below for what to do.", mood: .confused)
      }
      return Status(
        title: "Ready to read", subtitle: "Hold the iPhone about 30 cm above a page, then tap Read text.", mood: .happy)
    }
    if !viewModel.hasActiveDevice {
      return Status(title: "Put on your glasses", subtitle: "Waiting for them to connect.", mood: .idle)
    }
    if isUpdateRequired {
      return Status(title: updateRequiredTitle, subtitle: "Apply the update to start reading.", mood: .confused)
    }
    if viewModel.hingeState == .closed {
      return Status(title: "Glasses folded", subtitle: "Unfold them to read.", mood: .idle)
    }
    if viewModel.isPaused {
      let removed = viewModel.donState == .doffed
      return Status(title: removed ? "Glasses removed" : "Paused", subtitle: "Tap your glasses to resume.", mood: .idle)
    }
    if viewModel.isBusy {
      return Status(title: "Starting the camera", subtitle: nil, mood: .idle)
    }
    return Status(title: "Ready to read", subtitle: "Hold some text in front of you, then tap Read text.", mood: .happy)
  }

  private var statusCard: some View {
    let status = status
    return MascotSays(mood: status.mood) {
      Text(status.title)
        .font(.rounded(.title3, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("status_title")
        .cameraQuickActions(status: speakStatus)
      if let subtitle = status.subtitle {
        Text(subtitle)
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !usingPhone, let battery = viewModel.batteryLevel, battery <= cameraBatteryWarningPercent {
        Label("Glasses battery \(battery)%", systemImage: "battery.25percent")
          .font(.rounded(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// In the page, not floating over it: the menu is tall, and this way it scrolls at any text size.
  private var settingsPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      VoiceSettingsRows()
      ReadingSettingsRows()
      CustomButton(title: "Replay setup", style: .secondary, isDisabled: false) {
        setSettingsMenu(open: false)
        A11yPreferences.shared.resetOnboarding()
      }
      .accessibilityHint("Goes through the sounds, speaker test and detail level again.")
      if wearablesVM.registrationState != .registered {
        CustomButton(title: "Connect my glasses", style: .secondary, isDisabled: wearablesVM.isConnecting) {
          setSettingsMenu(open: false)
          connectGlasses()
        }
        .accessibilityHint("Optional. Opens the Meta AI app to link your glasses, then come back.")
        .accessibilityIdentifier("settings_connect_glasses_button")
      }
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

  // MARK: - Read

  /// The one action. Always enabled: when reading can't start, the reader says why ("Glasses
  /// aren't connected…"), which beats a dimmed button that can't explain itself.
  private var readButton: some View {
    Button {
      TextReader.shared.read()
    } label: {
      PathTileLabel(icon: "text.viewfinder", title: "Read text", coin: .neutral, isBig: true, say: .read)
    }
    .buttonStyle(ChunkyButtonStyle(tone: .yellow, lipHeight: 8, radius: 30))
    .accessibilityIdentifier("read_button")
    .accessibilityLabel("Read text")
    .accessibilityHint("Reads the text in front of you aloud, word for word.")
    .cameraQuickActions(status: speakStatus)
  }

  // MARK: - Update controls

  @ViewBuilder
  private var updateControls: some View {
    UpdateRequiredMessage()
    // Gate the button while the external update flow launches so a double-tap can't
    // fire it twice; re-enabled once the await returns.
    CustomButton(title: "Update firmware", style: .primary, isDisabled: isLaunchingUpdate) {
      isLaunchingUpdate = true
      Task {
        await wearablesVM.openFirmwareUpdate()
        isLaunchingUpdate = false
      }
    }
    .accessibilityIdentifier("update_firmware_button")
    .accessibilityHint("Opens the Meta AI app to update your glasses.")
  }
}

// MARK: - Update banner

struct UpdateRequiredMessage: View {
  private let message = "Your glasses need a firmware update before SpeakUp can start."

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
