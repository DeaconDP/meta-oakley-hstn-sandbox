/*
 * LetterReader - what a letter is: sender, recipient, kind, subject, amount due and deadline
 *
 * Port of the Android LetterReader.kt: the same fixed rules, on the phone, no cloud (ROADMAP).
 * From the laid-out pages (LetterLayout):
 *   - header = everything above "Dear ..." (or the subject line); the recipient is the address
 *     block with a postcode or a "Mr/Mrs/Ms..." first line; the sender is a "From:" line, else the
 *     letterhead (the largest text near the top), else the name under "Yours sincerely", else the
 *     other address block, else an envelope's "If undelivered return to ..." line;
 *   - date = the first date that isn't a deadline; subject = "Re:/Subject:" or a heading line, else
 *     the first sentence of the body;
 *   - amount due = money on a line that says "amount due / total to pay / please pay / balance
 *     due..." (else "total"), deadline = a date on a line that says "due / pay by / before...";
 *   - kind = keyword scores (bill, bank, official, medical, personal, advert);
 *   - envelope = no "Dear", no paragraphs, few words, an address block or postal markings;
 *   - scam signs (new on iOS, ROADMAP U1): fixed phrases, given as a hint, never a verdict.
 *
 * The money rule: if any part of the amount due was read with low confidence, or a letter sits
 * where a digit should be, or the character boxes show a digit went missing, or two different
 * amounts are both "due", the amount is unsure or conflict and no figure is spoken. On iOS the
 * confidence is per word (see LetterModel): Vision's line confidence, cut when the runner-up
 * candidate readings disagree on that word, and the bar is ReadSpeech's own bar for money
 * (0.8), so the mail reader is never looser than Read text. MailTool also reads the amount on a
 * second picture and refuses it if the two disagree (crossChecked). Pure Swift.
 */

import Foundation

enum LetterKind: String, CaseIterable, Sendable {
  case bill, bank, official, medical, personal, advert, unknown
}

/// The amount to pay, as far as it can be read safely.
enum AmountDue: Equatable, Sendable {
  case none
  case sure(Money, minimum: Money? = nil, isTotal: Bool = false)
  /// There is an amount due, but a digit is unsure. Never say a figure.
  case unsure
  /// Two different amounts are both marked as due. Never say a figure.
  case conflict

  var isUnsureOrConflict: Bool { self == .unsure || self == .conflict }
}

enum DueKind: Sendable { case pay, reply, appointment, other }

/// A deadline: a date, or a phrase like "within 14 days". `sure` is false if a digit was unsure.
struct DueDate: Equatable, Sendable {
  var kind: DueKind
  var spoken: String
  var sure: Bool
}

struct Reference: Equatable, Sendable {
  var label: String
  var value: String

  var spoken: String { "\(label) \(LetterText.spellOut(value))" }
}

struct Letter: Equatable, Sendable {
  var pages: [LaidOutLetter]
  var isEnvelope: Bool
  var kind: LetterKind
  var sender: String?
  var recipient: String?
  /// The recipient's address after the name, one string with commas ("14 Elm Road, Leeds LS6 2AB").
  var recipientAddress: String?
  var salutation: String?
  var date: LetterDate?
  var subject: String?
  /// The first sentence of the body, when there's no subject line.
  var opening: String?
  var amount: AmountDue
  var due: DueDate?
  var references: [Reference]
  /// Number of money amounts anywhere in the letter (charges, balances...).
  var amountsMentioned: Int
  /// Money tokens (as printed) read below the confidence bar: never read out or shown.
  var unsureMoney: Set<String> = []
  /// Signs of a scam found in the text. A hint to check, never a verdict.
  var scamSigns: [ScamSign] = []

  /// Every paragraph of every page; "Page 2." before each later page.
  var paragraphs: [String] {
    pages.enumerated().flatMap { i, page in i == 0 ? page.paragraphs : ["Page \(i + 1)."] + page.paragraphs }
  }

  /// `paragraphs` ready for speech: unsure amounts replaced, digit runs spaced.
  var readingParagraphs: [String] { paragraphs.map { LetterSpeech.forReading($0, unsureMoney: unsureMoney) } }

  var fullText: String { paragraphs.joined(separator: "\n\n") }

  /// `fullText` with unsure amounts replaced: what the screen (and so VoiceOver) shows.
  var safeText: String { paragraphs.map { LetterSpeech.masked($0, unsureMoney: unsureMoney) }.joined(separator: "\n\n") }
}

enum LetterReader {
  /// A character of an amount read below this (character confidence, when known) is unsure.
  static let minDigitConfidence: Float = 0.5
  /// When only a word or line confidence is known (always, on iOS), below this is unsure. Android
  /// uses 0.6 for ML Kit word scores; iOS uses Read text's money bar, since Vision's scores are
  /// coarser and a disputed word lands at 0.45 of its line.
  static let minWordConfidence: Float = ReadSpeech.sensitiveNumberBelow

  private static let dear = MailRegex("^dear\\s+(.+?)[,.;:]?$", ignoreCase: true)
  private static let subjectLine = MailRegex("^(?:re|subject|regarding)\\s*[:\\-]\\s*(.+)$", ignoreCase: true)
  private static let fromLine = MailRegex("^from\\s*:\\s*(.+)$", ignoreCase: true)
  private static let returnTo = MailRegex(
    "(?:if undelivered,? (?:please )?return to|return address|returns? to)\\s*:?\\s*(.*)$", ignoreCase: true)
  private static let signOff = MailRegex(
    "^(?:yours (?:sincerely|faithfully|truly)|(?:kind|best|warm|warmest) (?:regards|wishes)|regards|"
      + "with (?:love|best wishes)|lots of love|love(?: from)?|all my love|many thanks|thank you|best),?$",
    ignoreCase: true)
  private static let title = MailRegex(
    "^(?:mr|mrs|ms|miss|mx|dr|prof|sir|lady|rev|the (?:occupier|resident|homeowner|householder))\\b\\.?", ignoreCase: true)
  private static let skipInAddress = MailRegex(
    "^(?:private (?:and|&) confidential|addressee only|personal|urgent|to the addressee|[A-Z0-9]{1,3}-[A-Z0-9-]{4,})$",
    ignoreCase: true)
  private static let postalMarks = MailRegex(
    "royal mail|postage paid|first class|1st class|second class|2nd class|if undelivered|return to|"
      + "par avion|air mail|do not bend|postage|franked|mailsort",
    ignoreCase: true)

  // Amount due, strongest first. Lines with these words but also "previous/paid/credit" don't count.
  private static let dueWords = MailRegex(
    "amount (?:now )?due|total (?:amount )?due|balance (?:now )?due|amount (?:to pay|payable|owing|outstanding)|"
      + "total to pay|please pay|you owe|now due|due now|to pay|we will (?:take|collect)|direct debit (?:of|amount)|"
      + "payment (?:of|due)|pay (?:by|before|the sum)|outstanding balance|new balance|statement balance",
    ignoreCase: true)
  private static let minimumWords = MailRegex("minimum (?:payment|amount|repayment)", ignoreCase: true)
  private static let totalWords = MailRegex("\\btotal\\b", ignoreCase: true)
  private static let notDue = MailRegex(
    "previous|last (?:bill|statement)|received|you paid|we received|paid on|credit limit|available|"
      + "excl|excluding|before vat|sub ?total|vat at|saving|you saved|was £",
    ignoreCase: true)

  private static let deadlinePay = MailRegex(
    "\\b(?:due|pay(?:ment)?(?: due)?(?: date)? (?:by|before|on)|deadline|no later than|collected on|taken on|expires?)\\b",
    ignoreCase: true)
  /// "by" or "before" straight in front of the date also makes it a deadline.
  private static let byBeforeDate = MailRegex("\\b(?:by|before|on or before)(?: the)?\\s*$", ignoreCase: true)
  private static let time = MailRegex("\\b(\\d{1,2})[:.](\\d{2}) ?(am|pm)?\\b|\\b(\\d{1,2}) ?(am|pm)\\b", ignoreCase: true)
  private static let deadlineReply = MailRegex(
    "\\b(?:reply|respond|return (?:this|the form)|let us know|contact us) (?:by|before)\\b", ignoreCase: true)
  private static let appointment = MailRegex("\\bappointment\\b", ignoreCase: true)
  private static let within = MailRegex(
    "\\bwithin (\\d{1,3}|seven|fourteen|twenty[- ]eight|thirty) (?:working )?days\\b", ignoreCase: true)

  static let reference = MailRegex(
    "\\b(account number|account no\\.?|acct no\\.?|customer number|customer no\\.?|reference number|reference|our ref(?:erence)?|"
      + "your ref(?:erence)?|ref|policy number|nhs number|hospital number|invoice number|national insurance number|"
      + "council tax reference|claim number|case number|membership number|account ending(?: in)?|sort code)"
      // The value: groups that each contain a digit ("8842 1937 55", "20-45-77", "AB123456C"), so
      // the words after it aren't taken.
      + "\\s*[:.#]?\\s*([A-Z]{0,4}\\d[A-Z0-9]*(?:[ \\-/][A-Z]{0,2}\\d[A-Z0-9]*)*)",
    ignoreCase: true)

  /// In score order: on a tie the earlier kind wins, as in the Kotlin map.
  private static let kindWords: [(LetterKind, [(String, Int)])] = [
    (
      .bill,
      [
        ("amount due", 3), ("your bill", 3), ("bill", 2), ("invoice", 3), ("payment due", 3), ("direct debit", 2),
        ("pay by", 2), ("please pay", 3), ("kwh", 3), ("electricity", 2), ("gas", 1), ("water", 1),
        ("broadband", 2), ("meter", 2), ("tariff", 2), ("standing charge", 3), ("total due", 3), ("charges", 1),
      ]
    ),
    (
      .bank,
      [
        ("bank", 3), ("building society", 3), ("sort code", 3), ("overdraft", 3), ("account ending", 2),
        ("credit card", 2), ("statement", 1), ("interest", 1), ("savings", 2), ("mortgage", 2), ("iban", 2),
        ("debit card", 2), ("current account", 3), ("card ending", 2),
      ]
    ),
    (
      .official,
      [
        ("council", 3), ("council tax", 3), ("hmrc", 4), ("dvla", 4), ("dwp", 4), ("department for", 3),
        ("government", 2), ("gov.uk", 3), ("benefit", 2), ("court", 3), ("electoral", 3), ("tv licensing", 3),
        ("national insurance", 3), ("jobcentre", 3), ("passport", 2), ("penalty charge", 3), ("tax year", 2),
        ("valuation band", 3), ("borough", 2),
      ]
    ),
    (
      .medical,
      [
        ("nhs", 3), ("hospital", 3), ("clinic", 2), ("appointment", 2), ("patient", 2), ("gp", 2),
        ("outpatient", 3), ("prescription", 2), ("vaccination", 2), ("consultant", 1), ("medical", 2),
        ("health centre", 3), ("dental", 2), ("surgery", 1),
      ]
    ),
    (
      .personal,
      [
        ("lots of love", 4), ("love from", 3), ("with love", 3), ("miss you", 3), ("hope you", 3),
        ("thinking of you", 3), ("best wishes", 2), ("love", 1), ("see you soon", 2), ("xx", 2),
      ]
    ),
    (
      .advert,
      [
        ("special offer", 3), ("offer", 2), ("free", 1), ("sale", 2), ("% off", 3), ("limited time", 3),
        ("win", 2), ("prize", 3), ("discount", 2), ("call now", 3), ("don't miss", 3), ("occupier", 3),
        ("homeowner", 2), ("resident", 2), ("exclusive", 2), ("deal", 2), ("voucher", 2), ("order now", 3),
        ("today only", 3), ("new customers", 2), ("visit our", 2), ("act now", 3), ("half price", 3),
      ]
    ),
  ]

  private static let kindPatterns: [(LetterKind, [(MailRegex, Int)])] = kindWords.map { kind, words in
    (
      kind,
      words.map { word, weight in
        (MailRegex("(?<![a-z])\(NSRegularExpression.escapedPattern(for: word))(?![a-z])"), weight)
      }
    )
  }

  static func read(_ scans: [LetterScan]) -> Letter { analyse(scans.map(LetterLayout.layout)) }

  static func analyse(_ pages: [LaidOutLetter]) -> Letter {
    precondition(!pages.isEmpty)
    let first = pages[0]
    let allLines = pages.flatMap(\.lines)
    let text = allLines.map(\.text).joined(separator: "\n")

    let header = headerOf(first)
    let salutation = first.lines.lazy.compactMap { dear.wholeMatch($0.text.trimmed)?.group(1, in: $0.text.trimmed)?.trimmed }.first
    let recipientBlock = recipientBlockOf(first, header: header)
    let recipientLines = (recipientBlock?.lines ?? []).map(\.text.trimmed).filter { !skipInAddress.matchesWhole($0) }
    let recipient = recipientLines.first?.trimmingTrailing([","])
    let address = recipientLines.dropFirst().map { $0.trimmingTrailing([","]) }.joined(separator: ", ")
    let recipientAddress = address.trimmed.isEmpty ? nil : address

    let due = deadlineOf(pages)
    func firstNonDeadlineDate(_ lines: [LetterLine]) -> LetterDate? {
      lines.lazy.compactMap { line in isDeadline(line.text) ? nil : LetterText.dates(line.text).first }.first
    }
    let date = firstNonDeadlineDate(header) ?? firstNonDeadlineDate(allLines)

    let subject = subjectOf(first, recipient: recipientBlock)
    let opening = subject == nil ? openingOf(first) : nil
    let amount = amountOf(allLines)
    let references = referencesOf(allLines)
    let amountsMentioned = allLines.reduce(0) { $0 + LetterText.money($1.text).count }
    let unsureMoney = Set(allLines.flatMap { line in LetterText.money(line.text).filter { !isSure(line, $0) }.map(\.raw) })

    let words = text.split(whereSeparator: \.isWhitespace).count
    let longLines = allLines.filter { $0.box.width > CGFloat(first.scan.width) * 0.5 && $0.text.utf16Count > 40 }.count
    let hasSignOff = allLines.contains { signOff.matchesWhole($0.text.trimmed) }
    let looksLikeEnvelope =
      salutation == nil && !hasSignOff && longLines <= 1 && words < 60
      && (recipientBlock != nil || postalMarks.contains(text))

    let kind = kindOf(text, salutation: salutation, amount: amount, references: references)
    let isEnvelope = looksLikeEnvelope && kind != .advert
    let sender = senderOf(first, header: header, recipient: recipientBlock, envelope: isEnvelope)

    return Letter(
      pages: pages, isEnvelope: isEnvelope, kind: isEnvelope ? .unknown : kind, sender: sender, recipient: recipient,
      recipientAddress: recipientAddress, salutation: salutation, date: date, subject: subject, opening: opening,
      amount: amount, due: due, references: references, amountsMentioned: amountsMentioned, unsureMoney: unsureMoney,
      scamSigns: ScamSigns.find(text))
  }

  /// The second-picture check, iOS only. `other` is the same page read from another picture.
  /// If both read a sure amount due and the figures differ, neither is trusted: the amount
  /// becomes unsure and every printing of it is masked. Anything else leaves `letter` as it was
  /// (a second picture that can't read the amount is no evidence against the first).
  static func crossChecked(_ letter: Letter, with other: Letter) -> Letter {
    guard case .sure(let money, let minimum, _) = letter.amount, case .sure(let otherMoney, let otherMinimum, _) = other.amount
    else { return letter }
    let minimumDiffers = minimum != nil && otherMinimum != nil && minimum != otherMinimum
    guard money != otherMoney || minimumDiffers else { return letter }
    var checked = letter
    checked.amount = .unsure
    let disputed = Set([money, minimum].compactMap { $0 })
    for line in letter.pages.flatMap(\.lines) {
      for token in LetterText.money(line.text) where token.money.map(disputed.contains) ?? false {
        checked.unsureMoney.insert(token.raw)
      }
    }
    return checked
  }

  /// Lines above "Dear ..." or the subject line; else the top third of the page.
  private static func headerOf(_ page: LaidOutLetter) -> [LetterLine] {
    let lines = page.lines
    if let stop = lines.firstIndex(where: { dear.matchesWhole($0.text.trimmed) || subjectLine.matchesWhole($0.text.trimmed) }),
      stop > 0
    {
      let y = lines[stop].box.minY
      return lines.filter { $0.box.maxY <= y + 1 }
    }
    return lines.filter { $0.box.maxY < CGFloat(page.scan.height) * 0.36 }
  }

  private static func looksLikeAddress(_ block: LetterBlock) -> Bool {
    block.lines.count >= 2 && block.lines.contains { LetterText.hasPostcode($0.text) }
  }

  private static func firstAddressLine(_ block: LetterBlock) -> String? {
    block.lines.map(\.text.trimmed).first { !skipInAddress.matchesWhole($0) }
  }

  private static func recipientBlockOf(_ page: LaidOutLetter, header: [LetterLine]) -> LetterBlock? {
    let width = CGFloat(page.scan.width)
    let candidates = page.blocks.filter { block in
      guard header.isEmpty || block.lines.contains(where: header.contains) else { return false }
      guard let first = firstAddressLine(block) else { return false }
      let titled = block.lines.count >= 2 && title.contains(first)
      // An untitled address on the right is the sender's own (a personal letter's top right).
      return titled || (looksLikeAddress(block) && block.box.midX < width * 0.55)
    }
    // Prefer a named addressee ("Mrs ...") on the left: the window position.
    func score(_ block: LetterBlock) -> Int {
      (title.contains(firstAddressLine(block) ?? "") ? 4 : 0) + (block.box.midX < width * 0.5 ? 2 : 0)
        + (looksLikeAddress(block) ? 1 : 0)
    }
    return candidates.max { score($0) < score($1) }
  }

  private static func senderOf(_ page: LaidOutLetter, header: [LetterLine], recipient: LetterBlock?, envelope: Bool) -> String? {
    let lines = page.lines
    if let from = lines.lazy.compactMap({ fromLine.wholeMatch($0.text.trimmed)?.group(1, in: $0.text.trimmed)?.trimmed }).first {
      return from
    }
    if envelope {
      for (i, line) in lines.enumerated() {
        guard let match = returnTo.firstMatch(in: line.text) else { continue }
        // "If undelivered please return to:" with the name on the next line.
        var name = (match.group(1, in: line.text) ?? "").trimmed.trimmingTrailing([",", "."])
        if name.isEmpty, i + 1 < lines.count { name = lines[i + 1].text.trimmed }
        if !name.isEmpty { return name.split(separator: ",").first.map { String($0).trimmed } ?? name }
      }
    }
    let recipientLines = recipient?.lines ?? []
    // Letterhead: the biggest text near the top that isn't the addressee, a date or a number.
    let top = lines.filter { $0.box.maxY < CGFloat(page.scan.height) * 0.25 && !recipientLines.contains($0) }
    let big = top.filter { line in
      line.box.height >= page.bodyHeight * 1.3 && line.text.filter(\.isLetter).count >= 3
        && LetterText.dates(line.text).isEmpty && !postalMarks.contains(line.text)
    }.max { $0.box.height < $1.box.height }
    if let big { return big.text.trimmed }
    if let signature = signatureOf(page) { return signature }
    // The other address block (a sender's address at the top right): its first line, if a name.
    let other = page.blocks.first { block in
      block != recipient && block.lines.count >= 2 && block.lines.contains(where: header.contains) && looksLikeAddress(block)
    }
    if let first = other?.lines.first?.text.trimmed, let c = first.first, !c.isNumber { return first }
    return nil
  }

  /// The name under "Yours sincerely" (or "Love,"): the first short line of letters after it.
  private static func signatureOf(_ page: LaidOutLetter) -> String? {
    let lines = page.lines
    guard let at = lines.firstIndex(where: { signOff.matchesWhole($0.text.trimmed) }) else { return nil }
    return lines.dropFirst(at + 1).prefix(3).map(\.text.trimmed).first { t in
      (2...40).contains(t.count) && t.split(separator: " ").count <= 5
        && Double(t.filter(\.isLetter).count) >= Double(t.count) * 0.7 && !(t.first?.isNumber ?? true)
    }
  }

  private static func subjectOf(_ page: LaidOutLetter, recipient: LetterBlock?) -> String? {
    if let subject = page.lines.lazy.compactMap({ subjectLine.wholeMatch($0.text.trimmed)?.group(1, in: $0.text.trimmed)?.trimmed })
      .first
    {
      return subject
    }
    // A heading: a short line of larger text below the letterhead, not an address.
    let skip = recipient?.lines ?? []
    return page.lines.first { line in
      let t = line.text.trimmed
      return !skip.contains(line) && line.box.minY > CGFloat(page.scan.height) * 0.15
        && line.box.height >= page.bodyHeight * 1.15 && (4...80).contains(line.text.count)
        && line.text.filter(\.isLetter).count >= 4 && !dear.matchesWhole(t) && !signOff.matchesWhole(t)
        && LetterText.money(line.text).isEmpty
    }?.text.trimmed
  }

  /// The first sentence after "Dear ...", trimmed to about 25 words.
  private static func openingOf(_ page: LaidOutLetter) -> String? {
    let body: [String]
    if let dearAt = page.paragraphs.firstIndex(where: { dear.matchesWhole($0.trimmed) }) {
      body = Array(page.paragraphs.dropFirst(dearAt + 1))
    } else {
      body = page.blocks.filter { !$0.isShortLines && $0.lines.count >= 2 }.map(LetterLayout.paragraph)
    }
    guard let paragraph = body.first(where: { $0.count > 30 }), let sentence = LetterSentences.split(paragraph).first else {
      return nil
    }
    let words = sentence.split(separator: " ")
    return words.count <= 25 ? sentence : words.prefix(25).joined(separator: " ") + "…"
  }

  private static func isDeadline(_ line: String) -> Bool {
    deadlinePay.contains(line) || deadlineReply.contains(line) || appointment.contains(line)
      || LetterText.dates(line).contains { byBeforeDate.contains(line.utf16Substring(0, $0.first)) }
  }

  private static func deadlineOf(_ pages: [LaidOutLetter]) -> DueDate? {
    var best: (rank: Int, due: DueDate)?
    for page in pages {
      let lines = page.lines
      for (i, line) in lines.enumerated() {
        let t = line.text
        let kind: DueKind
        if appointment.contains(t) {
          kind = .appointment
        } else if deadlineReply.contains(t) {
          kind = .reply
        } else if deadlinePay.contains(t) {
          kind = .pay
        } else if LetterText.dates(t).contains(where: { byBeforeDate.contains(t.utf16Substring(0, $0.first)) }) {
          kind = .other
        } else {
          continue
        }
        // The date on this line, or at the start of the next line in the same block.
        var source = line
        var dates = LetterText.dates(t)
        if dates.isEmpty, i + 1 < lines.count, lines[i + 1].block == line.block {
          dates = LetterText.dates(lines[i + 1].text).filter { $0.first <= 3 }
          source = lines[i + 1]
        }
        let rank =
          switch kind {
          case .pay: 4
          case .appointment: 3
          case .reply: 2
          case .other: 1
          }
        var due: DueDate?
        if let d = dates.first {
          let c = source.minConfidence(d.first, d.last + 1, digitsOnly: true)
          let sure = c.map { $0 >= threshold(source) } ?? true
          var spoken = d.spoken()
          if kind == .appointment, let match = time.firstMatch(in: source.text.utf16Substring(d.last + 1, source.text.utf16Count)) {
            spoken += " at " + match.value(in: source.text.utf16Substring(d.last + 1, source.text.utf16Count))
          }
          due = DueDate(kind: kind, spoken: spoken, sure: sure)
        } else if let match = within.firstMatch(in: t) {
          due = DueDate(kind: kind, spoken: match.value(in: t).lowercased(), sure: true)
        }
        if let due, best == nil || rank > best!.rank { best = (rank, due) }
      }
    }
    return best?.due
  }

  private static func threshold(_ line: LetterLine) -> Float {
    let hasSymbols = line.words.contains { !$0.symbolConfidences.isEmpty && $0.symbolConfidences.count == $0.text.utf16Count }
    return hasSymbols ? minDigitConfidence : minWordConfidence
  }

  private struct Mention {
    var money: Money?
    var sure: Bool
  }

  /// The money rule for one amount as printed: every character parsed as a digit (no O for 0),
  /// every part of it (digits, point and currency sign: a digit lost to a smudge lowers its
  /// neighbours) read at or above the bar, and no sign of a character gone missing.
  static func isSure(_ line: LetterLine, _ token: MoneyToken) -> Bool {
    guard token.money != nil else { return false }
    let start = token.first
    let end = token.last + 1
    if let c = line.minConfidence(start, end), c < threshold(line) { return false }
    return !line.looksLikeAMissingCharacter(start, end)
  }

  /// The money rule lives here. See the file header.
  static func amountOf(_ lines: [LetterLine]) -> AmountDue {
    func mentions(_ filter: (String) -> Bool) -> [Mention] {
      lines.filter { filter($0.text) && !notDue.contains($0.text) }.flatMap { line in
        LetterText.money(line.text).filter { !$0.credit }.map { Mention(money: $0.money, sure: isSure(line, $0)) }
      }
    }
    var due = mentions { dueWords.contains($0) && !minimumWords.contains($0) }
    let isTotal = due.isEmpty
    if isTotal { due = mentions { totalWords.contains($0) && !minimumWords.contains($0) } }
    let minimum = mentions { minimumWords.contains($0) }
    if due.isEmpty && minimum.isEmpty { return .none }
    if due.isEmpty { return judge(minimum).map { .sure($0) } ?? verdict(minimum) }
    guard let main = judge(due) else { return verdict(due) }
    return .sure(main, minimum: minimum.isEmpty ? nil : judge(minimum), isTotal: isTotal)
  }

  /// The one value if every mention is sure and they agree, else nil.
  private static func judge(_ mentions: [Mention]) -> Money? {
    guard mentions.allSatisfy(\.sure) else { return nil }
    let values = distinct(mentions.compactMap(\.money))
    return values.count == 1 ? values[0] : nil
  }

  private static func verdict(_ mentions: [Mention]) -> AmountDue {
    let sureValues = distinct(mentions.filter(\.sure).compactMap(\.money))
    return mentions.allSatisfy(\.sure) && sureValues.count > 1 ? .conflict : .unsure
  }

  private static func distinct(_ values: [Money]) -> [Money] {
    var seen = Set<Money>()
    return values.filter { seen.insert($0).inserted }
  }

  private static let trailingNo = MailRegex("\\bno\\.?$")
  private static let ourYourRef = MailRegex("^(our|your) ref$")

  private static func referencesOf(_ lines: [LetterLine]) -> [Reference] {
    var out: [Reference] = []
    for line in lines {
      for match in reference.matches(in: line.text) {
        // Lower case, but acronyms as printed ("NHS number").
        let printed = (match.group(1, in: line.text) ?? "").split(separator: " ", omittingEmptySubsequences: false).map { w in
          (2...4).contains(w.count) && w.allSatisfy(\.isUppercase) ? String(w) : w.lowercased()
        }.joined(separator: " ")
        var label = ourYourRef.replace(in: trailingNo.replace(in: printed, template: "number"), template: "$1 reference")
        if label == "ref" { label = "reference" }
        let value = (match.group(2, in: line.text) ?? "").trimmed
        if value.filter(\.isASCIIDigit).count < 3 { continue }
        if !out.contains(where: { $0.value == value }) { out.append(Reference(label: label, value: value)) }
      }
    }
    return out
  }

  static func kindOf(_ text: String, salutation: String?, amount: AmountDue, references: [Reference]) -> LetterKind {
    let lower = text.lowercased()
    var scores: [(LetterKind, Int)] = kindPatterns.map { kind, patterns in
      (kind, patterns.reduce(0) { $0 + ($1.0.contains(lower) ? $1.1 : 0) })
    }
    func add(_ kind: LetterKind, _ points: Int) {
      if let i = scores.firstIndex(where: { $0.0 == kind }) { scores[i].1 += points }
    }
    func score(_ kind: LetterKind) -> Int { scores.first { $0.0 == kind }?.1 ?? 0 }
    if amount != .none { add(.bill, 3) }
    add(.advert, min(3, text.filter { $0 == "!" }.count))
    let sal = salutation?.trimmed ?? ""
    let generic: Set<String> = ["sir", "madam", "customer", "occupier", "resident", "homeowner", "member", "patient"]
    if !sal.isEmpty && !title.contains(sal) && sal.split(separator: " ").count == 1 && !generic.contains(sal.lowercased()) {
      add(.personal, 2)
    }
    if amount == .none && references.isEmpty { add(.personal, 1) }
    // A council tax bill is an official letter that asks for money: official/bank/medical beat bill
    // when they're strong, and the amount is said either way.
    guard let best = scores.max(by: { $0.1 < $1.1 }) else { return .unknown }
    let advert = score(.advert)
    if advert >= 5 && scores.filter({ $0.0 != .advert }).allSatisfy({ $0.1 < advert }) { return .advert }
    for kind in [LetterKind.official, .medical, .bank] where score(kind) >= 5 && score(kind) >= best.1 - 3 {
      return kind
    }
    if best.1 < 3 { return .unknown }
    if best.0 == .advert {
      // Adverts must clearly win; otherwise it's something that mentions an offer.
      guard let other = scores.filter({ $0.0 != .advert }).max(by: { $0.1 < $1.1 }), other.1 >= 3 else { return .unknown }
      return other.0
    }
    return best.0
  }
}

// MARK: - Sentences

/// A paragraph cut into sentences (Android SpeechChunker.sentences): at ". ! ? …" followed by a
/// space and a capital, digit or quote, not after a known abbreviation ("Mr.", "No.").
enum LetterSentences {
  private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

  static func split(_ paragraph: String) -> [String] {
    let text = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let chars = Array(text)
    guard !chars.isEmpty else { return [] }
    var out: [String] = []
    var start = 0
    var i = 0
    while i < chars.count {
      if ".!?…".contains(chars[i]) {
        var end = i + 1
        while end < chars.count && ".!?".contains(chars[end]) { end += 1 }
        while end < chars.count && closers.contains(chars[end]) { end += 1 }
        let atEnd = end >= chars.count
        let followedBySpace = !atEnd && chars[end] == " "
        if atEnd || (followedBySpace && startsSentence(chars, end + 1) && !isAbbreviation(chars, at: i)) {
          let sentence = String(chars[start..<end]).trimmed
          if !sentence.isEmpty { out.append(sentence) }
          start = end
          i = end
          continue
        }
      }
      i += 1
    }
    if start < chars.count {
      let rest = String(chars[start...]).trimmed
      if !rest.isEmpty { out.append(rest) }
    }
    return out
  }

  private static func startsSentence(_ chars: [Character], _ at: Int) -> Bool {
    guard at < chars.count else { return false }
    let c = chars[at]
    return c.isUppercase || c.isNumber || "\"'“‘([«".contains(c)
  }

  /// The word ending at `at` (a ".") is an abbreviation or an initial.
  private static func isAbbreviation(_ chars: [Character], at: Int) -> Bool {
    guard chars[at] == "." else { return false }
    var start = at
    while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
    let word = String(chars[start...at])
    return SentenceSplitter.abbreviations.contains(word.lowercased()) || (word.count == 2 && word.first?.isUppercase == true)
  }
}
