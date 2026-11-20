/*
 * BigTextMirror - a full-screen, very large, high-contrast view of what is being read
 * (V0 "Phone-specific UX": helps presbyopia and low vision follow along)
 *
 * It shows the sentence being spoken (or the step, in step mode) and follows the speech. With the
 * phone's voice, the word being said is highlighted: Announcer publishes AVSpeechSynthesizer's
 * willSpeakRange as `spokenWord`. The natural (cloud) voice gives no word timing, so it follows by
 * sentence only.
 *
 * It shows the words as they are spoken (the sentence's chunks), so a withheld dose reads "a dose I
 * can't read reliably" here too.
 *
 * Controls: swipe left for next, right for previous, tap the text to pause or carry on; buttons for
 * the same, Smaller and Larger (its own scale, on top of Dynamic Type), Contrast (dark on light,
 * light on dark, yellow on black), and Close. "big text" / "big text off" by voice (Read text).
 *
 * VoiceOver: the mirror never speaks. It posts no announcements, the sentence isn't a live region,
 * and the highlight is visual only, so VoiceOver and the app's voice don't talk over each other.
 * VoiceOver focus starts on Pause, not on the sentence. The sentence element has Next and Previous
 * as custom actions and swipe up / down (adjustable) for next / previous.
 *
 * The screen stays awake while it is open.
 */

import SwiftUI

// MARK: - Model (pure)

enum MirrorContrast: String, CaseIterable, Identifiable, Sendable {
  case darkOnLight
  case lightOnDark
  case yellowOnBlack

  var id: String { rawValue }

  var title: String {
    switch self {
    case .darkOnLight: "Dark on light"
    case .lightOnDark: "Light on dark"
    case .yellowOnBlack: "Yellow on black"
    }
  }

  var next: MirrorContrast {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + 1) % all.count]
  }

  /// Text, background, the highlighted word's text and its background. Every pair is above 7:1
  /// (WCAG AAA), checked in BigTextMirrorTests.
  var colors: (text: RGB, background: RGB, highlightText: RGB, highlight: RGB) {
    switch self {
    case .darkOnLight: (RGB(0, 0, 0), RGB(1, 1, 1), RGB(1, 1, 1), RGB(0, 0, 0.55))
    case .lightOnDark: (RGB(1, 1, 1), RGB(0, 0, 0), RGB(0, 0, 0), RGB(1, 1, 1))
    case .yellowOnBlack: (RGB(1, 0.92, 0), RGB(0, 0, 0), RGB(0, 0, 0), RGB(1, 0.92, 0))
    }
  }

  struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
      self.red = red
      self.green = green
      self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG relative luminance.
    var luminance: Double {
      func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
      return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
      let (light, dark) = a.luminance > b.luminance ? (a.luminance, b.luminance) : (b.luminance, a.luminance)
      return (light + 0.05) / (dark + 0.05)
    }
  }
}

/// The mirror's own text scale, on top of Dynamic Type.
enum MirrorTextScale {
  static let steps: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0, 2.5]
  static let defaultStep = 1
  /// Points at scale 1 and the default text size: three times body text.
  static let basePoints: Double = 48

  static func clamp(_ step: Int) -> Int { min(max(step, 0), steps.count - 1) }
  static func factor(_ step: Int) -> Double { steps[clamp(step)] }
}

/// What the mirror shows: the words of the current sentence and which one is being said. Pure.
struct BigTextMirrorModel: Equatable {
  /// The spoken chunks of the sentence or step, in order.
  var chunks: [String]
  /// The line the app's voice is saying and the word's range in it, when known.
  var spokenLine: String?
  var spokenRange: NSRange?

  var words: [String] { chunks.flatMap(Self.tokens) }

  var text: String { words.joined(separator: " ") }

  /// The index in `words` of the word being said, or nil (cloud voice, between lines, another line).
  var highlightedWord: Int? {
    guard let spokenLine, let spokenRange else { return nil }
    return Self.wordIndex(chunks: chunks, line: spokenLine, range: spokenRange)
  }

  static func wordIndex(chunks: [String], line: String, range: NSRange) -> Int? {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let chunk = chunks.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == line }) else { return nil }
    let before = chunks[..<chunk].map { tokens($0).count }.reduce(0, +)
    let text = line as NSString
    guard range.location != NSNotFound, range.location <= text.length else { return nil }
    // Words in the line before the range starts.
    let head = text.substring(to: range.location)
    var within = tokens(head).count
    // The range starts mid-token only if the head doesn't end in a space ("don't" split by the voice).
    if let last = head.last, !last.isWhitespace, within > 0 { within -= 1 }
    let count = tokens(chunks[chunk]).count
    guard count > 0 else { return nil }
    return before + min(within, count - 1)
  }

  static func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }
}

/// Tap and swipe on the mirror. Pure.
enum MirrorGesture {
  enum Action: Equatable {
    case pause
    case resume
    case next
    case previous
    case none
  }

  /// Tap: pause while reading, carry on when stopped with something to read.
  static func tap(phase: TextReader.Phase, hasSentences: Bool) -> Action {
    switch phase {
    case .reading, .preparing, .recognizing: .pause
    case .stopped, .finished: hasSentences ? .resume : .none
    case .idle, .guided: .none
    }
  }

  /// A horizontal swipe of `dx` points: left is next, right is previous. Short drags are taps.
  static func swipe(dx: Double, dy: Double) -> Action {
    guard abs(dx) >= 50, abs(dx) > abs(dy) else { return .none }
    return dx < 0 ? .next : .previous
  }
}

// MARK: - Controller

@MainActor
@Observable
final class BigTextMirror {
  static let shared = BigTextMirror()

  var isShown = false

  @ObservationIgnored var reader: TextReader = .shared

  /// "big text": shows it when there is something to show. Returns the line said.
  @discardableResult
  func show(announce: Bool = true) -> String {
    guard reader.hasSentences || reader.steps.currentStep != nil || reader.notice != nil else {
      if announce { Announcer.shared.say(SpokenMessage.bigTextNothing, kind: .reply, interrupt: false) }
      return SpokenMessage.bigTextNothing
    }
    isShown = true
    if announce { confirm(SpokenMessage.bigTextOn) }
    return SpokenMessage.bigTextOn
  }

  @discardableResult
  func hide(announce: Bool = true) -> String {
    isShown = false
    if announce { confirm(SpokenMessage.bigTextOff) }
    return SpokenMessage.bigTextOff
  }

  /// A reading in progress carries on, so only an earcon then. VoiceOver says the screen change
  /// itself, so nothing is spoken over it.
  private func confirm(_ line: String) {
    if reader.isActive || UIAccessibility.isVoiceOverRunning {
      EarconPlayer.shared.play(.ready)
    } else {
      Announcer.shared.say(line, kind: .reply, interrupt: false)
    }
  }

  /// The chunks on show: the step in step mode, else the sentence, else the last notice.
  var chunks: [String] {
    if let step = reader.steps.currentStep { return step.rendered.chunks.map(\.text) }
    if let sentence = reader.currentSentence { return sentence.chunks.map(\.text) }
    if let notice = reader.notice { return [notice] }
    return []
  }

  var model: BigTextMirrorModel {
    let spoken = Announcer.shared.spokenWord
    return BigTextMirrorModel(chunks: chunks, spokenLine: spoken?.line, spokenRange: spoken?.range)
  }

  var placeText: String {
    if let status = reader.steps.statusText, reader.steps.isActive { return status }
    return reader.statusText
  }

  func perform(_ action: MirrorGesture.Action) {
    let stepping = reader.steps.isActive
    switch action {
    case .pause: reader.stop()
    case .resume: stepping ? reader.steps.perform(.repeatStep) : reader.repeatSentence()
    case .next: stepping ? reader.steps.perform(.next) : reader.next()
    case .previous: stepping ? reader.steps.perform(.previous) : reader.previous()
    case .none: break
    }
  }
}

// MARK: - View

struct BigTextMirrorView: View {
  private var mirror: BigTextMirror { BigTextMirror.shared }
  private var reader: TextReader { TextReader.shared }
  @Bindable private var settings = PhoneReadingSettings.shared
  @ScaledMetric(relativeTo: .largeTitle) private var basePoints: CGFloat = MirrorTextScale.basePoints
  @AccessibilityFocusState private var pauseFocused: Bool

  private var colors: (text: MirrorContrast.RGB, background: MirrorContrast.RGB, highlightText: MirrorContrast.RGB, highlight: MirrorContrast.RGB) {
    settings.mirrorContrast.colors
  }

  private var isPlaying: Bool { MirrorGesture.tap(phase: reader.phase, hasSentences: reader.hasSentences) == .pause }

  var body: some View {
    let model = mirror.model
    VStack(spacing: 0) {
      topBar
      ScrollView {
        sentence(model)
          .padding(.horizontal, 16)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
      .onTapGesture { mirror.perform(MirrorGesture.tap(phase: reader.phase, hasSentences: reader.hasSentences)) }
      .gesture(
        DragGesture(minimumDistance: 30).onEnded { value in
          mirror.perform(MirrorGesture.swipe(dx: value.translation.width, dy: value.translation.height))
        })
      bottomBar
    }
    .background(colors.background.color.ignoresSafeArea())
    .foregroundStyle(colors.text.color)
    .tint(colors.text.color)
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      pauseFocused = true
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      mirror.isShown = false
    }
    .accessibilityAction(.escape) { mirror.hide() }
  }

  private func sentence(_ model: BigTextMirrorModel) -> some View {
    let highlighted = model.highlightedWord
    var attributed = AttributedString()
    for (index, word) in model.words.enumerated() {
      if index > 0 { attributed += AttributedString(" ") }
      var piece = AttributedString(word)
      if index == highlighted {
        piece.foregroundColor = colors.highlightText.color
        piece.backgroundColor = colors.highlight.color
      }
      attributed += piece
    }
    let size = basePoints * MirrorTextScale.factor(settings.mirrorScaleStep)
    return Text(attributed)
      .font(.custom(BrandFont.bold, fixedSize: size))
      .lineSpacing(size * 0.15)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.text.isEmpty ? "Nothing to show yet" : model.text)
      .accessibilityAddTraits(.isStaticText)
      .accessibilityIdentifier("big_text_sentence")
      .accessibilityAction(named: "Next") { mirror.perform(.next) }
      .accessibilityAction(named: "Previous") { mirror.perform(.previous) }
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: mirror.perform(.next)
        case .decrement: mirror.perform(.previous)
        @unknown default: break
        }
      }
  }

  private var topBar: some View {
    HStack(alignment: .center, spacing: 12) {
      Text(mirror.placeText)
        .font(.rounded(.headline, weight: .heavy))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("big_text_place")
      mirrorButton("xmark", "Close big text", id: "big_text_close_button") { mirror.hide() }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  private var bottomBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        mirrorButton("backward.fill", "Previous", id: "big_text_previous_button") { mirror.perform(.previous) }
        mirrorButton(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Carry on", id: "big_text_pause_button") {
          mirror.perform(MirrorGesture.tap(phase: reader.phase, hasSentences: reader.hasSentences))
        }
        .accessibilityFocused($pauseFocused)
        mirrorButton("forward.fill", "Next", id: "big_text_next_button") { mirror.perform(.next) }
      }
      HStack(spacing: 10) {
        mirrorButton("textformat.size.smaller", "Smaller", id: "big_text_smaller_button") {
          settings.mirrorScaleStep = MirrorTextScale.clamp(settings.mirrorScaleStep - 1)
        }
        mirrorButton("circle.lefthalf.filled", "Contrast: \(settings.mirrorContrast.title)", id: "big_text_contrast_button") {
          settings.mirrorContrast = settings.mirrorContrast.next
        }
        mirrorButton("textformat.size.larger", "Larger", id: "big_text_larger_button") {
          settings.mirrorScaleStep = MirrorTextScale.clamp(settings.mirrorScaleStep + 1)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  /// Outlined in the text colour on the mirror's background, so every contrast choice keeps its
  /// buttons at the same contrast as the text. 60 pt targets.
  private func mirrorButton(_ icon: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 26, weight: .heavy))
        .frame(maxWidth: .infinity, minHeight: 60)
        .overlay {
          RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(colors.text.color, lineWidth: 3)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(minWidth: 60)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }
}

extension View {
  /// Presents the big-text mirror over Read text when BigTextMirror.shared.isShown.
  func bigTextMirrorCover() -> some View {
    modifier(BigTextMirrorCover())
  }
}

private struct BigTextMirrorCover: ViewModifier {
  @Bindable private var mirror = BigTextMirror.shared

  func body(content: Content) -> some View {
    content.fullScreenCover(isPresented: $mirror.isShown) { BigTextMirrorView() }
  }
}
