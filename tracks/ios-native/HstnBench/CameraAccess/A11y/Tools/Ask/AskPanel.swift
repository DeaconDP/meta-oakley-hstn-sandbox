/*
 * AskPanel - Ask about the text on the phone screen
 *
 * What text the questions are about, a field to type a question (for people who'd rather type),
 * the last answer in large print, and the follow-ups as buttons: More, Spell it, "No, the word I
 * said" (only after "Did you mean"), and Recap. The same things work by voice. Where answers come
 * from (the phone, or OpenAI for open questions when a key is set) and the WordNet credit are
 * shown at the bottom. Dynamic Type via the brand font, 60 pt targets, VoiceOver labels.
 */

import SwiftUI

struct AskPanel: View {
  let tool: AskTool

  @State private var typed = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(tool.sourceSummary ?? "Nothing has been read yet. You can still ask what a word means.")
        .font(.rounded(.subheadline, weight: .bold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("ask_source")

      questionField

      if let question = tool.lastQuestion {
        Text("You asked: \(question)")
          .font(.rounded(.body, weight: .medium))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("ask_question")
      }

      if tool.isAnswering {
        Text("Looking that up…")
          .font(.rounded(.title3, weight: .bold))
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("ask_working")
      } else if let answer = tool.lastAnswer {
        Text(answer)
          .font(.rounded(.title2, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier("ask_answer")
      }

      VStack(spacing: 10) {
        if tool.offersMore {
          Button { tool.more() } label: { Label("More", systemImage: "text.badge.plus") }
            .buttonStyle(ChunkyButtonStyle(tone: .blue))
            .accessibilityHint("Other meanings, mentions or matches.")
            .accessibilityIdentifier("ask_more_button")
        }
        if tool.offersNo {
          Button { tool.noTheWordISaid() } label: { Label("No, the word I said", systemImage: "arrow.uturn.backward") }
            .buttonStyle(.a11ySecondary)
            .accessibilityIdentifier("ask_no_button")
        }
        if tool.lastAnswer != nil {
          Button { tool.spellIt() } label: { Label("Spell it", systemImage: "character.cursor.ibeam") }
            .buttonStyle(.a11ySecondary)
            .accessibilityHint("Spells the last word asked about, letter by letter.")
            .accessibilityIdentifier("ask_spell_button")
        }
        Button { tool.recap() } label: { Label("Recap", systemImage: "arrow.counterclockwise") }
          .buttonStyle(.a11ySecondary)
          .accessibilityHint("Says the last few sentences that were read.")
          .accessibilityIdentifier("ask_recap_button")
      }

      Text("Say: what does a word mean, who is someone, what did it say about something, or recap.")
        .font(.rounded(.subheadline, weight: .medium))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(tool.answersOnline ? AskWording.privacyOnline : AskWording.privacyOnDevice)
        Text(AskWording.dictionaryCredit)
      }
      .font(.rounded(.footnote, weight: .medium))
      .foregroundStyle(Theme.inkSoft)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("ask_privacy")
    }
    .themeCard()
    .accessibilityElement(children: .contain)
  }

  private var questionField: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { field; askButton }
      VStack(alignment: .leading, spacing: 10) { field; askButton }
    }
  }

  private var field: some View {
    TextField("What does recondite mean?", text: $typed)
      .font(.rounded(.title3, weight: .bold))
      .foregroundStyle(Theme.ink)
      .submitLabel(.send)
      .focused($fieldFocused)
      .onSubmit(submit)
      .padding(.horizontal, 14)
      .frame(minHeight: 60)
      .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2)
      }
      .accessibilityLabel("Your question")
      .accessibilityHint("Type a question about what was read, then Ask.")
      .accessibilityIdentifier("ask_question_field")
  }

  private var askButton: some View {
    Button(action: submit) { Text("Ask") }
      .buttonStyle(.a11yPrimary)
      .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
      .accessibilityIdentifier("ask_button")
  }

  private func submit() {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    fieldFocused = false
    typed = ""
    tool.ask(text)
  }
}
