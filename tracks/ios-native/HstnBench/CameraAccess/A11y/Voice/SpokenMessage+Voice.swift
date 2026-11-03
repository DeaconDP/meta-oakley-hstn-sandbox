/*
 * SpokenMessage+Voice - what the app says about its voice and voice control
 *
 * The voice-download path, as far as it could be checked on 2026-11-03: the iOS 27.0 Simulator's
 * Settings has Accessibility > Spoken Content, and Apple's support article 111798 (March 2025)
 * gives Spoken Content > Voices. The Simulator shows no Voices row there, and some web sources call
 * the screen "Read & Speak". So it isn't confirmed on a real phone: both lines also say to search
 * Settings for "Voices", and notes/a11y-device-test.md asks to confirm it.
 */

extension SpokenMessage {
  // MARK: The app's voice

  static func voiceDownload(current: String?) -> String {
    let using = current.map { "so I'm using \($0)" } ?? "so I'm using the system voice"
    return "A British woman's voice isn't installed on this phone, \(using). To add one, open Settings, Accessibility, Spoken Content, Voices, English, then download Serena or Kate. If you can't find it, search Settings for Voices. I'll switch to the new voice by myself."
  }

  static func voiceDownloadOnScreen(current: String?) -> String {
    let using = current.map { "The app is using \($0) for now." } ?? "The app is using the system voice for now."
    return "A British woman's voice isn't installed. \(using) To add one: Settings > Accessibility > Spoken Content > Voices > English, then download Serena or Kate. Some iOS versions call Spoken Content \"Read & Speak\". You can also search Settings for \"Voices\"."
  }

  static func voiceNowInstalled(name: String) -> String {
    "\(name) is installed. I'll use this voice from now on."
  }

  // MARK: Voice control

  static let voiceControlOn = "Voice control is on. Say help at any time."

  static let voiceControlOnWakeWord = "Voice control is on. Say reader, help at any time."

  static let voiceControlTurnedOff = "Voice control off."

  /// Before the system's microphone and speech recognition dialogs.
  static let voiceControlExplanation =
    "You can run this app by speaking. It needs the microphone to hear you, and speech recognition to understand you. Both stay on your phone, and nothing you say is stored. You'll be asked to allow them next."

  static let voiceControlKeepOff = "Voice control stays off. You can turn it on in the app's settings."

  static let voicePermissionDenied =
    "Voice control is off because the microphone or speech recognition isn't allowed. Every button still works. To fix it, open Settings, find HSTN Reader, and turn both on."

  static let voiceNoOnDeviceRecognition =
    "Voice control can't start: this phone has no on-device speech recognition for English. To add it, open Settings, General, Keyboard, and turn on Enable Dictation. Every button still works."

  static let voiceControlTroubled = "Voice control has stopped hearing you. I'll keep trying. Every button still works."

  static let voiceNotUnderstood = "Sorry, I didn't catch that. Say reader, help."

  static let voiceHomeStatus = "Your glasses aren't connected to this app yet. Say connect."

  static let voiceGlassesMicNeedsMetaAI =
    "To listen through your glasses, you'll switch to the Meta AI app to allow their microphone, then come back here."

  static let voiceGlassesMicAllowed = "Glasses microphone allowed. Voice control will use it during a session."

  static let voiceGlassesMicNotAllowed = "The glasses microphone wasn't allowed. Voice control keeps using the phone's microphone."

  static let voiceRateFollowsVoiceOver = "Speech is using your VoiceOver speaking rate. Change it in VoiceOver settings."

  static let voiceFaster = "Faster."

  static let voiceSlower = "Slower."

  static let voiceFastest = "That's the fastest."

  static let voiceSlowest = "That's the slowest."
}
