/*
 * HandsFreeMode - the pure rules around the two modes (notes/hands-free-mode.md)
 *
 * The mode itself is one persisted setting, A11yPreferences.handsFree (default off: the touch
 * toolbox). VoiceControl.setHandsFree(_:) is the one place it is switched at run time. This file
 * holds what can be decided without the world: the first-run default, the launch URL, the tools
 * list, and the names screens go by when spoken or shown on the glasses.
 */

import Foundation

enum HandsFreeMode {
  /// The first-run rule: hands-free starts on when VoiceOver is running, off otherwise. nil once a
  /// choice has been stored (by this rule or by the user), so it applies only once.
  static func firstRunChoice(hasChoice: Bool, voiceOverRunning: Bool) -> Bool? {
    hasChoice ? nil : voiceOverRunning
  }

  static let urlScheme = "speakup"

  /// speakup://handsfree (any case, with or without a trailing slash) opens straight into hands-free.
  static func isHandsFreeURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == urlScheme else { return false }
    let target = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return target == "handsfree" || target == "hands-free"
  }
}

/// What the toolbox lists and "list tools" names: the seven tools (ToolID), then status and
/// settings, so a new user can find them.
enum HandsFreeTool: String, CaseIterable, Identifiable, Sendable {
  case reader
  case mail
  case labels
  case watch
  case ask
  case light
  case reminders
  case status
  case settings

  var id: String { rawValue }

  /// The tool this row opens, if it is one.
  var tool: ToolID? {
    switch self {
    case .reader: .read
    case .mail: .mail
    case .labels: .labels
    case .watch: .watch
    case .ask: .ask
    case .light: .light
    case .reminders: .reminders
    case .status, .settings: nil
    }
  }

  init(_ tool: ToolID) {
    switch tool {
    case .read: self = .reader
    case .mail: self = .mail
    case .labels: self = .labels
    case .watch: self = .watch
    case .ask: self = .ask
    case .light: self = .light
    case .reminders: self = .reminders
    }
  }

  var title: String {
    if let tool { return tool.title }
    return self == .status ? "Camera status" : "Settings"
  }

  var summary: String {
    if let tool { return tool.summary }
    return self == .status ? "Says whether the camera is ready to read." : "Voice, speed, answer length and the glasses display."
  }

  var icon: String {
    if let tool { return tool.systemImage }
    return self == .status ? "checkmark.circle" : "gearshape.fill"
  }

  /// The spoken command that does the same as tapping it.
  var command: VoiceCommand {
    switch self {
    case .reader: .read
    case .status: .status
    case .settings: .openSettings
    default: tool.map(VoiceCommand.open) ?? .help
    }
  }
}

extension VoiceScreen {
  /// For "where am I": "You're on the main menu."
  var spokenName: String {
    switch self {
    case .welcome: "setup"
    case .home: "the main menu"
    case .camera: "the main menu, with the reader"
    }
  }

  /// The glasses display card's title.
  var cardTitle: String {
    switch self {
    case .welcome: "Setup"
    case .home: "SpeakUp"
    case .camera: "Reader"
    }
  }

  /// "main menu", "back" and "close" when the screen has nothing more specific to do.
  var mainMenuLine: String {
    switch self {
    case .welcome: SpokenMessage.mainMenuWelcome
    case .home: SpokenMessage.mainMenuHome
    case .camera: SpokenMessage.mainMenuCamera
    }
  }
}
