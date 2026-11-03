/*
 * ThemeComponents - the pieces every screen shares: cards, the mascot's speech bubble, the chunky
 * progress bar, the lesson page, path tiles and the reading progress card
 */

import SwiftUI

// MARK: - Card

extension View {
  /// A big soft card with an outline that reaches 3:1 against the page.
  func themeCard(padding: CGFloat = 16) -> some View {
    modifier(ThemeCard(padding: padding))
  }
}

private struct ThemeCard: ViewModifier {
  let padding: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
          .strokeBorder(Theme.stroke, lineWidth: contrast == .increased ? 3 : 2)
      }
  }
}

// MARK: - Speech bubble

/// The mascot saying something. The words are the same ones the app speaks; VoiceOver reads them as
/// ordinary text and skips the mascot.
struct MascotSays<Content: View>: View {
  var mood: MascotMood
  var mascotSize: CGFloat = 76
  @ViewBuilder var content: Content

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 2))
    layout {
      Mascot(mood: mood)
        .frame(width: mascotSize, height: mascotSize)
      VStack(alignment: .leading, spacing: 8) { content }
        .padding(14)
        // The tail takes this much of the shape's width.
        .padding(.leading, stacked ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SpeechBubbleShape(tail: !stacked).fill(Theme.surface) }
        .overlay { SpeechBubbleShape(tail: !stacked).stroke(Theme.stroke, lineWidth: contrast == .increased ? 3 : 2) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension MascotSays where Content == A11yNote {
  init(mood: MascotMood, text: String, mascotSize: CGFloat = 76) {
    self.init(mood: mood, mascotSize: mascotSize) { A11yNote(text: text) }
  }
}

/// A rounded card with a little tail on its leading side, pointing at the mascot.
struct SpeechBubbleShape: Shape {
  var tail = true

  func path(in rect: CGRect) -> Path {
    let radius: CGFloat = 20
    let tailWidth: CGFloat = tail ? 12 : 0
    let body = CGRect(x: rect.minX + tailWidth, y: rect.minY, width: rect.width - tailWidth, height: rect.height)
    var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
    if tail {
      var tip = Path()
      tip.move(to: CGPoint(x: body.minX + 1, y: rect.minY + 22))
      tip.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 34))
      tip.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY + 44))
      path = path.union(tip)
    }
    return path
  }
}

// MARK: - Progress bar

/// Thick and rounded. Decorative by itself: whoever uses it gives the value in words and to VoiceOver.
struct ChunkyProgressBar: View {
  var fraction: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 18

  var body: some View {
    let barHeight = min(height, 30)
    GeometryReader { geometry in
      let clamped = max(0, min(1, fraction))
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track)
        if clamped > 0 {
          Capsule()
            .fill(Theme.fill)
            .frame(width: max(barHeight, geometry.size.width * clamped))
            .overlay(alignment: .top) {
              // The highlight that makes it look moulded.
              Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(height: barHeight * 0.22)
                .padding(.horizontal, barHeight * 0.4)
                .padding(.top, barHeight * 0.18)
            }
        }
      }
      .overlay { Capsule().strokeBorder(Theme.stroke, lineWidth: contrast == .increased ? 3 : 2) }
      .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7), value: clamped)
    }
    .frame(height: barHeight)
    .accessibilityHidden(true)
  }
}

// MARK: - Lesson page

private struct LessonHeaderKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
  /// What a LessonPage shows above its content (the step title, in setup).
  var lessonHeader: AnyView? {
    get { self[LessonHeaderKey.self] }
    set { self[LessonHeaderKey.self] = newValue }
  }
}

/// One thing per screen, with its main buttons in reach at the bottom. At large text sizes the
/// buttons would take up the screen if pinned, so everything scrolls together instead.
struct LessonPage<Content: View, Footer: View>: View {
  @ViewBuilder var content: Content
  @ViewBuilder var footer: Footer

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.lessonHeader) private var header
  @Environment(\.colorSchemeContrast) private var contrast

  private var pinsFooter: Bool { dynamicTypeSize <= .xLarge }

  var body: some View {
    // Above the footer, not under it: nothing is ever hidden behind a pinned button.
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let header { header }
          content
          if !pinsFooter {
            VStack(spacing: 12) { footer }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      if pinsFooter {
        Rectangle()
          .fill(Theme.stroke)
          .frame(height: contrast == .increased ? 3 : 2)
          .accessibilityHidden(true)
        VStack(spacing: 10) { footer }
          .padding(.horizontal, 20)
          .padding(.top, 12)
          .padding(.bottom, 8)
          .frame(maxWidth: 700)
          .frame(maxWidth: .infinity)
      }
    }
    .background(Theme.page.ignoresSafeArea())
  }
}

// MARK: - Path tiles

/// What goes inside a tile's button: a round coin, the name, and the "Say ..." line. The biggest tile
/// is the one main action right now.
struct PathTileLabel: View {
  let icon: String
  let title: String
  var value: String?
  var coin: Tone = .blue
  var isBig = false
  var say: VoiceCommand?
  /// Shown while disabled, so low-vision users can read why (VoiceOver has it as the hint).
  var lockedNote: String?

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title3) private var coinSize: CGFloat = 52

  var body: some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    let size = min(coinSize * (isBig ? 1.35 : 1), 96)
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))
    layout {
      TileCoin(icon: isEnabled ? icon : "lock.fill", tone: isEnabled ? coin : .neutral, size: size)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.rounded(isBig ? .title2 : .title3, weight: .heavy))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        if let value {
          Text(value)
            .font(.rounded(.subheadline, weight: .semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let say, isEnabled {
          SayHint(command: say)
            .multilineTextAlignment(.leading)
        }
        if !isEnabled, let lockedNote {
          Text(lockedNote)
            .font(.rounded(.footnote, weight: .semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, isBig ? 6 : 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The button it's in has the name, hint and value. This adds no second element inside it.
    .accessibilityHidden(true)
  }
}

/// A small 3D coin holding an icon.
struct TileCoin: View {
  let icon: String
  let tone: Tone
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(Theme.lip(tone)).offset(y: 3)
      Circle().fill(Theme.face(tone))
      Circle().strokeBorder(Theme.lip(tone), lineWidth: 2)
      Image(systemName: icon)
        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
        .foregroundStyle(Theme.onFace(tone))
    }
    .frame(width: size, height: size)
    .padding(.bottom, 3)
    .accessibilityHidden(true)
  }
}

/// The dots between tiles. Purely visual, and gone at accessibility sizes, where every point of
/// height is needed for the text.
struct PathDots: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      Color.clear.frame(height: 12).accessibilityHidden(true)
    } else {
      VStack(spacing: 4) {
        ForEach(0..<2, id: \.self) { _ in
          Circle().fill(Theme.stroke).frame(width: 8, height: 8)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
      .accessibilityHidden(true)
    }
  }
}

enum PathSide {
  case left, right, center
}

extension View {
  /// The path's zigzag. Tiles keep their width at large text, so reflow beats a nudge there.
  func pathSide(_ side: PathSide) -> some View {
    modifier(PathSideModifier(side: side))
  }
}

private struct PathSideModifier: ViewModifier {
  let side: PathSide
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func body(content: Content) -> some View {
    let nudge: CGFloat = dynamicTypeSize >= .xLarge ? 0 : 26
    content
      .padding(.leading, side == .right ? nudge : 0)
      .padding(.trailing, side == .left ? nudge : 0)
  }
}

// MARK: - Reading progress

/// The streak and today's pages: one element, one spoken value.
struct ReadingProgressCard: View {
  private var store: ReadingProgressStore { ReadingProgressStore.shared }

  var body: some View {
    // Re-reads the date each minute, so the card turns over at midnight by itself.
    TimelineView(.everyMinute) { _ in
      let summary = store.summary
      VStack(alignment: .leading, spacing: 10) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            streak(summary)
            Spacer(minLength: 0)
            pages(summary)
          }
          VStack(alignment: .leading, spacing: 6) {
            streak(summary)
            pages(summary)
          }
        }
        ChunkyProgressBar(fraction: summary.fraction)
        if let best = summary.bestText {
          Text(best)
            .font(.rounded(.footnote, weight: .semibold))
            .foregroundStyle(Theme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .themeCard()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Reading progress")
      .accessibilityValue(summary.spokenValue)
      .accessibilityIdentifier("reading_progress")
    }
  }

  private func streak(_ summary: ReadingSummary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: summary.streak > 0 ? "flame.fill" : "flame")
        .foregroundStyle(Theme.lip(.orange))
      Text(summary.streakText)
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.rounded(.headline, weight: .heavy))
  }

  private func pages(_ summary: ReadingSummary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: summary.goalReached ? "checkmark.seal.fill" : "book.fill")
        .foregroundStyle(Theme.lip(.green))
      Text(summary.pagesText)
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.rounded(.subheadline, weight: .bold))
  }
}
