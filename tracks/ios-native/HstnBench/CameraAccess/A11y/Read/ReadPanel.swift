/*
 * ReadPanel - the main screen's reading card: where the reader is, the sentence being read in
 * large print, and Previous / Repeat / Next / Stop
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

  private var mood: MascotMood {
    switch reader.phase {
    case .reading: .reading
    case .finished: .happy
    case .guided: .confused
    case .idle, .preparing, .recognizing, .stopped: .idle
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MascotSays(mood: mood, mascotSize: 64) {
        Text(reader.statusText)
          .font(.rounded(.subheadline, weight: .heavy))
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

        if let step = reader.steps.currentStep {
          Text(step.printed)
            .font(.rounded(.title2, weight: .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("read_step_text")
            .cameraQuickActions(status: onStatus)
        } else if let sentence = reader.currentSentence {
          Text(sentence.display)
            .font(.rounded(.title2, weight: .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("read_sentence")
            .cameraQuickActions(status: onStatus)
        } else if let notice = reader.notice, reader.phase == .guided {
          Text(notice)
            .font(.rounded(.title2, weight: .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("read_notice")
            .cameraQuickActions(status: onStatus)
        }
      }

      // Timings are for the benchmark and UI tests, not users (bench.sh reads them from the log).
      if LaunchOptions.isUITesting, let timing = reader.lastTiming {
        Text(timing.summary)
          .font(.rounded(.footnote, weight: .medium))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("read_timing")
      }

      controls

      if reader.torchOfferPending {
        wideButton("flashlight.on.fill", "Torch on", tone: .yellow, id: "read_torch_button") { reader.acceptTorchOffer() }
          .accessibilityHint("Turns on the phone's torch and reads again.")
      }

      if !reader.steps.steps.isEmpty {
        stepsRow
      }

      if reader.hasSentences || reader.notice != nil {
        wideButton("textformat.size", "Big text", id: "read_big_text_button") { BigTextMirror.shared.show(announce: false) }
          .accessibilityHint("Shows what is being read in very large print, following the voice.")
      }

      if reader.hasSentences || reader.isActive {
        SayLine(commands: reader.hasSentences ? [.back, .repeatLast, .continueOn, .stop] : [.stop])
      }
    }
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
        control("stop.fill", "Stop reading", tone: .red, id: "read_stop_button") { reader.stop() }
      }
    }
    if isLargeText {
      VStack(spacing: 10) { buttons }
    } else {
      HStack(spacing: 10) { buttons }
    }
  }

  /// "Step 2 of 6" (or "6 steps found") and Previous / Repeat / Next step. Steps work from memory,
  /// so these stay after the read ends.
  private var stepsRow: some View {
    let steps: ReadSteps = reader.steps
    let buttons = Group {
      control("chevron.backward.2", "Previous step", id: "read_step_previous_button") { steps.perform(.previous) }
      control("arrow.counterclockwise.circle", "Repeat step", id: "read_step_repeat_button") { steps.perform(.repeatStep) }
      control("chevron.forward.2", "Next step", id: "read_step_next_button") { steps.perform(.next) }
    }
    return VStack(alignment: .leading, spacing: 8) {
      Text(steps.statusText ?? "")
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("read_steps_status")
      if isLargeText {
        VStack(spacing: 10) { buttons }
      } else {
        HStack(spacing: 10) { buttons }
      }
      Text("You can say next step, repeat step, or what step am I on.")
        .font(.rounded(.footnote, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func wideButton(_ icon: String, _ title: String, tone: Tone = .neutral, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(ChunkyButtonStyle(tone: tone, lipHeight: 5))
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
    .cameraQuickActions(status: onStatus)
  }

  private func control(_ icon: String, _ title: String, tone: Tone = .neutral, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      // Above the words at large text, so the words get the whole width and don't hyphenate.
      VStack(spacing: 4) {
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
