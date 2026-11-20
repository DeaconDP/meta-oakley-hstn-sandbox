/*
 * MacroRunner - runs a macro's steps in order, each as if the user had said it
 *
 * Each step goes through VoiceControl.inject with the address word in front, so it is routed the
 * way speech is: the open tool's own phrases ("read it all"), then the app's commands. The app has
 * no "this command has finished" signal, so the runner waits for what it can observe: a short
 * settle delay (a tool opening, a read starting), then until SpeakUp stops talking and the reader
 * stops reading, up to a cap per step. A step that reads a whole letter therefore finishes before
 * the next starts. Anything the user says while a macro runs cancels the rest (WordsEngine).
 */

import Foundation

@MainActor
final class MacroRunner {
  struct Environment {
    /// Run one step, as words said to the app.
    var perform: @MainActor (_ step: String) -> Void
    /// SpeakUp is still doing the last step: talking, or reading.
    var isBusy: @MainActor () -> Bool
    var sleep: @MainActor (_ seconds: Double) async -> Void
  }

  /// After a step, before checking whether it is still busy: long enough for a tool to start
  /// its first line or a read to begin.
  static let settleDelay: Double = 0.6
  static let pollInterval: Double = 0.2
  /// The longest one step is waited for. A long letter read aloud can take minutes.
  static let maxWaitPerStep: Double = 300

  private let environment: Environment
  private var task: Task<Void, Never>?
  private var runID = 0
  /// Steps performed so far, for tests and logs.
  private(set) var performed: [String] = []

  var isRunning: Bool { task != nil }

  init(environment: Environment) {
    self.environment = environment
  }

  /// Runs `macro` from its first step, cancelling one already running.
  func run(_ macro: WordMacro) {
    cancel()
    performed = []
    runID += 1
    let id = runID
    let environment = environment
    task = Task { [weak self] in
      for (index, step) in macro.steps.enumerated() {
        if Task.isCancelled { break }
        if index > 0 { await Self.waitUntilIdle(environment) }
        if Task.isCancelled { break }
        self?.performed.append(step)
        environment.perform(step)
      }
      if self?.runID == id { self?.task = nil }
    }
  }

  /// Waits for the run to end. For tests and the launch path.
  func wait() async {
    await task?.value
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  private static func waitUntilIdle(_ environment: Environment) async {
    await environment.sleep(settleDelay)
    var waited = settleDelay
    while environment.isBusy(), waited < maxWaitPerStep, !Task.isCancelled {
      await environment.sleep(pollInterval)
      waited += pollInterval
    }
  }
}
