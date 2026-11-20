/*
 * OnboardingView - the one screen before the app (notes/a11y-onboarding.md, "One screen", 2026-11-17)
 *
 * The mascot says what SpeakUp does, one safety sentence, and what happens next. Two choices
 * (V0 "Glasses optional"): Use my iPhone's camera goes straight to the main screen with no Meta AI
 * and no registration; Connect glasses starts registration with Meta AI. "Not now" by voice is the
 * phone choice. Glasses can be connected later from Settings or the camera switch.
 *
 * The App Store build (GlassesLink.supportsGlasses false, no DAT) has one button, Start reading,
 * which goes straight to the phone camera. Its welcome line doesn't mention glasses.
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
 * `A11yPreferences.shared.resetOnboarding()`. Reaching the main screen either way marks it done.
 */

import SwiftUI

struct OnboardingView: View {
  var link: any GlassesLink

  @AccessibilityFocusState private var titleFocused: Bool

  private let preferences = A11yPreferences.shared

  /// Kept in A11yPreferences.onboardingStep while Meta AI has the user. If the app is relaunched
  /// and finds itself registered, it goes straight on instead of offering to connect again.
  static let connectingMarker = "connecting"

  private var isRegistered: Bool { link.isRegistered }

  /// Why the last attempt didn't connect. Not shown once registered.
  private var notice: String? { isRegistered ? nil : link.connectionNotice }

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
      link.connectedFollowUp = nil
      VoiceControl.shared.clearScreen { $0 == .welcome }
      VoiceCoach.shared.stopProviding(for: .welcome)
    }
    .onChange(of: link.isRegistered) { _, registered in
      // WearablesViewModel has said "Connected to …" with connectedFollowUp as one line.
      if registered { finishConnected(alreadySpoken: true) }
    }
    .onChange(of: link.connectionNotice) { _, newNotice in
      // Queued behind the reason, which the view model has just said.
      if newNotice != nil, !isRegistered { speakKeyLine(SpokenMessage.welcomeRetry) }
    }
    // "Connecting…" otherwise only changes visually.
    .a11yAnnounce(onChangeOf: link.isConnecting) { connecting in
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
      A11yNote(text: introLine)
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
    if !link.supportsGlasses {
      // The App Store build: no glasses, so one button straight to the phone camera.
      Button("Start reading", action: usePhone)
        .buttonStyle(.a11yPrimary)
        .sayHint(.continueOn)
        .accessibilityHint("Goes to the main screen. Reads with this iPhone's camera.")
        .accessibilityIdentifier("onboarding_use_phone_button")
    } else if isRegistered {
      Button("Start reading", action: startReading)
        .buttonStyle(.a11yPrimary)
        .sayHint(.continueOn)
        .accessibilityHint("Goes to the main screen.")
        .accessibilityIdentifier("onboarding_start_button")
    } else {
      Button("Use my iPhone's camera", action: usePhone)
        .buttonStyle(.a11yPrimary)
        .sayHint(.usePhone)
        .accessibilityHint("Starts reading with this iPhone's camera. No glasses or Meta AI needed.")
        .accessibilityIdentifier("onboarding_use_phone_button")
      // Identifier shared with the home screen's button, so tests find either the same way.
      Button(connectTitle, action: connect)
        .buttonStyle(.a11ySecondary)
        .sayHint(notice == nil ? .connect : .tryAgain)
        .disabled(link.isConnecting)
        .accessibilityHint(
          link.isConnecting ? "" : "Opens the Meta AI app. Choose Connect there, then come back.")
        .accessibilityIdentifier("connect_glasses_button")
    }
  }

  private var connectTitle: String {
    if link.isConnecting { return "Connecting…" }
    return notice == nil ? "Connect glasses" : "Try again"
  }

  /// The first half of the bubble: what SpeakUp is. The App Store build doesn't mention glasses.
  private var introLine: String {
    link.supportsGlasses ? SpokenMessage.welcomeIntro : SpokenMessage.welcomeIntroPhoneOnly
  }

  /// The second half of the bubble: what to do now.
  private var nextStepLine: String {
    if !link.supportsGlasses { return SpokenMessage.welcomeStartPhoneOnly }
    if isRegistered { return SpokenMessage.welcomeAlreadyConnected }
    return notice == nil ? SpokenMessage.welcomeConnect : SpokenMessage.welcomeRetry
  }

  /// The next step as said on appearing and by "where am I".
  private var startLine: String {
    if !link.supportsGlasses { return SpokenMessage.welcomeStartPhoneOnly }
    return isRegistered ? SpokenMessage.welcomeAlreadyConnected : SpokenMessage.welcomeConnect
  }

  /// Everything the screen says when it appears, safety sentence included.
  private var welcomeLine: String {
    "\(introLine) \(SpokenMessage.safetyNote) \(startLine)"
  }

  // MARK: Actions

  private func appeared() {
    // Back after Meta AI finished while the app wasn't running: nothing left to ask.
    if isRegistered, preferences.onboardingStep == Self.connectingMarker {
      finishConnected(alreadySpoken: false)
      return
    }
    link.connectedFollowUp = SpokenMessage.connectedNext
    focusTitle()
    // Before setScreen: if voice control still needs permission, its one-sentence explanation and
    // the system dialogs queue behind this line instead of cutting it off.
    speakKeyLine(welcomeLine)
    VoiceControl.shared.setScreen(.welcome, describe: { [link] in
      if !link.supportsGlasses { return SpokenMessage.welcomeStartPhoneOnly }
      return link.isRegistered ? SpokenMessage.welcomeAlreadyConnected : SpokenMessage.welcomeConnect
    }, handler: handleVoice)
    if link.supportsGlasses {
      HandsFreeSurface.shared.publish(screen: .welcome, state: "Phone or glasses", hints: [.usePhone, .connect, .help])
    } else {
      HandsFreeSurface.shared.publish(screen: .welcome, state: "Welcome", hints: [.continueOn, .help])
    }
    VoiceCoach.shared.provide(for: .welcome) { [link] in
      // The welcome tips name the glasses; the App Store build has one button and says so already.
      if !link.supportsGlasses { return nil }
      // Nothing to suggest while Meta AI is being opened or waited for.
      if link.isConnecting { return nil }
      if link.isRegistered { return .welcomeConnected }
      return link.connectionNotice == nil ? .welcome : .welcomeRetry
    }
  }

  private func connect() {
    // The failure alert, if it is still up, would sit over Meta AI's return.
    link.dismissError()
    preferences.onboardingStep = Self.connectingMarker
    // Once linked, auto reads with the glasses (and falls back to the phone without them).
    if preferences.cameraSource == .phone { preferences.cameraSource = .auto }
    link.connectGlasses()
  }

  /// Replay setup with the glasses already connected.
  private func startReading() {
    finishConnected(alreadySpoken: false)
  }

  /// The iPhone's camera: no Meta AI, no registration. Straight to the main screen, Read enabled.
  private func usePhone() {
    link.dismissError()
    preferences.cameraSource = .phone
    Announcer.shared.announce(SpokenMessage.setupUsePhone, earcon: .ready)
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
    // The App Store build: anything that moves on starts with the phone; asking for glasses says
    // they need the Beta app.
    if !link.supportsGlasses {
      switch command {
      case .continueOn, .yes, .usePhone, .no: usePhone()
      case .connect, .tryAgain, .useGlasses: link.connectGlasses()
      case .repeatLast: Announcer.shared.say(welcomeLine)
      default: return false
      }
      return true
    }
    switch command {
    case .connect, .tryAgain, .yes, .continueOn, .useGlasses:
      if isRegistered { startReading() } else { connect() }
    case .usePhone, .no:
      usePhone()
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
