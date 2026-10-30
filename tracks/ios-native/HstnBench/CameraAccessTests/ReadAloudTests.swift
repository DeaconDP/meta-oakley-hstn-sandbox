/*
 * ReadAloudTests - the pure parts of "Read it aloud": per-word confidence, reading order,
 * sentence splitting, framing classification and guidance wording, the dose/money guard, clause
 * chunks, plus one end-to-end OCR pass over the bundled test page
 *
 * Geometry in these tests is in pixels with a top-left origin, in the wearer's point of view,
 * the same as ReadLine.
 */

import CoreGraphics
@testable import CameraAccess
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 20, confidence: Float = 1) -> ReadLine {
  ReadLine(
    words: text.split(separator: " ").map { ReadWord(text: String($0), confidence: confidence) },
    box: CGRect(x: x, y: y, width: width, height: height))
}

private func words(_ text: String, confidence: Float = 1) -> [ReadWord] {
  text.split(separator: " ").map { ReadWord(text: String($0), confidence: confidence) }
}

private func texts(_ sentences: [[ReadWord]]) -> [String] {
  sentences.map { $0.map(\.text).joined(separator: " ") }
}

private func spoken(_ sentence: RenderedSentence) -> String {
  sentence.chunks.map(\.text).joined(separator: " ")
}

final class WordConfidenceTests: XCTestCase {
  func testNoAlternativesKeepsLineConfidence() {
    let result = WordConfidence.words(top: "Take two tablets", confidence: 0.9, alternatives: [])
    XCTAssertEqual(result.map(\.text), ["Take", "two", "tablets"])
    XCTAssertEqual(result.map(\.confidence), [0.9, 0.9, 0.9])
  }

  func testDisagreeingWordIsLowered() {
    let result = WordConfidence.words(top: "Take 5 mg", confidence: 1, alternatives: [("Take 8 mg", 0.8)])
    XCTAssertEqual(result[0].confidence, 1)
    XCTAssertLessThan(result[1].confidence, ReadSpeech.uncertainBelow)
    XCTAssertEqual(result[2].confidence, 1)
  }

  func testPunctuationAroundAWordIsNotADisagreement() {
    let result = WordConfidence.words(top: "the lazy dog.", confidence: 1, alternatives: [("the lazy dog,", 1)])
    XCTAssertEqual(result.map(\.confidence), [1, 1, 1])
  }

  func testDecimalPointInsideANumberIsADisagreement() {
    let result = WordConfidence.words(top: "2.5 mg", confidence: 1, alternatives: [("25 mg", 0.9)])
    XCTAssertLessThan(result[0].confidence, 0.5)
  }

  func testWeakAlternativeIsIgnored() {
    let result = WordConfidence.words(top: "brown fox", confidence: 1, alternatives: [("crown fox", 0.2)])
    XCTAssertEqual(result.map(\.confidence), [1, 1])
  }

  func testDifferentWordCountFallsBackToMembership() {
    let result = WordConfidence.words(top: "jumps over the dog", confidence: 1, alternatives: [("jumps overthe dog", 0.9)])
    XCTAssertEqual(result.map { $0.confidence < 0.5 }, [false, true, true, false])
  }
}

final class ReadingOrderTests: XCTestCase {
  func testSingleColumnIsTopToBottomWhateverTheInputOrder() {
    let lines = [
      line("third line", x: 50, y: 100, width: 300),
      line("first line", x: 50, y: 40, width: 300),
      line("second line", x: 50, y: 70, width: 300),
    ]
    let blocks = ReadingOrder.blocks(lines)
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks[0].map(\.text), ["first line", "second line", "third line"])
  }

  func testTwoColumnsReadLeftThenRight() {
    // Rows interleave by y; the right column even starts a little higher.
    let lines = [
      line("right one", x: 300, y: 38, width: 200),
      line("left one", x: 40, y: 40, width: 200),
      line("right two", x: 300, y: 68, width: 200),
      line("left two", x: 40, y: 70, width: 200),
      line("left three", x: 40, y: 100, width: 200),
    ]
    let order = ReadingOrder.blocks(lines).flatMap { $0.map(\.text) }
    XCTAssertEqual(order, ["left one", "left two", "left three", "right one", "right two"])
  }

  func testHeadingAboveColumnsComesFirst() {
    let lines = [
      line("right body", x: 300, y: 80, width: 200),
      line("left body", x: 40, y: 80, width: 200),
      line("Heading across the page", x: 40, y: 20, width: 460, height: 30),
    ]
    let order = ReadingOrder.blocks(lines).flatMap { $0.map(\.text) }
    XCTAssertEqual(order, ["Heading across the page", "left body", "right body"])
  }

  func testParagraphsStaySeparateBlocksInOrder() {
    let lines = [
      line("Second paragraph.", x: 40, y: 200, width: 300),
      line("First paragraph.", x: 40, y: 40, width: 300),
    ]
    let blocks = ReadingOrder.blocks(lines)
    XCTAssertEqual(blocks.map { $0.map(\.text) }, [["First paragraph."], ["Second paragraph."]])
  }

  func testSameRowPiecesAreMergedLeftToRight() {
    let lines = [
      line("12.99", x: 230, y: 50, width: 60),
      line("Coffee", x: 200 - 90, y: 51, width: 100),
    ]
    let merged = ReadingOrder.mergeRows(lines)
    XCTAssertEqual(merged.map(\.text), ["Coffee 12.99"])
  }

  func testColumnsWithAWideGutterAreNotMerged() {
    let lines = [
      line("left", x: 40, y: 50, width: 150),
      line("right", x: 300, y: 50, width: 150),
    ]
    XCTAssertEqual(ReadingOrder.mergeRows(lines).count, 2)
  }
}

final class SentenceSplitterTests: XCTestCase {
  private func split(_ lines: [ReadLine]) -> [String] {
    texts(SentenceSplitter.sentences(blocks: ReadingOrder.blocks(lines)))
  }

  func testSplitsOnEndPunctuation() {
    let result = split([line("The fox ran. The dog slept! Did it? Yes.", x: 20, y: 20, width: 400)])
    XCTAssertEqual(result, ["The fox ran.", "The dog slept!", "Did it?", "Yes."])
  }

  func testAbbreviationsInitialsAndDecimalsDoNotSplit() {
    let result = split([line("Dr. Smith met J. Doe at 3.30 today. Then left.", x: 20, y: 20, width: 400)])
    XCTAssertEqual(result, ["Dr. Smith met J. Doe at 3.30 today.", "Then left."])
  }

  func testLowercaseAfterAPeriodDoesNotSplit() {
    let result = split([line("Use approx. five drops. Done.", x: 20, y: 20, width: 400)])
    XCTAssertEqual(result, ["Use approx. five drops.", "Done."])
  }

  func testWordsHyphenatedAcrossLinesAreRejoined() {
    let result = split([
      line("Take this medi-", x: 20, y: 20, width: 380),
      line("cation with food.", x: 20, y: 45, width: 380),
    ])
    XCTAssertEqual(result, ["Take this medication with food."])
  }

  func testCapitalisedSecondHalfKeepsItsHyphen() {
    XCTAssertFalse(SentenceSplitter.isHyphenBreak("Lloyd-", then: "George"))
    XCTAssertTrue(SentenceSplitter.isHyphenBreak("medi-", then: "cation"))
    XCTAssertFalse(SentenceSplitter.isHyphenBreak("-", then: "and"))
  }

  func testShortUnpunctuatedLineIsItsOwnSentence() {
    let result = split([
      line("Reading test", x: 20, y: 20, width: 150, height: 24),
      line("The quick brown fox jumps over the lazy", x: 20, y: 52, width: 400),
      line("dog. It slept.", x: 20, y: 80, width: 140),
    ])
    XCTAssertEqual(result, ["Reading test", "The quick brown fox jumps over the lazy dog.", "It slept."])
  }

  func testBlockEndEndsTheSentence() {
    let result = split([
      line("No full stop here", x: 20, y: 20, width: 400),
      line("Next paragraph.", x: 20, y: 200, width: 400),
    ])
    XCTAssertEqual(result, ["No full stop here", "Next paragraph."])
  }

  func testVeryLongUnpunctuatedTextIsCut() {
    let long = (1...50).map { "word\($0)" }.joined(separator: " ")
    let result = SentenceSplitter.sentences(blocks: [[line(long, x: 0, y: 0, width: 1000)]])
    XCTAssertEqual(result.map(\.count), [SentenceSplitter.maxWords, 10])
  }
}

final class FramingTests: XCTestCase {
  private let size = CGSize(width: 540, height: 960)
  private let fine = FrameQuality(brightness: 0.6, sharpness: 300)

  private func page(_ lines: [ReadLine]) -> ReadPage { ReadPage(lines: lines, imageSize: size) }

  func testCentredPageIsGood() {
    let verdict = FramingAdvisor.assess(page([line("Some text here.", x: 100, y: 300, width: 300, height: 30)]), quality: fine)
    XCTAssertEqual(verdict, .good)
    XCTAssertNil(SpokenMessage.readGuidance(verdict, verbosity: .normal))
  }

  func testNoTextAndWhy() {
    XCTAssertEqual(FramingAdvisor.assess(page([]), quality: fine), .noText)
    XCTAssertEqual(FramingAdvisor.assess(page([]), quality: FrameQuality(brightness: 0.05, sharpness: 300)), .tooDark)
    XCTAssertEqual(FramingAdvisor.assess(page([]), quality: FrameQuality(brightness: 0.6, sharpness: 3)), .tooBlurry)
  }

  func testNoTextGuidanceSaysWhereToHoldThePage() {
    XCTAssertEqual(
      SpokenMessage.readGuidance(.noText, verbosity: .normal),
      "No text found. Hold the page about an arm's length away, a little to your right.")
  }

  func testTinyTextIsTooSmall() {
    let lines = [line("tiny print", x: 100, y: 300, width: 80, height: 9), line("more tiny", x: 100, y: 312, width: 80, height: 9)]
    XCTAssertEqual(FramingAdvisor.assess(page(lines), quality: fine), .tooSmall)
  }

  func testMostlyUnreadableBlurryTextIsTooBlurry() {
    let lines = [line("blurred words", x: 100, y: 300, width: 300, height: 30, confidence: 0.2)]
    XCTAssertEqual(FramingAdvisor.assess(page(lines), quality: FrameQuality(brightness: 0.6, sharpness: 5)), .tooBlurry)
  }

  /// The image is the wearer's view: text running off the image's right edge is off to the
  /// wearer's right, so they turn their head right.
  func testTextTouchingTheRightEdgeMeansTurnRight() {
    let lines = [line("Text that runs off the", x: 120, y: 300, width: 420, height: 30)]
    let verdict = FramingAdvisor.assess(page(lines), quality: fine)
    XCTAssertEqual(verdict, .cutOff([.right]))
    XCTAssertFalse(verdict.blocksReading)
    XCTAssertEqual(
      SpokenMessage.readGuidance(verdict, verbosity: .normal),
      "Text is cut off on the right. Turn your head slightly right. Reading what I can see.")
    XCTAssertEqual(SpokenMessage.readGuidance(verdict, verbosity: .short), "Cut off on the right. Turn right.")
  }

  func testLeftAndBottomEdges() {
    let lines = [line("edge text", x: 0, y: 930, width: 200, height: 30)]
    let verdict = FramingAdvisor.assess(page(lines), quality: fine)
    XCTAssertEqual(verdict, .cutOff([.left, .bottom]))
    XCTAssertEqual(
      SpokenMessage.readGuidance(verdict, verbosity: .normal),
      "Text is cut off on the left and at the bottom. Turn your head slightly left and tilt it down. Reading what I can see.")
  }

  func testBothSidesMeansMoveBack() {
    let lines = [line("very wide text line", x: 2, y: 400, width: 536, height: 30)]
    let verdict = FramingAdvisor.assess(page(lines), quality: fine)
    XCTAssertEqual(verdict, .cutOff([.left, .right]))
    XCTAssertEqual(
      SpokenMessage.readGuidance(verdict, verbosity: .normal), "Text runs off on both sides. Move back a little. Reading what I can see.")
  }

  func testPoorFramesBlockReading() {
    for verdict in [FramingVerdict.noText, .tooDark, .tooBlurry, .tooSmall] {
      XCTAssertTrue(verdict.blocksReading)
      for verbosity in Verbosity.allCases {
        let text = SpokenMessage.readGuidance(verdict, verbosity: verbosity) ?? ""
        XCTAssertFalse(text.isEmpty, "\(verdict) at \(verbosity) must say something")
        XCTAssertTrue(text.hasSuffix("."), text)
      }
    }
  }

  func testQualityMeasure() {
    let flat = FrameQuality.measure(gray: [UInt8](repeating: 128, count: 100), width: 10, height: 10)
    XCTAssertEqual(flat.brightness, 128.0 / 255, accuracy: 0.001)
    XCTAssertEqual(flat.sharpness, 0, accuracy: 0.001)

    let checker = (0..<100).map { UInt8(($0 / 10 + $0 % 10) % 2 == 0 ? 0 : 255) }
    let sharp = FrameQuality.measure(gray: checker, width: 10, height: 10)
    XCTAssertGreaterThan(sharp.sharpness, FramingAdvisor.blurryBelow)

    let dark = FrameQuality.measure(gray: [UInt8](repeating: 10, count: 100), width: 10, height: 10)
    XCTAssertLessThan(dark.brightness, FramingAdvisor.darkBelow)
  }
}

final class ReadSpeechTests: XCTestCase {
  private func render(_ words: [ReadWord], verbosity: Verbosity = .normal, earcons: Bool = true) -> RenderedSentence {
    ReadSpeech.render(words, verbosity: verbosity, earconsEnabled: earcons)
  }

  func testConfidentTextIsReadVerbatim() {
    let result = render(words("Take 2 tablets with 250 ml of water, $3.50 each."))
    XCTAssertEqual(spoken(result), "Take 2 tablets with 250 ml of water, $3.50 each.")
    XCTAssertNil(result.withheld)
    XCTAssertEqual(result.uncertainWords, 0)
  }

  func testLowConfidenceDoseIsWithheld() {
    var sentence = words("Take 500 mg twice daily.")
    sentence[1].confidence = 0.6
    let result = render(sentence)
    XCTAssertEqual(result.withheld, .dose)
    XCTAssertFalse(spoken(result).contains("500"), "Must not guess the dose")
    XCTAssertEqual(
      result.chunks,
      [
        SpokenChunk(text: "Take", flagged: false),
        SpokenChunk(text: "a dose I can't read reliably", flagged: true),
        SpokenChunk(text: "twice daily.", flagged: false),
        SpokenChunk(text: "Check this dose with a pharmacist or another reader.", flagged: false),
      ])
    XCTAssertEqual(result.display, "Take [dose unreadable] twice daily.")
  }

  func testUnsureUnitAlsoWithholdsTheDose() {
    var sentence = words("Take 5 ml now.")
    sentence[2].confidence = 0.3
    XCTAssertEqual(render(sentence).withheld, .dose)
  }

  func testAttachedUnitsAndNumberWords() {
    XCTAssertEqual(render(words("Take 2.5mg/5ml daily.", confidence: 0.7)).withheld, .dose)
    XCTAssertEqual(render(words("Take two tablets.", confidence: 0.7)).withheld, .dose)
    XCTAssertEqual(render(words("Use 10 units.", confidence: 0.7)).withheld, .dose)
  }

  func testLowConfidenceMoneyIsWithheld() {
    var attached = words("Total $12.99 today.")
    attached[1].confidence = 0.4
    let result = render(attached)
    XCTAssertEqual(result.withheld, .money)
    XCTAssertFalse(spoken(result).contains("12"))
    XCTAssertTrue(spoken(result).contains("an amount I can't read reliably"))

    var separate = words("Total $ 12.99 today.")
    separate[2].confidence = 0.4
    let separateResult = render(separate)
    XCTAssertEqual(separateResult.withheld, .money)
    XCTAssertFalse(spoken(separateResult).contains("$"), "The sign goes with the amount")

    var word = words("Pay 40 dollars now.")
    word[1].confidence = 0.4
    XCTAssertEqual(render(word).withheld, .money)
  }

  func testOtherNumbersAreOnlyFlagged() {
    var sentence = words("See page 12 for details.")
    sentence[2].confidence = 0.3
    let result = render(sentence)
    XCTAssertNil(result.withheld)
    XCTAssertTrue(spoken(result).contains("12"))
    XCTAssertEqual(result.uncertainWords, 1)
  }

  func testUncertainWordGetsTheEarconOnly() {
    var sentence = words("The quick brown fox jumps.")
    sentence[2].confidence = 0.3
    let result = render(sentence)
    XCTAssertEqual(result.chunks, [SpokenChunk(text: "The quick", flagged: false), SpokenChunk(text: "brown fox jumps.", flagged: true)])
    XCTAssertEqual(result.display, "The quick brown(?) fox jumps.")
  }

  func testUncertainWordIsSaidWithoutEarconsOrWhenDetailed() {
    var sentence = words("The quick brown fox.")
    sentence[2].confidence = 0.3
    XCTAssertEqual(render(sentence, earcons: false).chunks.last?.text, "unclear word: brown fox.")
    XCTAssertEqual(render(sentence, verbosity: .short, earcons: false).chunks.last?.text, "unclear: brown fox.")
    XCTAssertEqual(render(sentence, verbosity: .detailed).chunks.last?.text, "unclear word: brown fox.")
  }

  func testAdjacentUncertainWordsAreFlaggedOnce() {
    var sentence = words("a b c d e")
    sentence[1].confidence = 0.2
    sentence[2].confidence = 0.2
    let result = render(sentence)
    XCTAssertEqual(result.chunks.filter(\.flagged).count, 1)
    XCTAssertEqual(result.uncertainWords, 2)
  }

  func testClauses() {
    XCTAssertEqual(
      ReadSpeech.clauses("When the light turns green, cross the road with care."),
      ["When the light turns green,", "cross the road with care."])
    XCTAssertEqual(ReadSpeech.clauses("Yes, it is."), ["Yes, it is."], "Too short to split")
    XCTAssertEqual(ReadSpeech.clauses("Costs 1,000 pounds in total today."), ["Costs 1,000 pounds in total today."])
  }

  func testLongSentenceStartsWithAShortChunk() {
    let result = render(words("If you can read this aloud, the reader is working, and it splits long sentences into clauses."))
    XCTAssertEqual(result.chunks.first?.text, "If you can read this aloud,")
    XCTAssertEqual(result.chunks.count, 3)
  }
}

@MainActor
final class ReadLaunchTests: XCTestCase {
  func testReadIsItsOwnLaunchAction() {
    XCTAssertEqual(LaunchAction.read.rawValue, "read")
    XCTAssertTrue(ReadIntent.openAppWhenRun)
  }

  func testReadLinesAreSentences() {
    let lines = [
      SpokenMessage.readStartingCamera, SpokenMessage.readTakingPhotoNoFrame, SpokenMessage.readTakingPhotoSmallText,
      SpokenMessage.readPhotoFailed, SpokenMessage.readNoCamera, SpokenMessage.readCameraTimedOut, SpokenMessage.readFailed,
      SpokenMessage.readNothingToNavigate, SpokenMessage.readLastSentence, SpokenMessage.readCheckWithheld(.dose),
      SpokenMessage.readCheckWithheld(.money), SpokenMessage.launchReading,
    ]
    for line in lines {
      XCTAssertTrue(line.hasSuffix("."), line)
      XCTAssertLessThan(line.split(separator: " ").count, 20, line)
    }
  }
}

/// The real Vision pass over the page the UI test feeds the mock (A11y/Read/Fixtures).
final class ReadFixtureOCRTests: XCTestCase {
  func testFixturePageReadsInOrder() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "read_page", withExtension: "png"), "Fixture should be in the app bundle")
    let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
    let recognized = try TextRecognizer.recognize(image)

    XCTAssertEqual(FramingAdvisor.assess(recognized.page, quality: recognized.quality), .good)
    let sentences = texts(SentenceSplitter.sentences(blocks: ReadingOrder.blocks(recognized.page.lines)))
    XCTAssertEqual(
      sentences,
      [
        "Reading test",
        "The quick brown fox jumps over the lazy dog.",
        "Printed text is read word for word, in order.",
        "This is the end of the test page.",
      ])
  }
}
