/*
 * ThemeComponents - the pieces every screen shares: cards, the mascot's speech bubble, the lesson
 * page and the tile label for big buttons
 */

import SwiftUI

// MARK: - Card

extension View {
  /// A big soft card with an outline that reaches 3:1 against the page.
  func themeCard(padding: CGFloat = Theme.Space.lg) -> some View {
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
          .strokeBorder(Theme.stroke, lineWidth: contrast == .increased ? Theme.outlineWidthIncreased : Theme.outlineWidth)
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
    let layout = stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs))
      : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.xxs))
    layout {
      // A mood change crossfades with the shared state-change motion (none under Reduce Motion).
      ZStack {
        Mascot(mood: mood)
          .id(mood)
          .transition(.opacity)
      }
      .frame(width: mascotSize, height: mascotSize)
      .stateAnimation(value: mood)
      VStack(alignment: .leading, spacing: Theme.Space.xs) { content }
        .padding(Theme.Space.md)
        // The tail takes this much of the shape's width.
        .padding(.leading, stacked ? 0 : SpeechBubbleShape.tailWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SpeechBubbleShape(tail: !stacked).fill(Theme.surface) }
        .overlay { SpeechBubbleShape(tail: !stacked).stroke(Theme.stroke, lineWidth: contrast == .increased ? Theme.outlineWidthIncreased : Theme.outlineWidth) }
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

  static let tailWidth: CGFloat = Theme.Space.sm

  func path(in rect: CGRect) -> Path {
    let radius = Theme.Radius.lg
    let tailWidth: CGFloat = tail ? Self.tailWidth : 0
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

// MARK: - Lesson page

/// One thing per screen, with its main buttons in reach at the bottom. At large text sizes the
/// buttons would take up the screen if pinned, so everything scrolls together instead.
struct LessonPage<Content: View, Footer: View>: View {
  @ViewBuilder var content: Content
  @ViewBuilder var footer: Footer

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast

  private var pinsFooter: Bool { dynamicTypeSize <= .xLarge }

  var body: some View {
    // Above the footer, not under it: nothing is ever hidden behind a pinned button.
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
          content
          if !pinsFooter {
            VStack(spacing: Theme.Space.sm) { footer }
          }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xl)
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      if pinsFooter {
        Rectangle()
          .fill(Theme.stroke)
          .frame(height: contrast == .increased ? Theme.outlineWidthIncreased : Theme.outlineWidth)
          .accessibilityHidden(true)
        VStack(spacing: Theme.Space.sm) { footer }
          .padding(.horizontal, Theme.Space.lg)
          .padding(.top, Theme.Space.md)
          .padding(.bottom, Theme.Space.xs)
          .frame(maxWidth: Theme.maxContentWidth)
          .frame(maxWidth: .infinity)
      }
    }
    .background(Theme.page.ignoresSafeArea())
  }
}

// MARK: - Tiles

/// What goes inside a big button: a round coin, the name, and the "Say ..." line.
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
    let layout = stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs))
      : AnyLayout(HStackLayout(spacing: Theme.Space.md))
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
    .padding(.vertical, isBig ? Theme.Space.xs : Theme.Space.xxs)
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
