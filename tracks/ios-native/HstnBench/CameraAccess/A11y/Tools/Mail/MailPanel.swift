/*
 * MailPanel - the mail reader on the phone screen
 *
 * Voice does everything; the panel mirrors it for low-vision users, VoiceOver users and sighted
 * helpers: where the tool is, big buttons (What is this letter?, Read it all / Pause / Carry on,
 * Back a sentence, Next page, How much?, Who is it from?, When is it due?, Is it a scam?), what
 * was found (kind, from, for, date, about, amount, due, pages, scam signs) in large text, the
 * sentence being read, and the letter's text. Amounts that couldn't be read for sure are never
 * shown: the facts say so, and the text is Letter.safeText, so VoiceOver can't read a guessed
 * figure either. Brand font at Dynamic Type sizes, theme colours (dark mode and Increase
 * Contrast follow), buttons at least 60 pt, stacked one per row at accessibility sizes.
 * Accessibility identifiers start with "mail_".
 */

import SwiftUI

struct MailPanel: View {
  let tool: MailTool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast

  private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }
  private var isLooking: Bool { tool.phase == .looking }
  private var hasLetter: Bool { tool.letter != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(statusText)
        .font(.rounded(.title3, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("mail_status")

      if let notice = tool.notice {
        Text(notice)
          .font(.rounded(.title2, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("mail_notice")
      }

      Button {
        tool.perform(.newLetter)
      } label: {
        Label("What is this letter?", systemImage: "envelope.open")
          .frame(maxWidth: .infinity, minHeight: 60)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .yellow))
      .disabled(isLooking)
      .accessibilityLabel("What is this letter?")
      .accessibilityHint("Takes a picture of the letter and says who it's from and what it wants.")
      .accessibilityIdentifier("mail_summarise_button")

      controls

      if let letter = tool.letter {
        facts(letter)
        if let sentence = tool.currentSentence {
          section("Reading now", id: "mail_sentence") {
            Text(sentence)
              .font(.rounded(.title2, weight: .bold))
              .foregroundStyle(Theme.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        section("The letter", id: "mail_text") {
          Text(letter.safeText)
            .font(.rounded(.title3, weight: .regular))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var statusText: String {
    switch tool.phase {
    case .idle: "Mail reader. Hold up a letter."
    case .looking: "Looking at the letter…"
    case .ready: tool.letter?.isEnvelope == true ? "Envelope read" : "Letter read"
    case .reading: "Reading sentence \(tool.sentenceIndex + 1) of \(tool.sentences.count)"
    case .paused: "Paused at sentence \(tool.sentenceIndex + 1) of \(tool.sentences.count)"
    }
  }

  // MARK: Buttons

  private var readTitle: String {
    switch tool.phase {
    case .reading: "Pause"
    case .paused: "Carry on"
    default: "Read it all"
    }
  }

  private var rows: [[Control]] {
    let readIcon = tool.phase == .reading ? "pause.fill" : "play.fill"
    return [
      [
        Control(title: readTitle, icon: readIcon, id: "mail_read_all_button", enabled: !isLooking) { tool.toggleReading() },
        Control(title: "Back a sentence", icon: "backward.fill", id: "mail_back_button", enabled: hasLetter && !isLooking) {
          tool.perform(.back)
        },
      ],
      [
        Control(title: "How much?", icon: "sterlingsign.circle", id: "mail_how_much_button", enabled: hasLetter && !isLooking) {
          tool.perform(.howMuch)
        },
        Control(title: "When is it due?", icon: "calendar", id: "mail_due_button", enabled: hasLetter && !isLooking) {
          tool.perform(.whenDue)
        },
      ],
      [
        Control(title: "Who is it from?", icon: "person.fill", id: "mail_from_button", enabled: hasLetter && !isLooking) {
          tool.perform(.from)
        },
        Control(title: "Is it a scam?", icon: "exclamationmark.shield", id: "mail_scam_button", enabled: hasLetter && !isLooking) {
          tool.perform(.scam)
        },
      ],
      [
        Control(title: "Next page", icon: "doc.on.doc", id: "mail_next_page_button", enabled: hasLetter && !isLooking) {
          tool.perform(.nextPage)
        }
      ],
    ]
  }

  @ViewBuilder
  private var controls: some View {
    let allRows = self.rows
    if isLargeText {
      VStack(spacing: 10) { ForEach(allRows.flatMap { $0 }) { button($0) } }
    } else {
      VStack(spacing: 10) {
        ForEach(allRows.indices, id: \.self) { index in
          HStack(spacing: 10) { ForEach(allRows[index]) { button($0) } }
        }
      }
    }
  }

  private struct Control: Identifiable {
    let title: String
    let icon: String
    let id: String
    let enabled: Bool
    let action: @MainActor () -> Void
  }

  private func button(_ control: Control) -> some View {
    Button(action: control.action) {
      VStack(spacing: 4) {
        Image(systemName: control.icon)
          .font(.rounded(.title3, weight: .heavy))
          .accessibilityHidden(true)
        Text(control.title)
      }
      .frame(maxWidth: .infinity, minHeight: 60)
    }
    .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
    .disabled(!control.enabled)
    .accessibilityLabel(control.title)
    .accessibilityIdentifier(control.id)
  }

  // MARK: What was found

  private func facts(_ letter: Letter) -> some View {
    section("What I found", id: "mail_facts") {
      VStack(alignment: .leading, spacing: 10) {
        fact("Kind", letter.isEnvelope ? "An envelope" : LetterSpeech.kindPhrase(letter).capitalisedFirst, id: "mail_kind")
        fact("From", letter.sender ?? "Can't see", id: "mail_from")
        fact("For", letter.recipient ?? letter.salutation ?? "Can't see", id: "mail_for")
        if let date = letter.date { fact("Date", date.spoken(), id: "mail_date") }
        if let subject = letter.subject { fact("About", subject, id: "mail_about") }
        if let amount = amountText(letter.amount) { fact("Amount", amount, id: "mail_amount") }
        if let due = letter.due { fact("Due", due.sure ? due.spoken : "Can't read the date for sure", id: "mail_due") }
        if letter.pages.count > 1 { fact("Pages", "\(letter.pages.count)", id: "mail_pages") }
        if let scam = LetterSpeech.scamHint(letter) {
          Text(scam)
            .font(.rounded(.title3, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.speak, lineWidth: contrast == .increased ? 4 : 3)
            }
            .accessibilityLabel("Warning. \(scam)")
            .accessibilityIdentifier("mail_scam")
        }
      }
    }
  }

  private func amountText(_ amount: AmountDue) -> String? {
    switch amount {
    case .sure(let money, let minimum, let isTotal):
      (isTotal ? "Total " : "") + money.spoken() + (minimum.map { ", minimum \($0.spoken())" } ?? "")
    case .unsure: "Can't read it for sure. Hold the letter closer and ask how much."
    case .conflict: "Two different amounts. Hold the letter closer and ask how much."
    case .none: nil
    }
  }

  private func fact(_ label: String, _ value: String, id: String) -> some View {
    // One VoiceOver element per fact: "From, Northgate Energy".
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.inkSoft)
      Text(value)
        .font(.rounded(.title2, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label), \(value)")
    .accessibilityIdentifier(id)
  }

  private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.rounded(.headline, weight: .heavy))
        .foregroundStyle(Theme.inkSoft)
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .themeCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }
}
