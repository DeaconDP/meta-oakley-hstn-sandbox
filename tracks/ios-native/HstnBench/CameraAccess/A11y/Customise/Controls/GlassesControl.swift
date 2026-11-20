/*
 * GlassesControl and ControlAction - "Your buttons" (C4, Experimental): which glasses event does
 * what in SpeakUp (notes/customisation-ios-words.md)
 *
 * The events are the ones DAT 1.0's Inputs capability delivers (MWDATInputs.InputEvent): Capture
 * (shortPress, hold, doublePress) from the capture button, Select (a touchpad double tap) and Nav
 * (swipes) from the touchpad, and Button(.action) from an action button. Single tap and tap-and-hold
 * on the touchpad are reserved by the glasses (pause and stop the session) and never reach an app,
 * so they aren't here. Swipe directions come from the device and the wearer can invert them.
 *
 * No DAT types: this is shared code, built into the App Store target too. The DAT side
 * (Glasses/DATGlassesInputs.swift) turns InputEvent into GlassesControl.
 */

import Foundation

enum GlassesControl: String, CaseIterable, Codable, Sendable, Identifiable {
  case captureShort
  case captureHold
  case captureDouble
  /// Select: a double tap on the touchpad (or a Neural Band tap).
  case doubleTap
  case swipeUp
  case swipeDown
  case swipeLeft
  case swipeRight
  /// Button(.action), on glasses that have one. Unconfirmed on HSTN.
  case actionButton

  var id: String { rawValue }

  /// "a short press" in "a short press will look".
  var spokenName: String {
    switch self {
    case .captureShort: "a short press"
    case .captureHold: "holding the button"
    case .captureDouble: "a double press"
    case .doubleTap: "a double tap"
    case .swipeUp: "swiping up"
    case .swipeDown: "swiping down"
    case .swipeLeft: "swiping left"
    case .swipeRight: "swiping right"
    case .actionButton: "the action button"
    }
  }

  /// The settings row's label.
  var title: String {
    switch self {
    case .captureShort: "Capture button, short press"
    case .captureHold: "Capture button, hold"
    case .captureDouble: "Capture button, double press"
    case .doubleTap: "Touchpad double tap"
    case .swipeUp: "Swipe up"
    case .swipeDown: "Swipe down"
    case .swipeLeft: "Swipe left"
    case .swipeRight: "Swipe right"
    case .actionButton: "Action button"
    }
  }

  /// What people call it in "when I double tap, repeat".
  var phrases: [String] {
    switch self {
    case .captureShort:
      ["press", "short press", "press the button", "press the capture button", "click", "single press", "press once",
        "a short press", "press the camera button", "the button", "the capture button"]
    case .captureHold:
      ["hold", "hold the button", "press and hold", "long press", "hold the capture button", "hold down the button",
        "hold the camera button", "holding the button"]
    case .captureDouble:
      ["double press", "double click", "press twice", "press the button twice", "double press the button", "a double press"]
    case .doubleTap: ["double tap", "tap twice", "double tap the side", "double tap the glasses", "a double tap", "select"]
    case .swipeUp: ["swipe up", "swiping up"]
    case .swipeDown: ["swipe down", "swiping down"]
    case .swipeLeft: ["swipe left", "swiping left"]
    case .swipeRight: ["swipe right", "swiping right"]
    case .actionButton: ["action button", "press the action button", "the action button"]
    }
  }

  /// The control named at the start of `tokens`, longest name first, and how many words it used.
  static func named(atStartOf tokens: [String]) -> (GlassesControl, Int)? {
    var best: (GlassesControl, Int)?
    for control in allCases {
      for phrase in control.phrases {
        let words = phrase.split(separator: " ").map(String.init)
        guard tokens.count >= words.count, Array(tokens.prefix(words.count)) == words else { continue }
        if words.count > best?.1 ?? 0 { best = (control, words.count) }
      }
    }
    return best
  }
}

enum ControlAction: Equatable, Hashable, Sendable {
  case nothing
  /// Look again: the open tool starts again (Light probes, Labels scans), or Read text reads.
  case look
  case read
  case repeatLast
  case stop
  case next
  case previous
  case status
  case help
  case favouriteTool
  case tool(ToolID)
  case macro(String)

  /// The verb phrase in "a short press will look".
  var spokenName: String {
    switch self {
    case .nothing: "do nothing"
    case .look: "look"
    case .read: "read"
    case .repeatLast: "repeat"
    case .stop: "stop"
    case .next: "go to the next sentence"
    case .previous: "go back"
    case .status: "say the status"
    case .help: "give help"
    case .favouriteTool: "open your favourite tool"
    case .tool(let tool): "open \(tool.title.lowercased())"
    case .macro(let name): "run \(name)"
    }
  }

  /// The settings picker's label.
  var title: String {
    switch self {
    case .nothing: "Nothing"
    case .look: "Look"
    case .read: "Read"
    case .repeatLast: "Repeat"
    case .stop: "Stop"
    case .next: "Next sentence"
    case .previous: "Back"
    case .status: "Status"
    case .help: "Help"
    case .favouriteTool: "Favourite tool"
    case .tool(let tool): "Open \(tool.title)"
    case .macro(let name): "Run \(name)"
    }
  }

  /// Stored form: "look", "tool:mail", "macro:morning post".
  var rawValue: String {
    switch self {
    case .nothing: "nothing"
    case .look: "look"
    case .read: "read"
    case .repeatLast: "repeat"
    case .stop: "stop"
    case .next: "next"
    case .previous: "previous"
    case .status: "status"
    case .help: "help"
    case .favouriteTool: "favourite"
    case .tool(let tool): "tool:\(tool.rawValue)"
    case .macro(let name): "macro:\(name)"
    }
  }

  init?(rawValue: String) {
    if rawValue.hasPrefix("tool:") {
      guard let tool = ToolID(rawValue: String(rawValue.dropFirst(5))) else { return nil }
      self = .tool(tool)
      return
    }
    if rawValue.hasPrefix("macro:") {
      let name = String(rawValue.dropFirst(6))
      guard !name.isEmpty else { return nil }
      self = .macro(name)
      return
    }
    guard let simple = Self.simple.first(where: { $0.rawValue == rawValue }) else { return nil }
    self = simple
  }

  static let simple: [ControlAction] = [
    .look, .read, .repeatLast, .stop, .next, .previous, .status, .help, .favouriteTool, .nothing,
  ]

  /// What people call it in "make double tap repeat", or nil. Macro names come from `macros`.
  static func named(_ words: [String], macros: [String]) -> ControlAction? {
    var tokens = words
    for lead in [["it", "should"], ["should"], ["to"], ["will"], ["please"], ["then"], ["i", "want", "it", "to"]]
    where tokens.count > lead.count && Array(tokens.prefix(lead.count)) == lead {
      tokens.removeFirst(lead.count)
    }
    let phrase = tokens.joined(separator: " ")
    switch phrase {
    case "nothing", "do nothing", "none", "off", "not do anything", "turn it off": return .nothing
    case "look", "look at it", "look again", "describe", "describe it", "whats in front of me": return .look
    case "read", "read it", "read this", "read text", "read aloud", "read it aloud": return .read
    case "repeat", "repeat that", "say it again", "again", "say again": return .repeatLast
    case "stop", "be quiet", "pause", "quiet", "stop talking": return .stop
    case "next", "next sentence", "go on", "continue", "go forward": return .next
    case "previous", "back", "go back", "previous sentence", "go back a sentence": return .previous
    case "status", "check status", "say the status", "whats the status": return .status
    case "help", "give help", "what can i say": return .help
    case "favourite", "my favourite", "favourite tool", "my favourite tool", "open my favourite", "open my favourite tool",
      "open favourite tool":
      return .favouriteTool
    default: break
    }
    var macroName = phrase
    if macroName.hasPrefix("run ") { macroName.removeFirst(4) }
    if macros.contains(macroName) { return .macro(macroName) }
    if let tool = ToolID.named(phrase) { return .tool(tool) }
    return nil
  }
}

extension ControlAction: Codable {
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let action = ControlAction(rawValue: raw) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown action \(raw)"))
    }
    self = action
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

struct ControlsSettings: Codable, Equatable, Sendable {
  /// Off gives the glasses' own button actions back (no Inputs capability on the session).
  var enabled = true
  var map: [GlassesControl: ControlAction] = Self.defaultMap
  var favouriteTool: ToolID?

  /// Short = look, hold = read (Android phase 6), double press = stop, double tap = repeat, and
  /// left/right swipes step through a page. Up, down and the action button are free.
  static let defaultMap: [GlassesControl: ControlAction] = [
    .captureShort: .look, .captureHold: .read, .captureDouble: .stop, .doubleTap: .repeatLast,
    .swipeLeft: .previous, .swipeRight: .next, .swipeUp: .nothing, .swipeDown: .nothing, .actionButton: .nothing,
  ]

  init() {}

  func action(for control: GlassesControl) -> ControlAction { map[control] ?? .nothing }

  private enum CodingKeys: String, CodingKey { case enabled, map, favouriteTool }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    var map = Self.defaultMap
    let stored = (try? container.decodeIfPresent([String: String].self, forKey: .map)) ?? [:]
    for (key, value) in stored {
      guard let control = GlassesControl(rawValue: key), let action = ControlAction(rawValue: value) else { continue }
      map[control] = action
    }
    self.map = map
    let favourite = (try? container.decodeIfPresent(String.self, forKey: .favouriteTool)) ?? nil
    favouriteTool = favourite.flatMap(ToolID.init(rawValue:))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(
      Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .map)
    try container.encodeIfPresent(favouriteTool?.rawValue, forKey: .favouriteTool)
  }
}
