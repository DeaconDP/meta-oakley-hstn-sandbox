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
 *
 * "Deal with this letter": after a letter with a deadline, the reminder offer as buttons; Explain
 * this letter / Explain with AI and the explanation (marked as AI when it is); My letters, which
 * shows the letters log (LettersPanel) in place of the letter; and a letter opened from the log,
 * with a way back to the one just read.
 */

import SwiftUI

struct MailPanel: View {
  let tool: MailTool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast

  private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }
  private var isLooking: Bool { tool.phase == .looking }
  private var hasLetter: Bool { tool.letter != nil || tool.savedFocus != nil }

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

      if tool.pendingQuestion == .reminder, !tool.reminderOffers.isEmpty {
        reminderOffer
      }

      dealButtons

      if let explanation = tool.explanation {
        section(tool.explanationIsAI ? "AI explanation" : "Explanation", id: "mail_explanation") {
          VStack(alignment: .leading, spacing: 6) {
            Text(explanation)
              .font(.rounded(.title3, weight: .bold))
              .foregroundStyle(Theme.ink)
              .fixedSize(horizontal: false, vertical: true)
            Text(tool.explanationIsAI ? "Written by AI from the letter's text. Check anything important." : "From rules on your phone.")
              .font(.rounded(.body, weight: .regular))
              .foregroundStyle(Theme.inkSoft)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if tool.showingLetters {
        LettersPanel(tool: tool)
      } else if let saved = tool.savedFocus {
        savedLetter(saved)
      } else if let letter = tool.letter {
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
    if tool.isExplainingOnline { return "Asking online for an AI explanation…" }
    return switch tool.phase {
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

  // MARK: Deal with this letter

  private var reminderOffer: some View {
    section("Reminder", id: "mail_reminder_offer") {
      VStack(alignment: .leading, spacing: 10) {
        Text(tool.activeRecord?.deadlineKind == .appointment ? "Do you want a reminder before the appointment?" : "Do you want a reminder before the deadline?")
          .font(.rounded(.title3, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(tool.reminderOffers.enumerated()), id: \.offset) { _, choice in
          let title = LetterReminderPlanner.phrase(choice).capitalisedFirst
          Button {
            tool.remind(choice)
          } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 60)
          }
          .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
          .accessibilityLabel(title)
          .accessibilityIdentifier("mail_remind_\(title.lowercased().replacingOccurrences(of: " ", with: "_"))")
        }
        Button {
          tool.perform(letter: .no)
        } label: {
          Text("No reminder").frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
        .accessibilityIdentifier("mail_remind_no_button")
      }
    }
  }

  @ViewBuilder
  private var dealButtons: some View {
    let hasRecord = tool.activeRecord != nil && !isLooking
    let explain = Control(title: "Explain this letter", icon: "text.bubble", id: "mail_explain_button", enabled: hasRecord) {
      tool.explain(.onDevice)
    }
    let ai = Control(title: "Explain with AI", icon: "sparkles", id: "mail_explain_ai_button", enabled: hasRecord && !tool.isExplainingOnline) {
      tool.explain(.online)
    }
    let log = Control(title: tool.showingLetters ? "Hide my letters" : "My letters", icon: "tray.full", id: "mail_letters_button", enabled: true) {
      if tool.showingLetters {
        EarconPlayer.shared.play(.ready)
        tool.showingLetters = false
      } else {
        tool.listLetters()
      }
    }
    if isLargeText {
      VStack(spacing: 10) { ForEach([explain, ai, log]) { button($0) } }
    } else {
      VStack(spacing: 10) {
        HStack(spacing: 10) { ForEach([explain, ai]) { button($0) } }
        button(log)
      }
    }
  }

  private func savedLetter(_ saved: LetterRecord) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      section("Saved letter", id: "mail_saved") {
        VStack(alignment: .leading, spacing: 10) {
          Text(saved.title)
            .font(.rounded(.title2, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text(saved.summary)
            .font(.rounded(.title3, weight: .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
          if saved.reminderAt != nil {
            Text("Reminder set")
              .font(.rounded(.headline, weight: .heavy))
              .foregroundStyle(Theme.inkSoft)
          }
          Button {
            EarconPlayer.shared.play(.ready)
            tool.closeSaved()
          } label: {
            Text(tool.letter == nil ? "Close this letter" : "Back to the letter I just read").frame(maxWidth: .infinity, minHeight: 60)
          }
          .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
          .accessibilityIdentifier("mail_saved_close_button")
        }
      }
      if let sentence = tool.currentSentence {
        section("Reading now", id: "mail_sentence") {
          Text(sentence)
            .font(.rounded(.title2, weight: .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      section("The letter", id: "mail_saved_text") {
        Text(saved.text)
          .font(.rounded(.title3, weight: .regular))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
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
