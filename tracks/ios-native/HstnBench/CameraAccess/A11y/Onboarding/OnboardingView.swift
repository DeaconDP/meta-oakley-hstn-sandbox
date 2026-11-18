/*
 * OnboardingView - the one screen before the app (notes/a11y-onboarding.md, "One screen", 2026-11-17)
 *
 * The mascot says what SpeakUp does, one safety sentence, and what happens next. One big Connect
 * glasses button starts registration with Meta AI straight away. Not now goes to the app.
 *
 * Coming back from Meta AI: WearablesViewModel says "Connected to …. Hold up a page and say read."
 * and this screen hands over to the main screen. If it didn't finish, the view model says why, the
 * screen shows it, and the button becomes Try again. Every action works by voice ("connect", "try
 * again", "not now", "repeat"), by button, and with VoiceOver.
 *
 * Nothing else is asked. The audio route is detected, not tested: after connecting, a tip if sound
 * is still on the phone speaker. Verbosity and speech rate keep their defaults and live in
 * Settings. Voice control asks for the microphone and speech recognition here, after one spoken
 * sentence (VoiceControl.promptForPermissions), queued behind the welcome line.
 *
 * MainAppView shows it while A11yPreferences.onboardingCompleted is false, so "Replay setup" is
 * `A11yPreferences.shared.resetOnboarding()`. Reaching the main screen, or Not now, marks it done.
 */

import MWDATCore
import SwiftUI

struct OnboardingView: View {
  var wearablesViewModel: WearablesViewModel

  @AccessibilityFocusState private var titleFocused: Bool

  private let preferences = A11yPreferences.shared

  /// Kept in A11yPreferences.onboardingStep while Meta AI has the user. If the app is relaunched
  /// and finds itself registered, it goes straight on instead of offering to connect again.
  static let connectingMarker = "connecting"

  private var isRegistered: Bool { wearablesViewModel.registrationState == .registered }

  /// Why the last attempt didn't connect. Not shown once registered.
  private var notice: String? { isRegistered ? nil : wearablesViewModel.connectionNotice }

  var body: some View {
    VStack(spacing: 0) {
      PinnedVoiceIndicator()
      LessonPage {
        content
      } footer: {
        footer
      }
    }
    .background(Theme.page.ignoresSafeArea())
    .onAppear { appeared() }
    .onDisappear {
      // Leaving without connecting: a later connection shouldn't get setup's follow-up.
      wearablesViewModel.connectedFollowUp = nil
      VoiceControl.shared.clearScreen { $0 == .welcome }
      VoiceCoach.shared.stopProviding(for: .welcome)
    }
    .onChange(of: wearablesViewModel.registrationState) { _, state in
      // WearablesViewModel has said "Connected to …" with connectedFollowUp as one line.
      if state == .registered { finishConnected(alreadySpoken: true) }
    }
    .onChange(of: wearablesViewModel.connectionNotice) { _, newNotice in
      // Queued behind the reason, which the view model has just said.
      if newNotice != nil, !isRegistered { speakKeyLine(SpokenMessage.welcomeRetry) }
    }
    // "Connecting…" otherwise only changes visually.
    .a11yAnnounce(onChangeOf: wearablesViewModel.isConnecting) { connecting in
      connecting ? "Connecting." : nil
    }
    // A container, so the identifier stays on the screen and doesn't land on what's inside it.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("onboarding_welcome")
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    FlowingVoiceIndicator()
    Text("Welcome to SpeakUp")
      .font(.rounded(.largeTitle, weight: .black))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
      .accessibilityFocused($titleFocused)
    MascotSays(mood: notice == nil ? .happy : .confused, mascotSize: 96) {
      A11yNote(text: SpokenMessage.welcomeIntro)
      A11yNote(text: nextStepLine)
    }
    if let notice {
      ConnectionNoticeView(text: notice)
    }
    A11yNote(text: SpokenMessage.safetyNote)
      .themeCard()
      .accessibilityIdentifier("onboarding_safety_note")
  }

  @ViewBuilder
  private var footer: some View {
    if isRegistered {
      Button("Start reading", action: startReading)
        .buttonStyle(.a11yPrimary)
        .sayHint(.continueOn)
        .accessibilityHint("Goes to the main screen.")
        .accessibilityIdentifier("onboarding_start_button")
    } else {
      // Identifier shared with the home screen's button, so tests find either the same way.
      Button(connectTitle, action: connect)
        .buttonStyle(.a11yPrimary)
        .sayHint(notice == nil ? .connect : .tryAgain)
        .disabled(wearablesViewModel.isConnecting)
        .accessibilityHint(
          wearablesViewModel.isConnecting ? "" : "Opens the Meta AI app. Choose Connect there, then come back.")
        .accessibilityIdentifier("connect_glasses_button")
      Button("Not now", action: notNow)
        .buttonStyle(.a11ySecondary)
        .sayHint(.no)
        .accessibilityHint("Goes to the app without connecting. You can connect from there.")
        .accessibilityIdentifier("onboarding_not_now_button")
    }
  }

  private var connectTitle: String {
    if wearablesViewModel.isConnecting { return "Connecting…" }
    return notice == nil ? "Connect glasses" : "Try again"
  }

  /// The second half of the bubble: what to do now.
  private var nextStepLine: String {
    if isRegistered { return SpokenMessage.welcomeAlreadyConnected }
    return notice == nil ? SpokenMessage.welcomeConnect : SpokenMessage.welcomeRetry
  }

  /// Everything the screen says when it appears, safety sentence included.
  private var welcomeLine: String {
    let next = isRegistered ? SpokenMessage.welcomeAlreadyConnected : SpokenMessage.welcomeConnect
    return "\(SpokenMessage.welcomeIntro) \(SpokenMessage.safetyNote) \(next)"
  }

  // MARK: Actions

  private func appeared() {
    // Back after Meta AI finished while the app wasn't running: nothing left to ask.
    if isRegistered, preferences.onboardingStep == Self.connectingMarker {
      finishConnected(alreadySpoken: false)
      return
    }
    wearablesViewModel.connectedFollowUp = SpokenMessage.connectedNext
    focusTitle()
    // Before setScreen: if voice control still needs permission, its one-sentence explanation and
    // the system dialogs queue behind this line instead of cutting it off.
    speakKeyLine(welcomeLine)
    VoiceControl.shared.setScreen(.welcome, describe: { [wearablesViewModel] in
      wearablesViewModel.registrationState == .registered ? SpokenMessage.welcomeAlreadyConnected : SpokenMessage.welcomeConnect
    }, handler: handleVoice)
    HandsFreeSurface.shared.publish(screen: .welcome, state: "Connect your glasses", hints: [.connect, .no, .help])
    VoiceCoach.shared.provide(for: .welcome) { [wearablesViewModel] in
      // Nothing to suggest while Meta AI is being opened or waited for.
      if wearablesViewModel.isConnecting { return nil }
      if wearablesViewModel.registrationState == .registered { return .welcomeConnected }
      return wearablesViewModel.connectionNotice == nil ? .welcome : .welcomeRetry
    }
  }

  private func connect() {
    // The failure alert, if it is still up, would sit over Meta AI's return.
    wearablesViewModel.dismissError()
    preferences.onboardingStep = Self.connectingMarker
    wearablesViewModel.connectGlasses()
  }

  /// Replay setup with the glasses already connected.
  private func startReading() {
    finishConnected(alreadySpoken: false)
  }

  private func notNow() {
    wearablesViewModel.dismissError()
    Announcer.shared.say(SpokenMessage.setupNotNow)
    complete()
  }

  /// `alreadySpoken`: WearablesViewModel has just said "Connected to …. Hold up a page and say read."
  private func finishConnected(alreadySpoken: Bool) {
    if !alreadySpoken {
      Announcer.shared.announce(SpokenMessage.setupConnected, earcon: .connected, interrupt: false)
    }
    // Detect, don't test: say so only when the sound isn't reaching the glasses.
    if Announcer.shared.currentOutputDescription() == "phone speaker" {
      Announcer.shared.say(SpokenMessage.soundOnPhoneSpeaker, interrupt: false)
    }
    complete()
  }

  /// Done either way: reaching the app is the end of setup, and it can be replayed. The safety
  /// sentence was on this screen, so the main screen doesn't repeat the long disclaimer.
  private func complete() {
    preferences.disclaimerHeard = true
    preferences.onboardingStep = nil
    preferences.onboardingCompleted = true
  }

  /// The same calls the buttons make. VoiceCommandParser only lets through what's valid here;
  /// help, stop, faster and slower are VoiceControl's own.
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    switch command {
    case .connect, .tryAgain, .yes, .continueOn:
      if isRegistered { startReading() } else { connect() }
    case .no:
      notNow()
    case .repeatLast:
      // Repeat this screen's words, even with VoiceOver: the user asked out loud.
      let line = notice.map { "\($0) \(SpokenMessage.welcomeRetry)" } ?? welcomeLine
      Announcer.shared.say(line)
    default:
      return false
    }
    return true
  }

  /// VoiceOver focus on the title, once the screen is in the accessibility tree.
  private func focusTitle() {
    titleFocused = false
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      titleFocused = true
    }
  }

  /// Speaks a line of this screen, queued, only in hands-free and without VoiceOver. The toolbox has
  /// no start-up narration (notes/hands-free-mode.md). With VoiceOver, focus moves to the title and
  /// VoiceOver reads the screen in the user's own voice; speaking as well would be cut off by, or
  /// talk over, VoiceOver.
  private func speakKeyLine(_ text: String) {
    guard preferences.handsFree, !UIAccessibility.isVoiceOverRunning else { return }
    Announcer.shared.say(text, interrupt: false)
  }
}

/// The last failed attempt, shown so it can be read as well as heard. Marked with a symbol and
/// the words "Not connected", not colour alone.
struct ConnectionNoticeView: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.rounded(.title3, weight: .bold))
        .foregroundStyle(Theme.onFace(.orange))
        .a11yDecorative()
      Text(text)
        .font(.rounded(.body, weight: .semibold))
        .foregroundStyle(Theme.onFace(.orange))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(Theme.face(.orange), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.lip(.orange), lineWidth: 2)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Not connected. \(text)")
    .accessibilityIdentifier("connection_notice")
  }
}
