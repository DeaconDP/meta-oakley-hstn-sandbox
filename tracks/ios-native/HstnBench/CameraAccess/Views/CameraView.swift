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
// The main screen, and the only one after setup: the tools home (notes/tools-home-ios.md). The
// status, then the six tools (ToolHub), the camera card, and Settings. Opening a tool shows its
// panel with a Close button in place of the list. Read text is the first tool: its tile reads at
// once, as the one big Read button did. There are no camera steps to take by hand. Reading starts
// the session and the stream itself, and going to the background ends them. Glasses are a small
// optional row, and absent in the App Store build.
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
// No DAT types here: the glasses come in as GlassesLink and GlassesCamera (A11y/Glasses). In the
// App Store build (SPEAKUP_NO_DAT) they are NoGlassesLink, so there is no connect or disconnect,
// no camera switch, and "connect" or "use the glasses" says glasses need the Beta app.
//

import SwiftUI
import UIKit

private let updateRequiredTitle = "Update required"

struct CameraView: View {
  @State private var viewModel: any GlassesCamera
  var link: any GlassesLink
  @State private var showSettingsMenu: Bool = false
  @State private var isLaunchingUpdate: Bool = false
  @State private var narrator = CameraNarrator()
  @AccessibilityFocusState private var toolTitleFocused: Bool
  private var router: CameraSourceRouter { CameraSourceRouter.shared }
  private var hub: ToolHub { ToolHub.shared }

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(link: any GlassesLink) {
    self._viewModel = State(wrappedValue: link.makeCamera())
    self.link = link
  }

  private var isUpdateRequired: Bool {
    link.requiresFirmwareUpdate
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
        ScrollViewReader { scroll in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              FlowingVoiceIndicator()
              topBar
                .id(Self.topID)
              // Settings opens at the top. The tools come next; the mode switch and mic button
              // follow them (Settings has its own copy of the switch).
              if showSettingsMenu {
                settingsPanel
              }
              if isUpdateRequired, !usingPhone {
                CameraSourceCard(router: router, connectGlasses: connectGlasses)
                updateControls
                if !showSettingsMenu { HandsFreeControls() }
              } else if let open = hub.openTool {
                ToolPanelHeader(tool: open, isLargeText: isLargeText, close: { hub.close() })
                  .accessibilityFocused($toolTitleFocused)
                hub.tool(open).makePanel()
                if !showSettingsMenu { HandsFreeControls() }
                CameraSourceCard(router: router, connectGlasses: connectGlasses)
              } else {
                ToolsHome(openTool: openFromHome, status: speakStatus)
                ImportButton(subtitle: "Hear a photo, screenshot or PDF from your phone.")
                  .buttonStyle(.a11ySecondary)
                if !showSettingsMenu { HandsFreeControls() }
                CameraSourceCard(router: router, connectGlasses: connectGlasses)
                if link.supportsGlasses {
                  GlassesRow(link: link, connected: viewModel.hasActiveDevice, connect: connectGlasses)
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
          // A tool opened or closed: back to the top, where its name (or the list) is.
          .onChange(of: hub.openTool) { _, open in
            withAnimation(motion(.easeOut(duration: 0.2))) { scroll.scrollTo(Self.topID, anchor: .top) }
            guard open != nil else { return }
            Task {
              try? await Task.sleep(for: .milliseconds(300))
              toolTitleFocused = true
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    // Two-finger double-tap: read, or stop reading (or quiet the open tool).
    .accessibilityAction(.magicTap) { performPrimaryAction() }
    // Two-finger scrub closes the settings menu, then the open tool.
    .accessibilityAction(.escape) {
      if showSettingsMenu {
        setSettingsMenu(open: false)
      } else {
        hub.close()
      }
    }
    // No dialogs in hands-free: CameraNarrator says the error and "try again" runs its action.
    .alert(viewModel.errorTitle.isEmpty ? "Couldn't do that" : viewModel.errorTitle, isPresented: unlessHandsFree(showErrorBinding)) {
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
    .alert("Allow camera access", isPresented: unlessHandsFree(permissionPromptBinding)) {
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
        viewModel: viewModel, narrator: narrator, updateRequired: { [link] in link.requiresFirmwareUpdate },
        permissionYes: confirmCameraPermission, permissionNo: declineCameraPermission))
    // The router follows the glasses' link and presence to pick the camera.
    .onChange(of: link.isRegistered) { _, registered in router.registered = registered }
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
      router.glasses = viewModel.frameSource
      router.registered = link.isRegistered
      router.glassesConnected = viewModel.hasActiveDevice
      narrator.glassesInUse = { [router] in router.active == .glasses }
      LaunchActionRouter.shared.statusProvider = { [viewModel, link, router] in
        router.phoneStatusLine ?? viewModel.statusLine(updateRequired: link.requiresFirmwareUpdate)
      }
      TextReader.shared.source = router
      hub.source = router
      VoiceControl.shared.tools = hub
      VoiceControl.shared.setScreen(.camera, describe: describeForVoice, handler: handleVoice)
      // Spoken tips after a quiet spell ("Hold some text in front of you and say read").
      VoiceCoach.shared.provide(for: .camera) { [viewModel, link, router, hub] in
        // A tool has its own words; the tips are about reading.
        if let open = hub.openTool, open != .read { return nil }
        if router.active == .phone {
          return CoachSituation.forPhone(problem: router.phoneProblem, hasReadSentences: TextReader.shared.hasSentences)
        }
        return viewModel.coachSituation(
          updateRequired: link.requiresFirmwareUpdate, hasReadSentences: TextReader.shared.hasSentences)
      }
    }
    .onDisappear {
      hub.close(announce: false)
      if VoiceControl.shared.tools === hub { VoiceControl.shared.tools = nil }
      VoiceControl.shared.clearScreen { $0 == .camera }
      VoiceCoach.shared.stopProviding(for: .camera)
      LaunchActionRouter.shared.statusProvider = nil
      let reader = TextReader.shared
      if reader.source === router {
        if reader.isActive { reader.stop() }
        reader.source = nil
      }
      router.screenDisappeared()
      if router.glasses === viewModel.frameSource { router.glasses = nil }
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

  private static let topID = "camera_top"

  /// A tile on the tools home. Read text reads at once, as the one Read button always did.
  private func openFromHome(_ tool: ToolID) {
    setSettingsMenu(open: false)
    if tool == .read {
      readNow()
    } else {
      hub.open(tool)
    }
  }

  /// Read text, opened if it isn't, then read what's in view.
  private func readNow() {
    if hub.openTool != .read { hub.openReadTextQuietly() }
    TextReader.shared.read()
  }

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
    // The App Store build: the link only says that glasses need the Beta app. The setting stays.
    if link.supportsGlasses, A11yPreferences.shared.cameraSource == .phone { A11yPreferences.shared.cameraSource = .auto }
    link.connectGlasses()
  }

  /// Magic Tap: iOS's play/pause gesture. Stops a read in progress, otherwise reads. With an update
  /// pending nothing can be read, so it says the status instead.
  private func performPrimaryAction() {
    let reader = TextReader.shared
    if let open = hub.openTool, open != .read {
      Announcer.shared.stop()
      hub.stopForGlobal()
    } else if reader.isActive {
      reader.stop()
    } else if isUpdateRequired, !usingPhone {
      speakStatus()
    } else {
      readNow()
    }
  }

  private func runLaunchAction(_ action: LaunchAction?) {
    switch action {
    case .read: readNow()
    case .status: speakStatus()
    case .repeatLast: Announcer.shared.repeatLast()
    case .readImported:
      // Shown in Read text's panel, as any page is.
      if hub.openTool != .read { hub.openReadTextQuietly() }
      ImportedReading.readPending()
    case .openMail, .openLabels, .openWatch, .openAsk, .openLight:
      setSettingsMenu(open: false)
      if let tool = action?.tool { hub.open(tool) }
    case nil: break
    }
  }

  /// A voice command: the same calls as Siri, Magic Tap and the actions rotor. Returns false for
  /// what VoiceControl handles the same way on every screen (help, faster, slower, settings by
  /// voice, tools, where am I).
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    let reader = TextReader.shared
    switch command {
    case .read:
      setSettingsMenu(open: false)
      runLaunchAction(.read)
    case .status: runLaunchAction(.status)
    case .stop:
      // Stopping the reader also stops the voice; otherwise just cut what is being said. An open
      // tool also goes quiet (a tone, a watch loop, a barcode search) but stays open.
      if reader.isActive { reader.stop() } else { Announcer.shared.stop() }
      hub.stopForGlobal()
    case .repeatLast:
      if reader.hasSentences { reader.repeatSentence() } else { runLaunchAction(.repeatLast) }
    case .continueOn: reader.next()
    case .back:
      // Sentences first, as before (an open tool had "back" first); then out of settings; then out
      // of the tool; then the main menu line.
      if reader.hasSentences, hub.openTool == nil || hub.openTool == .read {
        reader.previous()
      } else if showSettingsMenu {
        closeSettings()
      } else if hub.openTool != nil {
        hub.close()
      } else {
        return false
      }
    case .close:
      if showSettingsMenu {
        closeSettings()
      } else if hub.openTool != nil {
        hub.close()
      } else {
        return false
      }
    case .mainMenu:
      setSettingsMenu(open: false)
      if reader.isActive { reader.stop() }
      hub.close(announce: false)
      return false  // VoiceControl says where that is
    case .help:
      // With a tool open: its own commands, then how to leave it. Otherwise the app's help.
      guard let tool = hub.current else { return false }
      Announcer.shared.say(SpokenMessage.toolHelp(tool.toolID, tool.helpLine))
    case .openSettings:
      setSettingsMenu(open: true)
      Announcer.shared.say(SpokenMessage.settingsOpened)
    case .openReader:
      setSettingsMenu(open: false)
      hub.open(.read)
    case .openMail, .openLabels, .openWatch, .openAsk, .openLight:
      // Usually ToolHub opened it already with the words said; this is a glasses display button.
      setSettingsMenu(open: false)
      if let tool = command.tool { hub.open(tool) }
    case .tryAgain:
      if let action = viewModel.errorAction {
        viewModel.errorAction = nil
        perform(action)
      } else {
        TextReader.shared.read()
      }
    case .connect:
      if link.isRegistered {
        Announcer.shared.say(SpokenMessage.alreadyConnected)
      } else {
        connectGlasses()
      }
    case .usePhone: router.choose(.phone)
    case .useGlasses:
      if link.supportsGlasses { router.choose(.glasses) } else { link.connectGlasses() }
    case .whichCamera: Announcer.shared.say(router.whichCameraLine)
    case .torchOn: router.setTorch(true)
    case .torchOff: router.setTorch(false)
    case .disconnect:
      link.disconnectGlasses()
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
    if showSettingsMenu { return "Settings are open. \(status)" }
    if let open = hub.openTool { return "\(open.title) is open. Say close to go back to the tools. \(status)" }
    return status
  }

  private func performTool(_ tool: HandsFreeTool) {
    switch tool {
    case .status: speakStatus()
    case .settings: setSettingsMenu(open: !showSettingsMenu)
    default: if let open = tool.tool { openFromHome(open) }
    }
  }

  private func confirmCameraPermission() {
    // The view model resumes the read only once "Camera access allowed" has been heard to the end.
    // If something else cut that line (a camera status line), the read would never carry on, so
    // once speech is quiet (at most 4 s) it carries on here instead, unless access was refused.
    let resumed = ResumeFlag()
    Task {
      await viewModel.confirmCameraPermissionRedirect {
        guard !resumed.done else { return }
        resumed.done = true
        readNow()
      }
      var waited = 0
      while waited < 40, !resumed.done, Announcer.shared.isSpeaking {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      guard !resumed.done, !viewModel.showError, viewModel.isSessionActive, !TextReader.shared.isActive else { return }
      resumed.done = true
      readNow()
    }
  }

  private func declineCameraPermission() {
    viewModel.showCameraPermissionRedirectConfirm = false
    narrator.cameraPermissionPromptCancelled()
  }

  /// An alert binding that stays down in hands-free, where the narrator speaks instead.
  private func unlessHandsFree(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue && !A11yPreferences.shared.handsFree }, set: { binding.wrappedValue = $0 })
  }

  private var showErrorBinding: Binding<Bool> {
    Binding(get: { [viewModel] in viewModel.showError }, set: { [viewModel] in viewModel.showError = $0 })
  }

  private var permissionPromptBinding: Binding<Bool> {
    Binding(
      get: { [viewModel] in viewModel.showCameraPermissionRedirectConfirm },
      set: { [viewModel] in viewModel.showCameraPermissionRedirectConfirm = $0 })
  }

  // MARK: - The glasses display card

  /// One line: what the reader is doing, else the status title.
  private var cardState: String {
    let reader = TextReader.shared
    let readerShown = hub.openTool == .read || hub.openTool == nil
    if readerShown, reader.phase != .idle { return reader.statusText }
    if showSettingsMenu { return "Settings" }
    if let open = hub.openTool { return open.title }
    return status.title
  }

  private var cardHints: [VoiceCommand] {
    let readerShown = hub.openTool == .read || hub.openTool == nil
    if readerShown, TextReader.shared.isActive { return [.stop, .continueOn, .mainMenu] }
    if readerShown, TextReader.shared.hasSentences { return [.read, .continueOn, .back] }
    if showSettingsMenu { return [.faster, .slower, .close] }
    if hub.openTool != nil { return [.stop, .close, .help] }
    return [.read, .listTools, .help]
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
      Task { await link.openDATGlassesAppUpdate() }
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
      .accessibilityHint(
        link.supportsGlasses
          ? "Shows voice control, voice, reading voice, Replay setup and Disconnect."
          : "Shows voice control, voice, reading voice and Replay setup.")
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
    if viewModel.hinge == .closed {
      return Status(title: "Glasses folded", subtitle: "Unfold them to read.", mood: .idle)
    }
    if viewModel.isPaused {
      let removed = viewModel.wear == .doffed
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
      MakeItYourOwnEntry()
      ReadingSettingsRows()
      CustomButton(title: "Replay setup", style: .secondary, isDisabled: false) {
        setSettingsMenu(open: false)
        A11yPreferences.shared.resetOnboarding()
      }
      .accessibilityHint("Goes through the sounds, speaker test and detail level again.")
      // The App Store build has no glasses, so nothing to connect or disconnect.
      if link.supportsGlasses {
        if !link.isRegistered {
          CustomButton(title: "Connect my glasses", style: .secondary, isDisabled: link.isConnecting) {
            setSettingsMenu(open: false)
            connectGlasses()
          }
          .accessibilityHint("Optional. Opens the Meta AI app to link your glasses, then come back.")
          .accessibilityIdentifier("settings_connect_glasses_button")
        }
        CustomButton(
          title: "Disconnect",
          style: .destructive,
          isDisabled: !link.isRegistered
        ) {
          link.disconnectGlasses()
          setSettingsMenu(open: false)
        }
        .accessibilityHint("Disconnects this app from your glasses. You'd connect again through Meta AI.")
      }
    }
    .themeCard()
    .transition(.opacity)
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
        await link.openFirmwareUpdate()
        isLaunchingUpdate = false
      }
    }
    .accessibilityIdentifier("update_firmware_button")
    .accessibilityHint("Opens the Meta AI app to update your glasses.")
  }
}

/// Whether the Read that asked for camera access has carried on (confirmCameraPermission).
@MainActor
private final class ResumeFlag {
  var done = false
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
