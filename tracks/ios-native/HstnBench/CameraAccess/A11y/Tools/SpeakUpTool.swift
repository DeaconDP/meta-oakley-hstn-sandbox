/*
 * SpeakUpTool - the seam every everyday tool plugs into (phone first, glasses optional)
 *
 * iOS started with one tool, Read text. The Android app has six (notes/tools-layer.md). Each iOS
 * port lives in its own folder under A11y/Tools/<Tool>/ and conforms to SpeakUpTool, so the
 * tools home, voice routing, App Intents and the glasses all reach every tool the same way.
 *
 * A tool gets frames from a ReadFrameSource, which is CameraSourceRouter in the app: the
 * iPhone's camera by default, the glasses when linked. A tool never imports MWDAT, so every tool
 * ships in the store build without the DAT SDK.
 *
 * Rules that carry over from ROADMAP.md > Ground rules: every action plays an earcon, failures are
 * spoken, the tool says "can't tell" rather than guess, money and medicine doses are never guessed,
 * and nothing leaves the phone unless the user asks.
 */

import SwiftUI

/// Every tool, in the order the tools home lists them.
enum ToolID: String, CaseIterable, Identifiable, Sendable {
  case read
  case mail
  case labels
  case watch
  case ask
  case light

  var id: String { rawValue }

  /// Name on the tools home, in help and in "open …".
  var title: String {
    switch self {
    case .read: "Read text"
    case .mail: "Mail reader"
    case .labels: "Labels and barcodes"
    case .watch: "Watch for text"
    case .ask: "Ask about the text"
    case .light: "Light and colour"
    }
  }

  /// One plain sentence: the job, not the technology.
  var summary: String {
    switch self {
    case .read: "Reads printed text aloud, word for word."
    case .mail: "Says who a letter is from, what it wants, how much and by when."
    case .labels: "Scans barcodes and reads labels: dates, ingredients, cooking steps."
    case .watch: "Keeps looking and tells you when a word or number appears."
    case .ask: "Answers questions about what was just read."
    case .light: "Tells you if a light is on, and what colour something is."
    }
  }

  var systemImage: String {
    switch self {
    case .read: "text.viewfinder"
    case .mail: "envelope.open"
    case .labels: "barcode.viewfinder"
    case .watch: "eye"
    case .ask: "questionmark.bubble"
    case .light: "lightbulb"
    }
  }

  /// Phrases that open it from anywhere ("open mail reader", "read my mail").
  var openPhrases: [String] {
    switch self {
    case .read: ["open reader", "read text"]
    case .mail: ["open mail reader", "mail reader", "read my mail", "read this letter"]
    case .labels: ["open labels", "labels", "scan a barcode", "read the label"]
    case .watch: ["open watch for text", "watch for text"]
    case .ask: ["open ask", "ask about the text"]
    case .light: ["open light and colour", "light and colour", "is the light on", "what colour is this"]
    }
  }
}

/// What a tool needs from the app. Tools reach speech through Announcer.shared and earcons
/// through EarconPlayer.shared as Read text does; this only carries what differs per run.
@MainActor
protocol SpeakUpTool: AnyObject {
  var toolID: ToolID { get }
  /// Opened: start looking (the source may still be starting). Says what to do first.
  func start(source: ReadFrameSource)
  /// Closed, or another tool opened: stop the camera work and any speech it started.
  func stop()
  /// A transcript while this tool is open. The tool sees it before most global commands (ToolHub,
  /// VoiceControl): only stop, close, main menu, help and the like are taken first. True if the
  /// tool used it.
  func handle(transcript: String) -> Bool
  /// What "help" says while this tool is open.
  var helpLine: String { get }
  /// The tool's panel on the phone screen. Large text, VoiceOver labelled, WCAG 2.2 AA.
  func makePanel() -> AnyView
  /// The app's global "stop" while this tool stays open: quiet the tool's own sound and work
  /// (a tone, a watch loop, an answer). Speech is already cut by then. Default: nothing more.
  func pauseForStop()
}

extension SpeakUpTool {
  func pauseForStop() {}
}
