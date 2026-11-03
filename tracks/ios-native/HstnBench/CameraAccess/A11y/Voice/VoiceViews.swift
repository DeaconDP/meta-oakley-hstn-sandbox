/*
 * VoiceViews - the small views voice control and the app's voice need
 *
 * Styled from A11y/Theme. The always-visible listening indicator is Theme/VoiceIndicator.swift.
 * VoiceInjectionOverlay exists only for UI tests.
 */

import SwiftUI
import UIKit

// MARK: - Settings

/// Added to the camera screen's settings menu, the one place preferences are edited after setup.
struct VoiceSettingsRows: View {
  private var voice: VoiceControl { VoiceControl.shared }
  private let preferences = A11yPreferences.shared

  var body: some View {
    Text(voice.reason.map { "\(voice.statusText). \($0)" } ?? voice.statusText)
      .settingsLabel(id: "voice_status_label")
    Text(AppVoice.shared.displayString)
      .settingsLabel(id: "voice_name_label")
    CustomButton(
      title: voice.isEnabled ? "Turn voice control off" : "Turn voice control on", style: .secondary, isDisabled: false
    ) {
      voice.setEnabled(!voice.isEnabled)
    }
    .accessibilityHint("Runs the app by speaking. Buttons always work.")
    .accessibilityIdentifier("voice_control_toggle")
    CustomButton(
      title: preferences.useVoiceOverVoice ? "Use the British voice" : "Use VoiceOver's voice", style: .secondary,
      isDisabled: false
    ) {
      preferences.useVoiceOverVoice.toggle()
    }
    .accessibilityHint("Chooses whose voice the app speaks with while VoiceOver is running.")
    .accessibilityIdentifier("use_voiceover_voice_toggle")
    if voice.canRequestGlassesMicrophone {
      CustomButton(title: "Listen through glasses", style: .secondary, isDisabled: false) {
        voice.requestGlassesMicrophone()
      }
      .accessibilityHint("Opens the Meta AI app to allow the glasses microphone.")
      .accessibilityIdentifier("voice_glasses_mic_button")
    }
  }
}

extension Text {
  fileprivate func settingsLabel(id: String) -> some View {
    self
      .font(.rounded(.subheadline, weight: .bold))
      .foregroundStyle(Theme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(id)
  }
}

// MARK: - The one-time voice download notice

/// Shown until dismissed. Not an alert: an alert would block someone who is using the app by voice.
/// It is long, and pinned above the page, so at large text it scrolls inside a limited height rather
/// than pushing the page off the screen.
struct VoiceDownloadNoticeBanner: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if let notice = AppVoice.shared.downloadNotice {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          ScrollView { content(notice) }
            .frame(maxHeight: 320)
        } else {
          content(notice)
        }
      }
      .background(Theme.surface)
    }
  }

  private func content(_ notice: String) -> some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout {
      Text(notice)
        .font(.rounded(.callout, weight: .medium))
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("voice_download_notice")
      Button("OK") { AppVoice.shared.dismissDownloadNotice() }
        .buttonStyle(.a11ySecondary)
        .frame(maxWidth: stacked ? .infinity : 80)
        .accessibilityHint("Hides this message.")
        .accessibilityIdentifier("voice_download_notice_ok")
    }
    .padding(16)
  }
}

// MARK: - Setup step

/// Says why the mic and speech recognition are needed, then asks. A denial gets the fix in words
/// and a way to Settings, and setup carries on: every button works without voice control.
struct VoiceControlStep: View {
  var speak: OnboardingSpeak
  var onContinue: () -> Void
  var onSkip: () -> Void
  var onExit: () -> Void

  private var voice: VoiceControl { VoiceControl.shared }
  private let preferences = A11yPreferences.shared

  private var isDenied: Bool { voice.phoneMicPermission == .denied || voice.speechPermission == .denied }
  private var isGranted: Bool { voice.phoneMicPermission == .granted && voice.speechPermission == .granted }

  var body: some View {
    LessonPage {
      MascotSays(
        mood: isDenied ? .confused : .listening,
        text: isDenied ? SpokenMessage.voicePermissionDenied : SpokenMessage.voiceControlExplanation)
    } footer: {
      if isDenied {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .buttonStyle(.a11yPrimary)
        .accessibilityHint("Turn on Microphone and Speech Recognition for HSTN Reader.")
        .accessibilityIdentifier("voice_open_settings_button")
        Button("Continue", action: onContinue)
          .buttonStyle(.a11ySecondary)
          .sayHint(.continueOn)
          .accessibilityIdentifier("onboarding_continue_button")
      } else {
        Button(isGranted ? "Continue" : "Turn on voice control", action: turnOn)
          .buttonStyle(.a11yPrimary)
          .sayHint(.yes)
          .accessibilityHint(isGranted ? "" : "Asks to use the microphone and speech recognition.")
          .accessibilityIdentifier("voice_turn_on_button")
        Button("Keep voice control off", action: keepOff)
          .buttonStyle(.a11ySecondary)
          .sayHint(.no)
          .accessibilityHint("Every button still works. You can turn it on later in settings.")
          .accessibilityIdentifier("voice_keep_off_button")
      }
      OnboardingSkipButtons(onSkip: onSkip, onExit: onExit)
    }
    .onAppear {
      speak(isDenied ? SpokenMessage.voicePermissionDenied : SpokenMessage.voiceControlExplanation, .status)
      voice.stepHandler = { command in
        switch command {
        case .yes, .continueOn:
          // Denied can't be fixed from here by voice; "continue" still moves on.
          if isDenied { onContinue() } else { turnOn() }
        case .no: keepOff()
        default: return false
        }
        return true
      }
    }
  }

  private func turnOn() {
    voice.setEnabled(true)
    guard !isGranted, !LaunchOptions.isAutomatedTest else {
      onContinue()
      return
    }
    Task {
      await voice.requestPermissions()
      if isGranted { onContinue() }
    }
  }

  private func keepOff() {
    voice.setEnabled(false)
    // After going on, which stops speech: the next step's key line queues behind this.
    onContinue()
    Announcer.shared.say(SpokenMessage.voiceControlKeepOff, interrupt: false)
  }
}

// MARK: - Test seam

#if DEBUG
/// With `--ui-testing --voice-inject`: a field whose text goes to VoiceControl as a transcript, and
/// the state to assert on. Never shown otherwise.
struct VoiceInjectionOverlay: View {
  @State private var text = ""

  var body: some View {
    if LaunchOptions.injectsVoice {
      VStack(spacing: 4) {
        Text(VoiceControl.shared.status.rawValue)
          .accessibilityIdentifier("voice_test_status")
        Text(VoiceControl.shared.lastCommand?.rawValue ?? "none")
          .accessibilityIdentifier("voice_test_last_command")
        TextField("Transcript", text: $text)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .accessibilityIdentifier("voice_test_transcript")
          .onSubmit {
            VoiceControl.shared.inject(transcript: text)
            text = ""
          }
      }
      .padding(8)
      .background(Color(.systemBackground))
    }
  }
}
#endif
