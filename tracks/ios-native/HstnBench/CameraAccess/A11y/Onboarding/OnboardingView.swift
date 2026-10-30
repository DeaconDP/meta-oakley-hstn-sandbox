/*
 * OnboardingView - the guided first-run setup (notes/a11y-onboarding.md, stages 2-6)
 *
 * One focused screen per step: welcome, learn the sounds, speaker test, verbosity, safety and
 * privacy, connect. Practice, not a tour. Each step's key line is spoken when it appears, and
 * VoiceOver focus moves to its title. The current step is saved, so leaving the app (or Meta AI
 * taking over) resumes where the user was. Every step can be skipped, and the whole setup can be
 * left at any point.
 *
 * Entry points:
 * - MainAppView shows it in place of the app while A11yPreferences.onboardingCompleted is false.
 *   "Replay setup" is therefore just `A11yPreferences.shared.resetOnboarding()`.
 * - Or present `OnboardingView(wearablesViewModel:onFinish:)` yourself (sheet or cover); it marks
 *   onboarding completed and calls onFinish when the user finishes or leaves.
 */

import SwiftUI

enum OnboardingStep: String, CaseIterable {
  case welcome
  case sounds
  case speakerTest
  case verbosity
  case disclaimer
  case connect

  var title: String {
    switch self {
    case .welcome: "Welcome"
    case .sounds: "Learn the sounds"
    case .speakerTest: "Speaker test"
    case .verbosity: "How much detail"
    case .disclaimer: "Safety and privacy"
    case .connect: "Connect your glasses"
    }
  }

  var next: OnboardingStep? {
    let all = Self.allCases
    guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
    return all[index + 1]
  }

  /// "Step 2 of 5". Welcome isn't counted: it is the question about doing the setup at all.
  var progress: String? {
    guard self != .welcome, let index = Self.allCases.firstIndex(of: self) else { return nil }
    return "Step \(index) of \(Self.allCases.count - 1)"
  }
}

struct OnboardingView: View {
  var wearablesViewModel: WearablesViewModel
  var onFinish: () -> Void

  @State private var step: OnboardingStep
  /// Set when opened part way through, so the first key line says setup is continuing.
  @State private var isResuming: Bool
  @AccessibilityFocusState private var titleFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let preferences = A11yPreferences.shared

  init(wearablesViewModel: WearablesViewModel, onFinish: @escaping () -> Void = {}) {
    self.wearablesViewModel = wearablesViewModel
    self.onFinish = onFinish
    let saved = A11yPreferences.shared.onboardingStep.flatMap(OnboardingStep.init(rawValue:))
    _step = State(initialValue: saved ?? .welcome)
    _isResuming = State(initialValue: saved != nil && saved != .welcome)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        content
      }
      .padding(24)
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    // A new scroll view per step, so each step starts at the top.
    .id(step)
    .background(Color(.systemBackground).ignoresSafeArea())
    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
    .onAppear {
      preferences.onboardingStep = step.rawValue
      focusTitle()
    }
    .onChange(of: step) { _, newStep in
      preferences.onboardingStep = newStep.rawValue
      focusTitle()
    }
    .accessibilityIdentifier("onboarding_\(step.rawValue)")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let progress = step.progress {
        Text(progress)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          // Read as part of the title, so a swipe doesn't stop on "Step 2 of 5" alone.
          .accessibilityHidden(true)
      }
      Text(step.title)
        .font(.largeTitle.bold())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(step.progress.map { "\(step.title). \($0)" } ?? step.title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case .welcome:
      WelcomeStep(speak: speakKeyLine, onGuided: { go(to: .sounds) }, onSkip: { finish(skipped: true) })
    case .sounds:
      LearnSoundsStep(speak: speakKeyLine, onContinue: advance, onSkip: advance, onExit: exit)
    case .speakerTest:
      SpeakerTestStep(speak: speakKeyLine, onContinue: advance, onSkip: advance, onExit: exit)
    case .verbosity:
      VerbosityStep(speak: speakKeyLine, onContinue: advance, onSkip: advance, onExit: exit)
    case .disclaimer:
      DisclaimerStep(speak: speakKeyLine, onContinue: advance, onSkip: advance, onExit: exit)
    case .connect:
      ConnectStep(
        viewModel: wearablesViewModel, speak: speakKeyLine,
        onConnected: { finish(skipped: false, alreadySpoken: true) },
        onFinish: { finish(skipped: false) },
        onSkip: { finish(skipped: true) })
    }
  }

  // MARK: Navigation

  private func go(to newStep: OnboardingStep) {
    Announcer.shared.stop()
    if reduceMotion {
      step = newStep
    } else {
      withAnimation(.easeInOut(duration: 0.25)) { step = newStep }
    }
  }

  private func advance() {
    if let next = step.next { go(to: next) } else { finish(skipped: false) }
  }

  private func exit() {
    finish(skipped: true)
  }

  /// Marks onboarding done either way: leaving is a choice, and it can be replayed.
  /// `alreadySpoken`: connecting finished it, and WearablesViewModel has said "Connected to ….
  /// Setup finished." as one line (ConnectStep sets connectedFollowUp).
  private func finish(skipped: Bool, alreadySpoken: Bool = false) {
    if skipped {
      Announcer.shared.say(SpokenMessage.setupSkipped)
    } else if !alreadySpoken {
      Announcer.shared.say(SpokenMessage.setupFinished, interrupt: false)
    }
    preferences.onboardingCompleted = true
    preferences.onboardingStep = nil
    onFinish()
  }

  /// VoiceOver focus on the new title. The step's view is new (see `.id(step)`), so give it a
  /// moment to be in the accessibility tree first.
  private func focusTitle() {
    titleFocused = false
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      titleFocused = true
    }
  }

  /// Speaks a step's key line, led by "Continuing setup" the first time after a resume, but only
  /// without VoiceOver. With VoiceOver, focus moves to the title and VoiceOver reads the screen
  /// in the user's own voice; speaking as well would be cut off by, or talk over, VoiceOver.
  /// Queued, not interrupting: go(to:) has already stopped the last step's speech.
  private func speakKeyLine(_ text: String, kind: AnnouncementKind) {
    guard !UIAccessibility.isVoiceOverRunning else { return }
    var line = text
    if isResuming {
      isResuming = false
      line = "\(SpokenMessage.resumingSetup) \(text)"
    }
    Announcer.shared.say(line, kind: kind, interrupt: false)
  }
}

/// How a step speaks its key line (see OnboardingView.speakKeyLine).
typealias OnboardingSpeak = (String, AnnouncementKind) -> Void

/// The "Skip this step" and "Leave setup" buttons at the end of every step after Welcome.
struct OnboardingSkipButtons: View {
  var onSkip: () -> Void
  var onExit: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Button("Skip this step", action: onSkip)
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Goes to the next step.")
        .accessibilityIdentifier("onboarding_skip_step_button")
      Button("Leave setup", action: onExit)
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Goes to the app. You can replay setup later.")
        .accessibilityIdentifier("onboarding_exit_button")
    }
  }
}
