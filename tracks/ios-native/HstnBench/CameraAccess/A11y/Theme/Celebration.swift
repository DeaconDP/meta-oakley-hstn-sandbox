/*
 * Celebration - a small moment when setup finishes, a page is read or a goal is reached
 *
 * Purely visual, and on top of what's already heard: "Setup finished." and the reader's end line and
 * earcon are spoken as before. So it is hidden from VoiceOver, ignores touches, goes away by itself,
 * and adds no audio. Under Reduce Motion there's no confetti and no bounce, only the card.
 */

import Observation
import SwiftUI

@MainActor
@Observable
final class Celebrations {
  static let shared = Celebrations()

  struct Moment: Equatable {
    var id = UUID()
    var title: String
    var detail: String?
    var confetti: Bool
  }

  private(set) var current: Moment?
  @ObservationIgnored private var dismissal: Task<Void, Never>?

  func show(_ moment: Moment, for seconds: Double = 4) {
    current = moment
    dismissal?.cancel()
    dismissal = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.current = nil
    }
  }

  func setupFinished() {
    show(Moment(title: "Setup finished!", detail: "You're ready to read.", confetti: true))
  }

  /// A page was read to its end. Confetti only for a goal or a streak, so a page stays a small thing.
  func pageRead(summary: ReadingSummary, milestone: ReadingMilestone?) {
    switch milestone {
    case .streak(let days):
      show(Moment(title: "\(days)-day streak!", detail: summary.countText, confetti: true))
    case .dailyGoal:
      show(Moment(title: "Goal reached!", detail: summary.countText, confetti: true))
    case nil:
      show(Moment(title: "Page read!", detail: summary.countText, confetti: false))
    }
  }
}

struct CelebrationOverlay: View {
  private var celebrations: Celebrations { Celebrations.shared }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    ZStack(alignment: .top) {
      if let moment = celebrations.current {
        if moment.confetti, !reduceMotion {
          ConfettiView().id(moment.id)
        }
        card(moment)
          .padding(.horizontal, 20)
          .padding(.top, 8)
          .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: celebrations.current)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func card(_ moment: Celebrations.Moment) -> some View {
    HStack(spacing: 12) {
      Mascot(mood: .happy)
        .frame(width: 64, height: 64)
      VStack(alignment: .leading, spacing: 2) {
        Text(moment.title)
          .font(.rounded(.title3, weight: .heavy))
          .fixedSize(horizontal: false, vertical: true)
        // At accessibility sizes the title alone: the card shouldn't cover the page, and the
        // progress card already has the count.
        if let detail = moment.detail, !dynamicTypeSize.isAccessibilitySize {
          Text(detail)
            .font(.rounded(.subheadline, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(Theme.onFace(.green))
    .padding(12)
    .padding(.bottom, 6)
    .background {
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.lip(.green))
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.face(.green)).padding(.bottom, 6)
      }
    }
    .accessibilityIdentifier("celebration_card")
  }
}

/// Rounded bits falling once. Deterministic, so nothing depends on chance.
private struct ConfettiView: View {
  @State private var start = Date()

  private static let duration = 2.4
  private static let colors: [Color] = [.green, .orange, .purple, .blue, .pink, .yellow]

  var body: some View {
    TimelineView(.animation) { context in
      Canvas { canvas, size in
        let elapsed = context.date.timeIntervalSince(start)
        guard elapsed < Self.duration else { return }
        for index in 0..<36 {
          let seed = Double(index)
          let x = (sin(seed * 12.9898) * 0.5 + 0.5) * size.width
          let delay = (sin(seed * 78.233) * 0.5 + 0.5) * 0.6
          let time = max(0, elapsed - delay)
          let y = -20 + time * time * 260 + time * 120
          let drift = sin(time * 4 + seed) * 18
          let rect = CGRect(x: x + drift, y: y, width: 10, height: 14)
          var piece = canvas
          piece.translateBy(x: rect.midX, y: rect.midY)
          piece.rotate(by: .radians(time * 5 + seed))
          piece.translateBy(x: -rect.midX, y: -rect.midY)
          piece.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Self.colors[index % Self.colors.count]))
        }
      }
    }
    .ignoresSafeArea()
    .a11yDecorative()
  }
}
