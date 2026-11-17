/*
 * ReadingSettingsRows - the "Reading" part of the camera screen's settings menu
 *
 * Which voice reads (the natural OpenAI voice or the phone's), a field to paste an OpenAI key
 * (kept in the Keychain, never shown again once saved), Remove for a pasted key, and "Use natural
 * voice" to force on-phone reading even with a key. Every change is also spoken, like the voice
 * settings above it, so it is heard by someone using the app by voice without VoiceOver.
 */

import SwiftUI

struct ReadingSettingsRows: View {
  private var cloud: CloudReading { CloudReading.shared }
  @Bindable private var preferences = A11yPreferences.shared
  @State private var draftKey = ""
  @FocusState private var isKeyFieldFocused: Bool

  private var trimmedDraft: String { draftKey.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var statusText: String {
    if cloud.isEnabled { return "Reading voice: Natural voice (OpenAI)" }
    if !cloud.hasKey { return "Reading voice: On-phone voice. Add an OpenAI key for the natural voice." }
    return "Reading voice: On-phone voice"
  }

  var body: some View {
    Text("Reading")
      .font(.rounded(.headline, weight: .heavy))
      .foregroundStyle(Theme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
      .accessibilityAddTraits(.isHeader)
    Text(statusText)
      .font(.rounded(.subheadline, weight: .bold))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("reading_voice_status_label")
    Toggle(isOn: $preferences.useNaturalVoice) {
      Text("Use natural voice")
        .font(.rounded(.body, weight: .bold))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(minHeight: 60)
    .accessibilityHint("Reads pages with OpenAI's voice when a key is set. Off keeps reading on the phone.")
    .accessibilityIdentifier("natural_voice_toggle")
    .onChange(of: preferences.useNaturalVoice) { _, isOn in
      Announcer.shared.say(isOn ? SpokenMessage.readNaturalVoiceOn : SpokenMessage.readNaturalVoiceOff)
    }
    SecureField("Paste an OpenAI API key", text: $draftKey)
      .font(.rounded(.body, weight: .medium))
      .foregroundStyle(Theme.ink)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.done)
      .focused($isKeyFieldFocused)
      .onSubmit(saveKey)
      .padding(.horizontal, 16)
      .frame(minHeight: 60)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 2)
      }
      .accessibilityLabel("OpenAI API key")
      .accessibilityHint("Paste your key, then choose Save key. It is kept in this phone's Keychain.")
      .accessibilityIdentifier("openai_key_field")
    CustomButton(title: "Save key", style: .primary, isDisabled: trimmedDraft.isEmpty, action: saveKey)
      .accessibilityHint("Saves the pasted key so pages are read with the natural voice.")
      .accessibilityIdentifier("openai_key_save_button")
    if cloud.hasStoredKey {
      CustomButton(title: "Remove key", style: .destructive, isDisabled: false) {
        cloud.removeKey()
        Announcer.shared.say(cloud.hasKey ? SpokenMessage.readCloudKeyRemovedBuiltIn : SpokenMessage.readCloudKeyRemoved)
      }
      .accessibilityHint("Deletes the saved OpenAI key from this phone.")
      .accessibilityIdentifier("openai_key_remove_button")
    }
  }

  private func saveKey() {
    guard !trimmedDraft.isEmpty else { return }
    isKeyFieldFocused = false
    guard cloud.saveKey(trimmedDraft) else {
      Announcer.shared.say(SpokenMessage.readCloudKeyNotSaved)
      return
    }
    draftKey = ""
    Announcer.shared.say(preferences.useNaturalVoice ? SpokenMessage.readCloudKeySaved : SpokenMessage.readCloudKeySavedVoiceOff)
  }
}
