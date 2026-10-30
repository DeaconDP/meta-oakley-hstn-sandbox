/*
 * OnboardingSteps - the screens OnboardingView steps through
 *
 * Each step is one focused screen: its text in reading order, then its choices, then skip and
 * leave. Speech that the user should be able to cut off or replay (test phrases, samples, the
 * disclaimer) uses the app's own voice (`.reply`), so it goes down the same audio route the app
 * will use for answers and queues in order instead of overlapping VoiceOver announcements.
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
    VStack(alignment: .leading, spacing: 24) {
      A11yNote(text: SpokenMessage.welcome)
      VStack(spacing: 12) {
        Button("Start guided setup", action: onGuided)
          .buttonStyle(.a11yPrimary)
          .accessibilityHint("About five minutes. Every step can be skipped.")
          .accessibilityIdentifier("onboarding_guided_button")
        Button("Skip to the app", action: onSkip)
          .buttonStyle(.a11ySecondary)
          .accessibilityHint("You can replay setup later.")
          .accessibilityIdentifier("onboarding_skip_button")
      }
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
    VStack(alignment: .leading, spacing: 24) {
      A11yNote(text: SpokenMessage.learnSoundsIntro)
      VStack(spacing: 12) {
        ForEach(Earcon.allCases, id: \.self) { earcon in
          Button {
            Announcer.shared.announce(earcon.spokenMeaning, earcon: earcon, kind: .reply)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(earcon.displayName)
                .font(.headline)
              Text(earcon.spokenMeaning)
                .font(.callout)
                // Spoken on activation; reading it first as well would say it twice.
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.a11ySecondary)
          .accessibilityLabel("\(earcon.displayName) sound")
          .accessibilityHint("Plays the sound and says what it means.")
          .accessibilityIdentifier("onboarding_earcon_\(earcon.rawValue)")
        }
      }
      Button("Continue", action: onContinue)
        .buttonStyle(.a11yPrimary)
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
    VStack(alignment: .leading, spacing: 24) {
      A11yNote(text: "You'll hear a tone and a short sentence. Then say whether it came from the glasses.")
      Text("Sound is going to: \(output)")
        .font(.headline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("onboarding_output_label")

      if !showFixes {
        Text(SpokenMessage.speakerTestQuestion)
          .font(.title2.bold())
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        VStack(spacing: 12) {
          // First in reading order: with VoiceOver nothing plays until this is pressed.
          replayButton
          // No "good, it works" line: the next step's key line would cut it off anyway.
          Button("Yes, I heard it", action: onContinue)
            .buttonStyle(.a11yPrimary)
            .accessibilityIdentifier("onboarding_heard_yes_button")
          Button("No") {
            showFixes = true
            // Status, so with VoiceOver it is spoken by VoiceOver rather than over it.
            Announcer.shared.say(SpokenMessage.speakerTestFixes)
          }
          .buttonStyle(.a11ySecondary)
          .accessibilityHint("Gives a few things to check.")
          .accessibilityIdentifier("onboarding_heard_no_button")
        }
      } else {
        Text("Things to check")
          .font(.title2.bold())
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: 12) {
          bullet("Wear the glasses with the arms unfolded.")
          bullet("In the phone's Bluetooth settings, check the glasses are connected.")
          bullet("Turn the volume up with the phone's side buttons.")
        }
        VStack(spacing: 12) {
          replayButton
          Button("Continue anyway", action: onContinue)
            .buttonStyle(.a11ySecondary)
            .accessibilityIdentifier("onboarding_continue_button")
        }
      }
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear {
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
    Button(hasPlayed ? "Replay" : "Play test") {
      showFixes = false
      playTest()
    }
    .buttonStyle(.a11ySecondary)
    .accessibilityHint("Plays a tone and a short sentence.")
    .accessibilityIdentifier("onboarding_replay_button")
  }

  private func bullet(_ text: String) -> some View {
    Text("•  \(text)")
      .font(.body)
      .foregroundStyle(.primary)
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
  private let preferences = A11yPreferences.shared
  private let rateStep: Float = 0.05

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      A11yNote(text: SpokenMessage.verbosityIntro)
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
                .font(.title2)
                .a11yDecorative()
              Text(selected ? "\(level.title), chosen" : level.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .buttonStyle(A11yButtonStyle(kind: selected ? .primary : .secondary))
          .accessibilityLabel(level.title)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityHint("Chooses this level and plays a sample answer.")
          .accessibilityIdentifier("onboarding_verbosity_\(level.rawValue)")
        }
      }

      Text("Speaking speed")
        .font(.title2.bold())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
      if voiceOverEnabled, !preferences.useAppVoice {
        A11yNote(text: SpokenMessage.speechRateFollowsVoiceOver)
      } else {
        Text("Speed: \(ratePercent) percent")
          .font(.body)
          .foregroundStyle(.primary)
          .accessibilityIdentifier("onboarding_rate_label")
        HStack(spacing: 12) {
          Button("Slower") { changeRate(by: -rateStep) }
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Then plays a sample.")
          Button("Faster") { changeRate(by: rateStep) }
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Then plays a sample.")
        }
      }

      Button("Continue", action: onContinue)
        .buttonStyle(.a11yPrimary)
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
    VStack(alignment: .leading, spacing: 24) {
      Text("Safety")
        .font(.title2.bold())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
      A11yNote(text: SpokenMessage.disclaimer)
      Text("Privacy")
        .font(.title2.bold())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
      A11yNote(text: SpokenMessage.privacy)
      VStack(spacing: 12) {
        Button("I understand") {
          // Heard means confirmed: with VoiceOver it was read from the screen, not spoken by us.
          preferences.disclaimerHeard = true
          onContinue()
        }
          .buttonStyle(.a11yPrimary)
          .accessibilityIdentifier("onboarding_continue_button")
        Button("Hear again", action: speakAll)
          .buttonStyle(.a11ySecondary)
          .accessibilityIdentifier("onboarding_hear_again_button")
      }
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
    VStack(alignment: .leading, spacing: 24) {
      if viewModel.registrationState == .registered {
        A11yNote(text: SpokenMessage.connectAlreadyRegistered)
        Button("Finish setup", action: onFinish)
          .buttonStyle(.a11yPrimary)
          .accessibilityIdentifier("onboarding_finish_button")
      } else {
        A11yNote(text: SpokenMessage.beforeMetaAIHandoff)
        if let notice = viewModel.connectionNotice {
          ConnectionNoticeView(text: notice)
        }
        VStack(spacing: 12) {
          Button(viewModel.isConnecting ? "Connecting…" : "Connect my glasses") {
            viewModel.connectGlasses()
          }
          .buttonStyle(.a11yPrimary)
          .disabled(viewModel.isConnecting)
          .accessibilityHint("Opens the Meta AI app.")
          .accessibilityIdentifier("connect_glasses_button")
          Button("Skip for now", action: onSkip)
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Goes to the app. You can connect from there.")
            .accessibilityIdentifier("onboarding_skip_step_button")
        }
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
        .font(.title3)
        .foregroundStyle(.primary)
        .a11yDecorative()
      Text(text)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Not connected. \(text)")
    .accessibilityIdentifier("connection_notice")
  }
}
