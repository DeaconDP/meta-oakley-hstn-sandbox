/*
 * OnboardingView - the guided first-run setup (notes/a11y-onboarding.md, stages 2-6)
 *
 * One focused screen per step: welcome, voice control, learn the sounds, speaker test, verbosity,
 * safety and privacy, connect. Practice, not a tour. Each step's key line is spoken when it appears, and
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
  case voiceControl
  case sounds
  case speakerTest
  case verbosity
  case disclaimer
  case connect

  var title: String {
    switch self {
    case .welcome: "Welcome"
    case .voiceControl: "Voice control"
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

  var previous: OnboardingStep? {
    let all = Self.allCases
    guard let index = all.firstIndex(of: self), index > 0 else { return nil }
    return all[index - 1]
  }

  /// "Step 2 of 6". Welcome isn't counted: it is the question about doing the setup at all.
  var progress: String? {
    guard self != .welcome, let index = Self.allCases.firstIndex(of: self) else { return nil }
    return "Step \(index) of \(Self.allCases.count - 1)"
  }

  /// How far along the bar is. Welcome is the empty bar.
  var progressFraction: Double {
    guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
    return Double(index) / Double(Self.allCases.count - 1)
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
    VStack(spacing: 0) {
      // The step number is part of the title for VoiceOver, so the bar itself is hidden.
      ChunkyProgressBar(fraction: step.progressFraction)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
      PinnedVoiceIndicator()
      content
        // A new page per step, so each one starts at the top.
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
    }
    .background(Theme.page.ignoresSafeArea())
    .environment(\.lessonHeader, AnyView(header))
    .onAppear {
      preferences.onboardingStep = step.rawValue
      focusTitle()
      VoiceControl.shared.setScreen(.setup(step), handler: handleVoice)
    }
    .onChange(of: step) { _, newStep in
      preferences.onboardingStep = newStep.rawValue
      focusTitle()
      VoiceControl.shared.setScreen(.setup(newStep), handler: handleVoice)
    }
    .onDisappear { VoiceControl.shared.clearScreen { if case .setup = $0 { true } else { false } } }
    // A container, so the identifier stays on the screen and doesn't land on what's inside it.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("onboarding_\(step.rawValue)")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      FlowingVoiceIndicator()
      if let progress = step.progress {
        Text(progress)
          .font(.rounded(.subheadline, weight: .heavy))
          .foregroundStyle(Theme.inkSoft)
          // Read as part of the title, so a swipe doesn't stop on "Step 2 of 5" alone.
          .accessibilityHidden(true)
      }
      Text(step.title)
        .font(.rounded(.largeTitle, weight: .black))
        .foregroundStyle(Theme.ink)
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
      WelcomeStep(speak: speakKeyLine, onGuided: { go(to: .voiceControl) }, onSkip: { finish(skipped: true) })
    case .voiceControl:
      VoiceControlStep(speak: speakKeyLine, onContinue: advance, onSkip: advance, onExit: exit)
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
    VoiceControl.shared.stepHandler = nil
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
    if !skipped { Celebrations.shared.setupFinished() }
    preferences.onboardingCompleted = true
    preferences.onboardingStep = nil
    onFinish()
  }

  /// A voice command for this step. Commands that only make sense inside a step's own state (the
  /// speaker test's answer) went to its stepHandler first; everything else maps to the same calls
  /// the step's buttons make. VoiceCommandParser only lets through what's valid for the step.
  private func handleVoice(_ command: VoiceCommand) -> Bool {
    switch (step, command) {
    case (.welcome, .continueOn), (.welcome, .yes): go(to: .voiceControl)
    case (.welcome, .skip), (.welcome, .no): finish(skipped: true)
    case (.disclaimer, .continueOn):
      preferences.disclaimerHeard = true
      advance()
    case (.connect, .connect), (.connect, .continueOn), (.connect, .yes):
      if wearablesViewModel.registrationState == .registered {
        finish(skipped: false)
      } else {
        wearablesViewModel.connectGlasses()
      }
    case (.connect, .skip), (.connect, .no): finish(skipped: true)
    case (_, .continueOn), (_, .skip): advance()
    case (_, .back):
      guard let previous = step.previous else { return false }
      go(to: previous)
    default: return false
    }
    return true
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

/// The "Skip this step" and "Leave setup" buttons at the end of every step after Welcome. Side by
/// side while the footer is pinned, so the main button keeps the room.
struct OnboardingSkipButtons: View {
  var onSkip: () -> Void
  var onExit: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout = dynamicTypeSize <= .xLarge ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
    layout {
      Button("Skip this step", action: onSkip)
        .buttonStyle(.a11ySecondary)
        .sayHint(.skip)
        .accessibilityHint("Goes to the next step.")
        .accessibilityIdentifier("onboarding_skip_step_button")
      Button("Leave setup", action: onExit)
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Goes to the app. You can replay setup later.")
        .accessibilityIdentifier("onboarding_exit_button")
    }
  }
}
