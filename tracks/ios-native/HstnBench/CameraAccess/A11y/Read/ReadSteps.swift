/*
 * ReadSteps - "read me the next step" for recipes and manuals, in Read text
 *
 * Every page TextReader reads (camera, cloud or imported) is handed here as text. StepSplitter
 * finds its steps. Then "next step", "previous step", "repeat step", "what step am I on" and "how
 * many steps" work from memory: no camera, as long as the user's hands are busy. The place is
 * kept until a different page with text is read (a failed read, or reading the same steps again,
 * keeps it).
 *
 * Steps are said as printed, through ReadSpeech, so a dose or an amount the recognizer wasn't sure
 * of is still withheld. A step printed without a number gets "Step 3." before it. Steps use the
 * phone's voice, also when pages are read with the natural voice.
 *
 * ReadTextPhrases maps what was said to a Read text command (steps and big text), for
 * ReadTextTool.handle. These phrases are Read text's own, not the app's grammar.
 */

import Foundation
import Observation

@MainActor
@Observable
final class ReadSteps {
  struct Step: Equatable {
    /// As printed, marker included.
    var printed: String
    /// What is said, chunk by chunk.
    var rendered: RenderedSentence
  }

  private(set) var steps: [Step] = []
  private(set) var navigator = StepNavigator(count: 0)
  /// A step has been asked for since this page was read. The mirror and the card show the step.
  private(set) var isActive = false
  /// A page has been read (with or without steps).
  private(set) var hasPage = false

  @ObservationIgnored private weak var reader: TextReader?
  @ObservationIgnored var announcer: Announcer = .shared
  /// Bumped per step spoken, so a late completion does nothing.
  @ObservationIgnored private var generation = 0

  init(reader: TextReader?) {
    self.reader = reader
  }

  /// The reader whose pages these are (TextReader.init).
  func attach(_ reader: TextReader) {
    self.reader = reader
  }

  var currentStep: Step? {
    guard isActive, let index = navigator.index, steps.indices.contains(index) else { return nil }
    return steps[index]
  }

  /// "Step 2 of 6", or "6 steps".
  var statusText: String? {
    guard !steps.isEmpty else { return nil }
    if isActive, let index = navigator.index { return "Step \(index + 1) of \(steps.count)" }
    return "\(steps.count) steps found"
  }

  // MARK: Pages

  /// A page's text, from TextReader. `words` are the page's words in the same order, with how
  /// sure the recognizer was of each (StepPageText).
  func pageRead(text: String, words: [ReadWord]) {
    let printed = StepSplitter.steps(in: text)
    let preferences = A11yPreferences.shared
    var cursor = 0
    let newSteps = printed.map { step -> Step in
      let stepWords = StepPageText.words(of: StepSplitter.spokenText(step), in: words, cursor: &cursor)
      let rendered = ReadSpeech.render(stepWords, verbosity: preferences.verbosity, earconsEnabled: preferences.earconsEnabled)
      return Step(printed: step, rendered: rendered)
    }
    hasPage = true
    // The same steps read again: keep the place.
    if !newSteps.isEmpty, newSteps.map(\.printed) == steps.map(\.printed) { return }
    steps = newSteps
    navigator = StepNavigator(count: newSteps.count)
    isActive = false
    BenchClock.shared.note("read steps=\(newSteps.count)")
  }

  /// A new read started: plain "next" means sentences again. The place in the steps is kept.
  func leaveStepMode() {
    if isActive { isActive = false }
  }

  /// Forget the page (tests).
  func reset() {
    steps = []
    navigator = StepNavigator(count: 0)
    isActive = false
    hasPage = false
  }

  // MARK: Commands

  func perform(_ command: ReadTextPhrases.StepCommand) {
    guard hasPage else { return say(SpokenMessage.stepsNothingRead) }
    guard !steps.isEmpty else { return say(SpokenMessage.stepsNone) }
    switch command {
    case .next: move(navigator.next())
    case .previous: move(navigator.previous())
    case .repeatStep: move(navigator.repeatStep())
    case .first: move(navigator.go(to: 1))
    case .number(let number): move(navigator.go(to: number))
    case .whichStep:
      if let index = navigator.index {
        say(SpokenMessage.stepPosition(index, of: steps.count))
      } else {
        say(SpokenMessage.stepsNotStarted(steps.count))
      }
    case .howMany:
      say(SpokenMessage.stepsCount(steps.count))
    case .howManyLeft:
      say(navigator.index == nil ? SpokenMessage.stepsCount(steps.count) : SpokenMessage.stepsLeft(navigator.remaining))
    }
  }

  private func move(_ move: StepNavigator.Move) {
    switch move {
    case .step(let index):
      speak(index, lead: nil)
    case .atFirst:
      speak(0, lead: SpokenMessage.stepFirst)
    case .pastLast:
      isActive = true
      say(SpokenMessage.stepLast)
    case .noSteps:
      say(SpokenMessage.stepsNone)
    }
  }

  private func speak(_ index: Int, lead: String?) {
    guard steps.indices.contains(index) else { return }
    isActive = true
    reader?.quietForOtherSpeech()
    generation += 1
    let step = steps[index]
    var first = true
    func line(_ text: String, earcon: Earcon? = nil, flagged: Bool = false) {
      let interrupt = first
      first = false
      if flagged {
        announcer.announce(text, earcon: .uncertain, kind: .reply, interrupt: interrupt)
      } else if let earcon {
        announcer.announce(text, earcon: earcon, kind: .reply, interrupt: interrupt)
      } else {
        announcer.say(text, kind: .reply, interrupt: interrupt)
      }
    }
    if let lead { line(lead, earcon: .attention) }
    if !StepSplitter.isNumberedInPrint(step.printed) { line(SpokenMessage.stepLabel(index), earcon: lead == nil ? .ready : nil) }
    for chunk in step.rendered.chunks { line(chunk.text, flagged: chunk.flagged) }
    reader?.recentText.setCurrent(TextReader.spokenText(step.rendered), source: .read)
  }

  private func say(_ text: String) {
    announcer.say(text, kind: .reply)
  }
}

// MARK: - Read text's voice

/// What ReadTextTool.handle does with a transcript. True when Read text used it.
@MainActor
enum ReadTextVoice {
  static func handle(_ transcript: String, reader: TextReader, mirror: BigTextMirror = .shared) -> Bool {
    if let command = ReadTextPhrases.command(for: transcript) {
      switch command {
      case .step(let step):
        reader.steps.perform(step)
        return true
      case .bigTextOn:
        mirror.show()
        return true
      case .bigTextOff:
        guard mirror.isShown else { return false }
        mirror.hide()
        return true
      case .yes:
        guard reader.torchOfferPending else { return false }
        reader.acceptTorchOffer()
        return true
      case .no:
        guard reader.torchOfferPending else { return false }
        reader.declineTorchOffer()
        return true
      }
    }
    // In step mode the plain words move through the steps.
    if reader.steps.isActive, let step = ReadTextPhrases.stepModeCommand(for: transcript) {
      reader.steps.perform(step)
      return true
    }
    return false
  }
}

// MARK: - Read text's own phrases

/// What Read text does with a transcript: steps, big text, and the torch offer. Pure.
enum ReadTextPhrases {
  enum StepCommand: Equatable {
    case next
    case previous
    case repeatStep
    case first
    case number(Int)
    case whichStep
    case howMany
    case howManyLeft
  }

  enum Command: Equatable {
    case step(StepCommand)
    case bigTextOn
    case bigTextOff
    case yes
    case no
  }

  static let phrases: [String: Command] = {
    var table: [String: Command] = [:]
    func add(_ command: Command, _ list: [String]) { for phrase in list { table[phrase] = command } }
    add(.step(.next), [
      "next step", "read me the next step", "read the next step", "whats the next step", "what is the next step",
      "go to the next step", "next instruction", "the next step", "next step please", "and the next step",
    ])
    add(.step(.previous), [
      "previous step", "last step", "go back a step", "back a step", "step back", "the step before", "go to the previous step",
      "read the previous step", "read me the previous step",
    ])
    add(.step(.repeatStep), [
      "repeat step", "repeat the step", "repeat that step", "repeat this step", "say the step again", "read the step again",
      "this step again", "read this step", "read me this step", "what was that step",
    ])
    add(.step(.first), [
      "steps", "read the steps", "read me the steps", "step mode", "first step", "go to the first step", "start the steps",
      "read me the first step", "read the first step", "start from the first step",
    ])
    add(.step(.whichStep), [
      "what step am i on", "which step am i on", "what step is this", "which step is this", "where am i in the steps", "which step",
      "what step",
    ])
    add(.step(.howMany), ["how many steps", "how many steps are there", "count the steps", "how many steps is it"])
    add(.step(.howManyLeft), ["how many steps left", "how many steps are left", "how many more steps", "steps left"])
    add(.bigTextOn, [
      "big text", "big text on", "show big text", "open big text", "large text", "large text on", "large print", "big print",
      "show large text", "make it big", "bigger text",
    ])
    add(.bigTextOff, [
      "big text off", "close big text", "hide big text", "large text off", "large print off", "close large text", "small text",
      "normal text", "exit big text",
    ])
    add(.yes, ["yes", "yeah", "yep", "yes please", "ok", "okay", "sure", "go on then"])
    add(.no, ["no", "nope", "no thanks", "not now"])
    return table
  }()

  private static let numberWords = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "for": 4, "to": 2, "too": 2,
  ]

  private static let leading: [[String]] = [["can", "you"], ["could", "you"], ["please"], ["just"], ["now"], ["ok"], ["okay"], ["so"]]
  private static let trailing: [[String]] = [["please"], ["thanks"], ["thank", "you"], ["for", "me"]]

  /// The command for `transcript`, or nil when it isn't one of Read text's phrases.
  static func command(for transcript: String) -> Command? {
    var tokens = VoiceCommandParser.normalize(transcript)
    while true {
      if tokens.isEmpty { return nil }
      if let command = phrases[tokens.joined(separator: " ")] { return command }
      if let number = stepNumber(tokens) { return .step(.number(number)) }
      if let filler = leading.first(where: { tokens.count > $0.count && Array(tokens.prefix($0.count)) == $0 }) {
        tokens.removeFirst(filler.count)
      } else if let filler = trailing.first(where: { tokens.count > $0.count && Array(tokens.suffix($0.count)) == $0 }) {
        tokens.removeLast(filler.count)
      } else {
        return nil
      }
    }
  }

  /// "step 3", "go to step three", "read step 3".
  private static func stepNumber(_ tokens: [String]) -> Int? {
    var rest = tokens[...]
    for lead in [["go", "to"], ["read"], ["read", "me"], ["skip", "to"], ["jump", "to"]] where rest.starts(with: lead) {
      rest = rest.dropFirst(lead.count)
      break
    }
    guard rest.count == 2, rest.first == "step", let word = rest.last else { return nil }
    if let number = Int(word), (1...99).contains(number) { return number }
    return numberWords[word]
  }

  /// With step mode on, the plain words move through the steps instead of the sentences.
  static func stepModeCommand(for transcript: String) -> StepCommand? {
    switch VoiceCommandParser.normalize(transcript).joined(separator: " ") {
    case "next", "continue", "go on", "carry on", "next one": .next
    case "back", "previous", "go back", "back one": .previous
    case "repeat", "again", "say again", "say that again", "repeat that": .repeatStep
    default: nil
    }
  }
}
