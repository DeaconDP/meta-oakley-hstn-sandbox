/*
 * LabelsTool - "Labels and barcodes": barcodes first, then the label word for word
 *
 * Port of Android's tools/labels/LabelsViewModel.kt, phone first. Opening the tool starts looking
 * for a barcode in the camera's frames (3 a second, Apple Vision on the phone). Geiger ticks get
 * faster and higher as something barcode-like gets bigger and more central (BarcodeHint); after 5 s
 * with nothing it says "Turn it slowly. Barcodes are usually on the back or bottom.", and after 15 s
 * it reads the label instead. A decode plays the done earcon and a success haptic, and offers "look
 * it up" or "read the label". "Look it up" is the only network call: the barcode number alone goes
 * to Open Food Facts (OpenFoodFacts.swift), results cached on the phone.
 *
 * Reading the label takes a full-resolution photo (the latest frame if the photo fails), runs OCR
 * on the phone (TextRecognizer), checks the text is readable (FramingAdvisor), and reads it word for
 * word, or jumps to the expiry date, cooking instructions, ingredients or allergens. Each jump takes
 * a fresh photo (the user may have turned the pack) and searches every side seen so far, newest
 * first. Medicine (MedicineCheck: label words or the Open Food Facts category) gets its name and its
 * date only (the date only when read clearly, always with a reminder); anything about doses gets
 * "I won't read medicine doses...". Medicine label text is never shown on screen.
 * Every action plays an earcon; every failure is spoken. See notes/labels-and-light-ios.md.
 */

import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class LabelsTool: SpeakUpTool {
  enum Phase: Equatable, Sendable {
    case idle
    case searching
    case found
    case lookingUp
    case reading
  }

  /// One side of the pack as read: lines in reading order, and paragraphs (OCR blocks) for reading.
  struct LabelView: Sendable {
    var lines: [LabelLine]
    var paragraphs: [String]
    var text: String { lines.map(\.text).joined(separator: "\n") }
  }

  let toolID = ToolID.labels

  private(set) var phase: Phase = .idle
  private(set) var code: ScannedCode?
  /// "Snickers, by Mars..., 50 grams." after a lookup. For medicine, its name only.
  private(set) var productSummary: String?
  /// The newest side's text, or nil. Never set for medicine.
  private(set) var labelText: String?
  private(set) var isMedicine = false
  /// For medicine: the name only.
  private(set) var medicineName: String?
  /// The last line spoken, for the screen. Never a medicine dose: the tool never speaks one.
  private(set) var lastLine = ""

  // Timing, as on Android (the frame rate is a little higher: Vision on a phone is quick).
  static let searchInterval: Duration = .milliseconds(333)
  static let turnHintAfter: TimeInterval = 5
  static let giveUpAfter: TimeInterval = 15
  static let workingTickEvery: TimeInterval = 2

  private static let owner = "labels"

  @ObservationIgnored private weak var source: (any ReadFrameSource)?
  @ObservationIgnored private let productSource: any ProductSource
  @ObservationIgnored private let today: () -> CivilDate
  @ObservationIgnored private let tones: ToolTonePlayer
  @ObservationIgnored private let announcer = Announcer.shared
  @ObservationIgnored private let earcons = EarconPlayer.shared
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var workTask: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var product: OffProduct?
  @ObservationIgnored private var views: [LabelView] = []
  /// Bumped by every command and stop, so late work from before does nothing.
  @ObservationIgnored private var generation = 0

  /// `productSource` is where "look it up" goes (Open Food Facts; tests pass a fake). `today` decides
  /// whether a date has passed.
  init(
    productSource: any ProductSource = OpenFoodFactsSource(),
    today: @escaping () -> CivilDate = { CivilDate.today() },
    tones: ToolTonePlayer = .shared
  ) {
    self.productSource = productSource
    self.today = today
    self.tones = tones
  }

  // MARK: SpeakUpTool

  var helpLine: String { LabelsSpeech.help }

  func start(source: any ReadFrameSource) {
    self.source = source
    startScan(announce: true)
  }

  func stop() {
    stopAll()
    announcer.stop()
    phase = code != nil ? .found : .idle
  }

  func handle(transcript: String) -> Bool {
    guard let command = LabelsGrammar.parse(transcript) else { return false }
    perform(command)
    return true
  }

  func makePanel() -> AnyView { AnyView(LabelsPanel(tool: self)) }

  // MARK: Commands (voice and buttons)

  func perform(_ command: LabelsCommand) {
    switch command {
    case .scan: startScan(announce: true)
    case .stopScan:
      stopAll()
      phase = code != nil ? .found : .idle
      reply(LabelsSpeech.stopped, earcon: .ready)
    case .lookUp: lookUp()
    case .readLabel: withFreshView { $0.readAll() }
    case .readAll:
      if views.isEmpty {
        withFreshView { $0.readAll() }
      } else {
        readAll()
      }
    case .expiry: withFreshView { $0.reply($0.expiryAnswer(), earcon: .done) }
    case .cooking: sectionCommand(.cooking)
    case .ingredients: sectionCommand(.ingredients)
    case .allergens(let query):
      if isMedicine { return refuseMedicine() }
      withFreshView(productIsEnough: product != nil) { tool in
        tool.isMedicine ? tool.refuseMedicine() : tool.allergenAnswer(query)
      }
    case .name: reply(nameAnswer(), earcon: .done)
    case .dose:
      stopAll()
      reply(LabelsSpeech.medicineDose, earcon: .attention)
    }
  }

  private func sectionCommand(_ section: LabelSection) {
    if isMedicine { return refuseMedicine() }
    withFreshView { tool in tool.isMedicine ? tool.refuseMedicine() : tool.sectionAnswer(section) }
  }

  // MARK: Barcode search

  private func startScan(announce: Bool) {
    stopAll()
    code = nil
    product = nil
    productSummary = nil
    views = []
    labelText = nil
    isMedicine = false
    medicineName = nil
    phase = .searching
    guard let source else { return warn("The camera isn't ready yet. Try again in a moment.") }
    earcons.play(.working)
    let myGeneration = generation
    tones.begin(owner: Self.owner)
    scanTask = Task { [weak self] in
      await self?.search(source, announce: announce, myGeneration)
    }
  }

  private func search(_ source: any ReadFrameSource, announce: Bool, _ myGeneration: Int) async {
    defer { if isCurrent(myGeneration) { tones.end(owner: Self.owner) } }
    let wait = await LightLabelKit.waitForStream(source, isCurrent: { isCurrent(myGeneration) }) {
      say("Starting the camera.")
    }
    guard isCurrent(myGeneration) else { return }
    switch wait {
    case .ready: break
    case .blocked, .cancelled:
      phase = .idle
      return
    case .failed(let reason):
      phase = .idle
      return warn(reason)
    }
    if announce { say(LabelsSpeech.searching) }

    let started = Date()
    var lastSound = started
    var turnHintSaid = false
    var barsHintSaid = false
    var barsSeen = 0
    while isCurrent(myGeneration) {
      let tickStarted = ContinuousClock.now
      let now = Date()
      if let frame = source.latestReadFrame, LightLabelKit.age(of: frame) < 1 {
        let image = frame.image
        let (decoded, region) = await Task.detached(priority: .userInitiated) { LabelsVision.scan(image) }.value
        guard isCurrent(myGeneration) else { return }
        if let decoded {
          tones.end(owner: Self.owner)
          return found(decoded)
        }
        if let region {
          barsSeen += 1
          lastSound = now
          geiger(region.closeness)
          if !barsHintSaid, barsSeen >= 4, !announcer.isSpeaking {
            barsHintSaid = true
            say(region.closeness < 0.45 ? LabelsSpeech.barsCloser : LabelsSpeech.barsSteady)
          }
        }
      }
      if now.timeIntervalSince(lastSound) >= Self.workingTickEvery {
        lastSound = now
        earcons.play(.working)
      }
      let elapsed = now.timeIntervalSince(started)
      if !turnHintSaid, elapsed >= Self.turnHintAfter, barsSeen == 0 {
        turnHintSaid = true
        say(LabelsSpeech.turnHint)
      }
      if elapsed >= Self.giveUpAfter {
        tones.end(owner: Self.owner)
        scanTask = nil
        LightLabelKit.haptic(.failed)
        announcer.announce(LabelsSpeech.noBarcode, earcon: .error, kind: .reply, interrupt: true)
        lastLine = LabelsSpeech.noBarcode
        withFreshView(keepSpeech: true) { $0.readAll() }
        return
      }
      try? await Task.sleep(until: tickStarted + Self.searchInterval, clock: .continuous)
    }
  }

  /// Geiger-style: 1 to 4 short ticks in the interval until the next frame, higher when closer.
  private func geiger(_ closeness: Double) {
    let (count, hz) = BarcodeHint.ticks(for: closeness)
    let spacing = Duration.milliseconds(333 / count)
    tickTask?.cancel()
    tickTask = Task { [tones] in
      for _ in 0..<count {
        guard !Task.isCancelled else { return }
        tones.tick(hz: hz)
        try? await Task.sleep(for: spacing)
      }
    }
  }

  private func found(_ found: ScannedCode) {
    scanTask = nil
    code = found
    phase = .found
    LightLabelKit.haptic(.found)
    let text: String
    switch found.kind {
    case .product: text = LabelsSpeech.foundProduct
    case .qr: text = LabelCodes.describeQr(found.raw) + " " + LabelsSpeech.qrMore
    case .other: text = LabelsSpeech.foundOther(LabelCodes.spokenDigits(String(found.raw.prefix(24))))
    }
    reply(text, earcon: .done)
  }

  // MARK: Product lookup (the only network call)

  private func lookUp() {
    if code == nil, scanTask != nil { return reply(LabelsSpeech.stillSearching, earcon: .attention) }
    guard let code else { return reply(LabelsSpeech.noCodeYet, earcon: .attention) }
    guard let lookupCode = code.productCode else { return reply(LabelsSpeech.notProduct, earcon: .attention) }
    stopAll()
    let myGeneration = generation
    phase = .lookingUp
    reply(LabelsSpeech.lookingUp, earcon: .working)
    earcons.startWorkingTick(owner: Self.owner)
    let productSource = productSource
    workTask = Task { [weak self] in
      let result = await productSource.lookup(lookupCode)
      guard let self, self.isCurrent(myGeneration) else { return }
      self.earcons.stopWorkingTick(owner: Self.owner)
      self.phase = .found
      switch result {
      case .found(let product, _): self.productFound(product)
      case .notFound: self.warn(LabelsSpeech.notFound)
      case .offline: self.warn(LabelsSpeech.offline)
      case .failed: self.warn(LabelsSpeech.lookupFailed)
      }
    }
  }

  private func productFound(_ p: OffProduct) {
    product = p
    if MedicineCheck.looksLikeMedicine(p.name ?? "", categoryTags: p.categoryTags) { markMedicine(p.name) }
    if isMedicine {
      let name = medicineName ?? "a medicine"
      productSummary = name
      return reply(LabelsSpeech.medicineName(name) + " " + LabelsSpeech.medicineDose, earcon: .done)
    }
    let summary = p.summary()
    productSummary = summary
    reply(summary + " " + LabelsSpeech.lookupMore, earcon: .done)
  }

  // MARK: Reading the label

  /// Takes a fresh photo, reads it and adds it to the sides seen, then runs `then`. If the camera
  /// can't give a picture but something is already known (`productIsEnough` or a side read
  /// before), `then` answers from that.
  private func withFreshView(productIsEnough: Bool = false, keepSpeech: Bool = false, then: @escaping @MainActor (LabelsTool) -> Void) {
    stopAll()
    guard let source else {
      if !views.isEmpty || productIsEnough { return then(self) }
      return warn("The camera isn't ready yet. Try again in a moment.")
    }
    let myGeneration = generation
    phase = .reading
    if views.isEmpty {
      if keepSpeech {
        earcons.play(.working)
      } else {
        reply(LabelsSpeech.reading, earcon: .working)
      }
    } else {
      earcons.play(.working)
    }
    earcons.startWorkingTick(owner: Self.owner)
    workTask = Task { [weak self] in
      guard let self else { return }
      let problem = await self.readFreshView(source, myGeneration)
      guard self.isCurrent(myGeneration) else { return }
      self.earcons.stopWorkingTick(owner: Self.owner)
      self.phase = self.code != nil ? .found : .idle
      if let problem, self.views.isEmpty, !productIsEnough {
        self.warn(problem)
      } else {
        then(self)
      }
    }
  }

  /// One photo, OCR and the framing check. nil when a side was added; otherwise what to say.
  private func readFreshView(_ source: any ReadFrameSource, _ myGeneration: Int) async -> String? {
    let wait = await LightLabelKit.waitForStream(source, isCurrent: { isCurrent(myGeneration) }) {
      say("Starting the camera.")
    }
    guard isCurrent(myGeneration) else { return nil }
    switch wait {
    case .ready: break
    case .blocked, .cancelled: return LabelsSpeech.captureFailed
    case .failed(let reason): return reason
    }
    var captured = await source.captureStillForReading()
    guard isCurrent(myGeneration) else { return nil }
    if captured == nil { captured = await LightLabelKit.recentFrame(source)?.image }
    guard let image = captured, isCurrent(myGeneration) else { return LabelsSpeech.captureFailed }
    let result = await Task.detached(priority: .userInitiated) { () -> Result<RecognizedFrame, any Error> in
      Result { try TextRecognizer.recognize(image) }
    }.value
    guard isCurrent(myGeneration) else { return nil }
    guard case .success(let recognized) = result else { return LabelsSpeech.ocrFailed }
    let verdict = FramingAdvisor.assess(recognized.page, quality: recognized.quality)
    switch verdict {
    case .tooDark: return LabelsSpeech.tooDark(source.cameraKind)
    case .tooBlurry: return LabelsSpeech.blurred
    case .tooSmall: return LabelsSpeech.textSmall
    case .noText: return LabelsSpeech.noText(source.cameraKind)
    case .good, .cutOff: break
    }
    guard addView(recognized.page) else { return LabelsSpeech.noText(source.cameraKind) }
    return nil
  }

  /// Adds a side. False if it held no text.
  private func addView(_ page: ReadPage) -> Bool {
    let blocks = ReadingOrder.blocks(page.lines)
    let lines = blocks.flatMap { $0 }.compactMap { line -> LabelLine? in
      let text = LabelsString.trimmed(line.text)
      guard !text.isEmpty else { return nil }
      return LabelLine(text: text, height: Double(line.box.height), confidence: line.words.map(\.confidence).min())
    }
    guard !lines.isEmpty else { return false }
    let paragraphs = blocks.map { block in block.map { LabelsString.trimmed($0.text) }.joined(separator: " ") }.filter { !$0.isEmpty }
    let view = LabelView(lines: lines, paragraphs: paragraphs)
    views.append(view)
    if !isMedicine, MedicineCheck.looksLikeMedicine(view.text, categoryTags: product?.categoryTags ?? []) {
      markMedicine(product?.name ?? LabelText.nameGuess(lines))
    }
    // Nothing from a medicine label is shown or kept on screen beyond its name.
    labelText = isMedicine ? nil : view.text
    return true
  }

  private func markMedicine(_ name: String?) {
    isMedicine = true
    medicineName = MedicineCheck.nameOnly(name ?? "")
    labelText = nil
  }

  /// Word for word, newest side. Medicine: the name and the refusal, nothing else.
  private func readAll() {
    if isMedicine { return refuseMedicine() }
    guard let view = views.last else { return reply(LabelsSpeech.noText(source?.cameraKind ?? .phone), earcon: .attention) }
    speakAll(view.paragraphs + [LabelsSpeech.readMore])
  }

  private func sectionAnswer(_ section: LabelSection) {
    if let text = views.reversed().lazy.compactMap({ LabelText.section($0.lines, section) }).first {
      let head: String
      switch section {
      case .ingredients: head = "Ingredients: "
      case .cooking: head = "Cooking instructions: "
      case .allergens: head = "Allergy advice: "
      }
      return speakAll([head + text])
    }
    if section == .ingredients, let ingredients = product?.ingredients {
      return speakAll([LabelsSpeech.ingredientsFromOff(ingredients)])
    }
    switch section {
    case .ingredients: reply(LabelsSpeech.noIngredients, earcon: .attention)
    case .cooking: reply(LabelsSpeech.noCooking, earcon: .attention)
    case .allergens: reply(LabelsSpeech.noAllergens, earcon: .attention)
    }
  }

  private func allergenAnswer(_ query: String?) {
    let allLines = views.reversed().flatMap(\.lines)
    guard let query else {
      if let summary = LabelText.allergenSummary(allLines.isEmpty ? nil : allLines, product: product) {
        return reply(summary, earcon: .done)
      }
      return reply(LabelsSpeech.noAllergens, earcon: .attention)
    }
    let label = views.isEmpty ? nil : allLines.map(\.text).joined(separator: "\n")
    reply(LabelText.allergenAnswer(query, label: label, product: product), earcon: .done)
  }

  /// "When does it expire". Medicine: only a clearly read date, always with the reminder.
  func expiryAnswer() -> String {
    let today = today()
    let lines = views.reversed().flatMap(\.lines)
    let plain = LabelDates.answer(LabelDates.find(lines.map(\.text).joined(separator: "\n"), today: today), today: today)
    guard isMedicine else { return plain ?? LabelsSpeech.noExpiry }
    // The lines the date is on: any line with a date or a date keyword, and the line after a
    // keyword (the date often sits below).
    let dateLines = lines.indices.filter { i in
      !LabelDates.find(lines[i].text, today: today).dates.isEmpty
        || (i > 0 && LabelDates.find(lines[i - 1].text, today: today).keywordWithoutDate != nil)
    }
    return MedicineCheck.expiry(plain, dateLineConfidences: dateLines.map { lines[$0].confidence }) ?? LabelsSpeech.noExpiry
  }

  private func nameAnswer() -> String {
    if isMedicine { return LabelsSpeech.medicineName(medicineName ?? "a medicine") }
    if let product { return product.summary() }
    if let view = views.last {
      return LabelText.nameGuess(view.lines).map(LabelsSpeech.nameLabel) ?? LabelsSpeech.noName
    }
    return LabelsSpeech.noName
  }

  private func refuseMedicine() {
    reply(
      LabelsSpeech.medicineName(medicineName ?? "a medicine") + " " + LabelsSpeech.medicineOnlyName + " " + LabelsSpeech.medicineDose,
      earcon: .attention)
  }

  // MARK: Speaking

  private static let sentenceBreak = LabelsRegex("(?<=[.!?])\\s+(?=\\S)")

  /// The first sentence cuts off what's playing; the rest queue behind it. "Stop" drops them all.
  private func speakAll(_ parts: [String]) {
    let chunks = parts.flatMap { part in
      Self.sentenceBreak.replace(in: part) { _ in "\n" }.split(separator: "\n").map { LabelsString.trimmed(String($0)) }
    }.filter { !$0.isEmpty }
    guard let first = chunks.first else { return }
    lastLine = first
    announcer.announce(first, earcon: .done, kind: .reply, interrupt: true)
    for chunk in chunks.dropFirst() { announcer.say(chunk, kind: .reply, interrupt: false) }
  }

  private func reply(_ text: String, earcon: Earcon) {
    lastLine = text
    announcer.announce(text, earcon: earcon, kind: .reply, interrupt: true)
  }

  /// A progress line that doesn't cut what's playing.
  private func say(_ text: String) {
    lastLine = text
    announcer.say(text, kind: .reply, interrupt: false)
  }

  private func warn(_ text: String) {
    LightLabelKit.haptic(.failed)
    reply(text, earcon: .error)
  }

  private func stopAll() {
    generation += 1
    scanTask?.cancel()
    scanTask = nil
    workTask?.cancel()
    workTask = nil
    tickTask?.cancel()
    tickTask = nil
    tones.end(owner: Self.owner)
    earcons.stopWorkingTick(owner: Self.owner)
  }

  private func isCurrent(_ myGeneration: Int) -> Bool { myGeneration == generation && !Task.isCancelled }

  // MARK: For tests

  /// Feeds an OCR'd side as if photographed (unit tests; no camera in the Simulator).
  func addViewForTesting(_ lines: [LabelLine]) {
    views.append(LabelView(lines: lines, paragraphs: lines.map(\.text)))
    let text = lines.map(\.text).joined(separator: "\n")
    if !isMedicine, MedicineCheck.looksLikeMedicine(text, categoryTags: product?.categoryTags ?? []) {
      markMedicine(product?.name ?? LabelText.nameGuess(lines))
    }
    labelText = isMedicine ? nil : text
  }
}
