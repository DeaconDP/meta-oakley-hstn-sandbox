/*
 * LaunchIntents - "Look", "Read", "Status" and "Repeat" as App Intents, so the app can be used
 * without finding its icon: from Siri, the Shortcuts app, Back Tap (Settings > Accessibility >
 * Touch > Back Tap) or the Action Button (notes/a11y-onboarding.md, "Launch (every day)").
 *
 * Whether each one opens the app:
 * - Look and Read open it. The camera needs a foreground app: CameraViewModel ends the session
 *   when the app goes to the background, and raw DAT frames stop there anyway (only hvc1 keeps
 *   coming). On a locked phone iOS asks to unlock first; that is the price of a working stream.
 * - Status and Repeat don't. Both are answered by Siri reading the dialog, which works with the
 *   phone locked, the screen off, and over the glasses' A2DP route. Status only needs the app
 *   forward when no main screen is alive to ask; then it asks to continue in the app and runs
 *   there.
 *
 * Intents park work on LaunchActionRouter instead of calling view models, since a cold launch
 * has no view model yet.
 */

import AppIntents

struct LookIntent: AppIntent {
  static var title: LocalizedStringResource { "Look" }
  static var description: IntentDescription {
    IntentDescription("Takes a photo with your glasses and describes it.")
  }
  static var openAppWhenRun: Bool { true }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    LaunchActionRouter.shared.request(.look)
    // Immediate feedback while the app comes up and the glasses connect.
    return .result(dialog: "\(SpokenMessage.launchLooking)")
  }
}

struct ReadIntent: AppIntent {
  static var title: LocalizedStringResource { "Read" }
  static var description: IntentDescription {
    IntentDescription("Reads the text your glasses see aloud, word for word.")
  }
  static var openAppWhenRun: Bool { true }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    LaunchActionRouter.shared.request(.read)
    return .result(dialog: "\(SpokenMessage.launchReading)")
  }
}

struct StatusIntent: AppIntent, ForegroundContinuableIntent {
  static var title: LocalizedStringResource { "Status" }
  static var description: IntentDescription {
    IntentDescription("Says whether your glasses are ready.")
  }
  static var openAppWhenRun: Bool { false }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    if let line = LaunchActionRouter.shared.statusProvider?() {
      return .result(dialog: "\(line)")
    }
    // No main screen alive (cold launch, or still in onboarding), so nothing can tell. Continue in
    // the app, where the main screen speaks the status once it can.
    throw needsToContinueInForegroundError("\(SpokenMessage.launchOpeningForStatus)") {
      LaunchActionRouter.shared.request(.status)
    }
  }
}

struct RepeatLastIntent: AppIntent {
  static var title: LocalizedStringResource { "Repeat" }
  static var description: IntentDescription {
    IntentDescription("Says the last thing the app said again.")
  }
  static var openAppWhenRun: Bool { false }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    // Siri reads it, so it works locked. The app's own voice may not be able to start from the
    // background, and VoiceOver announcements aren't spoken for a background app.
    .result(dialog: "\(Announcer.shared.lastSpoken ?? SpokenMessage.launchNothingToRepeat)")
  }
}

/// Phrases must include the app name (the bundle display name). Keep them short and natural;
/// these are what people say to Siri and what Shortcuts lists for Back Tap and the Action Button.
/// No phrase may fit two intents: anything with "read" goes to Read (word for word), "look" and
/// "describe" to Look.
struct LaunchShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: LookIntent(),
      phrases: [
        "Look with \(.applicationName)",
        "Describe this with \(.applicationName)",
        "\(.applicationName) look",
      ],
      shortTitle: "Look",
      systemImageName: "eye"
    )
    AppShortcut(
      intent: ReadIntent(),
      phrases: [
        "Read this with \(.applicationName)",
        "Read text with \(.applicationName)",
        "\(.applicationName) read",
      ],
      shortTitle: "Read",
      systemImageName: "text.viewfinder"
    )
    AppShortcut(
      intent: StatusIntent(),
      phrases: [
        "\(.applicationName) status",
        "Is \(.applicationName) ready",
        "Check \(.applicationName)",
      ],
      shortTitle: "Status",
      systemImageName: "checkmark.circle"
    )
    AppShortcut(
      intent: RepeatLastIntent(),
      phrases: [
        "\(.applicationName) repeat",
        "Repeat that with \(.applicationName)",
      ],
      shortTitle: "Repeat",
      systemImageName: "arrow.counterclockwise"
    )
  }
}
