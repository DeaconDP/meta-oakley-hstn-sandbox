/*
 * ReadPanel - the main screen's reading card: where the reader is ("Reading sentence 2 of 4" and a
 * progress bar), the sentence being read in large print, and Previous / Repeat / Next / Stop
 *
 * The current sentence doubles as a magnifier: 30 pt bold at the default text size, scaling with
 * Dynamic Type, Night or Paper ink on the page colour, and a bar beside it that is Voice Coral while
 * the sentence is spoken and Listen Cyan while the reader waits for a command. The mascot lives only
 * in the status card above, so this card stays calm.
 *
 * The large-print sentence is for low-vision users following along (notes/a11y-prior-art.md > 3,
 * "large-print live transcript"). Controls are at least 60 pt, labelled for VoiceOver, and shown
 * with their names at accessibility text sizes. The same actions are VoiceOver custom actions on
 * every camera-screen element (cameraQuickActions), so nobody has to find this card to use them.
 */

import SwiftUI

struct ReadPanel: View {
  let isLargeText: Bool
  let onStatus: () -> Void

  private var reader: TextReader { TextReader.shared }
  @ScaledMetric(relativeTo: .title) private var accentWidth: CGFloat = 6
  @Environment(\.colorSchemeContrast) private var contrast

  /// Coral while the sentence is being spoken, Cyan while the reader waits for a command.
  private var isSpeaking: Bool { reader.phase == .reading }

  /// How far through the page, 0 to 1. Finished counts as the whole page.
  private var progress: Double {
    guard reader.hasSentences else { return 0 }
    if reader.phase == .finished { return 1 }
    return Double(reader.index + 1) / Double(reader.sentences.count)
  }

  /// The status line as shown. When the reader gave guidance, the guidance is already in large print
  /// below, so the line just says what happened; VoiceOver still hears the full status.
  private var visibleStatus: String {
    reader.phase == .guided && reader.notice != nil ? "Couldn\u{2019}t read this time" : reader.statusText
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.lg) {
      VStack(alignment: .leading, spacing: Theme.Space.sm) {
        Text(visibleStatus)
          .font(.rounded(.headline, weight: .heavy))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          // It carries VoiceOver actions, so it needs a target's height, not just a line's.
          .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          .contentShape(Rectangle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(reader.statusText)
          .accessibilityAddTraits(.isStaticText)
          .accessibilityIdentifier("read_status")
          .cameraQuickActions(status: onStatus)
        if reader.hasSentences {
          ReadProgressBar(progress: progress)
        }
      }

      if let sentence = reader.currentSentence {
        magnified(sentence.display, accent: isSpeaking ? Theme.speak : Theme.listen)
          .accessibilityIdentifier("read_sentence")
      } else if let notice = reader.notice, reader.phase == .guided {
        magnified(notice, accent: Theme.listen)
          .accessibilityIdentifier("read_notice")
      }

      // Timings are for the benchmark and UI tests, not users (bench.sh reads them from the log).
      if LaunchOptions.isUITesting, let timing = reader.lastTiming {
        Text(timing.summary)
          .font(.rounded(.footnote, weight: .regular))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("read_timing")
      }

      controls

      if reader.hasSentences || reader.isActive {
        SayLine(commands: reader.hasSentences ? [.back, .repeatLast, .continueOn, .stop] : [.stop])
      }
    }
    .themeCard()
    .stateAnimation(value: isSpeaking)
    .accessibilityElement(children: .contain)
  }

  /// The current sentence as a low-vision magnifier: large bold print on the page colour, with a
  /// bar in the state colour beside it. The bar is decoration; VoiceOver reads only the sentence.
  private func magnified(_ text: String, accent: Color) -> some View {
    Text(text)
      .font(.brand(size: 30, relativeTo: .title, weight: .bold))
      .lineSpacing(6)
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Theme.Space.md)
      .padding(.leading, accentWidth + Theme.Space.md)
      .padding(.trailing, Theme.Space.md)
      .background(alignment: .leading) {
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.page)
          Capsule()
            .fill(accent)
            .frame(width: accentWidth)
            .padding(.vertical, Theme.Space.sm)
            .padding(.leading, Theme.Space.xs)
        }
        .accessibilityHidden(true)
      }
      .overlay {
        if contrast == .increased {
          RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: Theme.outlineWidthIncreased)
            .accessibilityHidden(true)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
      .accessibilityAddTraits(.isStaticText)
      .cameraQuickActions(status: onStatus)
  }

  @ViewBuilder
  private var controls: some View {
    let buttons = Group {
      if reader.hasSentences {
        control("backward.fill", "Previous sentence", id: "read_previous_button") { reader.previous() }
        control("arrow.counterclockwise", "Repeat sentence", id: "read_repeat_button") { reader.repeatSentence() }
        control("forward.fill", "Next sentence", id: "read_next_button") { reader.next() }
      }
      if reader.isActive {
        control("stop.fill", "Stop reading", tone: .red, id: "read_stop_button") { reader.stop() }
      }
    }
    if isLargeText {
      VStack(spacing: Theme.Space.sm) { buttons }
    } else {
      HStack(spacing: Theme.Space.sm) { buttons }
    }
  }

  private func control(_ icon: String, _ title: String, tone: Tone = .neutral, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      // Above the words at large text, so the words get the whole width and don't hyphenate.
      VStack(spacing: Theme.Space.xxs) {
        Image(systemName: icon)
          .font(.rounded(.title3, weight: .heavy))
          .accessibilityHidden(true)
        if isLargeText {
          Text(title)
        }
      }
    }
    .buttonStyle(ChunkyButtonStyle(tone: tone, lipHeight: 5))
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
    .cameraQuickActions(status: onStatus)
  }
}

/// "Sentence n of m" as a bar: the fill on its track (both at least 3:1, ThemePaletteTests). The
/// status line above says the same in words, so VoiceOver skips it.
struct ReadProgressBar: View {
  let progress: Double
  @ScaledMetric(relativeTo: .body) private var height: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track)
        Capsule()
          .fill(Theme.fill)
          .frame(width: max(height, proxy.size.width * min(max(progress, 0), 1)))
      }
    }
    .frame(height: height)
    .stateAnimation(value: progress)
    .accessibilityHidden(true)
    .accessibilityIdentifier("read_progress")
  }
}
