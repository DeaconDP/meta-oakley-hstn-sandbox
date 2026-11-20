/*
 * RemindersPanel - Reminders on the phone screen
 *
 * The last thing said, in large print; a field to type a reminder (the same words as by voice);
 * what's coming up, each with Cancel; the daily reminders; the medicine log with an "I took ..."
 * button per name already logged; and, when notifications are off, how to turn them on. Brand
 * font with Dynamic Type, 60 pt targets, VoiceOver labels, theme colours.
 */

import SwiftUI

struct RemindersPanel: View {
  let tool: RemindersTool

  @State private var typed = ""
  @FocusState private var fieldFocused: Bool
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let line = tool.lastLine {
        Text(line)
          .font(.rounded(.title3, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("reminders_last_line")
      }

      if tool.store?.notificationsAllowed == false { notificationsOff }

      typeField

      section("Coming up", id: "reminders_coming_up")
      comingUp

      if let daily = tool.store?.dailyByNext, !daily.isEmpty {
        section("Every day", id: "reminders_daily")
        ForEach(daily) { reminder in
          row(
            text: RemindersWording.yours(reminder.text),
            detail: "Every day at \(ReminderFormat.clock(hour: reminder.hour, minute: reminder.minute))",
            cancelLabel: "Cancel daily reminder: \(RemindersWording.yours(reminder.text))"
          ) { tool.cancelDaily(id: reminder.id) }
        }
      }

      section("Medicine log", id: "reminders_medicine_log")
      medicineLog

      Text("You can say: remind me in 20 minutes to, remind me at 6 to, what's due this week, cancel the bins reminder, snooze, done, I took my evening pill, or what was I doing.")
        .font(.rounded(.subheadline, weight: .medium))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("reminders_say_line")

      Text(RemindersWording.privacy)
        .font(.rounded(.footnote, weight: .medium))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("reminders_privacy")
    }
    .themeCard()
    .accessibilityElement(children: .contain)
  }

  // MARK: Parts

  private func section(_ title: String, id: String) -> some View {
    Text(title)
      .font(.rounded(.title3, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier(id)
  }

  @ViewBuilder
  private var comingUp: some View {
    let upcoming = tool.store?.upcoming(before: .distantFuture) ?? []
    if upcoming.isEmpty {
      Text("Nothing coming up.")
        .font(.rounded(.body, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .accessibilityIdentifier("reminders_none")
    } else {
      ForEach(upcoming) { request in
        row(text: tool.displayText(request), detail: detail(request), cancelLabel: "Cancel reminder: \(tool.displayText(request))") {
          tool.cancelReminder(id: request.id)
        }
      }
    }
  }

  private func detail(_ request: ReminderRequest) -> String {
    guard let store = tool.store else { return "" }
    let format = store.clock.format
    var parts = ["Reminder at \(format.when(request.fireDate))"]
    if let due = request.dueDate { parts.append("Due \(format.day(due))") }
    if request.source != ToolID.reminders.rawValue, let from = ToolID(rawValue: request.source) {
      parts.append("From \(from.title)")
    }
    return parts.joined(separator: ". ")
  }

  private func row(text: String, detail: String, cancelLabel: String, cancel: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(text)
          .font(.rounded(.title3, weight: .bold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(detail)
          .font(.rounded(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Button(action: cancel) { Label("Cancel", systemImage: "xmark") }
        .buttonStyle(.a11ySecondary)
        .accessibilityLabel(cancelLabel)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var medicineLog: some View {
    let entries = Array((tool.store?.medicineLog ?? []).suffix(5).reversed())
    if entries.isEmpty {
      Text("Nothing logged yet. Say I took, and the medicine's name.")
        .font(.rounded(.body, weight: .semibold))
        .foregroundStyle(Theme.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
    } else if let store = tool.store {
      ForEach(entries) { entry in
        Text("\(entry.name): \(RemindersTool.past(entry.takenAt, store.clock.format))")
          .font(.rounded(.body, weight: .semibold))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    ForEach(Array((tool.store?.knownMedicines ?? []).prefix(4)), id: \.self) { name in
      Button { tool.logTaken(name) } label: { Label("I took \(name)", systemImage: "checkmark.circle") }
        .buttonStyle(.a11ySecondary)
        .accessibilityHint("Adds it to your log with the time now.")
    }
    Text(RemindersWording.logNote)
      .font(.rounded(.footnote, weight: .medium))
      .foregroundStyle(Theme.inkSoft)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("reminders_log_note")
  }

  private var notificationsOff: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Notifications are off, so reminders can't go off. Turn them on in Settings, then Apps, SpeakUp, Notifications.")
        .font(.rounded(.body, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
      } label: {
        Label("Open notification settings", systemImage: "gearshape")
      }
      .buttonStyle(.a11yPrimary)
      .accessibilityIdentifier("reminders_open_settings")
    }
    .accessibilityElement(children: .contain)
  }

  private var typeField: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { field; addButton }
      VStack(alignment: .leading, spacing: 10) { field; addButton }
    }
  }

  private var field: some View {
    TextField("Remind me at 6 to take the bins out", text: $typed)
      .font(.rounded(.title3, weight: .bold))
      .foregroundStyle(Theme.ink)
      .submitLabel(.done)
      .focused($fieldFocused)
      .onSubmit(submit)
      .padding(.horizontal, 14)
      .frame(minHeight: 60)
      .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2)
      }
      .accessibilityLabel("Type a reminder")
      .accessibilityHint("For example, remind me at 6 to take the bins out, or I took my evening pill. Then Add.")
      .accessibilityIdentifier("reminders_field")
  }

  private var addButton: some View {
    Button(action: submit) { Text("Add") }
      .buttonStyle(.a11yPrimary)
      .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
      .accessibilityIdentifier("reminders_add_button")
  }

  private func submit() {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    fieldFocused = false
    typed = ""
    tool.submit(text)
  }
}
