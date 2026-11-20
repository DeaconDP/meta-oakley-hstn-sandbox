/*
 * MakeItYourOwnView - the screen for every Make it your own setting (design rule 10)
 *
 * Mirrors what can be said: profiles, undo, keep, lock and "what's my setup"; speech (preset,
 * speed, pitch, pauses, answers and per-tool overrides, voice); tips; sounds on or off;
 * descriptions; share codes; resets. Each change goes through the same area methods as voice, so
 * it is recorded for undo and spoken aloud with its new value. Screen changes are kept at once.
 *
 * Opened from the settings menu (MakeItYourOwnEntry). Large text wraps; every control has a
 * VoiceOver label and a 60 pt target; colours come from Theme (WCAG 2.2 AA, checked in ThemeTests).
 */

import SwiftUI

/// The settings menu's way in.
struct MakeItYourOwnEntry: View {
  @State private var isOpen = false

  var body: some View {
    CustomButton(title: "Make it your own", style: .secondary, isDisabled: false) { isOpen = true }
      .accessibilityHint("Speech speed, answers, voice, tips, profiles and share codes.")
      .accessibilityIdentifier("make_it_your_own_button")
      .sheet(isPresented: $isOpen) {
        NavigationStack {
          MakeItYourOwnView()
            .navigationTitle("Make it your own")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isOpen = false }
                  .accessibilityIdentifier("make_it_your_own_done")
              }
            }
        }
      }
  }
}

struct MakeItYourOwnView: View {
  @Bindable private var preferences = A11yPreferences.shared
  private var store: SettingsStore { SettingsStore.shared }
  private var speech: SpeechSettings? { MakeItYourOwn.speech }
  private var tips: TipsSettings? { MakeItYourOwn.tips }
  private var descriptions: DescriptionSettings? { MakeItYourOwn.descriptions }

  @State private var setupText: String?
  @State private var newProfileName = ""
  @State private var shareCode: String?
  @State private var pastedCode = ""
  @State private var voices: [VoiceDescriptor] = []
  @State private var confirmResetEverything = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Change anything here or by voice. Say what's my setup to hear what you've changed.")
          .settingsBody()
        setupSection
        if let speech { speechSection(speech) }
        if let tips { tipsSection(tips) }
        soundsSection
        if let descriptions { descriptionsSection(descriptions) }
        shareSection
        resetSection
      }
      .padding(16)
    }
    .background(Theme.page)
    .task { await loadVoices() }
  }

  private func say(_ line: String) {
    Announcer.shared.say(line, kind: .reply)
  }

  // MARK: Your setup

  private var setupSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Your setup")
      PickerRow(title: "Profile", selection: Binding(get: { store.activeProfile }, set: { say(store.switchProfile(to: $0)) })) {
        ForEach(store.profileNames, id: \.self) { Text($0).tag($0) }
      }
      .disabled(store.isLocked)
      .accessibilityIdentifier("profile_picker")
      CustomButton(title: "What's my setup?", style: .primary, isDisabled: false) {
        let line = store.whatsMySetup()
        setupText = line
        say(line)
      }
      .accessibilityIdentifier("whats_my_setup_button")
      if let setupText {
        Text(setupText).settingsBody().accessibilityIdentifier("setup_summary_label")
      }
      CustomButton(title: "Undo the last change", style: .secondary, isDisabled: store.undoStack.isEmpty || store.isLocked) {
        say(store.undo())
      }
      .accessibilityIdentifier("settings_undo_button")
      if !store.unkeptAreas.isEmpty {
        CustomButton(title: "Keep the changes made by voice", style: .secondary, isDisabled: store.isLocked) { say(store.keep()) }
          .accessibilityHint("Voice changes last until SpeakUp closes unless you keep them.")
          .accessibilityIdentifier("settings_keep_button")
      }
      SettingsToggle(
        title: "Lock settings", hint: "Stops accidental changes by voice or touch until you unlock.",
        isOn: Binding(get: { store.isLocked }, set: { say($0 ? store.lock() : store.unlock()) }), id: "settings_lock_toggle")
      TextField("New profile name", text: $newProfileName)
        .settingsField()
        .accessibilityLabel("New profile name")
        .accessibilityIdentifier("new_profile_field")
      CustomButton(
        title: "Save as a new profile", style: .secondary,
        isDisabled: newProfileName.trimmingCharacters(in: .whitespaces).isEmpty || store.isLocked
      ) {
        say(store.saveProfile(named: newProfileName))
        newProfileName = ""
      }
      .accessibilityHint("Saves everything as it is now under that name.")
      .accessibilityIdentifier("save_profile_button")
    }
    .themeCard()
  }

  // MARK: Speech

  private func speechSection(_ speech: SpeechSettings) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Speech")
      Text("Style: \(speech.presetDescription())").settingsBody().accessibilityIdentifier("speech_style_label")
      PickerRow(
        title: "Preset",
        selection: Binding(get: { speech.currentPreset?.rawValue ?? "" }, set: { SpeechPreset(rawValue: $0).map { say(speech.applyPreset($0)) } })
      ) {
        if speech.currentPreset == nil { Text("Your own").tag("") }
        ForEach(SpeechPreset.allCases) { Text($0.title).tag($0.rawValue) }
      }
      .accessibilityIdentifier("speech_preset_picker")
      Stepper {
        Text("Speed: \(SettingsWords.rate(preferences.speechRateMultiplier))").settingsBody()
      } onIncrement: {
        say(speech.stepRate(faster: true))
      } onDecrement: {
        say(speech.stepRate(faster: false))
      }
      .frame(minHeight: 60)
      .accessibilityIdentifier("speech_rate_stepper")
      Stepper {
        Text("Pitch: \(SettingsWords.decimal(Double(preferences.speechPitch)))").settingsBody()
      } onIncrement: {
        say(speech.stepPitch(higher: true))
      } onDecrement: {
        say(speech.stepPitch(higher: false))
      }
      .frame(minHeight: 60)
      .accessibilityIdentifier("speech_pitch_stepper")
      Stepper {
        Text(preferences.sentencePause < 0.001 ? "Pause between sentences: none" : "Pause between sentences: \(SettingsWords.decimal(preferences.sentencePause)) seconds")
          .settingsBody()
      } onIncrement: {
        say(speech.stepPause(longer: true))
      } onDecrement: {
        say(speech.stepPause(longer: false))
      }
      .frame(minHeight: 60)
      .accessibilityIdentifier("speech_pause_stepper")
      PickerRow(title: "Answers", selection: Binding(get: { preferences.verbosity }, set: { say(speech.setVerbosity($0)) })) {
        ForEach(Verbosity.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("verbosity_picker")
      Text("Answers for each tool").settingsBody(weight: .heavy)
      ForEach(ToolID.allCases) { tool in
        PickerRow(
          title: tool.title,
          selection: Binding(
            get: { preferences.toolVerbosity[tool.rawValue]?.rawValue ?? "" },
            set: { value in
              say(Verbosity(rawValue: value).map { speech.setVerbosity($0, tool: tool) } ?? speech.clearToolVerbosity(tool))
            })
        ) {
          Text("Same as main (\(preferences.verbosity.title))").tag("")
          ForEach(Verbosity.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .accessibilityIdentifier("tool_verbosity_\(tool.rawValue)")
      }
      PickerRow(title: "Voice", selection: Binding(get: { preferences.appVoiceIdentifier ?? "" }, set: { say(speech.setVoice($0.isEmpty ? nil : $0)) })) {
        Text("SpeakUp's choice").tag("")
        ForEach(voices, id: \.identifier) { voice in
          Text("\(VoiceSelection.baseName(voice)), \(VoiceSelection.accentName(language: voice.language))").tag(voice.identifier)
        }
      }
      .accessibilityIdentifier("voice_picker")
      CustomButton(title: "Hear this voice", style: .secondary, isDisabled: false) {
        say("This is how I sound. \(SettingsWords.sentence(SettingsWords.rate(preferences.speechRateMultiplier))).")
      }
      .accessibilityIdentifier("voice_sample_button")
      SettingsToggle(
        title: "Use VoiceOver's voice when VoiceOver is on", hint: "Off keeps SpeakUp's own voice and speed.",
        isOn: Binding(
          get: { preferences.useVoiceOverVoice },
          set: { say(speech.setVoiceOverVoice($0, voiceOverRunning: UIAccessibility.isVoiceOverRunning)) }),
        id: "speech_voiceover_voice_toggle")
    }
    .disabled(store.isLocked)
    .themeCard()
  }

  private func loadVoices() async {
    guard let trial = MakeItYourOwn.voiceTrial else { return }
    let installed = await Task.detached(priority: .utility) { AppVoice.installedVoices() }.value
    voices = trial.candidateList(from: installed)
  }

  // MARK: Tips and sounds

  private func tipsSection(_ tips: TipsSettings) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Spoken tips")
      PickerRow(title: "Tips", selection: Binding(get: { tips.pacing }, set: { say(tips.setPacing($0)) })) {
        ForEach(TipPacing.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("tips_pacing_picker")
      Text("Tips say what you can say next after a quiet spell, in hands-free.").settingsBody()
    }
    .disabled(store.isLocked)
    .themeCard()
  }

  private var soundsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Sounds")
      SettingsToggle(
        title: "Sounds (earcons)", hint: "Short tones before lines and for actions. Everything is still spoken without them.",
        isOn: Binding(
          get: { preferences.earconsEnabled },
          set: {
            preferences.earconsEnabled = $0
            say($0 ? "Sounds on." : "Sounds off. Everything is still spoken.")
          }),
        id: "earcons_toggle")
    }
    .disabled(store.isLocked)
    .themeCard()
  }

  // MARK: Descriptions

  private func descriptionsSection(_ descriptions: DescriptionSettings) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Descriptions")
      Text("For Look closer, which isn't on iPhone yet. Your choices are saved for when it is.").settingsBody()
      PickerRow(title: "Detail", selection: Binding(get: { descriptions.detail }, set: { say(descriptions.setDetail($0)) })) {
        ForEach(DescriptionDetail.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("description_detail_picker")
      SettingsToggle(
        title: "Read any text first", hint: nil,
        isOn: Binding(get: { descriptions.readTextFirst }, set: { say(descriptions.setReadTextFirst($0)) }), id: "description_text_first_toggle")
      SettingsToggle(
        title: "Mention colours", hint: nil,
        isOn: Binding(get: { descriptions.mentionColours }, set: { say(descriptions.setMentionColours($0)) }), id: "description_colours_toggle")
      PickerRow(title: "Directions", selection: Binding(get: { descriptions.directions }, set: { say(descriptions.setDirections($0)) })) {
        ForEach(DescriptionDirections.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("description_directions_picker")
    }
    .disabled(store.isLocked)
    .themeCard()
  }

  // MARK: Share

  private var shareSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Share your setup")
      Text("A code holds all your settings and profiles. Paste it into SpeakUp on another phone, or give it to a helper.")
        .settingsBody()
      CustomButton(title: "Make a share code", style: .secondary, isDisabled: false) {
        shareCode = store.exportCode()
        say("Share code ready.")
      }
      .accessibilityIdentifier("make_share_code_button")
      if let shareCode {
        Text(shareCode)
          .font(.system(.footnote, design: .monospaced))
          .foregroundStyle(Theme.ink)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Share code, \(shareCode.count) characters")
          .accessibilityIdentifier("share_code_label")
        ShareLink(item: shareCode) {
          Text("Share the code").frame(maxWidth: .infinity)
        }
        .buttonStyle(ChunkyButtonStyle(tone: .neutral))
        .accessibilityIdentifier("share_code_button")
        CustomButton(title: "Copy the code", style: .secondary, isDisabled: false) {
          UIPasteboard.general.string = shareCode
          say("Code copied.")
        }
        .accessibilityIdentifier("copy_share_code_button")
      }
      TextField("Paste a setup code", text: $pastedCode, axis: .vertical)
        .settingsField()
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityLabel("Setup code to import")
        .accessibilityIdentifier("import_code_field")
      CustomButton(
        title: "Use this setup", style: .primary,
        isDisabled: pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLocked
      ) {
        say(store.importSetup(pastedCode))
        pastedCode = ""
      }
      .accessibilityHint("Replaces your settings. Say undo or use Undo to put yours back.")
      .accessibilityIdentifier("import_code_button")
      PasteButton(payloadType: String.self) { strings in
        guard let text = strings.first else { return }
        Task { @MainActor in say(store.importSetup(text)) }
      }
      .disabled(store.isLocked)
      .accessibilityIdentifier("paste_setup_button")
    }
    .themeCard()
  }

  // MARK: Reset

  private var resetSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Start again")
      ForEach(store.areas().map { (id: type(of: $0).areaID, name: $0.spokenName) }, id: \.id) { area in
        CustomButton(title: "Reset \(area.name)", style: .secondary, isDisabled: store.isLocked) {
          say(store.reset(areaID: area.id))
        }
        .accessibilityHint("Back to the defaults for \(area.name) only. You can undo it.")
        .accessibilityIdentifier("reset_\(area.id)_button")
      }
      CustomButton(title: "Reset everything", style: .destructive, isDisabled: store.isLocked) { confirmResetEverything = true }
        .accessibilityHint("Every setting back to the defaults. Profiles are kept, and you can undo it.")
        .accessibilityIdentifier("reset_everything_button")
        .confirmationDialog("Reset everything?", isPresented: $confirmResetEverything, titleVisibility: .visible) {
          Button("Reset everything", role: .destructive) { say(store.resetEverything()) }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Every setting goes back to the defaults. You can still undo it.")
        }
    }
    .themeCard()
  }
}

// MARK: - Pieces

private struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.rounded(.title3, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A title above a menu picker, so long names and large text wrap instead of truncating.
private struct PickerRow<Value: Hashable, Options: View>: View {
  let title: String
  let selection: Binding<Value>
  @ViewBuilder let options: () -> Options

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).settingsBody(weight: .bold)
        .accessibilityHidden(true)
      Picker(title, selection: selection) { options() }
        .pickerStyle(.menu)
        .tint(Theme.ink)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.horizontal, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2) }
    }
  }
}

private struct SettingsToggle: View {
  let title: String
  let hint: String?
  let isOn: Binding<Bool>
  let id: String

  var body: some View {
    Toggle(isOn: isOn) {
      Text(title).settingsBody(weight: .bold)
    }
    .frame(minHeight: 60)
    .accessibilityHint(hint ?? "")
    .accessibilityIdentifier(id)
  }
}

extension Text {
  fileprivate func settingsBody(weight: Font.Weight = .medium) -> some View {
    self
      .font(.rounded(.body, weight: weight))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension View {
  fileprivate func settingsField() -> some View {
    self
      .font(.rounded(.body, weight: .medium))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(minHeight: 60)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2) }
  }
}
