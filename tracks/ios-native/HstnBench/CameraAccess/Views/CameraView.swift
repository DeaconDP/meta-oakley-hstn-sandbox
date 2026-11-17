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
          VStack(alignment: .leading, spacing: Theme.Space.lg) {
            FlowingVoiceIndicator()
            topBar
            if isUpdateRequired {
              updateControls
            } else {
              readButton
              if TextReader.shared.phase != .idle {
                ReadPanel(isLargeText: isLargeText, onStatus: speakStatus)
                  .transition(.opacity)
              }
            }
          }
          .stateAnimation(value: TextReader.shared.phase == .idle)
          .padding(.horizontal, Theme.Space.lg)
          .padding(.top, Theme.Space.lg)
          .padding(.bottom, Theme.Space.xl)
          .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    // A sheet, so opening Settings never pushes Read text off the screen.
    .sheet(isPresented: $showSettingsMenu) { settingsSheet }
    .accessibilityElement(children: .contain)
    // Two-finger double-tap: read, or stop reading.
    .accessibilityAction(.magicTap) { performPrimaryAction() }
    // Two-finger scrub closes the settings menu.
    .accessibilityAction(.escape) { setSettingsMenu(open: false) }
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
      // The Read that asked for access carries on once it's allowed.
      Button("Continue") { Task { await viewModel.confirmCameraPermissionRedirect { TextReader.shared.read() } } }
      Button("Cancel", role: .cancel) { narrator.cameraPermissionPromptCancelled() }
    } message: {
      Text(SpokenMessage.cameraPermissionBeforeRedirect)
    }
    .modifier(CameraNarration(viewModel: viewModel, narrator: narrator, updateRequired: { wearablesVM.requiresFirmwareUpdate }))
    // Both alerts answer to voice too ("yes", "try again", "OK"...).
    .modifier(CameraVoicePrompts(viewModel: viewModel, narrator: narrator, perform: perform))
    // Siri / Shortcuts / Back Tap. Cold launch: the intent parked the action before this view existed.
    // The appear sequence (CameraNarrator.screenAppeared) waits for the device stream first, so a
    // cold-launch "Read" or "Status" sees the real glasses state; it then speaks the status line
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
      VoiceControl.shared.setScreen(.camera, canUpdate: { [wearablesVM] in wearablesVM.requiresFirmwareUpdate }, handler: handleVoice)
      // Spoken tips after a quiet spell ("Hold some text in front of you and say read").
      VoiceCoach.shared.provide(for: .camera) { [viewModel, wearablesVM] in
        viewModel.coachSituation(
          updateRequired: wearablesVM.requiresFirmwareUpdate, hasReadSentences: TextReader.shared.hasSentences)
      }
    }
    .onDisappear {
      VoiceControl.shared.clearScreen { $0 == .camera }
      VoiceCoach.shared.stopProviding(for: .camera)
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

  private func setSettingsMenu(open: Bool) {
    guard showSettingsMenu != open else { return }
    withAnimation(Theme.stateChange(reduceMotion: reduceMotion)) {
      showSettingsMenu = open
    }
  }

  private func speakStatus() {
    viewModel.speakStatus(updateRequired: isUpdateRequired)
  }

  /// Magic Tap: iOS's play/pause gesture. Stops a read in progress, otherwise reads. With an update
  /// pending nothing can be read, so it says the status instead.
  private func performPrimaryAction() {
    let reader = TextReader.shared
    if reader.isActive {
      reader.stop()
    } else if isUpdateRequired {
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
  /// what VoiceControl handles the same way on every screen (help, faster, slower).
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    let reader = TextReader.shared
    switch command {
    case .read: runLaunchAction(.read)
    case .status: runLaunchAction(.status)
    case .stop:
      // Stopping the reader also stops the voice; otherwise cut what is being said, and drop a read
      // still waiting behind "Camera access allowed".
      if reader.isActive {
        reader.stop()
      } else {
        reader.cancelPendingRead()
        Announcer.shared.stop()
      }
    case .repeatLast:
      if reader.hasSentences { reader.repeatSentence() } else { runLaunchAction(.repeatLast) }
    // After a stop, continue starts the stopped sentence again; next always moves on.
    case .continueOn: reader.continueReading()
    case .next: reader.next()
    case .back: reader.previous()
    case .resume: reader.resume()
    case .update:
      // The same as the Update firmware button, with the same guard against a double launch.
      guard !isLaunchingUpdate else { break }
      isLaunchingUpdate = true
      Task {
        await wearablesVM.openFirmwareUpdate()
        isLaunchingUpdate = false
      }
    case .disconnect: wearablesVM.disconnectByVoice()
    case .goodbye:
      // VoiceControl then stops listening and says how to come back.
      if reader.isActive { reader.stop() }
      viewModel.endSession()
      return false
    default: return false
    }
    return true
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

  /// The app's name with Settings at the right, then the mascot saying what the glasses are doing,
  /// across the full width so its words get room.
  private var topBar: some View {
    VStack(alignment: .leading, spacing: Theme.Space.md) {
      HStack(alignment: .center, spacing: Theme.Space.sm) {
        Text("SpeakUp")
          .font(.rounded(.title, weight: .black))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        settingsButton
      }
      statusCard
    }
  }

  private var settingsButton: some View {
    Group {
      Button {
        setSettingsMenu(open: !showSettingsMenu)
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.rounded(.title3, weight: .heavy))
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5, radius: Theme.Radius.pill))
      .frame(width: Theme.touchTargetMin + Theme.Space.xs)
      .accessibilityIdentifier("settings_button")
      .accessibilityLabel("Settings")
      .accessibilityValue(showSettingsMenu ? "Open" : "Closed")
      .accessibilityHint("Shows voice control, voice, reading voice, light or dark, Replay setup and Disconnect.")
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
    return Status(
      title: "Ready to read", subtitle: "Hold some text in front of you, then say \u{201C}read\u{201D}, or tap Read text.",
      mood: readerMood ?? .happy)
  }

  /// The one mascot on this screen follows the reader too: looking at its book while it works and
  /// reads, pleased when the page is done, puzzled when it couldn't read.
  private var readerMood: MascotMood? {
    switch TextReader.shared.phase {
    case .preparing, .recognizing, .reading: .reading
    case .finished: .happy
    case .guided: .confused
    case .idle, .stopped: nil
    }
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
      if let battery = viewModel.batteryLevel, battery <= cameraBatteryWarningPercent {
        Label("Glasses battery \(battery)%", systemImage: "battery.25percent")
          .font(.rounded(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .stateAnimation(value: status.title)
  }

  /// A full-height sheet that scrolls at any text size. The main screen stays as it was underneath,
  /// with Read text where the user left it.
  private var settingsSheet: some View {
    // At accessibility text sizes the title and Done stack, so neither word breaks.
    let headerLayout = isLargeText
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
      : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Space.md))
    return VStack(spacing: 0) {
      headerLayout {
        Text("Settings")
          .font(.rounded(.largeTitle, weight: .black))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        Button("Done") { setSettingsMenu(open: false) }
          .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 4, radius: Theme.Radius.pill))
          .frame(maxWidth: isLargeText ? .infinity : 120)
          .accessibilityHint("Closes Settings.")
          .accessibilityIdentifier("settings_done_button")
      }
      .padding(.horizontal, Theme.Space.lg)
      .padding(.top, Theme.Space.lg)
      .padding(.bottom, Theme.Space.md)
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
          VStack(alignment: .leading, spacing: Theme.Space.sm) {
            settingsSectionTitle("Voice")
            VoiceSettingsRows()
          }
          .themeCard()
          VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ReadingSettingsRows()
          }
          .themeCard()
          VStack(alignment: .leading, spacing: Theme.Space.sm) {
            settingsSectionTitle("Look and setup")
            CustomButton(
              title: "Appearance: \(ThemeAppearance.shared.mode.title)", style: .secondary,
              isDisabled: false
            ) {
              ThemeAppearance.shared.cycle()
            }
            .accessibilityHint("Switches between matching the phone, dark and light. Text stays high contrast in each.")
            .accessibilityIdentifier("appearance_toggle")
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
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xl)
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .background(Theme.page.ignoresSafeArea())
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(Theme.page)
    // Two-finger scrub closes it, as on the main screen.
    .accessibilityAction(.escape) { setSettingsMenu(open: false) }
  }

  private func settingsSectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.rounded(.title2, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
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
    .buttonStyle(ChunkyButtonStyle(tone: .yellow, lipHeight: 8, radius: Theme.Radius.xl))
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
