/*
 * ReadPanel - the camera screen's reading card: where the reader is, the sentence being read in
 * large print, the last timing, and Previous / Repeat / Next / Stop
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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(reader.statusText)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color(white: 0.85))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("read_status")
        .cameraQuickActions(status: onStatus)

      if let sentence = reader.currentSentence {
        Text(sentence.display)
          .font(.title3)
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("read_sentence")
          .cameraQuickActions(status: onStatus)
      } else if let notice = reader.notice, reader.phase == .guided {
        Text(notice)
          .font(.title3)
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("read_notice")
          .cameraQuickActions(status: onStatus)
      }

      if let timing = reader.lastTiming {
        Text(timing.summary)
          .font(.footnote)
          .foregroundStyle(Color(white: 0.85))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("read_timing")
      }

      controls
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
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
        control("stop.fill", "Stop reading", id: "read_stop_button") { reader.stop() }
      }
    }
    if isLargeText {
      VStack(spacing: 10) { buttons }
    } else {
      HStack(spacing: 10) { buttons }
    }
  }

  private func control(_ icon: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      ControlLabel(icon: icon, title: isLargeText ? title : nil)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
    .cameraQuickActions(status: onStatus)
  }
}
