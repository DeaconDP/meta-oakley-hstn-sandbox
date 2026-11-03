/*
 * OnboardingSteps - the screens OnboardingView steps through
 *
 * Each step is one focused screen: the mascot saying its key line, then its choices, with the main
 * button and skip and leave at the bottom. The bubble shows the words the step speaks. Speech that
 * the user should be able to cut off or replay (test phrases, samples, the disclaimer) uses the
 * app's own voice (`.reply`), so it goes down the same audio route the app will use for answers and
 * queues in order instead of overlapping VoiceOver announcements.
 */

import AVFoundation
import Combine
import SwiftUI

// MARK: - Welcome

/// One question only (notes/a11y-onboarding.md, "Detect, don't ask").
struct WelcomeStep: View {
  var speak: OnboardingSpeak
  var onGuided: () -> Void
  var onSkip: () -> Void

  var body: some View {
    LessonPage {
      MascotSays(mood: .happy, text: SpokenMessage.welcome, mascotSize: 96)
    } footer: {
      Button("Start guided setup", action: onGuided)
        .buttonStyle(.a11yPrimary)
        .sayHint(.yes)
        .accessibilityHint("About five minutes. Every step can be skipped.")
        .accessibilityIdentifier("onboarding_guided_button")
      Button("Skip to the app", action: onSkip)
        .buttonStyle(.a11ySecondary)
        .sayHint(.skip)
        .accessibilityHint("You can replay setup later.")
        .accessibilityIdentifier("onboarding_skip_button")
    }
    .onAppear { speak(SpokenMessage.welcome, .status) }
  }
}

// MARK: - Learn the sounds

struct LearnSoundsStep: View {
  var speak: OnboardingSpeak
  var onContinue: () -> Void
  var onSkip: () -> Void
  var onExit: () -> Void

  var body: some View {
    LessonPage {
      MascotSays(mood: .listening, text: SpokenMessage.learnSoundsIntro)
      VStack(spacing: 12) {
        ForEach(Earcon.allCases, id: \.self) { earcon in
          Button {
            Announcer.shared.announce(earcon.spokenMeaning, earcon: earcon, kind: .reply)
          } label: {
            HStack(spacing: 12) {
              TileCoin(icon: "speaker.wave.2.fill", tone: .blue, size: 44)
              VStack(alignment: .leading, spacing: 2) {
                Text(earcon.displayName)
                  .font(.rounded(.headline, weight: .heavy))
                Text(earcon.spokenMeaning)
                  .font(.rounded(.callout, weight: .medium))
              }
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The button has the name. The meaning is spoken on activation; reading it first as
            // well would say it twice.
            .accessibilityHidden(true)
          }
          .buttonStyle(.a11ySecondary)
          .accessibilityLabel("\(earcon.displayName) sound")
          .accessibilityHint("Plays the sound and says what it means.")
          .accessibilityIdentifier("onboarding_earcon_\(earcon.rawValue)")
        }
      }
    } footer: {
      Button("Continue", action: onContinue)
        .buttonStyle(.a11yPrimary)
        .sayHint(.continueOn)
        .accessibilityIdentifier("onboarding_continue_button")
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear { speak(SpokenMessage.learnSoundsIntro, .status) }
  }
}

extension Earcon {
  /// The name shown and read for the sound in the tutorial.
  var displayName: String {
    switch self {
    case .ready: "Ready"
    case .connected: "Connected"
    case .disconnected: "Disconnected"
    case .listening: "Listening"
    case .capturing: "Photo taken"
    case .working: "Working"
    case .done: "Answer ready"
    case .error: "Problem"
    case .uncertain: "Not sure"
    case .attention: "Needs you"
    case .heard: "Command understood"
    }
  }
}

// MARK: - Speaker test

/// Checks that the app's audio reaches the glasses over A2DP (stage 5, "Speaker test").
struct SpeakerTestStep: View {
  var speak: OnboardingSpeak
  var onContinue: () -> Void
  var onSkip: () -> Void
  var onExit: () -> Void

  /// The user said they didn't hear the test, so the fixes are showing.
  @State private var showFixes = false
  /// Until the first play the button says "Play test", after it "Replay".
  @State private var hasPlayed = false
  @State private var output = Announcer.shared.currentOutputDescription()

  var body: some View {
    LessonPage {
      MascotSays(mood: showFixes ? .confused : .listening, text: SpokenMessage.speakerTestIntro(output: output))
      Text("Sound is going to: \(output)")
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("onboarding_output_label")

      if !showFixes {
        Text(SpokenMessage.speakerTestQuestion)
          .font(.rounded(.title2, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      } else {
        Text("Things to check")
          .font(.rounded(.title2, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: 12) {
          bullet("Wear the glasses with the arms unfolded.")
          bullet("In the phone's Bluetooth settings, check the glasses are connected.")
          bullet("Turn the volume up with the phone's side buttons.")
        }
        .themeCard()
      }
      // First of the choices: with VoiceOver nothing plays until this is pressed.
      replayButton
    } footer: {
      if !showFixes {
        // No "good, it works" line: the next step's key line would cut it off anyway.
        Button("Yes, I heard it", action: onContinue)
          .buttonStyle(.a11yPrimary)
          .sayHint(.yes)
          .accessibilityIdentifier("onboarding_heard_yes_button")
        Button("No") {
          showFixes = true
          // Status, so with VoiceOver it is spoken by VoiceOver rather than over it.
          Announcer.shared.say(SpokenMessage.speakerTestFixes)
        }
        .buttonStyle(.a11ySecondary)
        .sayHint(.no)
        .accessibilityHint("Gives a few things to check.")
        .accessibilityIdentifier("onboarding_heard_no_button")
      } else {
        Button("Continue anyway", action: onContinue)
          .buttonStyle(.a11yPrimary)
          .sayHint(.continueOn)
          .accessibilityIdentifier("onboarding_continue_button")
      }
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear {
      VoiceControl.shared.stepHandler = { command in
        switch command {
        case .yes: onContinue()
        case .no:
          showFixes = true
          Announcer.shared.say(SpokenMessage.speakerTestFixes)
        case .testSpeaker:
          showFixes = false
          playTest()
        default: return false
        }
        return true
      }
      // With VoiceOver the user reads the screen and presses Play test when ready: playing on
      // appear would talk over VoiceOver reading the title.
      guard !UIAccessibility.isVoiceOverRunning else { return }
      speak(SpokenMessage.speakerTestIntro(output: output), .reply)
      // Queued behind the intro, tone included, so it doesn't land on top of it. Leaving the
      // step stops the queue (OnboardingView.go), so it can't play on the next screen.
      playTest(interrupt: false)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        .receive(on: DispatchQueue.main)
    ) { _ in
      output = Announcer.shared.currentOutputDescription()
    }
  }

  private var replayButton: some View {
    Button {
      showFixes = false
      playTest()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "play.fill")
          .accessibilityHidden(true)
        Text(hasPlayed ? "Replay" : "Play test")
      }
    }
    .buttonStyle(.a11ySecondary)
    .sayHint(.testSpeaker)
    .accessibilityHint("Plays a tone and a short sentence.")
    .accessibilityIdentifier("onboarding_replay_button")
  }

  private func bullet(_ text: String) -> some View {
    Text("•  \(text)")
      .font(.rounded(.body, weight: .medium))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(text)
  }

  /// One utterance with the question, so it can't be spoken before the phrase it asks about.
  private func playTest(interrupt: Bool = true) {
    hasPlayed = true
    output = Announcer.shared.currentOutputDescription()
    Announcer.shared.announce(
      "\(SpokenMessage.speakerTestPhrase) \(SpokenMessage.speakerTestQuestion)", earcon: .ready, kind: .reply,
      interrupt: interrupt)
  }
}

// MARK: - Verbosity

/// Pick a level by hearing it (stage 6). Speech rate only without VoiceOver's voice, since with
/// it the rate follows VoiceOver's own setting.
struct VerbosityStep: View {
  var speak: OnboardingSpeak
  var onContinue: () -> Void
  var onSkip: () -> Void
  var onExit: () -> Void

  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private let preferences = A11yPreferences.shared
  private let rateStep: Float = 0.05

  var body: some View {
    LessonPage {
      MascotSays(mood: .reading, text: SpokenMessage.verbosityIntro)
      VStack(spacing: 12) {
        ForEach(Verbosity.allCases) { level in
          let selected = preferences.verbosity == level
          Button {
            preferences.verbosity = level
            Announcer.shared.say(
              "\(SpokenMessage.verbosityChosen(level)) \(SpokenMessage.verbositySample(level))", kind: .reply)
          } label: {
            HStack(spacing: 12) {
              // Selection shown by a checkmark and the word, not only by colour.
              Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.rounded(.title2, weight: .bold))
                .a11yDecorative()
              Text(selected ? "\(level.title), chosen" : level.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .buttonStyle(ChunkyButtonStyle(tone: selected ? .green : .neutral))
          .accessibilityLabel(level.title)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityHint("Chooses this level and plays a sample answer.")
          .accessibilityIdentifier("onboarding_verbosity_\(level.rawValue)")
        }
      }

      Text("Speaking speed")
        .font(.rounded(.title2, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      if voiceOverEnabled, preferences.useVoiceOverVoice {
        A11yNote(text: SpokenMessage.speechRateFollowsVoiceOver)
      } else {
        Text("Speed: \(ratePercent) percent")
          .font(.rounded(.body, weight: .bold))
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("onboarding_rate_label")
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
          Button("Slower") { changeRate(by: -rateStep) }
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Then plays a sample.")
          Button("Faster") { changeRate(by: rateStep) }
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Then plays a sample.")
        }
      }
    } footer: {
      Button("Continue", action: onContinue)
        .buttonStyle(.a11yPrimary)
        .sayHint(.continueOn)
        .accessibilityIdentifier("onboarding_continue_button")
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear { speak(SpokenMessage.verbosityIntro, .status) }
  }

  /// Rate as a percentage of the synthesizer's range, which is easier to follow than 0.0-1.0.
  private var ratePercent: Int {
    let range = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
    return Int((((preferences.speechRate - AVSpeechUtteranceMinimumSpeechRate) / range) * 100).rounded())
  }

  private func changeRate(by delta: Float) {
    preferences.speechRate += delta
    Announcer.shared.say(SpokenMessage.verbositySample(preferences.verbosity), kind: .reply)
  }
}

// MARK: - Safety and privacy

/// Spoken in full once (A11yPreferences.disclaimerHeard), always readable on screen.
struct DisclaimerStep: View {
  var speak: OnboardingSpeak
  var onContinue: () -> Void
  var onSkip: () -> Void
  var onExit: () -> Void

  private let preferences = A11yPreferences.shared

  var body: some View {
    LessonPage {
      Text("Safety")
        .font(.rounded(.title2, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      MascotSays(mood: .idle, text: SpokenMessage.disclaimer)
      Text("Privacy")
        .font(.rounded(.title2, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      MascotSays(mood: .happy, text: SpokenMessage.privacy)
    } footer: {
      Button("I understand") {
        // Heard means confirmed: with VoiceOver it was read from the screen, not spoken by us.
        preferences.disclaimerHeard = true
        onContinue()
      }
      .buttonStyle(.a11yPrimary)
      .sayHint(.continueOn)
      .accessibilityIdentifier("onboarding_continue_button")
      Button("Hear again", action: speakAll)
        .buttonStyle(.a11ySecondary)
        .accessibilityIdentifier("onboarding_hear_again_button")
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear {
      // `speak` stays quiet under VoiceOver, which reads the text on screen instead.
      if preferences.disclaimerHeard {
        speak(SpokenMessage.disclaimerAgain, .status)
      } else {
        speak("\(SpokenMessage.disclaimer) \(SpokenMessage.privacy)", .reply)
      }
    }
  }

  private func speakAll() {
    Announcer.shared.say("\(SpokenMessage.disclaimer) \(SpokenMessage.privacy)", kind: .reply)
  }
}

// MARK: - Connect

/// Explains the Meta AI handoff before it happens, then starts it. Ends onboarding once registered.
struct ConnectStep: View {
  var viewModel: WearablesViewModel
  var speak: OnboardingSpeak
  /// Registration succeeded here; the "Connected … Setup finished." line is already spoken.
  var onConnected: () -> Void
  /// "Finish setup" when the glasses were already connected.
  var onFinish: () -> Void
  var onSkip: () -> Void

  var body: some View {
    LessonPage {
      if viewModel.registrationState == .registered {
        MascotSays(mood: .happy, text: SpokenMessage.connectAlreadyRegistered)
      } else {
        MascotSays(mood: viewModel.connectionNotice == nil ? .happy : .confused, text: SpokenMessage.beforeMetaAIHandoff)
        if let notice = viewModel.connectionNotice {
          ConnectionNoticeView(text: notice)
        }
      }
    } footer: {
      if viewModel.registrationState == .registered {
        Button("Finish setup", action: onFinish)
          .buttonStyle(.a11yPrimary)
          .sayHint(.continueOn)
          .accessibilityIdentifier("onboarding_finish_button")
      } else {
        Button(viewModel.isConnecting ? "Connecting…" : "Connect my glasses") {
          viewModel.connectGlasses()
        }
        .buttonStyle(.a11yPrimary)
        .sayHint(.connect)
        .disabled(viewModel.isConnecting)
        .accessibilityHint("Opens the Meta AI app.")
        .accessibilityIdentifier("connect_glasses_button")
        Button("Skip for now", action: onSkip)
          .buttonStyle(.a11ySecondary)
          .sayHint(.skip)
          .accessibilityHint("Goes to the app. You can connect from there.")
          .accessibilityIdentifier("onboarding_skip_step_button")
      }
    }
    .onAppear {
      viewModel.connectedFollowUp = SpokenMessage.setupFinished
      speak(
        viewModel.registrationState == .registered
          ? SpokenMessage.connectAlreadyRegistered : SpokenMessage.beforeMetaAIHandoff,
        .status)
    }
    // Leaving without connecting: a later connection outside setup shouldn't say "Setup finished".
    .onDisappear { viewModel.connectedFollowUp = nil }
    .onChange(of: viewModel.registrationState) { _, state in
      if state == .registered { onConnected() }
    }
  }
}

/// The last failed attempt, shown so it can be read as well as heard. Marked with a symbol and
/// the word "Not connected", not colour alone.
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
