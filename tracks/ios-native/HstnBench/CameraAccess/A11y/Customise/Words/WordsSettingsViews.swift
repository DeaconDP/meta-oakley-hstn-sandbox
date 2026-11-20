/*
 * WordsSettingsViews - "Your words" on the settings screen: the tools menu (order, hide, show),
 * what you call the app, your own words, and your macros
 *
 * Every button does what the voice phrase does, through WordsArea, and speaks the same line, so a
 * helper's tap is heard by the user. Styled from A11y/Theme; each row is one VoiceOver element
 * with its buttons as actions as well as visible buttons.
 */

import SwiftUI

struct WordsSettingsSection: View {
  private var area: WordsArea { WordsArea.shared }
  @State private var newName = ""
  @State private var newTarget = WordsTargets.all.first ?? ""
  @State private var newAddressWord = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CustomiseHeader(title: "Your words", id: "words_header")

      CustomiseSubheader(title: "Tools menu")
      ForEach(Array(area.orderedTools.enumerated()), id: \.element) { index, tool in
        toolRow(tool, index: index)
      }
      CustomButton(title: "Show all tools", style: .secondary, isDisabled: area.orderedTools.allSatisfy { !area.isHidden($0) }) {
        speak(area.showAll())
      }
      .accessibilityIdentifier("words_show_all_tools")

      CustomiseSubheader(title: "What you call me")
      CustomiseNote(text: "Say this before a command while I'm talking. Now: \(area.addressWord).")
      TextField("A new name, like Robin", text: $newAddressWord)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .accessibilityIdentifier("words_address_field")
      CustomButton(title: "Use this name", style: .secondary, isDisabled: newAddressWord.trimmingCharacters(in: .whitespaces).isEmpty) {
        speak(area.setAddressWord(newAddressWord))
        newAddressWord = ""
      }
      .accessibilityIdentifier("words_address_button")

      CustomiseSubheader(title: "Your own words")
      if area.aliases.isEmpty {
        CustomiseNote(text: "Say: when I say post, open mail reader. Or add one here.")
      }
      ForEach(area.aliases, id: \.self) { alias in
        wordRow(title: alias.name, detail: "means \(alias.phrase)", name: alias.name)
      }
      TextField("Your word, like post", text: $newName)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .accessibilityIdentifier("words_new_name_field")
      Picker("It means", selection: $newTarget) {
        ForEach(WordsTargets.all, id: \.self) { Text($0).tag($0) }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("words_new_target_picker")
      CustomButton(title: "Add this word", style: .secondary, isDisabled: newName.trimmingCharacters(in: .whitespaces).isEmpty) {
        speak(area.addAlias(name: newName, phrase: newTarget))
        newName = ""
      }
      .accessibilityIdentifier("words_add_button")

      CustomiseSubheader(title: "Your macros")
      CustomiseNote(
        text: area.macros.isEmpty
          ? "Make one by voice: say when I say morning post, open mail reader and read it all."
          : "Run one by saying its name, from a glasses button, or with the Run my macro shortcut.")
      ForEach(area.macros, id: \.self) { macro in
        wordRow(title: macro.name, detail: "will \(macro.spokenSteps)", name: macro.name, runnable: true)
      }
    }
  }

  private func toolRow(_ tool: ToolID, index: Int) -> some View {
    let hidden = area.isHidden(tool)
    let count = area.orderedTools.count
    return VStack(alignment: .leading, spacing: 6) {
      Text("\(index + 1). \(tool.title)\(hidden ? ", hidden" : "")")
        .font(.rounded(.subheadline, weight: .bold))
        .foregroundStyle(hidden ? Theme.inkSoft : Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        CustomButton(title: "Up", style: .secondary, isDisabled: index == 0) { speak(area.move(tool, by: -1)) }
          .accessibilityLabel("Move \(tool.title) up")
        CustomButton(title: "Down", style: .secondary, isDisabled: index == count - 1) { speak(area.move(tool, by: 1)) }
          .accessibilityLabel("Move \(tool.title) down")
        CustomButton(title: hidden ? "Show" : "Hide", style: .secondary, isDisabled: false) {
          speak(hidden ? area.show([tool]) : area.hide([tool]))
        }
        .accessibilityLabel("\(hidden ? "Show" : "Hide") \(tool.title)")
      }
    }
    .accessibilityIdentifier("words_tool_row_\(tool.rawValue)")
  }

  private func wordRow(title: String, detail: String, name: String, runnable: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(title): \(detail)")
        .font(.rounded(.subheadline, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if runnable {
          CustomButton(title: "Run", style: .secondary, isDisabled: false) { WordsEngine.shared.runMacro(named: name) }
            .accessibilityLabel("Run \(name)")
        }
        CustomButton(title: "Forget", style: .destructive, isDisabled: false) { speak(area.forget(name)) }
          .accessibilityLabel("Forget \(name)")
      }
    }
  }

  private func speak(_ line: String) {
    if !line.isEmpty { Announcer.shared.say(line, kind: .reply) }
  }
}

/// What a word made on screen can stand for: every command's phrase and every tool.
enum WordsTargets {
  static let all: [String] = {
    var seen = Set<String>()
    let tools = ToolID.allCases.map { "open \($0.title.lowercased())" }
    let commands = VoiceCommand.allCases.filter { $0.tool == nil }.map(\.phrase)
    return (tools + commands).filter { seen.insert($0).inserted }
  }()
}

// MARK: - Shared pieces for the customise sections

struct CustomiseHeader: View {
  let title: String
  let id: String

  var body: some View {
    Text(title)
      .font(.rounded(.title3, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier(id)
      .padding(.top, 8)
  }
}

struct CustomiseSubheader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.rounded(.headline, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .accessibilityAddTraits(.isHeader)
  }
}

struct CustomiseNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.rounded(.subheadline, weight: .semibold))
      .foregroundStyle(Theme.inkSoft)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
