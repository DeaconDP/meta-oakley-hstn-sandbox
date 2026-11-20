/*
 * ClarityCheck - the optional listening check for Clear speech: "which is clearer, A or B?"
 *
 * The same sentence is played twice through the speech bus, A at the current treble lift and B one
 * step away, and the user picks. ClarityLadder (pure, unit-tested) walks up first: while B wins it
 * keeps going up; if A wins straight away it tries one step down instead; it stops when A wins
 * after a move, when "about the same" is said, at the end of the scale, or after four rounds. The
 * result becomes Clear speech's treble (EarsArea.setTrebleGain), which "undo" can put back.
 *
 * Replies are returned to the grammar so the settings router speaks them; the samples are queued
 * just after, so that reply doesn't cut them off.
 */

import Foundation

struct ClarityLadder: Equatable, Sendable {
  enum Choice: Equatable, Sendable {
    case a
    case b
    case same
  }

  static let maxRounds = 4

  let steps: [Float]
  private(set) var index: Int
  private(set) var direction = 1
  private(set) var moved = false
  private(set) var rounds = 0
  private(set) var isDone = false

  init(steps: [Float] = ClearSpeech.trebleSteps, start: Float) {
    self.steps = steps
    index = steps.enumerated().min { abs($0.element - start) < abs($1.element - start) }?.offset ?? 0
    settle()
  }

  var current: Float { steps[index] }

  /// The pair to play now: A is the current setting, B the step being tried. nil when done.
  var pair: (a: Float, b: Float)? {
    guard !isDone else { return nil }
    return (steps[index], steps[index + direction])
  }

  mutating func choose(_ choice: Choice) {
    guard !isDone else { return }
    rounds += 1
    switch choice {
    case .b:
      index += direction
      moved = true
    case .a, .same:
      if moved || direction < 0 || choice == .same {
        isDone = true
        return
      }
      direction = -1
    }
    if rounds >= Self.maxRounds { isDone = true }
    settle()
  }

  /// At the end of the scale: turn round if nothing has moved yet, otherwise stop.
  private mutating func settle() {
    guard !isDone else { return }
    let next = index + direction
    if steps.indices.contains(next) { return }
    if direction > 0, !moved, steps.indices.contains(index - 1) {
      direction = -1
      return
    }
    isDone = true
  }
}

@MainActor
final class ClarityCheck {
  static let shared = ClarityCheck()

  static let sample = "Please check the date on the bottle before you take a sip."

  private(set) var ladder: ClarityLadder?
  var isRunning: Bool { ladder != nil }

  /// Starts the check. Needs the speech bus, since the EQ lives there.
  func start() -> String {
    if SettingsChanges.isLocked() { return AudioCustomisation.lockedMessage }
    guard !SpeechBusSpeaker.shared.isBroken, SpeechBusSpeaker.shared.routing != .off else {
      return "I can't play the comparison on this phone right now, so Clear speech stays as it is."
    }
    ladder = ClarityLadder(start: EarsArea.shared.values.trebleGainDB)
    playPairSoon()
    return "Clear speech check. I'll say a sentence twice, A then B. Then say A or B for the clearer one, or same."
  }

  func answer(_ choice: ClarityLadder.Choice) -> String {
    guard var ladder else { return "There's no check running. Say check clear speech to start one." }
    ladder.choose(choice)
    self.ladder = ladder
    if ladder.isDone { return finish(ladder.current) }
    playPairSoon()
    return choice == .b ? "B. One more." : "A. Let's try the other way."
  }

  func playAgain() -> String {
    guard isRunning else { return "There's no check running." }
    playPairSoon()
    return "Again."
  }

  func cancel() -> String {
    guard isRunning else { return "There's no check running." }
    ladder = nil
    Announcer.shared.stop()
    AudioCustomisation.previewTrebleGainDB = nil
    return "Check cancelled. Clear speech is as it was."
  }

  private func finish(_ gain: Float) -> String {
    ladder = nil
    AudioCustomisation.previewTrebleGainDB = nil
    return EarsArea.shared.setTrebleGain(gain)
  }

  /// After the router has spoken the reply: A, then B, then the question.
  private func playPairSoon() {
    guard let pair = ladder?.pair else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(80))
      guard self.ladder?.pair.map({ $0 == pair }) == true else { return }
      let announcer = Announcer.shared
      AudioCustomisation.previewTrebleGainDB = pair.a
      announcer.say("A. \(Self.sample)", kind: .reply, interrupt: false) { finished in
        guard finished, self.isRunning else { return AudioCustomisation.previewTrebleGainDB = nil }
        AudioCustomisation.previewTrebleGainDB = pair.b
        announcer.say("B. \(Self.sample)", kind: .reply, interrupt: false) { finished in
          AudioCustomisation.previewTrebleGainDB = nil
          guard finished, self.isRunning else { return }
          announcer.say("Which is clearer, A or B?", kind: .reply, interrupt: false)
        }
      }
    }
  }
}
