// LetterReader - what a letter is: sender, recipient, kind, subject, amount due and deadline
//
// Fixed rules on the phone, no cloud (ROADMAP). From the laid-out pages (LetterLayout):
//   - header = everything above "Dear ..." (or the subject line); the recipient is the address
//     block with a postcode or a "Mr/Mrs/Ms..." first line; the sender is a "From:" line, else the
//     letterhead (the largest text near the top), else the name under "Yours sincerely", else the
//     other address block, else an envelope's "If undelivered return to ..." line;
//   - date = the first date that isn't a deadline; subject = "Re:/Subject:" or a heading line, else
//     the first sentence of the body;
//   - amount due = money on a line that says "amount due / total to pay / please pay / balance
//     due..." (else "total"), deadline = a date on a line that says "due / pay by / before...";
//   - kind = keyword scores (bill, bank, official, medical, personal, advert);
//   - envelope = no "Dear", no paragraphs, few words, an address block or postal markings.
// The money rule: if any character of the amount due was read with low confidence, or a letter
// sits where a digit should be, or the character boxes show a digit went missing (a smudged "£84.17"
// read as "£8.17"), or two different amounts are both "due", the amount is Unsure or Conflict and
// no figure is spoken. Pages after the first add amounts and text, and fill in any
// header field the first page didn't have. Pure Kotlin.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

enum class LetterKind { BILL, BANK, OFFICIAL, MEDICAL, PERSONAL, ADVERT, UNKNOWN }

/** The amount to pay, as far as it can be read safely. */
sealed interface AmountDue {
  data object None : AmountDue

  data class Sure(val money: Money, val minimum: Money? = null, val isTotal: Boolean = false) : AmountDue

  /** There is an amount due, but a digit is unsure. Never say a figure. */
  data object Unsure : AmountDue

  /** Two different amounts are both marked as due. Never say a figure. */
  data object Conflict : AmountDue
}

enum class DueKind { PAY, REPLY, APPOINTMENT, OTHER }

/** A deadline: a date, or a phrase like "within 14 days". [sure] is false if a digit was unsure. */
data class DueDate(val kind: DueKind, val spoken: String, val sure: Boolean)

data class Reference(val label: String, val value: String) {
  val spoken: String
    get() = "$label ${LetterText.spellOut(value)}"
}

data class Letter(
    val pages: List<LaidOutLetter>,
    val isEnvelope: Boolean,
    val kind: LetterKind,
    val sender: String?,
    val recipient: String?,
    /** The recipient's address after the name, one string with commas ("14 Elm Road, Leeds LS6 2AB"). */
    val recipientAddress: String?,
    val salutation: String?,
    val date: LetterDate?,
    val subject: String?,
    /** The first sentence of the body, when there's no subject line. */
    val opening: String?,
    val amount: AmountDue,
    val due: DueDate?,
    val references: List<Reference>,
    /** Number of money amounts anywhere in the letter (charges, balances...). */
    val amountsMentioned: Int,
    /** Money tokens (as printed) with a digit read below the confidence threshold: never read out. */
    val unsureMoney: Set<String> = emptySet(),
) {
  /** [paragraphs] ready for speech: unsure amounts replaced, digit runs spaced. */
  val readingParagraphs: List<String>
    get() = paragraphs.map { LetterSpeech.forReading(it, unsureMoney) }

  /** Every paragraph of every page; "Page 2." before each later page. */
  val paragraphs: List<String>
    get() =
        pages.flatMapIndexed { i, p -> if (i == 0) p.paragraphs else listOf("Page ${i + 1}.") + p.paragraphs }

  val fullText: String
    get() = paragraphs.joinToString("\n\n")

  /** [fullText] with unsure amounts replaced: what the screen shows and the ask seam gets. */
  val safeText: String
    get() = paragraphs.joinToString("\n\n") { LetterSpeech.masked(it, unsureMoney) }
}

object LetterReader {

  /** A character of an amount read below this (character confidence) is unsure. */
  const val MIN_DIGIT_CONFIDENCE = 0.5f
  /** When only a word or line confidence is known, below this is unsure. */
  const val MIN_WORD_CONFIDENCE = 0.6f

  private val DEAR = Regex("^dear\\s+(.+?)[,.;:]?$", RegexOption.IGNORE_CASE)
  private val SUBJECT = Regex("^(?:re|subject|regarding)\\s*[:\\-]\\s*(.+)$", RegexOption.IGNORE_CASE)
  private val FROM = Regex("^from\\s*:\\s*(.+)$", RegexOption.IGNORE_CASE)
  private val RETURN_TO =
      Regex("(?:if undelivered,? (?:please )?return to|return address|returns? to)\\s*:?\\s*(.*)$", RegexOption.IGNORE_CASE)
  private val SIGN_OFF =
      Regex(
          "^(?:yours (?:sincerely|faithfully|truly)|(?:kind|best|warm|warmest) (?:regards|wishes)|regards|" +
              "with (?:love|best wishes)|lots of love|love(?: from)?|all my love|many thanks|thank you|best),?$",
          RegexOption.IGNORE_CASE,
      )
  private val TITLE = Regex("^(?:mr|mrs|ms|miss|mx|dr|prof|sir|lady|rev|the (?:occupier|resident|homeowner|householder))\\b\\.?", RegexOption.IGNORE_CASE)
  private val SKIP_IN_ADDRESS =
      Regex("^(?:private (?:and|&) confidential|addressee only|personal|urgent|to the addressee|[A-Z0-9]{1,3}-[A-Z0-9-]{4,})$", RegexOption.IGNORE_CASE)
  private val POSTAL_MARKS =
      Regex(
          "royal mail|postage paid|first class|1st class|second class|2nd class|if undelivered|return to|" +
              "par avion|air mail|do not bend|postage|franked|mailsort",
          RegexOption.IGNORE_CASE,
      )

  // Amount due, strongest first. Lines with these words but also "previous/paid/credit" don't count.
  private val DUE_WORDS =
      Regex(
          "amount (?:now )?due|total (?:amount )?due|balance (?:now )?due|amount (?:to pay|payable|owing|outstanding)|" +
              "total to pay|please pay|you owe|now due|due now|to pay|we will (?:take|collect)|direct debit (?:of|amount)|" +
              "payment (?:of|due)|pay (?:by|before|the sum)|outstanding balance|new balance|statement balance",
          RegexOption.IGNORE_CASE,
      )
  private val MINIMUM_WORDS = Regex("minimum (?:payment|amount|repayment)", RegexOption.IGNORE_CASE)
  private val TOTAL_WORDS = Regex("\\btotal\\b", RegexOption.IGNORE_CASE)
  private val NOT_DUE =
      Regex(
          "previous|last (?:bill|statement)|received|you paid|we received|paid on|credit limit|available|" +
              "excl|excluding|before vat|sub ?total|vat at|saving|you saved|was £",
          RegexOption.IGNORE_CASE,
      )

  private val DEADLINE_PAY =
      Regex("\\b(?:due|pay(?:ment)?(?: due)?(?: date)? (?:by|before|on)|deadline|no later than|collected on|taken on|expires?)\\b", RegexOption.IGNORE_CASE)
  /** "by" or "before" straight in front of the date also makes it a deadline: "...the form by 4 May 2026". */
  private val BY_BEFORE_DATE = Regex("\\b(?:by|before|on or before)(?: the)?\\s*$", RegexOption.IGNORE_CASE)
  private val TIME = Regex("\\b(\\d{1,2})[:.](\\d{2}) ?(am|pm)?\\b|\\b(\\d{1,2}) ?(am|pm)\\b", RegexOption.IGNORE_CASE)
  private val DEADLINE_REPLY = Regex("\\b(?:reply|respond|return (?:this|the form)|let us know|contact us) (?:by|before)\\b", RegexOption.IGNORE_CASE)
  private val APPOINTMENT = Regex("\\bappointment\\b", RegexOption.IGNORE_CASE)
  private val WITHIN = Regex("\\bwithin (\\d{1,3}|seven|fourteen|twenty[- ]eight|thirty) (?:working )?days\\b", RegexOption.IGNORE_CASE)

  internal val REFERENCE =
      Regex(
          "\\b(account number|account no\\.?|acct no\\.?|customer number|customer no\\.?|reference number|reference|our ref(?:erence)?|" +
              "your ref(?:erence)?|ref|policy number|nhs number|hospital number|invoice number|national insurance number|" +
              "council tax reference|claim number|case number|membership number|account ending(?: in)?|sort code)" +
              // The value: groups that each contain a digit ("8842 1937 55", "20-45-77", "AB123456C"), so
              // the words after it ("55 and your...") aren't taken.
              "\\s*[:.#]?\\s*([A-Z]{0,4}\\d[A-Z0-9]*(?:[ \\-/][A-Z]{0,2}\\d[A-Z0-9]*)*)",
          RegexOption.IGNORE_CASE,
      )

  private val KIND_WORDS: Map<LetterKind, List<Pair<String, Int>>> =
      mapOf(
          LetterKind.BILL to listOf(
              "amount due" to 3, "your bill" to 3, "bill" to 2, "invoice" to 3, "payment due" to 3, "direct debit" to 2,
              "pay by" to 2, "please pay" to 3, "kwh" to 3, "electricity" to 2, "gas" to 1, "water" to 1,
              "broadband" to 2, "meter" to 2, "tariff" to 2, "standing charge" to 3, "total due" to 3, "charges" to 1),
          LetterKind.BANK to listOf(
              "bank" to 3, "building society" to 3, "sort code" to 3, "overdraft" to 3, "account ending" to 2,
              "credit card" to 2, "statement" to 1, "interest" to 1, "savings" to 2, "mortgage" to 2, "iban" to 2,
              "debit card" to 2, "current account" to 3, "card ending" to 2),
          LetterKind.OFFICIAL to listOf(
              "council" to 3, "council tax" to 3, "hmrc" to 4, "dvla" to 4, "dwp" to 4, "department for" to 3,
              "government" to 2, "gov.uk" to 3, "benefit" to 2, "court" to 3, "electoral" to 3, "tv licensing" to 3,
              "national insurance" to 3, "jobcentre" to 3, "passport" to 2, "penalty charge" to 3, "tax year" to 2,
              "valuation band" to 3, "borough" to 2),
          LetterKind.MEDICAL to listOf(
              "nhs" to 3, "hospital" to 3, "clinic" to 2, "appointment" to 2, "patient" to 2, "gp" to 2,
              "outpatient" to 3, "prescription" to 2, "vaccination" to 2, "consultant" to 1, "medical" to 2,
              "health centre" to 3, "dental" to 2, "surgery" to 1),
          LetterKind.PERSONAL to listOf(
              "lots of love" to 4, "love from" to 3, "with love" to 3, "miss you" to 3, "hope you" to 3,
              "thinking of you" to 3, "best wishes" to 2, "love" to 1, "see you soon" to 2, "xx" to 2),
          LetterKind.ADVERT to listOf(
              "special offer" to 3, "offer" to 2, "free" to 1, "sale" to 2, "% off" to 3, "limited time" to 3,
              "win" to 2, "prize" to 3, "discount" to 2, "call now" to 3, "don't miss" to 3, "occupier" to 3,
              "homeowner" to 2, "resident" to 2, "exclusive" to 2, "deal" to 2, "voucher" to 2, "order now" to 3,
              "today only" to 3, "new customers" to 2, "visit our" to 2, "act now" to 3, "half price" to 3),
      )

  fun read(scans: List<LetterScan>): Letter = analyse(scans.map(LetterLayout::layout))

  fun analyse(pages: List<LaidOutLetter>): Letter {
    require(pages.isNotEmpty())
    val first = pages.first()
    val allLines = pages.flatMap { it.lines }
    val text = allLines.joinToString("\n") { it.text }

    val header = headerOf(first)
    val salutation = first.lines.firstNotNullOfOrNull { DEAR.matchEntire(it.text.trim())?.groupValues?.get(1)?.trim() }
    val recipientBlock = recipientBlock(first, header)
    val recipientLines = recipientBlock?.lines?.map { it.text.trim() }?.filterNot { SKIP_IN_ADDRESS.matches(it) }.orEmpty()
    val recipient = recipientLines.firstOrNull()?.trimEnd(',')
    val recipientAddress = recipientLines.drop(1).joinToString(", ") { it.trimEnd(',') }.ifBlank { null }

    val dueLines = deadlineOf(pages)
    val date =
        header.flatMap { l -> LetterText.dates(l.text).filter { !isDeadline(l.text) } }.firstOrNull()
            ?: allLines.flatMap { l -> LetterText.dates(l.text).filter { !isDeadline(l.text) } }.firstOrNull()

    val subject = subjectOf(first, recipientBlock)
    val opening = if (subject == null) openingOf(first) else null
    val amount = amountOf(allLines)
    val references = referencesOf(allLines)
    val amountsMentioned = allLines.sumOf { LetterText.money(it.text).size }
    val unsureMoney = allLines.flatMap { l -> LetterText.money(l.text).filter { !isSure(l, it) }.map { it.raw } }.toSet()

    val words = text.split(Regex("\\s+")).count { it.isNotBlank() }
    val longLines = allLines.count { it.box.width > first.scan.width * 0.5f && it.text.length > 40 }
    val hasSignOff = allLines.any { SIGN_OFF.matches(it.text.trim()) }
    val looksLikeEnvelope =
        salutation == null && !hasSignOff && longLines <= 1 && words < 60 &&
            (recipientBlock != null || POSTAL_MARKS.containsMatchIn(text))

    val kind = kindOf(text, salutation, amount, references)
    val isEnvelope = looksLikeEnvelope && kind != LetterKind.ADVERT
    val sender = senderOf(first, header, recipientBlock, isEnvelope)

    return Letter(
        pages = pages,
        isEnvelope = isEnvelope,
        kind = if (isEnvelope) LetterKind.UNKNOWN else kind,
        sender = sender,
        recipient = recipient,
        recipientAddress = recipientAddress,
        salutation = salutation,
        date = date,
        subject = subject,
        opening = opening,
        amount = amount,
        due = dueLines,
        references = references,
        amountsMentioned = amountsMentioned,
        unsureMoney = unsureMoney,
    )
  }

  /** Lines above "Dear ..." or the subject line; else the top third of the page. */
  private fun headerOf(page: LaidOutLetter): List<LetterLine> {
    val lines = page.lines
    val stop = lines.indexOfFirst { DEAR.matches(it.text.trim()) || SUBJECT.matches(it.text.trim()) }
    if (stop > 0) {
      val y = lines[stop].box.top
      return lines.filter { it.box.bottom <= y + 1f }
    }
    return lines.filter { it.box.bottom < page.scan.height * 0.36f }
  }

  private fun looksLikeAddress(block: LetterBlock): Boolean =
      block.lines.size >= 2 && block.lines.any { LetterText.hasPostcode(it.text) }

  private fun recipientBlock(page: LaidOutLetter, header: List<LetterLine>): LetterBlock? {
    val headerSet = header.toSet()
    val candidates =
        page.blocks.filter { b ->
          b.lines.any { it in headerSet } || header.isEmpty()
        }.filter { b ->
          val first = b.lines.map { it.text.trim() }.firstOrNull { !SKIP_IN_ADDRESS.matches(it) } ?: return@filter false
          val titled = b.lines.size >= 2 && TITLE.containsMatchIn(first)
          // An untitled address on the right is the sender's own (a personal letter's top right).
          titled || (looksLikeAddress(b) && b.box.centerX < page.scan.width * 0.55f)
        }
    if (candidates.isEmpty()) return null
    // Prefer a named addressee ("Mrs ...") on the left: the window position.
    return candidates.maxBy { b ->
      val first = b.lines.map { it.text.trim() }.firstOrNull { !SKIP_IN_ADDRESS.matches(it) }.orEmpty()
      (if (TITLE.containsMatchIn(first)) 4 else 0) +
          (if (b.box.centerX < page.scan.width * 0.5f) 2 else 0) +
          (if (looksLikeAddress(b)) 1 else 0)
    }
  }

  private fun senderOf(page: LaidOutLetter, header: List<LetterLine>, recipient: LetterBlock?, envelope: Boolean): String? {
    val lines = page.lines
    lines.firstNotNullOfOrNull { FROM.matchEntire(it.text.trim())?.groupValues?.get(1)?.trim() }?.let { return it }
    if (envelope) {
      lines.forEachIndexed { i, l ->
        val m = RETURN_TO.find(l.text) ?: return@forEachIndexed
        // "If undelivered please return to:" with the name on the next line.
        val name = m.groupValues[1].trim().trimEnd(',', '.').ifEmpty { lines.getOrNull(i + 1)?.text?.trim().orEmpty() }
        if (name.isNotEmpty()) return firstPart(name)
      }
    }
    val recipientLines = recipient?.lines.orEmpty().toSet()
    // Letterhead: the biggest text near the top that isn't the addressee, a date or a number.
    val top = lines.filter { it.box.bottom < page.scan.height * 0.25f && it !in recipientLines }
    val big =
        top.filter { l ->
          l.box.height >= page.bodyHeight * 1.3f && l.text.count(Char::isLetter) >= 3 &&
              LetterText.dates(l.text).isEmpty() && !POSTAL_MARKS.containsMatchIn(l.text)
        }.maxByOrNull { it.box.height }
    if (big != null) return big.text.trim()
    signatureOf(page)?.let { return it }
    // The other address block (a sender's address at the top right): its first line, if a name.
    val other =
        page.blocks.firstOrNull { b ->
          b != recipient && b.lines.size >= 2 && b.lines.any { it in header.toSet() } && looksLikeAddress(b)
        }
    other?.lines?.firstOrNull()?.text?.trim()?.takeIf { it.isNotEmpty() && !it.first().isDigit() }?.let { return it }
    return null
  }

  private fun firstPart(text: String): String = text.split(',').first().trim()

  /** The name under "Yours sincerely" (or "Love,"): the first short line of letters after it. */
  private fun signatureOf(page: LaidOutLetter): String? {
    val lines = page.lines
    val at = lines.indexOfFirst { SIGN_OFF.matches(it.text.trim()) }
    if (at < 0) return null
    return lines.drop(at + 1).take(3).map { it.text.trim() }.firstOrNull { t ->
      t.length in 2..40 && t.split(' ').size <= 5 && t.count(Char::isLetter) >= t.length * 0.7 && !t.first().isDigit()
    }
  }

  private fun subjectOf(page: LaidOutLetter, recipient: LetterBlock?): String? {
    page.lines.firstNotNullOfOrNull { SUBJECT.matchEntire(it.text.trim())?.groupValues?.get(1)?.trim() }?.let { return it }
    // A heading: a short line of larger text below the letterhead, not an address.
    val skip = recipient?.lines.orEmpty().toSet()
    return page.lines.firstOrNull { l ->
      l !in skip && l.box.top > page.scan.height * 0.15f &&
          l.box.height >= page.bodyHeight * 1.15f && l.text.length in 4..80 &&
          l.text.count(Char::isLetter) >= 4 && !DEAR.matches(l.text.trim()) && !SIGN_OFF.matches(l.text.trim()) &&
          LetterText.money(l.text).isEmpty()
    }?.text?.trim()
  }

  /** The first sentence after "Dear ...", trimmed to about 25 words. */
  private fun openingOf(page: LaidOutLetter): String? {
    val dearAt = page.paragraphs.indexOfFirst { DEAR.matches(it.trim()) }
    val body =
        if (dearAt >= 0) page.paragraphs.drop(dearAt + 1)
        else page.blocks.filter { !it.isShortLines && it.lines.size >= 2 }.map(LetterLayout::paragraph)
    val para = body.firstOrNull { it.length > 30 } ?: return null
    val sentence = com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunker.sentences(para).firstOrNull() ?: return null
    val words = sentence.split(' ')
    return if (words.size <= 25) sentence else words.take(25).joinToString(" ") + "…"
  }

  private fun isDeadline(line: String): Boolean =
      DEADLINE_PAY.containsMatchIn(line) || DEADLINE_REPLY.containsMatchIn(line) || APPOINTMENT.containsMatchIn(line) ||
          LetterText.dates(line).any { BY_BEFORE_DATE.containsMatchIn(line.substring(0, it.range.first)) }

  private fun deadlineOf(pages: List<LaidOutLetter>): DueDate? {
    var best: Pair<Int, DueDate>? = null
    for (page in pages) {
      val lines = page.lines
      lines.forEachIndexed { i, line ->
        val t = line.text
        val kind =
            when {
              APPOINTMENT.containsMatchIn(t) -> DueKind.APPOINTMENT
              DEADLINE_REPLY.containsMatchIn(t) -> DueKind.REPLY
              DEADLINE_PAY.containsMatchIn(t) -> DueKind.PAY
              LetterText.dates(t).any { BY_BEFORE_DATE.containsMatchIn(t.substring(0, it.range.first)) } -> DueKind.OTHER
              else -> return@forEachIndexed
            }
        // The date on this line, or at the start of the next line in the same block.
        var src = line
        var dates = LetterText.dates(t)
        if (dates.isEmpty()) {
          val next = lines.getOrNull(i + 1)
          if (next != null && next.block == line.block) {
            dates = LetterText.dates(next.text).filter { it.range.first <= 3 }
            src = next
          }
        }
        val rank = when (kind) { DueKind.PAY -> 4; DueKind.APPOINTMENT -> 3; DueKind.REPLY -> 2; DueKind.OTHER -> 1 }
        val due =
            dates.firstOrNull()?.let { d ->
              val c = src.minConfidence(d.range.first, d.range.last + 1, digitsOnly = true)
              val sure = c == null || c >= threshold(src, d.range.first, d.range.last + 1)
              val time = if (kind == DueKind.APPOINTMENT) TIME.find(src.text.substring(d.range.last + 1))?.value else null
              DueDate(kind, d.spoken() + (time?.let { " at $it" } ?: ""), sure)
            } ?: WITHIN.find(t)?.let { DueDate(kind, it.value.lowercase(), true) }
        if (due != null && (best == null || rank > best!!.first)) best = rank to due
      }
    }
    return best?.second
  }

  private fun threshold(line: LetterLine, start: Int, end: Int): Float {
    val hasSymbols = line.words.any { it.symbolConfidences.isNotEmpty() && it.symbolConfidences.size == it.text.length }
    return if (hasSymbols) MIN_DIGIT_CONFIDENCE else MIN_WORD_CONFIDENCE
  }

  private class Mention(val money: Money?, val sure: Boolean)

  /**
   * The money rule for one amount as printed: every character parsed as a digit (no O for 0), every
   * character of it (the digits, the point and the currency sign: a digit lost to a smudge lowers
   * its neighbours) read at or above the threshold, and no sign of a character gone missing.
   */
  internal fun isSure(line: LetterLine, tok: MoneyToken): Boolean {
    if (tok.money == null) return false
    val start = tok.range.first
    val end = tok.range.last + 1
    val c = line.minConfidence(start, end)
    if (c != null && c < threshold(line, start, end)) return false
    return !line.looksLikeAMissingCharacter(start, end)
  }

  /** The money rule lives here. See the file header. */
  internal fun amountOf(lines: List<LetterLine>): AmountDue {
    fun mentions(filter: (String) -> Boolean): List<Mention> =
        lines.filter { filter(it.text) && !NOT_DUE.containsMatchIn(it.text) }.flatMap { l ->
          LetterText.money(l.text).filter { !it.credit }.map { tok -> Mention(tok.money, isSure(l, tok)) }
        }
    var due = mentions { DUE_WORDS.containsMatchIn(it) && !MINIMUM_WORDS.containsMatchIn(it) }
    val isTotal = due.isEmpty()
    if (isTotal) due = mentions { TOTAL_WORDS.containsMatchIn(it) && !MINIMUM_WORDS.containsMatchIn(it) }
    val minimum = mentions { MINIMUM_WORDS.containsMatchIn(it) }
    if (due.isEmpty() && minimum.isEmpty()) return AmountDue.None
    if (due.isEmpty()) return judge(minimum)?.let { AmountDue.Sure(it) } ?: verdict(minimum)
    val main = judge(due) ?: return verdict(due)
    return AmountDue.Sure(main, minimum.takeIf { it.isNotEmpty() }?.let(::judge), isTotal)
  }

  /** The one value if every mention is sure and they agree, else null. */
  private fun judge(ms: List<Mention>): Money? {
    if (ms.any { !it.sure }) return null
    val values = ms.mapNotNull { it.money }.distinct()
    return values.singleOrNull()
  }

  private fun verdict(ms: List<Mention>): AmountDue {
    val sureValues = ms.filter { it.sure }.mapNotNull { it.money }.distinct()
    return if (ms.all { it.sure } && sureValues.size > 1) AmountDue.Conflict else AmountDue.Unsure
  }

  private fun referencesOf(lines: List<LetterLine>): List<Reference> {
    val out = mutableListOf<Reference>()
    for (l in lines) {
      for (m in REFERENCE.findAll(l.text)) {
        // Lower case, but acronyms as printed ("NHS number").
        val printed = m.groupValues[1].split(' ').joinToString(" ") { w -> if (w.length in 2..4 && w.all(Char::isUpperCase)) w else w.lowercase() }
        val label = printed.replace(Regex("\\bno\\.?$"), "number").replace(Regex("^(our|your) ref$"), "$1 reference")
            .let { if (it == "ref") "reference" else it }
        val value = m.groupValues[2].trim()
        if (value.count(Char::isDigit) < 3) continue
        if (out.none { it.value == value }) out += Reference(label, value)
      }
    }
    return out
  }

  internal fun kindOf(text: String, salutation: String?, amount: AmountDue, refs: List<Reference>): LetterKind {
    val lower = text.lowercase()
    val scores =
        KIND_WORDS.mapValues { (_, words) ->
          words.sumOf { (w, weight) -> if (Regex("(?<![a-z])${Regex.escape(w)}(?![a-z])").containsMatchIn(lower)) weight else 0 }
        }.toMutableMap()
    if (amount !is AmountDue.None) scores[LetterKind.BILL] = scores.getValue(LetterKind.BILL) + 3
    scores[LetterKind.ADVERT] = scores.getValue(LetterKind.ADVERT) + minOf(3, text.count { it == '!' })
    val sal = salutation?.trim().orEmpty()
    if (sal.isNotEmpty() && !TITLE.containsMatchIn(sal) && sal.split(' ').size == 1 &&
        sal.lowercase() !in setOf("sir", "madam", "customer", "occupier", "resident", "homeowner", "member", "patient")) {
      scores[LetterKind.PERSONAL] = scores.getValue(LetterKind.PERSONAL) + 2
    }
    if (amount is AmountDue.None && refs.isEmpty()) scores[LetterKind.PERSONAL] = scores.getValue(LetterKind.PERSONAL) + 1
    // A council tax bill is an official letter that asks for money: official/bank/medical beat bill
    // when they're strong, and the amount is said either way.
    val best = scores.maxBy { it.value }
    val advert = scores.getValue(LetterKind.ADVERT)
    if (advert >= 5 && scores.filterKeys { it != LetterKind.ADVERT }.values.all { it < advert }) return LetterKind.ADVERT
    for (k in listOf(LetterKind.OFFICIAL, LetterKind.MEDICAL, LetterKind.BANK)) {
      if (scores.getValue(k) >= 5 && scores.getValue(k) >= best.value - 3) return k
    }
    if (best.value < 3) return LetterKind.UNKNOWN
    if (best.key == LetterKind.ADVERT) {
      // Adverts must clearly win; otherwise it's something that mentions an offer.
      return scores.filterKeys { it != LetterKind.ADVERT }.maxBy { it.value }.takeIf { it.value >= 3 }?.key ?: LetterKind.UNKNOWN
    }
    return best.key
  }
}
