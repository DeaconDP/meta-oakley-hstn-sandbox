/*
 * Mascot - a small round reader wearing the glasses from the app icon (design/app-icon-glyph.svg)
 *
 * All vector, drawn in the icon's 512 x 512 space and scaled to fit. It reflects state with its
 * eyes, mouth and props, and it is decorative: hidden from VoiceOver, kept as is under Smart Invert,
 * and whatever it shows is always in text beside it too.
 */

import SwiftUI

enum MascotMood: String, CaseIterable, Sendable {
  case idle, listening, reading, happy, confused
}

struct Mascot: View {
  var mood: MascotMood = .idle

  private let bodyColor = Color(red: 1, green: 0.79, blue: 0.2)
  private let bodyShade = Color(red: 0.88, green: 0.6, blue: 0)
  private let ink = Color(red: 0.075, green: 0.15, blue: 0.106)

  var body: some View {
    ZStack {
      MascotShape(draw: Self.feet).fill(bodyShade)
      MascotShape(draw: Self.bodyLip).fill(bodyShade)
      MascotShape(draw: Self.bodyFace).fill(bodyColor)
      MascotShape(draw: Self.lenses).fill(Color.white)
      MascotShape(draw: Self.eyes(mood)).fill(ink)
      MascotShape(draw: Self.glasses).fill(ink, style: FillStyle(eoFill: true))
      mouth
      props
    }
    .aspectRatio(1, contentMode: .fit)
    .rotationEffect(mood == .confused ? .degrees(-5) : .zero)
    .a11yDecorative()
  }

  @ViewBuilder
  private var mouth: some View {
    let line = StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
    switch mood {
    case .happy:
      MascotShape(draw: Self.openSmile).fill(ink)
    case .listening:
      MascotShape(draw: Self.smallO).fill(ink)
    case .confused:
      MascotShape(draw: Self.wavyMouth, stroke: line).fill(ink)
    case .idle, .reading:
      MascotShape(draw: Self.smile, stroke: line).fill(ink)
    }
  }

  @ViewBuilder
  private var props: some View {
    switch mood {
    case .idle:
      EmptyView()
    case .listening:
      MascotShape(draw: Self.soundWaves, stroke: StrokeStyle(lineWidth: 16, lineCap: .round)).fill(ink)
    case .reading:
      MascotShape(draw: Self.bookPages).fill(Color.white)
      MascotShape(draw: Self.bookPages, stroke: StrokeStyle(lineWidth: 12, lineJoin: .round)).fill(ink)
      MascotShape(draw: Self.bookLines, stroke: StrokeStyle(lineWidth: 8, lineCap: .round)).fill(ink)
    case .happy:
      MascotShape(draw: Self.sparkles).fill(ink)
    case .confused:
      MascotShape(draw: Self.questionMark, stroke: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)).fill(ink)
      MascotShape(draw: Self.questionDot).fill(ink)
    }
  }

  // MARK: Drawing, in 512 x 512

  nonisolated private static func oval(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    p.addEllipse(in: CGRect(x: x, y: y, width: w, height: h))
  }

  nonisolated private static func feet(_ p: inout Path) {
    oval(&p, 140, 436, 92, 52)
    oval(&p, 280, 436, 92, 52)
  }

  nonisolated private static func bodyLip(_ p: inout Path) { oval(&p, 56, 92, 400, 372) }

  nonisolated private static func bodyFace(_ p: inout Path) { oval(&p, 56, 72, 400, 372) }

  nonisolated private static func lenses(_ p: inout Path) {
    p.addRoundedRect(in: CGRect(x: 76, y: 150, width: 150, height: 150), cornerSize: CGSize(width: 44, height: 44))
    p.addRoundedRect(in: CGRect(x: 286, y: 150, width: 150, height: 150), cornerSize: CGSize(width: 44, height: 44))
  }

  nonisolated private static func eyes(_ mood: MascotMood) -> @Sendable (inout Path) -> Void {
    { p in
      switch mood {
      case .happy:
        // Closed, smiling eyes: drawn as thick arcs, so they still read at small sizes.
        for x: CGFloat in [151, 361] {
          var eye = Path()
          eye.addArc(center: CGPoint(x: x, y: 236), radius: 34, startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
          eye.addArc(center: CGPoint(x: x, y: 240), radius: 19, startAngle: .degrees(350), endAngle: .degrees(190), clockwise: true)
          eye.closeSubpath()
          p.addPath(eye)
        }
      case .confused:
        p.addRoundedRect(in: CGRect(x: 128, y: 190, width: 46, height: 84), cornerSize: CGSize(width: 23, height: 23))
        oval(&p, 342, 212, 40, 40)
      case .reading:
        // Looking down at the book.
        p.addRoundedRect(in: CGRect(x: 128, y: 212, width: 46, height: 74), cornerSize: CGSize(width: 23, height: 23))
        p.addRoundedRect(in: CGRect(x: 338, y: 212, width: 46, height: 74), cornerSize: CGSize(width: 23, height: 23))
      case .idle, .listening:
        p.addRoundedRect(in: CGRect(x: 128, y: 182, width: 46, height: 92), cornerSize: CGSize(width: 23, height: 23))
        p.addRoundedRect(in: CGRect(x: 338, y: 182, width: 46, height: 92), cornerSize: CGSize(width: 23, height: 23))
      }
    }
  }

  /// The frame from the app icon, its lens holes cut out by the even-odd fill.
  nonisolated private static func glasses(_ p: inout Path) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 256 + (x - 256) * 0.82, y: 225 + (y - 256) * 0.82) }
    p.move(to: pt(12.65, 173.68))
    p.addQuadCurve(to: pt(42, 140), control: pt(8, 140))
    p.addLine(to: pt(470, 140))
    p.addQuadCurve(to: pt(499.35, 173.68), control: pt(504, 140))
    p.addLine(to: pt(482.38, 296.71))
    p.addQuadCurve(to: pt(396, 372), control: pt(472, 372))
    p.addLine(to: pt(366, 372))
    p.addQuadCurve(to: pt(284.24, 296.22), control: pt(290, 372))
    p.addLine(to: pt(278.08, 215))
    p.addQuadCurve(to: pt(277, 214), control: pt(278, 214))
    p.addLine(to: pt(235, 214))
    p.addQuadCurve(to: pt(233.92, 215), control: pt(234, 214))
    p.addLine(to: pt(227.76, 296.22))
    p.addQuadCurve(to: pt(146, 372), control: pt(222, 372))
    p.addLine(to: pt(116, 372))
    p.addQuadCurve(to: pt(29.62, 296.71), control: pt(40, 372))
    p.closeSubpath()
    p.move(to: pt(54.71, 203.81))
    p.addQuadCurve(to: pt(72, 184), control: pt(52, 184))
    p.addLine(to: pt(178, 184))
    p.addQuadCurve(to: pt(194.53, 201.94), control: pt(196, 184))
    p.addLine(to: pt(187.77, 284.15))
    p.addQuadCurve(to: pt(138, 330), control: pt(184, 330))
    p.addLine(to: pt(118, 330))
    p.addQuadCurve(to: pt(65.76, 284.43), control: pt(72, 330))
    p.closeSubpath()
    p.move(to: pt(446.24, 284.43))
    p.addQuadCurve(to: pt(394, 330), control: pt(440, 330))
    p.addLine(to: pt(374, 330))
    p.addQuadCurve(to: pt(324.23, 284.15), control: pt(328, 330))
    p.addLine(to: pt(317.47, 201.94))
    p.addQuadCurve(to: pt(334, 184), control: pt(316, 184))
    p.addLine(to: pt(440, 184))
    p.addQuadCurve(to: pt(457.29, 203.81), control: pt(460, 184))
    p.closeSubpath()
  }

  nonisolated private static func smile(_ p: inout Path) {
    p.move(to: CGPoint(x: 206, y: 352))
    p.addQuadCurve(to: CGPoint(x: 306, y: 352), control: CGPoint(x: 256, y: 400))
  }

  nonisolated private static func openSmile(_ p: inout Path) {
    p.move(to: CGPoint(x: 188, y: 340))
    p.addQuadCurve(to: CGPoint(x: 324, y: 340), control: CGPoint(x: 256, y: 352))
    p.addQuadCurve(to: CGPoint(x: 188, y: 340), control: CGPoint(x: 256, y: 442))
    p.closeSubpath()
  }

  nonisolated private static func smallO(_ p: inout Path) { oval(&p, 232, 340, 48, 54) }

  nonisolated private static func wavyMouth(_ p: inout Path) {
    p.move(to: CGPoint(x: 200, y: 368))
    p.addQuadCurve(to: CGPoint(x: 256, y: 362), control: CGPoint(x: 228, y: 336))
    p.addQuadCurve(to: CGPoint(x: 312, y: 356), control: CGPoint(x: 284, y: 388))
  }

  nonisolated private static func soundWaves(_ p: inout Path) {
    for (x, start, end): (CGFloat, Double, Double) in [(90, 150, 210), (422, -30, 30)] {
      for radius: CGFloat in [66, 96] {
        var wave = Path()
        wave.addArc(center: CGPoint(x: x, y: 300), radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        p.addPath(wave)
      }
    }
  }

  nonisolated private static func bookPages(_ p: inout Path) {
    p.move(to: CGPoint(x: 256, y: 396))
    p.addQuadCurve(to: CGPoint(x: 136, y: 384), control: CGPoint(x: 196, y: 366))
    p.addLine(to: CGPoint(x: 136, y: 472))
    p.addQuadCurve(to: CGPoint(x: 256, y: 484), control: CGPoint(x: 196, y: 454))
    p.addQuadCurve(to: CGPoint(x: 376, y: 472), control: CGPoint(x: 316, y: 454))
    p.addLine(to: CGPoint(x: 376, y: 384))
    p.addQuadCurve(to: CGPoint(x: 256, y: 396), control: CGPoint(x: 316, y: 366))
    p.closeSubpath()
    p.move(to: CGPoint(x: 256, y: 396))
    p.addLine(to: CGPoint(x: 256, y: 484))
  }

  nonisolated private static func bookLines(_ p: inout Path) {
    for y: CGFloat in [416, 442] {
      p.move(to: CGPoint(x: 166, y: y))
      p.addLine(to: CGPoint(x: 226, y: y))
      p.move(to: CGPoint(x: 286, y: y))
      p.addLine(to: CGPoint(x: 346, y: y))
    }
  }

  nonisolated private static func star(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    p.move(to: CGPoint(x: x, y: y - r))
    p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
    p.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
    p.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
    p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
    p.closeSubpath()
  }

  nonisolated private static func sparkles(_ p: inout Path) {
    star(&p, 66, 76, 46)
    star(&p, 450, 56, 38)
    star(&p, 478, 150, 22)
  }

  nonisolated private static func questionMark(_ p: inout Path) {
    p.move(to: CGPoint(x: 410, y: 58))
    p.addQuadCurve(to: CGPoint(x: 462, y: 44), control: CGPoint(x: 432, y: 22))
    p.addQuadCurve(to: CGPoint(x: 446, y: 100), control: CGPoint(x: 500, y: 74))
    p.addLine(to: CGPoint(x: 442, y: 120))
  }

  nonisolated private static func questionDot(_ p: inout Path) { oval(&p, 428, 140, 26, 26) }
}

/// One drawing in the 512 x 512 space, scaled to the frame it's given.
struct MascotShape: Shape {
  let draw: @Sendable (inout Path) -> Void
  /// A line instead of a filled shape. In drawing units, so it scales with the mascot.
  var stroke: StrokeStyle?

  func path(in rect: CGRect) -> Path {
    var path = Path()
    draw(&path)
    if let stroke { path = path.strokedPath(stroke) }
    let scale = min(rect.width, rect.height) / 512
    return path.applying(CGAffineTransform(scaleX: scale, y: scale))
      .offsetBy(dx: rect.midX - 256 * scale, dy: rect.midY - 256 * scale)
  }
}
