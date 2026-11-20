/*
 * LettersPanel - "My letters" inside the mail reader's panel
 *
 * The letters kept on the phone, newest first: one big row per letter (title, saved date, amount
 * and due date as the log has them), each opening the letter in the mail reader, with Delete.
 * Below: Export as text and Export as CSV (ShareLink, so nothing leaves the phone until the user
 * picks where it goes), and Forget all letters, which asks first, by voice and on screen.
 * Large text in the brand font, theme colours, buttons at least 60 pt, one VoiceOver element per
 * letter. Identifiers start with "letters_".
 */

import SwiftUI

struct LettersPanel: View {
  let tool: MailTool

  private var store: LettersStore { tool.letters }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("My letters")
          .font(.rounded(.title2, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("letters_title")
        Spacer()
        Button("Done") {
          EarconPlayer.shared.play(.ready)
          tool.showingLetters = false
        }
        .font(.rounded(.headline, weight: .heavy))
        .frame(minWidth: 60, minHeight: 60)
        .accessibilityLabel("Close my letters")
        .accessibilityIdentifier("letters_done_button")
      }

      Text("Kept on this phone only. The photo is never kept.")
        .font(.rounded(.body, weight: .regular))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)

      if store.letters.isEmpty {
        Text("No saved letters yet. Letters you read with the mail reader are kept here.")
          .font(.rounded(.title3, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("letters_empty")
      } else {
        ForEach(store.letters) { record in
          row(record)
        }
        exportButtons
        forgetAll
      }
    }
    .themeCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("letters_panel")
  }

  private func detail(_ record: LetterRecord) -> String {
    var parts = ["Saved \(LetterDay(record.savedAt, calendar: tool.calendar).spoken)"]
    let amount = LettersExport.amountText(record)
    if !amount.isEmpty { parts.append("Amount \(amount)") }
    let due = LettersExport.dueText(record)
    if !due.isEmpty { parts.append(due.capitalisedFirst) }
    if record.reminderAt != nil { parts.append("Reminder set") }
    if !record.signs.isEmpty { parts.append("Has scam signs") }
    return parts.joined(separator: ". ")
  }

  private func row(_ record: LetterRecord) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        tool.open(record)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(record.title)
            .font(.rounded(.title3, weight: .heavy))
          Text(detail(record))
            .font(.rounded(.body, weight: .regular))
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .multilineTextAlignment(.leading)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(record.title). \(detail(record))")
      .accessibilityHint("Opens the letter.")
      .accessibilityIdentifier("letters_row_\(record.id)")

      Button(role: .destructive) {
        tool.delete(record)
      } label: {
        Label("Delete", systemImage: "trash")
          .frame(maxWidth: .infinity, minHeight: 60)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .accessibilityLabel("Delete \(record.title)")
      .accessibilityIdentifier("letters_delete_\(record.id)")
    }
  }

  private var exportButtons: some View {
    VStack(spacing: 10) {
      ShareLink(item: LettersExportFile(records: store.letters, format: .text), preview: SharePreview("SpeakUp letters")) {
        Label("Export as text", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity, minHeight: 60)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .accessibilityHint("Shares your saved letters as plain text. You choose where they go.")
      .accessibilityIdentifier("letters_export_text_button")

      ShareLink(item: LettersExportFile(records: store.letters, format: .csv), preview: SharePreview("SpeakUp letters")) {
        Label("Export as CSV", systemImage: "tablecells")
          .frame(maxWidth: .infinity, minHeight: 60)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .accessibilityHint("Shares your saved letters as a spreadsheet file. You choose where they go.")
      .accessibilityIdentifier("letters_export_csv_button")
    }
  }

  @ViewBuilder
  private var forgetAll: some View {
    if tool.pendingQuestion == .forgetAll {
      VStack(alignment: .leading, spacing: 10) {
        Text("Forget all letters? This can't be undone.")
          .font(.rounded(.title3, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          tool.forgetAllConfirmed()
        } label: {
          Text("Yes, forget them").frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
        .accessibilityIdentifier("letters_forget_yes_button")
        Button {
          tool.keepLetters()
        } label: {
          Text("No, keep them").frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(ChunkyButtonStyle(tone: .yellow))
        .accessibilityIdentifier("letters_forget_no_button")
      }
    } else {
      Button(role: .destructive) {
        tool.askForgetAll()
      } label: {
        Label("Forget all letters", systemImage: "trash.slash")
          .frame(maxWidth: .infinity, minHeight: 60)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .accessibilityHint("Asks first, then deletes every saved letter from this phone.")
      .accessibilityIdentifier("letters_forget_all_button")
    }
  }
}
