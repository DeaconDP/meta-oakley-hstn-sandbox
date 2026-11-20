/*
 * VoiceIndicator - the screen always says how listening is doing (hands-free, or push to talk)
 *
 * VoiceIndicatorModel is pure: VoiceControl's state in, words, a mascot mood and at most one fix out.
 * The view only binds to it. A bar beside the mascot is Listen Cyan while listening and Voice Coral
 * while the app talks or can't listen; the words always say the same thing. It adds nothing to speech: VoiceControl already says what changes, so
 * this is a plain element VoiceOver reaches by swiping, with no live region.
 *
 * SayHint is the "Say ..." line on buttons. It appears only for a command valid on this screen right
 * now (VoiceCommandParser, the same list "help" reads out) and while voice control can hear it.
 */

import SwiftUI
import UIKit

struct VoiceIndicatorModel: Equatable {
  enum Fix: Equatable {
    case turnOn
    case askPermission
    case openSettings

    var title: String {
      switch self {
      case .turnOn: "Hands-free on"
      case .askPermission: "Allow"
      case .openSettings: "Open Settings"
      }
    }

    var hint: String {
      switch self {
      case .turnOn: "Turns hands-free on, so the app is always listening."
      case .askPermission: "Asks to use the microphone and speech recognition."
      case .openSettings: "Opens Settings for this app."
      }
    }
  }

  /// The colour cue beside the mascot. Only a cue: the title always says the same in words.
  enum Signal: Equatable {
    /// Listen Cyan.
    case listening
    /// Voice Coral: the app is talking.
    case speaking
    /// Voice Coral: not listening because something needs fixing.
    case warning
    /// The plain outline colour.
    case quiet
  }

  var title: String
  var detail: String?
  var mood: MascotMood
  var fix: Fix?
  var signal: Signal = .quiet

  /// Short enough to stay pinned at the top. A long reason scrolls with the page instead.
  var isCompact: Bool { (detail?.count ?? 0) <= 60 }

  var spokenLabel: String {
    [title, detail].compactMap { $0 }.joined(separator: ". ")
  }

  static func make(
    status: VoiceControl.Status,
    reason: String?,
    listener: VoiceListenerKind?,
    micPermission: VoicePermission,
    speechPermission: VoicePermission,
    isSpeaking: Bool,
    heard: VoiceCommand?,
    canPrompt: Bool
  ) -> VoiceIndicatorModel {
    switch status {
    case .listening:
      if let heard {
        return VoiceIndicatorModel(
          title: "Heard \u{201C}\(heard.phrase)\u{201D}", detail: nil, mood: .happy, fix: nil, signal: .listening)
      }
      let source = listener == .glasses ? "Listening through your glasses" : "Listening"
      let tip = isSpeaking ? "While I talk, start with \u{201C}reader\u{201D}." : "Say \u{201C}help\u{201D} any time."
      return VoiceIndicatorModel(
        title: source, detail: tip, mood: .listening, fix: nil, signal: isSpeaking ? .speaking : .listening)
    case .starting:
      return VoiceIndicatorModel(title: "Starting to listen", detail: nil, mood: .idle, fix: nil)
    case .paused:
      return VoiceIndicatorModel(title: "Listening paused", detail: reason, mood: .idle, fix: nil)
    case .off:
      return VoiceIndicatorModel(
        title: "Hands-free is off", detail: "Tap the mic for one command.", mood: .idle, fix: .turnOn)
    case .unavailable:
      let denied = micPermission == .denied || speechPermission == .denied
      var fix: Fix?
      if denied || reason == SpokenMessage.voiceNoOnDeviceRecognition {
        fix = .openSettings
      } else if canPrompt, micPermission == .notDetermined || speechPermission == .notDetermined {
        fix = .askPermission
      }
      return VoiceIndicatorModel(title: "Not listening", detail: reason, mood: .confused, fix: fix, signal: .warning)
    }
  }
}

/// The indicator as a card: mascot, words, and a way to fix it when there is one.
struct VoiceIndicatorView: View {
  private var voice: VoiceControl { VoiceControl.shared }

  /// The last command shows for a moment, so a sighted helper can see what was understood.
  @State private var heard: VoiceCommand?
  @ScaledMetric(relativeTo: .headline) private var mascotSize: CGFloat = 40
  @Environment(\.colorSchemeContrast) private var contrast

  /// VoiceControl's state right now, in the indicator's words.
  static func currentModel(heard: VoiceCommand? = nil) -> VoiceIndicatorModel {
    let voice = VoiceControl.shared
    return VoiceIndicatorModel.make(
      status: LaunchOptions.previewsListening ? .listening : voice.status,
      reason: LaunchOptions.previewsListening ? nil : voice.reason,
      listener: voice.activeListener,
      micPermission: voice.phoneMicPermission,
      speechPermission: voice.speechPermission,
      isSpeaking: Announcer.shared.isSpeaking,
      heard: heard,
      canPrompt: !LaunchOptions.isAutomatedTest)
  }

  var body: some View {
    let model = Self.currentModel(heard: heard)
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        Capsule()
          .fill(Self.color(for: model.signal))
          .frame(width: contrast == .increased ? 8 : 6, height: min(mascotSize, 72))
        Mascot(mood: model.mood)
          .frame(width: min(mascotSize, 72), height: min(mascotSize, 72))
        VStack(alignment: .leading, spacing: 0) {
          Text(model.title)
            .font(.rounded(.subheadline, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
          if let detail = model.detail {
            Text(detail)
              .font(.rounded(.footnote, weight: .semibold))
              .foregroundStyle(Theme.inkSoft)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.spokenLabel)
      .accessibilityIdentifier("voice_indicator")

      if let fix = model.fix {
        Button(fix.title) { perform(fix) }
          .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 4, radius: 16))
          .frame(maxWidth: 150)
          .accessibilityHint(fix.hint)
          .accessibilityIdentifier("voice_indicator_fix")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .task(id: voice.lastCommandAt) {
      guard voice.lastCommandAt != nil, let command = voice.lastCommand else { return }
      heard = command
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      heard = nil
    }
  }

  /// Listen Cyan while listening, Voice Coral while talking or stuck. Each is at least 3:1 on the
  /// page and on cards (ThemePaletteTests).
  static func color(for signal: VoiceIndicatorModel.Signal) -> Color {
    switch signal {
    case .listening: Theme.listen
    case .speaking, .warning: Theme.speak
    case .quiet: Theme.stroke
    }
  }

  private func perform(_ fix: VoiceIndicatorModel.Fix) {
    switch fix {
    case .turnOn:
      voice.setHandsFree(true)
    case .askPermission:
      Task { await voice.requestPermissions() }
    case .openSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
  }
}

/// Whether saying this would work right now.
@MainActor
enum VoiceHints {
  static func isSayable(_ command: VoiceCommand) -> Bool {
    let voice = VoiceControl.shared
    let hearing = LaunchOptions.previewsListening || voice.status == .listening || voice.status == .starting
    guard hearing, let screen = voice.screen else { return false }
    // The parser's list directly: VoiceControl.availableCommands also trims the echo buffer, which
    // a view body shouldn't do.
    let context = VoiceContext(screen: screen, hasReadSentences: TextReader.shared.hasSentences)
    return VoiceCommandParser.availableCommands(context: context).contains(command)
  }
}

/// A "Say ..." line for one button. Empty unless saying it would work right now.
struct SayHint: View {
  let command: VoiceCommand

  var body: some View {
    if VoiceHints.isSayable(command) {
      Text("Say \u{201C}\(command.phrase)\u{201D}")
        .font(.rounded(.footnote, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
  }
}

/// Several commands on one line, for controls too small to carry their own hint.
struct SayLine: View {
  let commands: [VoiceCommand]

  var body: some View {
    let phrases = commands.filter(VoiceHints.isSayable).map { "\u{201C}\($0.phrase)\u{201D}" }
    if !phrases.isEmpty {
      Text("Say " + phrases.joined(separator: ", "))
        .font(.rounded(.footnote, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        // Not hidden: text on screen that VoiceOver can't reach fails the accessibility audit
        // ("Potentially inaccessible text"), and it is how a VoiceOver user learns the commands.
        .accessibilityLabel("You can say " + phrases.joined(separator: ", "))
        .accessibilityIdentifier("say_line")
    }
  }
}

/// The indicator at the top of a screen while it fits there. Large text or a long reason would take
/// up the screen, so then it scrolls with the page (FlowingVoiceIndicator) instead.
@MainActor
private func voiceIndicatorPins(_ size: DynamicTypeSize) -> Bool {
  !size.isAccessibilitySize && VoiceIndicatorView.currentModel().isCompact
}

struct PinnedVoiceIndicator: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if voiceIndicatorPins(dynamicTypeSize) {
      VStack(spacing: 0) {
        VoiceIndicatorView()
        Rectangle().fill(Theme.stroke).frame(height: contrast == .increased ? 3 : 2).accessibilityHidden(true)
      }
      .background(Theme.page)
    }
  }
}

struct FlowingVoiceIndicator: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if !voiceIndicatorPins(dynamicTypeSize) {
      VoiceIndicatorView().themeCard(padding: 4)
    }
  }
}
