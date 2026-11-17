/*
 * VoiceIndicator - voice is the default input, so the screen always says how it's doing
 *
 * VoiceIndicatorModel is pure: VoiceControl's state (and whether the reader is busy) in, words, a
 * mood, a ribbon state and at most one fix out. The view only binds to it. The voice ribbon beside
 * the words is the brand's signature motif (tokens.json `state`): Signal Yellow breathing when idle,
 * Listen Cyan waves moving in while listening, three soft Paper pulses while working, Voice Coral
 * waves moving out while the app talks, and a still Coral notch when something needs fixing. Under
 * Reduce Motion it is a still shape in the state colour. It is decorative and hidden from VoiceOver:
 * the words always say the same thing. It adds nothing to speech: VoiceControl already says what
 * changes, so this is a plain element VoiceOver reaches by swiping, with no live region.
 *
 * SayHint is the "Say ..." line on buttons. It appears only for a command valid on this screen right
 * now (VoiceCommandParser, the same list "help" reads out) and while voice control can hear it.
 */

import SwiftUI
import UIKit

/// The voice ribbon's five states (tokens.json `state`).
enum RibbonState: String, CaseIterable, Sendable {
  case idle, listening, thinking, speaking, error
}

struct VoiceIndicatorModel: Equatable {
  enum Fix: Equatable {
    case turnOn
    case askPermission
    case openSettings

    var title: String {
      switch self {
      case .turnOn: "Turn on"
      case .askPermission: "Allow"
      case .openSettings: "Open Settings"
      }
    }

    var hint: String {
      switch self {
      case .turnOn: "Turns voice control back on."
      case .askPermission: "Asks to use the microphone and speech recognition."
      case .openSettings: "Opens Settings for this app."
      }
    }
  }

  /// The colour cue beside the words. Only a cue: the title always says the same in words.
  enum Signal: Equatable {
    /// Listen Cyan.
    case listening
    /// Voice Coral: the app is talking.
    case speaking
    /// Paper (Night in light mode): getting a picture, finding text, transcribing.
    case working
    /// Voice Coral: not listening because something needs fixing.
    case warning
    /// Signal Yellow, breathing: on, but not hearing right now.
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

  var ribbon: RibbonState {
    switch signal {
    case .listening: .listening
    case .speaking: .speaking
    case .working: .thinking
    case .warning: .error
    case .quiet: .idle
    }
  }

  /// `isWorking`: the reader is getting a picture or finding text, and `workDetail` says which.
  static func make(
    status: VoiceControl.Status,
    reason: String?,
    listener: VoiceListenerKind?,
    micPermission: VoicePermission,
    speechPermission: VoicePermission,
    isSpeaking: Bool,
    heard: VoiceCommand?,
    canPrompt: Bool,
    isWorking: Bool = false,
    workDetail: String? = nil
  ) -> VoiceIndicatorModel {
    switch status {
    case .listening, .starting:
      if let heard {
        return VoiceIndicatorModel(
          title: "Heard \u{201C}\(heard.phrase)\u{201D}", detail: nil, mood: .happy, fix: nil, signal: .listening)
      }
      if isWorking {
        return VoiceIndicatorModel(title: "Working on it", detail: workDetail, mood: .reading, fix: nil, signal: .working)
      }
      if status == .starting {
        return VoiceIndicatorModel(title: "Starting to listen", detail: nil, mood: .idle, fix: nil)
      }
      let source = listener == .glasses ? "Listening through your glasses" : "Listening"
      let tip = isSpeaking ? "While I talk, start with \u{201C}reader\u{201D}." : "Say \u{201C}help\u{201D} any time."
      return VoiceIndicatorModel(
        title: source, detail: tip, mood: .listening, fix: nil, signal: isSpeaking ? .speaking : .listening)
    case .paused:
      return VoiceIndicatorModel(title: "Listening paused", detail: reason, mood: .idle, fix: nil)
    case .off:
      return VoiceIndicatorModel(
        title: "Voice control is off", detail: "Every button still works.", mood: .idle, fix: .turnOn)
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

/// The indicator: the voice ribbon, the words, and a way to fix it when there is one.
struct VoiceIndicatorView: View {
  private var voice: VoiceControl { VoiceControl.shared }

  /// The last command shows for a moment, so a sighted helper can see what was understood.
  @State private var heard: VoiceCommand?
  @ScaledMetric(relativeTo: .headline) private var ribbonHeight: CGFloat = 40
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// VoiceControl's state right now, in the indicator's words.
  static func currentModel(heard: VoiceCommand? = nil) -> VoiceIndicatorModel {
    let voice = VoiceControl.shared
    let reader = TextReader.shared
    return VoiceIndicatorModel.make(
      status: LaunchOptions.previewsListening ? .listening : voice.status,
      reason: LaunchOptions.previewsListening ? nil : voice.reason,
      listener: voice.activeListener,
      micPermission: voice.phoneMicPermission,
      speechPermission: voice.speechPermission,
      isSpeaking: Announcer.shared.isSpeaking,
      heard: heard,
      canPrompt: !LaunchOptions.isAutomatedTest,
      isWorking: reader.isBusy,
      workDetail: reader.isBusy ? reader.statusText : nil)
  }

  var body: some View {
    let model = Self.currentModel(heard: heard)
    let stacked = dynamicTypeSize.isAccessibilitySize
    VStack(alignment: .leading, spacing: Theme.Space.sm) {
      Group {
        if stacked {
          VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ribbon(model)
            words(model)
          }
        } else {
          HStack(alignment: .center, spacing: Theme.Space.md) {
            words(model)
            ribbon(model)
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.spokenLabel)
      .accessibilityIdentifier("voice_indicator")

      if let fix = model.fix {
        Button(fix.title) { perform(fix) }
          .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 4, radius: Theme.Radius.md))
          .frame(maxWidth: stacked ? .infinity : 200, alignment: .leading)
          .accessibilityHint(fix.hint)
          .accessibilityIdentifier("voice_indicator_fix")
      }
    }
    .padding(.horizontal, Theme.Space.lg)
    .padding(.vertical, Theme.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .stateAnimation(value: model)
    .task(id: voice.lastCommandAt) {
      guard voice.lastCommandAt != nil, let command = voice.lastCommand else { return }
      heard = command
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      heard = nil
    }
  }

  private func words(_ model: VoiceIndicatorModel) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
      Text(model.title)
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
      if let detail = model.detail {
        Text(detail)
          .font(.rounded(.footnote, weight: .regular))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func ribbon(_ model: VoiceIndicatorModel) -> some View {
    VoiceRibbon(state: model.ribbon)
      .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 112, height: min(ribbonHeight, 56))
      .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
  }

  /// The ribbon's colour for a signal. Listen and speak are at least 3:1 on the page and on cards
  /// (ThemePaletteTests), though the words carry the meaning.
  static func color(for signal: VoiceIndicatorModel.Signal) -> Color {
    Theme.ribbon(VoiceIndicatorModel(title: "", mood: .idle, signal: signal).ribbon)
  }

  private func perform(_ fix: VoiceIndicatorModel.Fix) {
    switch fix {
    case .turnOn:
      voice.setEnabled(true)
    case .askPermission:
      Task { await voice.requestPermissions() }
    case .openSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
  }
}

// MARK: - The voice ribbon

/// A soft three-strand waveform in the state colour (brand-guide.html, "The voice ribbon"). Drawn in
/// one Canvas from a TimelineView at up to 30 fps, so it costs a few hundred path points a frame and
/// nothing while still (error, or Reduce Motion). A state change crossfades.
struct VoiceRibbon: View {
  var state: RibbonState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ZStack {
      strands
        .id(state)
        .transition(.opacity)
    }
    .stateAnimation(value: state)
    // The strands fade out at both ends.
    .mask {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0), .init(color: .black, location: 0.15),
          .init(color: .black, location: 0.85), .init(color: .clear, location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var strands: some View {
    let color = Theme.ribbon(state)
    let boost: CGFloat = contrast == .increased ? 1.5 : 1
    let state = state
    if reduceMotion || state == .error {
      Canvas { context, size in
        Self.draw(in: &context, size: size, time: 1.2, state: state, color: color, boost: boost)
      }
    } else {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        Canvas { context, size in
          let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 9_600)
          Self.draw(in: &context, size: size, time: time, state: state, color: color, boost: boost)
        }
      }
    }
  }

  /// One frame. `time` in seconds: the travelling waves repeat every ribbonLoop (1.6 s), the working
  /// pulses every 1.2 s and the idle breath every 4 s.
  static func draw(
    in context: inout GraphicsContext, size: CGSize, time t: Double, state: RibbonState, color: Color, boost: CGFloat
  ) {
    let loop = 2 * Double.pi / 1.6
    let amplitude: Double
    let direction: Double
    let frequency: Double
    switch state {
    case .idle:
      (amplitude, direction, frequency) = (0.3 * (0.6 + 0.4 * sin(2 * .pi * t / 4)), 0.25, 1)
    case .listening:
      // Phase rising: the waves travel right to left, in towards the glasses.
      (amplitude, direction, frequency) = (0.75 * (0.75 + 0.25 * sin(t * 3.1) * sin(t * 1.3)), 1, 1.4)
    case .thinking:
      (amplitude, direction, frequency) = (0.45, -0.3, 2.4)
    case .speaking:
      // Phase falling: the waves travel left to right, out of the glasses.
      (amplitude, direction, frequency) = (0.95 * (0.75 + 0.25 * sin(t * 3.7) * sin(t * 1.1)), -1, 1.7)
    case .error:
      (amplitude, direction, frequency) = (0.6, 0, 1)
    }
    let mid = size.height / 2
    let reach = size.height * 0.42
    let widths: [CGFloat] = [3.5, 2.5, 1.5]
    let opacities: [Double] = [1, 0.6, 0.35]
    let pulseCenter = (t / 1.2).truncatingRemainder(dividingBy: 1)
    let steps = max(Int(size.width / 3), 24)
    for k in 0..<3 {
      let strand = Double(k)
      let phase = t * loop * direction + strand * 0.9
      var path = Path()
      for i in 0...steps {
        let u = Double(i) / Double(steps)
        let envelope = sin(Double.pi * u)
        var y: Double
        if state == .error {
          // A single still notch in the middle.
          y = (u > 0.44 && u < 0.56) ? -sin((u - 0.44) / 0.12 * .pi) : 0
        } else {
          y = sin(u * .pi * 2 * frequency * (1 + strand * 0.35) + phase) * 0.6
            + sin(u * .pi * 5.3 * frequency + phase * 1.7 + strand) * 0.4
          if state == .thinking {
            // Three soft pulses travelling left to right.
            y *= 0.2 + 0.8 * max(0, cos((u - pulseCenter) * .pi * 6))
          }
        }
        let point = CGPoint(x: size.width * u, y: mid + y * amplitude * envelope * reach * (1 - strand * 0.22))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      context.stroke(
        path, with: .color(color.opacity(opacities[k])),
        style: StrokeStyle(lineWidth: widths[k] * boost, lineCap: .round, lineJoin: .round))
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
        .accessibilityHidden(true)
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
        // A divider, not a control boundary, so the quieter track colour.
        Rectangle()
          .fill(contrast == .increased ? Theme.stroke : Theme.track)
          .frame(height: contrast == .increased ? Theme.outlineWidthIncreased : Theme.outlineWidth)
          .accessibilityHidden(true)
      }
      .background(Theme.page)
    }
  }
}

struct FlowingVoiceIndicator: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if !voiceIndicatorPins(dynamicTypeSize) {
      VoiceIndicatorView().themeCard(padding: Theme.Space.xxs)
    }
  }
}
