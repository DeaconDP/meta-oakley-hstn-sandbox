/*
 * AskAboutTextTests - Ask about the text's pure parts, ported from Android's JVM tests
 *
 * AskGrammarTest: each kind of question, gated follow-ups, "find me" left to Watch, room chatter.
 * DictionaryTest: the bundled WordNet file (the same bytes Android ships), exact lookups, sense
 * order, irregular forms, inflections and British / American spellings, lookup speed.
 * TextToolsTest: sentences, read-so-far, the "last time" tail, sound-alike names, mentions,
 * search, recap. OnDeviceAskTest: whole questions with follow-ups on the real dictionary and the
 * Conan Doyle and Wells fixture pages. ClaudeAskTest became the OpenAI request and reply checks.
 * Plus RecentText, the store other tools publish to.
 */

@testable import CameraAccess
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

/// The fixture text, as the reader would publish it (BookFixtures on Android).
private enum AskFixtures {
  static let houndPage = [
    "Mr. Sherlock Holmes, who was usually very late in the mornings, save upon those not infrequent occasions when he was up all night, was seated at the breakfast table. I stood upon the hearth-rug and picked up the stick which our visitor had left behind him the night before. It was a fine, thick piece of wood, bulbous-headed, of the sort which is known as a \"Penang lawyer.\"",
    "\"Well, Watson, what do you make of it?\"",
    "Holmes was sitting with his back to me, and I had given him no sign of my occupation.",
  ].joined(separator: "\n\n")

  static let timePage = [
    "The Time Traveller (for so it will be convenient to speak of him) was expounding a recondite matter to us. His grey eyes shone and twinkled, and his usually pale face was flushed and animated.",
    "\"You must follow me carefully. I shall have to controvert one or two ideas that are almost universally accepted. The geometry, for instance, they taught you at school is founded on a misconception. It is extraordinarily simple, and you will soon admit as much on reasonable grounds.\"",
    "\"Is not that rather a large thing to expect us to begin upon?\" said Filby, an argumentative person with red hair.",
    "\"I do not mean to ask you to accept anything without reasonable ground for it. You will soon admit as much as I need from you.\"",
  ].joined(separator: "\n\n")

  static let houndNextPage =
    "\"How did you know what I was doing? I believe you have eyes in the back of your head.\"\n\n"
    + "\"I have, at least, a well-polished, silver-plated coffee-pot in front of me,\" said he. "
    + "\"But, tell me, Watson, what do you make of our visitor's stick? Since we have been so "
    + "unfortunate as to miss him and have no notion of his errand, this accidental souvenir "
    + "becomes of importance. Let me hear you reconstruct the man by an examination of it.\""

  static func snapshot(_ passages: String..., current: String? = nil, source: ToolID = .read) -> RecentText.Snapshot {
    RecentText.Snapshot(source: source, passages: passages, current: current, title: nil, updatedAt: Date())
  }

  static let dictionary: WordNetDictionary = {
    // swiftlint:disable:next force_try
    try! WordNetDictionary.loadBundled()
  }()
}

/// A stand-in for OpenAI that records what it was sent.
private final class FakeOnline: AskOnline, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [(question: String, text: String)] = []
  let reply: AskResult

  init(reply: AskResult) { self.reply = reply }

  var calls: [(question: String, text: String)] { lock.withLock { sent } }

  func ask(question: String, text: String) async -> AskResult {
    lock.withLock { sent.append((question, text)) }
    return reply
  }
}

@MainActor
final class AskAboutTextTests: XCTestCase {
  private let dict = AskFixtures.dictionary
  private var now = Date(timeIntervalSince1970: 1_000_000)

  /// Both Hound pages and the Time Machine page read, the reader on its second sentence.
  private let reading = AskFixtures.snapshot(
    AskFixtures.houndPage, AskFixtures.houndNextPage, AskFixtures.timePage,
    current: "His grey eyes shone and twinkled, and his usually pale face was flushed and animated.")

  private func asker(previous: String? = nil, online: FakeOnline? = nil) -> AskAnswerer {
    let dictionary = dict
    return AskAnswerer(dictionary: { dictionary }, previousSession: { previous }, online: { online })
  }

  private func ask(
    _ a: AskAnswerer, _ question: String, _ snapshot: RecentText.Snapshot?? = .none, carryOn: Bool = true,
    notes: ((String) -> Void)? = nil
  ) async -> AskResult {
    let snap: RecentText.Snapshot? = snapshot ?? reading
    return await a.answer(question, snapshot: snap, offerCarryOn: carryOn) { notes?($0) }
  }

  private func say(_ a: AskAnswerer, _ question: String, _ snapshot: RecentText.Snapshot?? = .none, carryOn: Bool = true) async -> String {
    let result = await ask(a, question, snapshot, carryOn: carryOn)
    guard case .answer(let text) = result else {
      XCTFail("\(question) -> \(result)")
      return ""
    }
    return text
  }

  private func stripHint(_ text: String) -> String {
    text.hasSuffix(" " + AskWording.carryOnHint) ? String(text.dropLast(AskWording.carryOnHint.count + 1)) : text
  }

  // MARK: Grammar

  private func q(_ said: String, _ followUps: AskFollowUps? = nil) -> AskQuestion? {
    AskGrammar.classify(transcript: said, followUps: followUps ?? AskFollowUps())
  }

  private func assertKind(_ kind: AskKind, _ subject: String?, _ phrases: String..., line: UInt = #line) {
    for phrase in phrases {
      let got = q(phrase)
      XCTAssertEqual(got?.kind, kind, phrase, line: line)
      XCTAssertEqual(got?.subject, subject, phrase, line: line)
    }
  }

  func testDefinitions() {
    assertKind(
      .define, "ephemeral", "What does ephemeral mean?", "what does the word ephemeral mean", "define ephemeral",
      "Define the word ephemeral, please", "what's the meaning of ephemeral", "what is the definition of ephemeral",
      "look up ephemeral", "what's ephemeral again", "Glasses, what does ephemeral mean?", "um what does ephemeral mean again")
    assertKind(.define, "penang lawyer", "what does Penang lawyer mean")
    assertKind(.define, "hansom", "what's a hansom", "what is a hansom")
    assertKind(.define, "recon dight", "what does recon dight mean")
  }

  func testSpelling() {
    assertKind(.spell, nil, "spell it", "spell that", "how do you spell it", "how is that spelt", "spell the word")
    assertKind(.spell, "recondite", "spell recondite", "how do you spell recondite", "how is recondite spelled")
  }

  func testWhoAndWhat() {
    assertKind(.who, "mr bennet", "Who is Mr. Bennet?", "who's Mr Bennet", "who was mr bennet again")
    assertKind(.who, "watson", "who's Watson?", "remind me who Watson is")
    assertKind(.what, "time machine", "what's the Time Machine?", "what is the time machine")
    for phrase in ["what's the time", "what is the weather", "what's the date", "who is it from", "who's there", "what's the matter"] {
      XCTAssertNil(q(phrase), phrase)
    }
  }

  func testRecap() {
    for phrase in ["what happened last time", "what happened before", "where did we leave off", "where were we", "where did I stop"] {
      XCTAssertEqual(q(phrase)?.kind, .recap, phrase)
      XCTAssertEqual(q(phrase)?.lastTime, true, phrase)
    }
    for phrase in ["recap", "what happened", "give me a recap", "what happened so far", "remind me what happened", "summarise so far"] {
      XCTAssertEqual(q(phrase)?.kind, .recap, phrase)
    }
  }

  func testFinding() {
    assertKind(
      .find, "the fire", "what did it say about the fire", "what did the book say about the fire",
      "what does it say about the fire", "did it say anything about the fire", "find the fire", "search for the fire",
      "where does it mention the fire", "where was the fire mentioned")
    assertKind(.find, "holmes", "what did Holmes say")
    // "Find me ..." belongs to Watch for text.
    XCTAssertNil(q("find me the exit"))
    XCTAssertEqual(WatchGrammar.opens("find me the exit")?.target, "exit")
  }

  func testOpenQuestions() {
    for phrase in [
      "why did he do that", "why is Holmes sitting with his back to me", "where did they go", "how did he know",
      "what did Filby want", "when did this happen", "does the letter say when it's due",
    ] {
      XCTAssertEqual(q(phrase)?.kind, .open, phrase)
    }
  }

  func testFollowUpsOnlyCountAfterAnAnswerOffersThem() {
    let followUps = AskFollowUps(clock: { [unowned self] in self.now })
    for phrase in ["more", "next", "tell me more", "no", "next match"] { XCTAssertNil(q(phrase, followUps), phrase) }
    followUps.open(more: true, no: false)
    XCTAssertEqual(q("more", followUps)?.kind, .more)
    XCTAssertEqual(q("next", followUps)?.kind, .more)
    XCTAssertEqual(q("other meanings", followUps)?.kind, .more)
    XCTAssertNil(q("no", followUps), "no wasn't offered")
    followUps.open(more: false, no: true)
    XCTAssertEqual(q("no, not that one", followUps)?.kind, .no)
    XCTAssertEqual(q("the other one", followUps)?.kind, .no)
    now = now.addingTimeInterval(AskFollowUps.windowSeconds + 1)
    XCTAssertNil(q("no", followUps), "expired")
    // A partial transcript never counts a follow-up as a question.
    followUps.open(more: true, no: true)
    XCTAssertFalse(AskGrammar.isQuestion("more"))
    XCTAssertTrue(AskGrammar.isQuestion("what does recondite mean"))
    XCTAssertTrue(AskGrammar.isQuestion("who is Holmes"))
    XCTAssertFalse(AskGrammar.isQuestion("what does"))
  }

  func testRoomChatterIsNotAQuestion() {
    for phrase in [
      "turn right at the lights", "I'll have a coffee", "it was a dark and stormy night", "more coffee please",
      "next stop is ours", "no idea", "the bus is late again today", "",
    ] {
      XCTAssertNil(q(phrase), phrase)
    }
  }

  // MARK: Dictionary

  func testDictionaryFileIsCompactCompleteAndLicensed() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "wordnet", withExtension: "wnask"))
    let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    XCTAssertTrue((2_000_000...6_000_000).contains(size), "file is \(size) bytes")
    XCTAssertEqual(dict.lemmaCount, 147_306)
    XCTAssertEqual(dict.definitionCount, 117_659)
    XCTAssertNotNil(Bundle.main.url(forResource: "WordNet-3.0-LICENSE", withExtension: "txt"))
    let raw = try WordNetDictionary.gunzip(Data(contentsOf: url))
    XCTAssertTrue(String(decoding: raw.prefix(2_000), as: UTF8.self).contains("WordNet 3.0 Copyright 2006 by Princeton"))
    XCTAssertThrowsError(try WordNetDictionary.gunzip(Data("not gzip at all, really not".utf8)))
  }

  func testExactLookups() throws {
    let recondite = try XCTUnwrap(dict.entry("recondite"))
    XCTAssertEqual(recondite.parts, ["a"])
    XCTAssertTrue(dict.senses(recondite).first?.gloss.hasPrefix("difficult to penetrate") == true)
    let ephemeral = try XCTUnwrap(dict.entry("ephemeral"))
    XCTAssertTrue(ephemeral.parts.contains("a"))
    XCTAssertEqual(dict.senses(ephemeral, posOrder: ["a"]).first?.gloss, "lasting a very short time")
    XCTAssertNotNil(dict.entry("Time Machine"))
    XCTAssertFalse(dict.senses(try XCTUnwrap(dict.entry("dog"))).contains { $0.gloss.contains("\"") })
    XCTAssertNil(dict.entry("penang lawyer"))
    XCTAssertNil(dict.entry("recondight"))
    XCTAssertNil(dict.entry(""))
    XCTAssertNil(dict.entry("zzzzzz"))
    XCTAssertTrue(dict.contains("aardvark"))
    XCTAssertTrue(dict.contains("zymurgy"))
  }

  func testSenseOrderFollowsWordNet() throws {
    let dog = try XCTUnwrap(dict.entry("dog"))
    XCTAssertEqual(dog.parts, ["n", "v"])
    XCTAssertTrue(dict.senses(dog).first?.gloss.contains("domesticated") == true)
    XCTAssertEqual(dog.senseCount("n"), 7)
  }

  func testIrregularForms() {
    XCTAssertTrue(dict.irregular("mice").contains(.init(pos: "n", base: "mouse")))
    XCTAssertTrue(dict.irregular("went").contains(.init(pos: "v", base: "go")))
    XCTAssertTrue(dict.irregular("dog").isEmpty)
  }

  private func assertLemma(_ word: String, _ lemma: String, _ pos: Character? = nil, line: UInt = #line) {
    let got = AskLemmatiser(dictionary: dict).lemmas(word)
    XCTAssertTrue(got.contains { $0.lemma == lemma }, "\(word) -> \(got), wanted \(lemma)", line: line)
    if let pos { XCTAssertEqual(got.first { $0.lemma == lemma }?.pos, pos, "\(word) pos", line: line) }
  }

  func testInflections() {
    assertLemma("expounding", "expound", "v")
    assertLemma("expounded", "expound", "v")
    assertLemma("travellers", "traveller", "n")
    assertLemma("travelled", "travel", "v")
    assertLemma("traveling", "travel", "v")
    assertLemma("stopped", "stop", "v")
    assertLemma("mice", "mouse", "n")
    assertLemma("went", "go", "v")
    assertLemma("happier", "happy", "a")
    assertLemma("finest", "fine", "a")
    assertLemma("boxes", "box", "n")
    assertLemma("churches", "church", "n")
    assertLemma("ladies", "lady", "n")
    assertLemma("controverted", "controvert", "v")
    assertLemma("misconceptions", "misconception", "n")
    assertLemma("argumentatively", "argumentative", "a")
    assertLemma("Holmes's", "holmes")
    assertLemma("visitor's", "visitor")
    assertLemma("hearth-rug", "hearthrug")
    let lemmatiser = AskLemmatiser(dictionary: dict)
    XCTAssertEqual(lemmatiser.lemma("recondite")?.lemma, "recondite", "as written comes first")
    XCTAssertEqual(lemmatiser.lemma("twinkled")?.lemma, "twinkle")
  }

  func testBritishAndAmericanSpellings() {
    assertLemma("colour", "color")
    assertLemma("colours", "color")
    assertLemma("honour", "honor")
    assertLemma("realised", "realize", "v")
    assertLemma("realise", "realize")
    assertLemma("organisation", "organization")
    assertLemma("analyse", "analyze")
    assertLemma("centre", "center")
    assertLemma("theatres", "theater")
    assertLemma("counsellor", "counselor")
    assertLemma("anaemia", "anemia")
    assertLemma("catalogue", "catalog")
    assertLemma("defence", "defense")
    assertLemma("grey", "grey")
    assertLemma("gray", "grey")
    assertLemma("programme", "program")
    assertLemma("traveler", "traveller")
  }

  func testNonWordsHaveNoLemma() {
    let lemmatiser = AskLemmatiser(dictionary: dict)
    for word in ["recondight", "xqzt", "", "   "] { XCTAssertNil(lemmatiser.lemma(word), word) }
  }

  func testLoadingAndLookupsAreQuickEnough() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "wordnet", withExtension: "wnask"))
    let data = try Data(contentsOf: url)
    let started = Date()
    let loaded = try WordNetDictionary.load(gzipData: data)
    let loadMs = Date().timeIntervalSince(started) * 1000
    XCTAssertEqual(loaded.lemmaCount, 147_306)
    let lemmatiser = AskLemmatiser(dictionary: dict)
    let words = ["recondite", "expounding", "travellers", "colour", "realised", "ephemeral", "zymurgy", "nothingness"]
    let lookupStart = Date()
    for _ in 0..<20 { for word in words { _ = lemmatiser.lemmas(word) } }
    let perWordMs = Date().timeIntervalSince(lookupStart) * 1000 / Double(20 * words.count)
    print("metric=ask_dictionary_load_sim ms=\(Int(loadMs)) metric=ask_lemmatise_sim ms_per_word=\(String(format: "%.2f", perWordMs))")
    // Debug build on the simulator: generous bounds; they catch an accidental quadratic pass.
    XCTAssertLessThan(loadMs, 10_000)
    XCTAssertLessThan(perWordMs, 50)
  }

  // MARK: Text tools

  private var hound: [String] { AskSentences.split(AskFixtures.houndPage) }
  private var time: [String] { AskSentences.split(AskFixtures.timePage) }

  func testSplitsSentences() {
    XCTAssertTrue(hound[0].hasPrefix("Mr. Sherlock Holmes, who was usually very late"))
    XCTAssertTrue(hound[0].hasSuffix("breakfast table."))
    XCTAssertEqual(hound[1], "I stood upon the hearth-rug and picked up the stick which our visitor had left behind him the night before.")
    XCTAssertEqual(hound[3], "\"Well, Watson, what do you make of it?\"")
    XCTAssertEqual(hound.count, 5)
    XCTAssertTrue(time.contains { $0.hasPrefix("\"Is not that rather a large thing") && $0.hasSuffix("red hair.") })
    XCTAssertEqual(AskSentences.split("Dr. Watson came. He sat down."), ["Dr. Watson came.", "He sat down."])
    XCTAssertEqual(AskSentences.split("One. Two! Three?"), ["One.", "Two!", "Three?"])
    XCTAssertEqual(AskSentences.split("No end"), ["No end"])
    XCTAssertTrue(AskSentences.split("  \n\n ").isEmpty)
  }

  func testReadSoFarStopsAtTheSentenceBeingRead() {
    let current = "His grey eyes shone and twinkled, and his usually pale face was flushed and animated."
    let read = AskReadText.sentences(AskFixtures.snapshot(AskFixtures.houndPage, AskFixtures.timePage, current: current))
    XCTAssertEqual(read.count, hound.count + 2)
    XCTAssertEqual(read.last, current)
    XCTAssertFalse(read.contains { $0.contains("Filby") }, "unread text searched")
    let partial = AskReadText.sentences(AskFixtures.snapshot(AskFixtures.timePage, current: "was expounding a recondite matter to us"))
    XCTAssertEqual(partial.count, 1)
    XCTAssertEqual(AskReadText.sentences(AskFixtures.snapshot(AskFixtures.timePage)).count, time.count)
    XCTAssertEqual(
      AskReadText.sentences(AskFixtures.snapshot(AskFixtures.timePage, current: "Something else entirely here.")).count, time.count)
    XCTAssertTrue(AskReadText.sentences(nil).isEmpty)
  }

  func testTailKeepsWholeSentencesUpToTheLimit() throws {
    let snap = AskFixtures.snapshot(
      AskFixtures.houndPage, AskFixtures.timePage,
      current: "It is extraordinarily simple, and you will soon admit as much on reasonable grounds.\"")
    let tail = try XCTUnwrap(AskReadText.tail(snap, maxCharacters: 200))
    XCTAssertLessThanOrEqual(tail.count, 200)
    XCTAssertTrue(tail.hasSuffix("reasonable grounds.\""), tail)
    XCTAssertFalse(tail.contains("Filby"))
    XCTAssertTrue(AskReadText.tail(snap)?.hasPrefix("Mr. Sherlock Holmes") == true)
    XCTAssertNil(AskReadText.tail(nil))
  }

  func testSoundAlikeAndLooseNames() {
    XCTAssertEqual(AskWords.soundKey("recondite"), AskWords.soundKey("recondight"))
    XCTAssertEqual(AskWords.soundKey("Bennet"), AskWords.soundKey("Bennett"))
    XCTAssertTrue(AskWords.sameName("bennett", "bennet"))
    XCTAssertTrue(AskWords.sameName("holms", "holmes"))
    XCTAssertTrue(AskWords.sameName("watsons", "watson"))
    XCTAssertFalse(AskWords.sameName("watson", "wilson"))
    XCTAssertGreaterThanOrEqual(AskWords.letterSimilarity("recon dight", "recondite"), 0.6)
    XCTAssertGreaterThanOrEqual(AskWords.soundSimilarity("recon dight", "recondite"), 0.99)
  }

  func testMentionsOfAName() {
    let text = hound + AskSentences.split(AskFixtures.houndNextPage)
    let holmes = AskMentions.find(text, "holmes")
    XCTAssertEqual(holmes.map(\.index), [0, 4])
    XCTAssertEqual(AskMentions.displayName(text, holmes, "holmes"), "Mr. Sherlock Holmes")
    XCTAssertEqual(AskMentions.displayName(text, AskMentions.find(text, "watson"), "watson"), "Watson")
    XCTAssertEqual(
      AskMentions.displayName(time, AskMentions.find(time, "the time traveller"), "the time traveller"), "Time Traveller")
    let watson = AskMentions.find(text, "watson")
    XCTAssertEqual(watson.count, 2)
    XCTAssertTrue(watson[1].sentence.contains("visitor's stick"))
    XCTAssertEqual(AskMentions.find(text, "mr holms"), holmes)
    XCTAssertEqual(AskMentions.find(text, "Sherlock Holmes"), holmes)
    XCTAssertEqual(AskMentions.find(text, "Mister Sherlock Holmes"), holmes)
    XCTAssertTrue(AskMentions.find(text, "mr bennet").isEmpty)
    XCTAssertTrue(AskMentions.find(time, "the time machine").isEmpty)
    XCTAssertEqual(AskMentions.find(time, "the time traveller").count, 1)
    XCTAssertEqual(AskMentions.displayName(time, AskMentions.find(time, "filbee"), "filbee"), "Filby")
  }

  func testSearchFindsTheSentencesAskedAbout() {
    let text = hound + AskSentences.split(AskFixtures.houndNextPage)
    let stick = AskSearch.find(text, "the stick")
    XCTAssertEqual(stick.count, 2)
    XCTAssertTrue(stick[0].sentence.contains("picked up the stick"))
    XCTAssertTrue(AskSearch.find(text, "the fire").isEmpty)
    XCTAssertEqual(AskSearch.find(text, "coffee pot").count, 1)
    XCTAssertEqual(AskSearch.find(text, "eyes in the back of his head").count, 1)
    XCTAssertTrue(AskSearch.find(time, "geometry").first?.sentence.contains("taught you at school") == true)
    XCTAssertEqual(AskSearch.find(time, "twinkling eyes").count, 1)
  }

  func testRecapIsTheLastFewSentences() {
    let recap = AskRecap.last(hound)
    XCTAssertEqual(recap.last, hound.last)
    XCTAssertLessThanOrEqual(recap.reduce(0) { $0 + AskWords.of($1).count }, 60)
    XCTAssertEqual(AskRecap.last(["A very long sentence " + String(repeating: "word ", count: 100)]).count, 1)
    XCTAssertTrue(AskRecap.last([]).isEmpty)
  }

  // MARK: Whole questions on the phone

  func testDefinesAWordFromTheText() async {
    let a = asker()
    let first = await say(a, "What does recondite mean?")
    XCTAssertTrue(first.hasPrefix("Recondite, adjective: difficult to penetrate"), first)
    XCTAssertTrue(first.hasSuffix(AskWording.carryOnHint), "hint once")
    let nothingMore = await say(a, "more")
    XCTAssertEqual(nothingMore, AskWording.nothingMore, "WordNet has one sense of recondite")
    let spelt = await say(a, "spell it")
    XCTAssertEqual(spelt, "Recondite is spelt R, E, C, O, N, D, I, T, E.")
    let pale = await say(a, "what does pale mean")
    XCTAssertTrue(
      pale.hasPrefix("Pale, adjective: very light colored; highly diluted with white. Or: (of light) lacking in intensity"), pale)
    XCTAssertTrue(pale.hasSuffix("Say more for other meanings."), pale)
    let more = await say(a, "more")
    XCTAssertTrue(more.hasPrefix("Another meaning: lacking in vitality"), more)
    XCTAssertFalse(more.contains(AskWording.carryOnHint))
    let more2 = await say(a, "more")
    XCTAssertTrue(more2.contains("As a verb: turn pale, as if in fear."), more2)
    let more3 = await say(a, "tell me more")
    XCTAssertTrue(more3.hasPrefix("As a noun: a wooden strip forming part of a fence"), more3)
    let done = await say(a, "more")
    XCTAssertEqual(done, AskWording.nothingMore)
  }

  func testInflectedWordInTheTextLeadsWithItsPartOfSpeech() async {
    let a = asker()
    let text = await say(a, "what does expounding mean")
    XCTAssertTrue(text.hasPrefix("Expounding, from expound, verb:"), text)
    let base = await say(a, "define expound")
    XCTAssertTrue(base.hasPrefix("Expound, verb:"), base)
  }

  func testMisheardWordOffersTheClosestWordInTheText() async {
    let a = asker()
    let text = await say(a, "what does recon dight mean")
    XCTAssertTrue(text.hasPrefix("Did you mean recondite? Recondite, adjective:"), text)
    let spelt = await say(a, "spell it")
    XCTAssertEqual(spelt, "Recondite is spelt R, E, C, O, N, D, I, T, E.")
    let reconnect = await say(asker(), "what does reconnect mean")
    XCTAssertTrue(reconnect.hasPrefix("Did you mean recondite?"), reconnect)
    let b = asker()
    let corrected = await say(b, "what does tinkled mean")
    XCTAssertTrue(corrected.hasPrefix("Did you mean twinkled? Twinkled, from twinkle, verb:"), corrected)
    XCTAssertTrue(b.offersNo)
    let asHeard = await say(b, "no")
    XCTAssertTrue(asHeard.hasPrefix("Tinkled, from tinkle, verb:"), asHeard)
    XCTAssertNil(b.classify("no"), "no is only offered straight after a Did you mean")
  }

  func testWordNotInTheTextIsLookedUpAsHeard() async {
    let a = asker()
    let ephemeral = await say(a, "what does ephemeral mean")
    XCTAssertTrue(ephemeral.hasPrefix("Ephemeral, adjective:"), ephemeral)
    let colour = await say(a, "define colour")
    XCTAssertTrue(colour.hasPrefix("Colour, noun:"), colour)
    let realised = await say(a, "define realised")
    XCTAssertTrue(realised.hasPrefix("Realised, from realise, verb:"), realised)
    let penang = await say(a, "what does Penang lawyer mean")
    XCTAssertEqual(stripHint(penang), AskWording.notInDictionary("penang lawyer"))
    let made = await say(a, "define blorptastic")
    XCTAssertEqual(made, AskWording.notInDictionary("blorptastic"))
  }

  func testWordLookupChoices() {
    let lookup = AskWordLookup(dictionary: dict)
    let read = AskReadText.sentences(reading)
    XCTAssertEqual(lookup.choose("recondite", sentences: read), AskWordLookup.Choice(word: "recondite", heard: "recondite", inText: true, corrected: false))
    XCTAssertEqual(lookup.choose("expound", sentences: read), AskWordLookup.Choice(word: "expound", heard: "expound", inText: true, corrected: false))
    XCTAssertEqual(lookup.inText("expounds", sentences: read), "expounding")
    XCTAssertEqual(lookup.choose("wreck on dight", sentences: read)?.word, "recondite")
    XCTAssertEqual(lookup.inText("twinkle", sentences: read), "twinkled")
    // Words further down the page (not read yet) aren't offered.
    XCTAssertEqual(lookup.choose("contra vert", sentences: read)?.word, "contra vert")
    XCTAssertEqual(lookup.choose("contra vert", sentences: AskSentences.split(AskFixtures.timePage))?.word, "controvert")
    XCTAssertEqual(lookup.choose("recon dight", sentences: read, allowCorrection: false)?.word, "recon dight")
    XCTAssertEqual(
      lookup.choose("gregarious", sentences: read), AskWordLookup.Choice(word: "gregarious", heard: "gregarious", inText: false, corrected: false))
  }

  func testWhoIsSomeone() async {
    let a = asker()
    let holmes = await say(a, "who is Holmes")
    XCTAssertTrue(holmes.hasPrefix("Mr. Sherlock Holmes first comes up here: Mr. Sherlock Holmes, who was usually very late"), holmes)
    XCTAssertTrue(holmes.contains("Most recently: Holmes was sitting with his back to me"), holmes)
    let watson = await say(a, "who's Watson?")
    XCTAssertTrue(watson.hasPrefix("Watson first comes up here: \"Well, Watson"), watson)
    let bennet = await say(a, "Who is Mr. Bennet?")
    XCTAssertEqual(bennet, AskWording.notReadAbout("Mr. Bennet"))
    let filby = await say(a, "who is Filby")
    XCTAssertEqual(filby, AskWording.notReadAbout("Filby"), "Filby is further down the page")
    let all = await say(a, "who is Filby", AskFixtures.snapshot(AskFixtures.timePage))
    XCTAssertTrue(all.hasPrefix("Filby is mentioned once: \"Is not that rather a large thing"), all)
  }

  func testWhatIsANameOrAWord() async {
    let a = asker()
    let traveller = await say(a, "what's the time traveller")
    XCTAssertTrue(traveller.hasPrefix("Time Traveller is mentioned once:"), traveller)
    let machine = await say(a, "what's the Time Machine?")
    XCTAssertTrue(machine.hasPrefix("Time machine, noun: a science fiction machine"), machine)
    let morlocks = await say(a, "what are the Morlocks")
    XCTAssertEqual(morlocks, AskWording.notReadAbout("Morlocks"))
    let geometry = await say(a, "what is the geometry", AskFixtures.snapshot(AskFixtures.timePage))
    XCTAssertTrue(geometry.hasPrefix("Geometry is mentioned once"), geometry)
  }

  func testRecapThisSessionAndLastSession() async {
    let a = asker(previous: "He sat by the fire. Then the letter came, and he read it twice.")
    let recap = await say(a, "recap")
    XCTAssertTrue(recap.hasPrefix("The last bit was: "), recap)
    XCTAssertTrue(recap.contains("His grey eyes shone and twinkled"))
    XCTAssertFalse(recap.contains("Filby"))
    let last = await say(a, "what happened last time", .some(nil))
    XCTAssertEqual(last, "Last time, we left off here: He sat by the fire. Then the letter came, and he read it twice.")
    let fire = await say(a, "what did it say about the fire", .some(nil))
    XCTAssertTrue(fire.hasPrefix("About the fire: He sat by the fire."), fire)
    let none = await ask(asker(), "what happened last time", .some(nil))
    XCTAssertEqual(none, .nothingRead)
  }

  func testFindAndNext() async {
    let a = asker()
    let stick = await say(a, "what did it say about the stick")
    XCTAssertTrue(stick.hasPrefix("About the stick: I stood upon the hearth-rug and picked up the stick"), stick)
    XCTAssertTrue(stick.contains("That's 1 of 2. Say next for the next one."), stick)
    let next = await say(a, "next")
    XCTAssertTrue(next.hasPrefix("Match 2 of 2: \"But, tell me, Watson, what do you make of our visitor's stick?"), next)
    let done = await say(a, "next")
    XCTAssertEqual(done, AskWording.nothingMore)
    let fire = await say(a, "what did it say about the fire")
    XCTAssertEqual(fire, AskWording.nothingFound("the fire"))
  }

  func testOpenQuestionsAreDeclinedHonestlyWithoutAKey() async {
    let answer = await say(asker(), "why did he do that")
    XCTAssertEqual(stripHint(answer), AskWording.canOnly)
  }

  func testOpenQuestionsGoOnlineOnlyWithAKeyAndSayAskingOnlineFirst() async {
    let online = FakeOnline(reply: .answer("Because he wanted to test Watson."))
    let a = asker(online: online)
    var notes: [String] = []
    let result = await ask(a, "why did he do that", notes: { notes.append($0) })
    XCTAssertEqual(notes, [AskWording.askingOnline])
    guard case .answer(let text) = result else { return XCTFail("\(result)") }
    XCTAssertTrue(text.hasPrefix("Because he wanted to test Watson."))
    XCTAssertEqual(online.calls.count, 1)
    XCTAssertEqual(online.calls.first?.question, "why did he do that")
    // Only the text read so far, never the unread rest of the page.
    XCTAssertTrue(online.calls.first?.text.contains("recondite") == true)
    XCTAssertFalse(online.calls.first?.text.contains("Filby") == true)
    // On-device kinds never go online.
    _ = await say(a, "what does recondite mean")
    _ = await say(a, "who is Holmes")
    _ = await say(a, "recap")
    XCTAssertEqual(online.calls.count, 1)
    // Nothing read: nothing is sent.
    let empty = await ask(a, "why did he do that", .some(nil))
    XCTAssertEqual(empty, .nothingRead)
    XCTAssertEqual(online.calls.count, 1)
  }

  func testNothingReadYet() async {
    let a = asker()
    let who = await ask(a, "who is Holmes", .some(nil))
    XCTAssertEqual(who, .nothingRead)
    let find = await ask(a, "what did it say about the fire", .some(nil))
    XCTAssertEqual(find, .nothingRead)
    let ephemeral = await say(a, "what does ephemeral mean", .some(nil))
    XCTAssertTrue(ephemeral.hasPrefix("Ephemeral, adjective:"), "a definition doesn't need any text")
    let spell = await say(asker(), "spell it", .some(nil))
    XCTAssertEqual(spell, AskWording.noWordYet)
  }

  func testTextFromAnyToolWorksTheSameWay() async {
    let letter =
      "Dear Mr. Bennet, Your account is overdue. Please pay the balance by the fourteenth of March. Yours sincerely, Hannah Price, Accounts."
    let snap = AskFixtures.snapshot(letter, source: .mail)
    let a = asker()
    let who = await say(a, "who is Mr Bennett", snap, carryOn: false)
    XCTAssertTrue(who.hasPrefix("Mr. Bennet is mentioned once: Dear Mr. Bennet"), who)
    let balance = await say(a, "what did it say about the balance", snap, carryOn: false)
    XCTAssertTrue(balance.contains("fourteenth of March"))
    let overdue = await say(a, "what does overdue mean", snap, carryOn: false)
    XCTAssertFalse(overdue.contains(AskWording.carryOnHint), "no carry-on hint unless a reader was paused")
  }

  func testWording() {
    XCTAssertEqual(AskWording.spell("hearth-rug"), "Hearth-rug is spelt H, E, A, R, T, H, hyphen, R, U, G.")
    XCTAssertEqual(AskWording.spokenName("mr bennet"), "Mr. Bennet")
    XCTAssertEqual(AskWording.spokenName("the time machine"), "the Time Machine")
    let long = (1...60).map { "w\($0)" }.joined(separator: " ") + " Holmes " + (1...60).map { "x\($0)" }.joined(separator: " ")
    let clipped = AskWording.clip(long, keys: ["holmes"])
    XCTAssertTrue(clipped.contains("Holmes") && clipped.hasPrefix("... ") && clipped.hasSuffix(" ..."), clipped)
    XCTAssertLessThanOrEqual(AskWords.of(clipped).count, 32)
  }

  // MARK: OpenAI request and reply (no live request)

  func testOnlineRequestSendsOnlyTheQuestionAndTheTextToOpenAI() throws {
    let client = OpenAIAskOnline(apiKey: "sk-test")
    let request = try client.request(question: "why did he do that", text: "Holmes was sitting with his back to me.")
    XCTAssertEqual(request.url?.host(), "api.openai.com")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["store"] as? Bool, false)
    XCTAssertEqual(json["model"] as? String, OpenAIClient.transcriptionModel)
    let raw = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(raw.contains("Holmes was sitting with his back to me."))
    XCTAssertTrue(raw.contains("why did he do that"))
    XCTAssertFalse(raw.contains("input_image"), "never an image")
    XCTAssertFalse(raw.contains("image_url"))
    XCTAssertTrue((json["instructions"] as? String)?.contains(OpenAIAskOnline.notInTextReply) == true)
    XCTAssertThrowsError(try OpenAIAskOnline(apiKey: "  ").request(question: "q", text: "t"))
    XCTAssertNil(OpenAIAskOnline.configured(store: EmptyKeyStore(), infoDictionary: [:]), "no key: stays on the phone")
  }

  func testOnlineRepliesAreHandled() {
    func reply(_ content: [[String: Any]], status: Int = 200) -> AskResult {
      let body: [String: Any] = [
        "status": "completed",
        "output": [["type": "reasoning", "summary": []], ["type": "message", "role": "assistant", "content": content]],
      ]
      // swiftlint:disable:next force_try
      return OpenAIAskOnline.result(status: status, body: try! JSONSerialization.data(withJSONObject: body))
    }
    XCTAssertEqual(reply([["type": "output_text", "text": "He wanted to test Watson."]]), .answer("He wanted to test Watson."))
    XCTAssertEqual(reply([["type": "output_text", "text": "The text doesn't say."]]), .notInText)
    XCTAssertEqual(reply([["type": "output_text", "text": "the text doesn't say"]]), .notInText)
    XCTAssertEqual(reply([["type": "refusal", "refusal": "I can't help with that."]]), .failed("refusal"))
    XCTAssertEqual(reply([]), .failed("empty"))
    XCTAssertEqual(OpenAIAskOnline.result(status: 401, body: Data()), .failed("unauthorized"))
    XCTAssertEqual(OpenAIAskOnline.result(status: 429, body: Data()), .failed("rate_limited"))
    XCTAssertEqual(OpenAIAskOnline.result(status: 200, body: Data("{not json".utf8)), .failed("bad_json"))
  }

  func testOnlineNetworkErrorsFailQuietly() async {
    let client = OpenAIAskOnline(apiKey: "sk-test", transport: { _ in throw URLError(.notConnectedToInternet) })
    let result = await client.ask(question: "why", text: "Some text.")
    XCTAssertEqual(result, .failed("network"))
  }

  // MARK: RecentText

  func testRecentTextKeepsTextPerToolBoundedAndReplacesByKey() {
    let store = RecentText(maxCharacters: 100, defaults: nil)
    XCTAssertNil(store.latest())
    store.append("Page one.", source: .read, key: "p1")
    store.append("Page one, corrected.", source: .read, key: "p1")
    store.append("Page two.", source: .read, key: "p2")
    XCTAssertEqual(store.snapshot(source: .read)?.passages, ["Page one, corrected.", "Page two."])
    store.append(String(repeating: "x", count: 95), source: .read)
    XCTAssertEqual(store.snapshot(source: .read)?.passages.count, 1, "oldest passages go first past the limit")
    store.append("   ", source: .read)
    XCTAssertEqual(store.snapshot(source: .read)?.passages.count, 1, "blank text is ignored")
    store.clear(source: .read)
    XCTAssertNil(store.snapshot(source: .read))
  }

  func testRecentTextPrefersTheAskingToolThenTheLatest() {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
    let clock = Clock()
    let store = RecentText(defaults: nil, clock: { clock.now })
    store.append("A letter from the bank.", source: .mail)
    clock.now = Date(timeIntervalSince1970: 5)
    store.append("A page of a book.", source: .read)
    XCTAssertEqual(store.latest()?.source, .read)
    XCTAssertEqual(store.forQuestion(source: .mail)?.source, .mail)
    XCTAssertEqual(store.forQuestion(source: .labels)?.source, .read, "nothing from labels: the latest")
    XCTAssertEqual(store.forQuestion(source: nil)?.source, .read)
    store.setCurrent("A page", source: .read)
    XCTAssertEqual(store.snapshot(source: .read)?.current, "A page")
  }

  func testRecentTextKeepsTheLastHeardTextForNextTime() throws {
    let suite = "AskAboutTextTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = RecentText(defaults: defaults)
    XCTAssertNil(first.previousSession)
    first.append(AskFixtures.timePage, source: .read)
    first.setCurrent("His grey eyes shone and twinkled, and his usually pale face was flushed and animated.", source: .read)
    let next = RecentText(defaults: defaults)
    let previous = try XCTUnwrap(next.previousSession)
    XCTAssertTrue(previous.hasSuffix("flushed and animated."), previous)
    XCTAssertFalse(previous.contains("Filby"), "only what was heard")
  }
}

private struct EmptyKeyStore: OpenAIKeyStore {
  func readKey() -> String? { nil }
  func saveKey(_ key: String) -> Bool { false }
  func deleteKey() {}
}
