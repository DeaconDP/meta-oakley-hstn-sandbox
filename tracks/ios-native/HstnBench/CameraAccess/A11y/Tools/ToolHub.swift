/*
 * ToolHub - the seven everyday tools behind the tools home: one instance of each, which one is open,
 * and where a transcript goes while it is open (notes/tools-home-ios.md)
 *
 * Opening a tool stops the one before it (its camera work and speech), then starts the new one
 * with the shared camera (CameraSourceRouter by default). The router itself keeps running, so a
 * switch doesn't restart the camera. Each tool says its own first line with an earcon as it starts
 * ("Mail reader. Hold the phone flat over a letter..."). Read text is the original TextReader,
 * wrapped as ReadTextTool so it opens and closes like the rest.
 *
 * Voice (VoiceToolRouting, called by VoiceControl before the screen's commands):
 * - The app's always-on commands win: stop, close, main menu, help, where am I, list tools,
 *   settings by voice, faster and slower, and a command that opens another tool.
 * - Then the open tool sees the words, so its own phrases ("read", "repeat", "how much", "back")
 *   aren't taken by the app's grammar first.
 * - Then "watch for 42" / "tell me when you see 42" from anywhere opens Watch with that target,
 *   and, with Read text open, a question about the page ("what does ephemeral mean") goes to Ask.
 * - Anything else goes on to the screen as before ("read" opens Read text and reads).
 * Global stop cuts speech (the screen does that) and also calls the open tool's pauseForStop(),
 * so a light tone, a watch loop or a barcode search goes quiet too.
 */

import Observation
import SwiftUI

@MainActor
@Observable
final class ToolHub: VoiceToolRouting {
  static let shared = ToolHub()

  /// The tool on screen, or nil on the tools home.
  private(set) var openTool: ToolID?

  /// Where tools get frames. The app's is the router; tests pass a fake.
  @ObservationIgnored var source: (any ReadFrameSource)?
  @ObservationIgnored private var tools: [ToolID: any SpeakUpTool] = [:]
  @ObservationIgnored private let makeTool: @MainActor (ToolID) -> any SpeakUpTool
  @ObservationIgnored private let announcer: Announcer

  /// The app's commands that always mean the same thing, even with a tool open.
  static let alwaysGlobal: Set<VoiceCommand> = [
    .stop, .close, .mainMenu, .help, .whereAmI, .listTools, .closeApp, .faster, .slower, .openSettings,
    .shortAnswers, .normalAnswers, .detailedAnswers, .glassesDisplayOn, .glassesDisplayOff, .handsFreeOn, .handsFreeOff,
    .usePhone, .useGlasses, .whichCamera, .torchOn, .torchOff, .status, .connect, .disconnect,
  ]

  init(
    source: (any ReadFrameSource)? = nil, announcer: Announcer = .shared,
    makeTool: @escaping @MainActor (ToolID) -> any SpeakUpTool = ToolHub.liveTool
  ) {
    self.source = source
    self.announcer = announcer
    self.makeTool = makeTool
  }

  /// The real tools, made the first time each is opened.
  static func liveTool(_ id: ToolID) -> any SpeakUpTool {
    switch id {
    case .read: ReadTextTool()
    case .mail: MailTool()
    case .labels: LabelsTool()
    case .watch: WatchTool()
    case .ask: AskTool()
    case .light: LightTool()
    case .reminders: RemindersTool()
    }
  }

  /// The one instance of `id`.
  func tool(_ id: ToolID) -> any SpeakUpTool {
    if let tool = tools[id] { return tool }
    let tool = makeTool(id)
    tools[id] = tool
    return tool
  }

  var current: (any SpeakUpTool)? { openTool.map(tool) }

  // MARK: Open, close, switch

  /// Opens `id`, closing whatever was open. `phrase` is what was said to open it, so a tool can
  /// pick its mode ("what colour is this" opens Light in colour mode). Opening the tool that is
  /// already open starts it again, which repeats its first line.
  func open(_ id: ToolID, phrase: String? = nil) {
    let source = source ?? CameraSourceRouter.shared
    if let openTool, openTool != id { tool(openTool).stop() }
    if let light = tool(id) as? LightTool {
      light.openingMode = phrase.map(LightTool.mode(forOpeningPhrase:)) ?? .probe
    }
    BenchClock.shared.note("tool open=\(id.rawValue)")
    ActivityLog.shared.note("Opened \(id.title)", tool: id)
    openTool = id
    tool(id).start(source: source)
  }

  /// Opens Read text without its spoken first line, for a caller that reads at once (the Read
  /// text tile, "read", Siri) or reads something else (an imported page).
  func openReadTextQuietly() {
    (tool(.read) as? ReadTextTool)?.quietStart = true
    open(.read)
  }

  /// "Watch for 42": opens Watch watching for `target`, or changes what an open Watch looks for.
  func openWatch(for target: String?) {
    guard let watch = tool(.watch) as? WatchTool else { return }
    if openTool == .watch {
      if let target { watch.watch(for: target) } else { open(.watch) }
      return
    }
    if let target { watch.watch(for: target) }
    open(.watch)
  }

  /// Back to the tools home. Says so unless `announce` is false (the screen is going away).
  func close(announce: Bool = true) {
    guard let openTool else { return }
    tool(openTool).stop()
    self.openTool = nil
    BenchClock.shared.note("tool close=\(openTool.rawValue)")
    ActivityLog.shared.note("Closed \(openTool.title)", tool: openTool)
    if announce { announcer.announce(SpokenMessage.toolClosed(openTool), earcon: .ready, kind: .status) }
  }

  /// The app's "stop" with a tool open: speech is cut by the caller; this quiets the tool too.
  func stopForGlobal() {
    current?.pauseForStop()
  }

  // MARK: Voice

  func route(_ text: String, command: VoiceCommand?) -> Bool {
    // A reminder just went off: "done" and "snooze" answer it, wherever the user is.
    if ReminderAlerts.shared.takesReply(text) { return true }
    if let command {
      // Another tool by name, or an always-on command: the app's. Saying the open tool's own name
      // phrase ("read the label", "what colour is this") is left to that tool first.
      if let target = command.tool, target != openTool, command != .read || openTool == nil {
        if command == .read { return false }  // The screen's "read": opens Read text and reads.
        open(target, phrase: text)
        return true
      }
      if Self.alwaysGlobal.contains(command), command.tool == nil { return false }
    }
    if let current, current.handle(transcript: text) { return true }
    if let request = WatchGrammar.opens(text) {
      openWatch(for: request.target)
      return true
    }
    // "Remind me at 6 to ...", "what's due this week", "I took my evening pill", "what was I
    // doing?" from anywhere (A11y/Reminders).
    if ReminderGrammar.worksFromAnywhere(text), let reminders = tool(.reminders) as? RemindersTool,
      reminders.handleFromAnywhere(text, hub: self)
    {
      return true
    }
    if command == nil, openTool == .read, AskGrammar.isQuestion(text), let ask = tool(.ask) as? AskTool {
      ask.preferredSource = .read
      ask.ask(text)
      return true
    }
    if let command, let target = command.tool, target == openTool, command != .read {
      // The open tool's name again, and the tool didn't use it: say its first line again.
      open(target, phrase: text)
      return true
    }
    return false
  }
}

// MARK: - Read text as a tool

/// The original reader (TextReader) behind the same seam as the other tools. Its voice commands
/// (read, next, back, repeat, stop) are the app's own, so it takes no transcript itself.
@MainActor
final class ReadTextTool: SpeakUpTool {
  let toolID: ToolID = .read
  private let reader: TextReader
  /// The next start says nothing: whoever opened it is about to read.
  var quietStart = false

  init(reader: TextReader = .shared) {
    self.reader = reader
  }

  var helpLine: String {
    "Read text. Say read to read what's in view, then next, back, repeat or stop."
  }

  func start(source: ReadFrameSource) {
    reader.source = source
    if quietStart {
      quietStart = false
      return
    }
    let how =
      source.cameraKind == .phone
      ? "Hold the phone flat, about 30 centimetres above a page, then say read or tap Read text."
      : "Hold some text in front of you, then say read or tap Read text."
    Announcer.shared.announce("Read text. \(how)", earcon: .ready, kind: .reply)
  }

  func stop() {
    if reader.isActive { reader.stop() }
  }

  func handle(transcript: String) -> Bool { false }

  func pauseForStop() {
    if reader.isActive { reader.stop() }
  }

  func makePanel() -> AnyView { AnyView(ReadTextPanel()) }
}

/// Read text's panel: the big Read button, and the reading card once something is read.
struct ReadTextPanel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private var reader: TextReader { TextReader.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Button {
        reader.read()
      } label: {
        PathTileLabel(icon: "text.viewfinder", title: "Read text", coin: .neutral, isBig: true, say: .read)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .yellow, lipHeight: 8, radius: 30))
      .accessibilityIdentifier("read_button")
      .accessibilityLabel("Read text")
      .accessibilityHint("Reads the text in front of you aloud, word for word.")
      .cameraQuickActions(status: speakStatus)
      if reader.phase != .idle {
        ReadPanel(isLargeText: dynamicTypeSize.isAccessibilitySize, onStatus: speakStatus)
      }
    }
  }

  private func speakStatus() {
    if let line = CameraSourceRouter.shared.phoneStatusLine {
      Announcer.shared.announce(line, earcon: .ready)
    } else if let line = LaunchActionRouter.shared.statusProvider?() {
      Announcer.shared.announce(line, earcon: .ready)
    }
  }
}
