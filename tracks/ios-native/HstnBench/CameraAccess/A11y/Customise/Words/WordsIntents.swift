/*
 * WordsIntents - phone triggers for "Your words" and "Your buttons": run one of your macros, or
 * open your favourite tool, from Shortcuts, Siri (through a shortcut you name), Back Tap or the
 * Action Button.
 *
 * Not App Shortcuts: LaunchShortcuts already has the 10 iOS allows. Both intents appear in the
 * Shortcuts app under SpeakUp; "Run my macro" picks the macro from a list (MacroEntity), so a
 * shortcut called "Morning post" makes "Hey Siri, morning post" work. Both open the app, because
 * every tool needs the camera.
 */

import AppIntents

struct MacroEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Macro" }
  static var defaultQuery: MacroQuery { MacroQuery() }

  /// The macro's name, as it is said.
  var id: String
  var steps: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(id)", subtitle: "\(steps)")
  }
}

struct MacroQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [MacroEntity] {
    await Self.all().filter { identifiers.contains($0.id) }
  }

  func entities(matching string: String) async throws -> [MacroEntity] {
    let wanted = string.lowercased()
    return await Self.all().filter { $0.id.contains(wanted) }
  }

  func suggestedEntities() async throws -> [MacroEntity] {
    await Self.all()
  }

  @MainActor
  private static func all() -> [MacroEntity] {
    WordsArea.shared.macros.map { MacroEntity(id: $0.name, steps: $0.spokenSteps) }
  }
}

struct RunMacroIntent: AppIntent {
  static var title: LocalizedStringResource { "Run my macro" }
  static var description: IntentDescription {
    IntentDescription("Runs one of the macros you made by voice, such as morning post.")
  }
  static var openAppWhenRun: Bool { true }

  @Parameter(title: "Macro")
  var macro: MacroEntity

  init() {}

  init(macro: MacroEntity) {
    self.macro = macro
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Run \(\.$macro)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    WordsLaunch.runWhenReady(macro.id)
    return .result(dialog: "\(SpokenMessage.launchRunningMacro(macro.id))")
  }
}

struct OpenFavouriteToolIntent: AppIntent {
  static var title: LocalizedStringResource { "Open my favourite tool" }
  static var description: IntentDescription {
    IntentDescription("Opens the tool you chose as your favourite in SpeakUp.")
  }
  static var openAppWhenRun: Bool { true }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let tool = ControlsArea.shared.favouriteTool else {
      return .result(dialog: "\(SpokenMessage.favouriteNone)")
    }
    return .result(dialog: "\(OpenToolLaunch.park(tool))")
  }
}

extension SpokenMessage {
  static func launchRunningMacro(_ name: String) -> String { "Running \(name)." }
}
