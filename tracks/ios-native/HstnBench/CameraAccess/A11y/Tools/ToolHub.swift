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
 * Voice (VoiceToolRouting, called by VoiceControl before the screen's commands). Short answers
 * go to the newest question still waiting (VoiceQuestions). The order:
 * 1. A reminder that just went off: "snooze" (for 30 minutes), and "done" while the reminder is
 *    the newest question (no tool opened or closed, nothing else asked since). Otherwise "done"
 *    is close again.
 * 2. "Undo" just after a reminder was added from another tool, while that's the newest question.
 * 3. The app's always-on commands win: stop, close, main menu, help, where am I, list tools,
 *    settings by voice, faster and slower, and a command that opens another tool.
 * 4. Then the open tool sees the words, so its own phrases ("read", "repeat", "how much", "back",
 *    "next step", "yes" to its own question) aren't taken by the app's grammar first. Steps belong
 *    to the open tool only: Read text's page steps, or Labels' cooking steps.
 * 5. "watch for 42" / "tell me when you see 42" from anywhere opens Watch with that target.
 * 6. Letters from anywhere: "my letters", "what letters do I have" and "read the letter from
 *    <sender>" open the mail reader and go to its letters log.
 * 7. Reminders from anywhere: "remind me at 6 to ...", "what's due this week", "I took my evening
 *    pill", "what was I doing?". From the home they open Reminders; inside a tool they answer in
 *    place and the tool stays open.
 * 8. "big text" outside Read text: from the home it opens Read text's big text; inside another
 *    tool it says where big text is.
 * 9. With Read text open, a question about the page ("what does ephemeral mean") goes to Ask.
 * 10. The open tool's own name again, unused by it, restarts its first line.
 * Anything else goes on to the screen as before ("read" opens Read text and reads).
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
  /// Who asked last (VoiceQuestions). Opening or closing a tool means the user moved on.
  @ObservationIgnored var questions: VoiceQuestions = .shared
  /// The reminder that went off last ("done", "snooze"); tests pass their own.
  @ObservationIgnored var alerts: ReminderAlerts = .shared

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
    questions.movedOn()
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
    questions.movedOn()
    if announce { announcer.announce(SpokenMessage.toolClosed(openTool), earcon: .ready, kind: .status) }
  }

  /// The app's "stop" with a tool open: speech is cut by the caller; this quiets the tool too.
  func stopForGlobal() {
    current?.pauseForStop()
  }

  // MARK: Voice

  func route(_ text: String, command: VoiceCommand?) -> Bool {
    // 1. A reminder just went off: "snooze", and "done" while it's the newest question.
    if alerts.takesReply(text) { return true }
    // 2. "Undo" right after a reminder was added from another tool, while that's the newest question.
    if openTool != .reminders, ReminderGrammar.isUndo(text), let reminders = tool(.reminders) as? RemindersTool,
      reminders.handleFromAnywhere(text, hub: self)
    {
      return true
    }
    if let command {
      // 3. Another tool by name, or an always-on command: the app's. Saying the open tool's own
      // name phrase ("read the label", "what colour is this") is left to that tool first.
      if let target = command.tool, target != openTool, command != .read || openTool == nil {
        if command == .read { return false }  // The screen's "read": opens Read text and reads.
        open(target, phrase: text)
        return true
      }
      if Self.alwaysGlobal.contains(command), command.tool == nil { return false }
    }
    // 4. The open tool's own phrases.
    if let current, current.handle(transcript: text) { return true }
    // 5. "Watch for 42" from anywhere.
    if let request = WatchGrammar.opens(text) {
      openWatch(for: request.target)
      return true
    }
    // 6. "My letters", "read the letter from Northgate" from anywhere (A11y/Letters).
    if routeLetters(text) { return true }
    // 7. "Remind me at 6 to ...", "what's due this week", "I took my evening pill", "what was I
    // doing?" from anywhere (A11y/Reminders). In place inside a tool, Reminders opens from the home.
    if ReminderGrammar.worksFromAnywhere(text), let reminders = tool(.reminders) as? RemindersTool,
      reminders.handleFromAnywhere(text, hub: self)
    {
      return true
    }
    // 8. "Big text" outside Read text.
    if routeBigText(text) { return true }
    // 9. A question about the page, with Read text open.
    if command == nil, openTool == .read, AskGrammar.isQuestion(text), let ask = tool(.ask) as? AskTool {
      ask.preferredSource = .read
      ask.ask(text)
      return true
    }
    // 10. The open tool's name again, and the tool didn't use it: say its first line again.
    if let command, let target = command.tool, target == openTool, command != .read {
      open(target, phrase: text)
      return true
    }
    return false
  }

  /// "my letters", "what letters do I have", "read the letter from <sender>" with another tool
  /// open or on the home: opens the mail reader without its first line, then its letters log.
  /// With the mail reader open these never get here: it hears them first.
  private func routeLetters(_ text: String) -> Bool {
    guard let letter = Self.globalLetterCommand(text), let mail = tool(.mail) as? MailTool else { return false }
    if openTool != .mail {
      mail.quietStart = true
      open(.mail)
    }
    switch letter {
    case .readSaved(let name): mail.openSaved(named: name)
    default: mail.listLetters()
    }
    return true
  }

  /// The letters phrases that work from anywhere. "read the council letter" stays the mail
  /// reader's: from anywhere only "... letter from <sender>" opens a saved letter.
  static func globalLetterCommand(_ text: String) -> LetterVoiceCommand? {
    switch LetterGrammar.parse(text) {
    case .myLetters: return .myLetters
    case .readSaved(let name) where VoiceCommandParser.normalize(text).contains("from"): return .readSaved(name)
    default: return nil
    }
  }

  /// "big text" with no tool open opens Read text and its big text (which says so if nothing has
  /// been read yet). Inside another tool it says where big text is, rather than nothing at all.
  private func routeBigText(_ text: String) -> Bool {
    guard let command = ReadTextPhrases.command(for: text), command == .bigTextOn || command == .bigTextOff else { return false }
    guard let openTool else {
      guard command == .bigTextOn else { return false }
      openReadTextQuietly()
      return current?.handle(transcript: text) ?? false
    }
    guard openTool != .read else { return false }
    announcer.announce(SpokenMessage.bigTextOnlyInReadText, earcon: .attention, kind: .reply)
    return true
  }
}

// MARK: - Read text as a tool

/// The original reader (TextReader) behind the same seam as the other tools. Its sentence commands
/// (read, next, back, repeat, stop) are the app's own; its own phrases (steps, big text, yes to the
/// torch offer) are in ReadTextVoice (A11y/Read/ReadSteps.swift).
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
    "Read text. Say read, then next, back or repeat. Say big text for large print, or next step for recipes."
  }

  func start(source: ReadFrameSource) {
    reader.source = source
    if reader === TextReader.shared { FramingAssist.shared.start(source: source) }
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
    if reader === TextReader.shared { FramingAssist.shared.stop() }
    if reader.isActive { reader.stop() }
    reader.dropTorchOffer()
  }

  func handle(transcript: String) -> Bool { ReadTextVoice.handle(transcript, reader: reader) }

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
    .bigTextMirrorCover()
  }

  private func speakStatus() {
    if let line = CameraSourceRouter.shared.phoneStatusLine {
      Announcer.shared.announce(line, earcon: .ready)
    } else if let line = LaunchActionRouter.shared.statusProvider?() {
      Announcer.shared.announce(line, earcon: .ready)
    }
  }
}
