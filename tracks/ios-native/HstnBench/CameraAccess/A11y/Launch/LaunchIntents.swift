/*
 * LaunchIntents - "Read", "Status" and "Repeat" as App Intents, so the app can be used
 * without finding its icon: from Siri, the Shortcuts app, Back Tap (Settings > Accessibility >
 * Touch > Back Tap) or the Action Button (notes/a11y-onboarding.md, "Launch (every day)").
 *
 * Whether each one opens the app:
 * - Read opens it. The camera needs a foreground app: CameraViewModel ends the session
 *   when the app goes to the background, and raw DAT frames stop there anyway (only hvc1 keeps
 *   coming). On a locked phone iOS asks to unlock first; that is the price of a working stream.
 * - Status and Repeat don't. Both are answered by Siri reading the dialog, which works with the
 *   phone locked, the screen off, and over the glasses' A2DP route. Status only needs the app
 *   forward when no main screen is alive to ask; then it asks to continue in the app and runs
 *   there.
 *
 * Intents park work on LaunchActionRouter instead of calling view models, since a cold launch
 * has no view model yet.
 *
 * Every tool has a one-step way in (V4 "Reach", notes/reach-ios.md): OpenToolIntent takes the tool
 * as a parameter (Shortcuts, and "Open <tool> in SpeakUp" to Siri), and each tool other than Read
 * also has its own intent with its own phrases ("Read my mail with SpeakUp"). They all open the
 * app, because every tool uses the camera. Any of them can be put on the Action Button (Settings >
 * Action Button > Shortcut) or Back Tap. A Control Center control needs a widget extension, which
 * this project doesn't have yet.
 *
 * App Shortcuts limits: at most 10 AppShortcuts, each phrase has `.applicationName` once, and no
 * phrase fits two intents. LaunchShortcuts uses all 10; ReadImportedIntent is in Shortcuts only.
 */

import AppIntents

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

/// Opens straight into hands-free mode and switches it on (notes/hands-free-mode.md section 2).
/// Opens the app: listening needs it in front. The same as the URL speakup://handsfree.
struct StartHandsFreeIntent: AppIntent {
  static var title: LocalizedStringResource { "Start hands-free" }
  static var description: IntentDescription {
    IntentDescription("Opens SpeakUp in hands-free mode, so you can use it by voice alone.")
  }
  static var openAppWhenRun: Bool { true }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    VoiceControl.shared.startHandsFreeFromLaunch()
    return .result(dialog: "\(SpokenMessage.launchHandsFree)")
  }
}

// MARK: Tools

extension ToolID: AppEnum {
  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tool" }
  static var caseDisplayRepresentations: [ToolID: DisplayRepresentation] {
    [
      .read: DisplayRepresentation(title: "Read text", image: .init(systemName: "text.viewfinder")),
      .mail: DisplayRepresentation(title: "Mail reader", image: .init(systemName: "envelope.open")),
      .labels: DisplayRepresentation(title: "Labels and barcodes", image: .init(systemName: "barcode.viewfinder")),
      .watch: DisplayRepresentation(title: "Watch for text", image: .init(systemName: "eye")),
      .ask: DisplayRepresentation(title: "Ask about the text", image: .init(systemName: "questionmark.bubble")),
      .light: DisplayRepresentation(title: "Light and colour", image: .init(systemName: "lightbulb")),
    ]
  }
}

/// What opening `tool` from a shortcut does: parks the launch action and returns Siri's line.
/// Shared by every open-tool intent, and the seam the tests use.
@MainActor
enum OpenToolLaunch {
  @discardableResult
  static func park(_ tool: ToolID, on router: LaunchActionRouter = .shared) -> String {
    router.request(LaunchAction.open(tool))
    return tool == .read ? SpokenMessage.launchReading : SpokenMessage.launchOpening(tool)
  }
}

/// Any tool, chosen in Shortcuts or by name to Siri.
struct OpenToolIntent: AppIntent {
  static var title: LocalizedStringResource { "Open a tool" }
  static var description: IntentDescription {
    IntentDescription("Opens one of SpeakUp's tools, ready to use.")
  }
  static var openAppWhenRun: Bool { true }

  @Parameter(title: "Tool", default: .read)
  var tool: ToolID

  init() {}

  init(tool: ToolID) {
    self.tool = tool
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$tool)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: "\(OpenToolLaunch.park(tool))")
  }
}

/// One intent per tool, so each gets its own Siri phrases and its own tile in Shortcuts.
protocol OpenOneToolIntent: AppIntent {
  static var tool: ToolID { get }
}

extension OpenOneToolIntent {
  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: "\(OpenToolLaunch.park(Self.tool))")
  }
}

struct OpenMailIntent: OpenOneToolIntent {
  static var tool: ToolID { .mail }
  static var openAppWhenRun: Bool { true }
  static var title: LocalizedStringResource { "Read my mail" }
  static var description: IntentDescription {
    IntentDescription("Opens the mail reader: who a letter is from and what it wants.")
  }
}

struct OpenLabelsIntent: OpenOneToolIntent {
  static var tool: ToolID { .labels }
  static var openAppWhenRun: Bool { true }
  static var title: LocalizedStringResource { "Scan a label" }
  static var description: IntentDescription {
    IntentDescription("Opens labels and barcodes: dates, ingredients, cooking steps.")
  }
}

struct OpenLightIntent: OpenOneToolIntent {
  static var tool: ToolID { .light }
  static var openAppWhenRun: Bool { true }
  static var title: LocalizedStringResource { "Check the light" }
  static var description: IntentDescription {
    IntentDescription("Opens light and colour: is a light on, what colour is this.")
  }
}

struct OpenWatchIntent: OpenOneToolIntent {
  static var tool: ToolID { .watch }
  static var openAppWhenRun: Bool { true }
  static var title: LocalizedStringResource { "Watch for text" }
  static var description: IntentDescription {
    IntentDescription("Opens watch for text: it tells you when a word or number appears.")
  }
}

struct OpenAskIntent: OpenOneToolIntent {
  static var tool: ToolID { .ask }
  static var openAppWhenRun: Bool { true }
  static var title: LocalizedStringResource { "Ask about the text" }
  static var description: IntentDescription {
    IntentDescription("Opens ask: questions about what was just read.")
  }
}

/// Reads photos and PDFs shared to SpeakUp that haven't been read yet. Shortcuts only (the 10 App
/// Shortcuts are taken); the share extension's "Open SpeakUp" note covers the common case.
struct ReadImportedIntent: AppIntent {
  static var title: LocalizedStringResource { "Read what I shared" }
  static var description: IntentDescription {
    IntentDescription("Reads the photos and PDFs you shared to SpeakUp, on this phone.")
  }
  static var openAppWhenRun: Bool { true }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    LaunchActionRouter.shared.request(.readImported)
    return .result(dialog: "\(SpokenMessage.launchReadingImported)")
  }
}

/// Phrases must include the app name (the bundle display name). Keep them short and natural;
/// these are what people say to Siri and what Shortcuts lists for Back Tap and the Action Button.
/// No phrase may fit two intents.
struct LaunchShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
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
    AppShortcut(
      intent: StartHandsFreeIntent(),
      phrases: [
        "Start hands-free in \(.applicationName)",
        "Start \(.applicationName) hands-free",
        "\(.applicationName) hands-free",
      ],
      shortTitle: "Hands-free",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: OpenMailIntent(),
      phrases: [
        "Read my mail with \(.applicationName)",
        "Read a letter with \(.applicationName)",
      ],
      shortTitle: "Read my mail",
      systemImageName: "envelope.open"
    )
    AppShortcut(
      intent: OpenLabelsIntent(),
      phrases: [
        "Scan a label with \(.applicationName)",
        "Scan a barcode with \(.applicationName)",
        "Read the label with \(.applicationName)",
      ],
      shortTitle: "Scan a label",
      systemImageName: "barcode.viewfinder"
    )
    AppShortcut(
      intent: OpenLightIntent(),
      phrases: [
        "Is the light on with \(.applicationName)",
        "What colour is this with \(.applicationName)",
        "What color is this with \(.applicationName)",
        "Check the light with \(.applicationName)",
      ],
      shortTitle: "Light and colour",
      systemImageName: "lightbulb"
    )
    AppShortcut(
      intent: OpenWatchIntent(),
      phrases: [
        "Watch for text with \(.applicationName)",
        "\(.applicationName) watch",
      ],
      shortTitle: "Watch for text",
      systemImageName: "eye"
    )
    AppShortcut(
      intent: OpenAskIntent(),
      phrases: [
        "Ask about the text with \(.applicationName)",
        "\(.applicationName) ask",
      ],
      shortTitle: "Ask",
      systemImageName: "questionmark.bubble"
    )
    AppShortcut(
      intent: OpenToolIntent(),
      phrases: [
        "Open \(\.$tool) in \(.applicationName)",
        "\(.applicationName) open \(\.$tool)",
      ],
      shortTitle: "Open a tool",
      systemImageName: "square.grid.2x2"
    )
  }
}
