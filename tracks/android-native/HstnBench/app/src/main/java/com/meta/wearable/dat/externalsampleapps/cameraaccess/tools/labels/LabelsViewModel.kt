// LabelsViewModel - the label reader: barcodes first, then the label word for word
//
// "What's this?" opens the tool, which looks for a barcode in the glasses' stream (2 frames a
// second, ML Kit on the phone). Geiger ticks get faster and higher as something barcode-like gets
// bigger and more central (BarcodeHint); after 5 s with nothing it says "Turn it slowly. Barcodes
// are usually on the back or bottom.", and after 15 s it reads the label instead. A decode plays the
// FOUND earcon and offers "look it up" or "read the label". "Look it up" is the only network call:
// the barcode number alone goes to Open Food Facts (OpenFoodFacts.kt), results cached on the phone.
//
// Reading the label captures a photo (capturePage), checks brightness (book/ImageCheck), runs OCR on
// the phone (bookreader/MlKitOcr), checks the text is readable (book/FramingCheck), and reads it
// word for word, or jumps to the expiry date, cooking instructions, ingredients or allergens. Each
// jump takes a fresh photo (the user may have turned the pack) and searches every side seen so far,
// newest first. Medicine (MedicineCheck: label words or the Open Food Facts category) gets its name
// and date only; anything about doses gets "I won't read medicine doses...". Medicine label text is
// never published to RecentText or shown on screen, so "ask about the text" can't read a dose either.
// The screen mirrors the state for TalkBack (labels_* test tags). See notes/labels-and-barcodes.md.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

import android.app.Application
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FramingCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FramingIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.ImageIssue
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrPage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageLayout
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.SpeechChunker
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.MlKitOcr
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Earcon
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.OpenReason
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolTexts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.GlobalCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.Phrases
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolRequest
import java.io.File
import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class LabelsPhase { IDLE, SEARCHING, FOUND, LOOKING_UP, READING }

/** What the label reader's screen shows. */
data class LabelsState(
    val phase: LabelsPhase = LabelsPhase.IDLE,
    val code: ScannedCode? = null,
    /** "Snickers, by Mars..., 50 grams." after a lookup. */
    val product: String? = null,
    /** The newest side's text, or null. Never set for medicine. */
    val labelText: String? = null,
    val isMedicine: Boolean = false,
    /** For medicine: the name only. */
    val medicineName: String? = null,
)

/** One side of the pack as read: lines in reading order, and paragraphs (OCR blocks) for reading. */
private class LabelView(val lines: List<LabelLine>, val paragraphs: List<String>) {
  val text: String
    get() = lines.joinToString("\n") { it.text }
}

class LabelsViewModel(application: Application, hub: ToolHub) :
    ToolViewModel(application, hub, ToolId.LABELS) {

  private val _state = MutableStateFlow(LabelsState())
  val state: StateFlow<LabelsState> = _state.asStateFlow()

  private val barcodes by lazy { MlKitBarcodes() }
  private val ocr by lazy { MlKitOcr() }
  private val realSource by lazy { OpenFoodFactsSource(File(application.filesDir, "labels_products")) }
  private val source: ProductSource
    get() = LabelsLookup.source ?: realSource

  private var scanJob: Job? = null
  private var workJob: Job? = null
  private var tickJob: Job? = null

  private var code: ScannedCode? = null
  private var product: OffProduct? = null
  private val views = mutableListOf<LabelView>()
  private var medicine = false
  private var medicineName: String? = null
  /** Reading a label out (the last queued sentence hasn't finished). */
  private var reading = false
  private var searchingWhenLost = false

  override fun texts(): ToolTexts =
      ToolTexts.generic(getApplication(), R.string.labels_name, R.string.labels_help)

  // MARK: - Lifecycle

  override fun onOpened(request: ToolRequest, reason: OpenReason) = startScan()

  /** "scan this" / "what's this product" again while open: a new product. */
  override fun onRequest(request: ToolRequest) {
    super.onRequest(request)
    startScan()
  }

  override fun onLeaving() {
    stopAll()
    _state.update { it.copy(phase = if (it.code != null) LabelsPhase.FOUND else LabelsPhase.IDLE) }
  }

  override fun onStreamLost(): Boolean {
    searchingWhenLost = scanJob?.isActive == true
    scanJob?.cancel()
    return true
  }

  override fun onStreamBack() {
    if (searchingWhenLost) {
      searchingWhenLost = false
      startScan(announce = false)
    }
  }

  override fun onCleared() {
    stopAll()
    runCatching { barcodes.close() }
    runCatching { ocr.close() }
    super.onCleared()
  }

  override fun isBusy(): Boolean = reading || workJob?.isActive == true

  override fun isWaitingForUser(): Boolean =
      !isBusy() && scanJob?.isActive != true && _state.value.phase in setOf(LabelsPhase.IDLE, LabelsPhase.FOUND)

  override fun reminder(index: Int, last: Boolean): String? =
      if (_state.value.phase == LabelsPhase.FOUND && code?.kind == CodeKind.PRODUCT && product == null) str(R.string.labels_reminder_found)
      else str(R.string.labels_reminder_idle)

  override fun onSpoken(tag: String) {
    if (tag == TAG_LAST) reading = false
  }

  // MARK: - Voice

  override fun onCommand(text: String): Boolean {
    val command = LabelsGrammar.parse(Phrases.normalize(text)) ?: return false
    Log.i(TAG, "command=$command")
    handle(command)
    return true
  }

  override fun onGlobal(command: GlobalCommand): Boolean {
    if (command == GlobalCommand.Pause) {
      // "stop": stop searching and reading as well as speech.
      stopAll()
      _state.update { it.copy(phase = if (code != null) LabelsPhase.FOUND else LabelsPhase.IDLE) }
    }
    return false
  }

  /** Every voice command and button press lands here. */
  fun handle(command: LabelsCommand) {
    when (command) {
      LabelsCommand.Scan -> startScan()
      LabelsCommand.StopScan -> {
        stopAll()
        _state.update { it.copy(phase = if (code != null) LabelsPhase.FOUND else LabelsPhase.IDLE) }
        hub.reply(str(R.string.labels_stopped))
      }
      LabelsCommand.LookUp -> lookUp()
      LabelsCommand.ReadLabel -> withFreshView { readAll() }
      LabelsCommand.ReadAll -> if (views.isEmpty()) withFreshView { readAll() } else readAll()
      LabelsCommand.Expiry -> withFreshView { answer(expiryAnswer()) }
      LabelsCommand.Cooking ->
          if (medicine) refuseMedicine() else withFreshView { if (medicine) refuseMedicine() else sectionAnswer(LabelSection.COOKING) }
      LabelsCommand.Ingredients ->
          if (medicine) refuseMedicine() else withFreshView { if (medicine) refuseMedicine() else sectionAnswer(LabelSection.INGREDIENTS) }
      is LabelsCommand.Allergens ->
          if (medicine) refuseMedicine()
          else withFreshView(productIsEnough = product != null) { if (medicine) refuseMedicine() else allergenAnswer(command.query) }
      LabelsCommand.Name -> answer(nameAnswer())
      LabelsCommand.Dose -> doseRefusal()
    }
  }

  /** A button press: earcon and reminder clock, then the same as the voice command. */
  fun press(command: LabelsCommand) {
    hub.userActed()
    handle(command)
  }

  // MARK: - Barcode search

  private fun startScan(announce: Boolean = true) {
    stopAll()
    code = null
    product = null
    views.clear()
    medicine = false
    medicineName = null
    hub.recentText.clear(ToolId.LABELS)
    _state.value = LabelsState(phase = LabelsPhase.SEARCHING)
    if (!hub.camera.isStreaming.value) {
      if (!hub.reconnectThen { startScan(announce) }) hub.explainNoGlasses()
      return
    }
    if (announce) say(str(R.string.labels_searching))
    scanJob = viewModelScope.launch { search() }
  }

  private enum class SearchEnd { FOUND, GAVE_UP }

  private suspend fun search() {
    val started = SystemClock.elapsedRealtime()
    var turnHintSaid = false
    var barsHintSaid = false
    var barsSeen = 0
    var lastSound = started
    var found: ScannedCode? = null
    var end: SearchEnd? = null
    // frames() emits nothing while the stream is down; the timeout still ends the search.
    withTimeoutOrNull(GIVE_UP_MS + 3_000L) {
      hub.camera.frames(SEARCH_FPS).first { frame ->
        val now = SystemClock.elapsedRealtime()
        val (decoded, region) =
            withContext(Dispatchers.Default) {
              val bmp = argb(frame)
              val c = runCatching { barcodes.scan(bmp) }.getOrNull()
              val r =
                  if (c == null) runCatching { MlKitBarcodes.hintRows(bmp).let { (l, w, h) -> BarcodeHint.find(l, w, h) } }.getOrNull()
                  else null
              c to r
            }
        if (decoded != null) {
          found = decoded
          end = SearchEnd.FOUND
          return@first true
        }
        if (region != null) {
          barsSeen++
          lastSound = now
          geiger(region.closeness)
          if (!barsHintSaid && barsSeen >= 4 && !hub.isSpeakingAside) {
            barsHintSaid = true
            say(str(if (region.closeness < 0.45f) R.string.labels_bars_closer else R.string.labels_bars_steady))
          }
        } else if (now - lastSound >= WORKING_TICK_MS) {
          lastSound = now
          hub.earcons.play(Earcon.WORKING)
        }
        val elapsed = now - started
        if (!turnHintSaid && elapsed >= TURN_HINT_MS && barsSeen == 0) {
          turnHintSaid = true
          say(str(R.string.labels_turn_hint))
        }
        if (elapsed >= GIVE_UP_MS) end = SearchEnd.GAVE_UP
        end != null
      }
    }
    scanJob = null
    if (end == SearchEnd.FOUND) {
      onFound(found!!)
    } else {
      Log.i(TAG, "no barcode after ${GIVE_UP_MS / 1000} s: reading the label")
      hub.earcons.play(Earcon.ERROR)
      say(str(R.string.labels_no_barcode))
      withFreshView { readAll() }
    }
  }

  /** Geiger-style: 1 to 4 short ticks in the half second until the next frame, higher when closer. */
  private fun geiger(closeness: Float) {
    tickJob?.cancel()
    val ticks = 1 + (closeness * 3.99f).toInt()
    val pitch = 500f + 900f * closeness
    tickJob = viewModelScope.launch {
      repeat(ticks) {
        hub.tones.play(pitch, 25, 0.35f)
        delay((1000f / SEARCH_FPS / ticks).toLong())
      }
    }
  }

  private fun onFound(found: ScannedCode) {
    Log.i(TAG, "barcode format=${found.format} raw=${found.raw}")
    code = found
    hub.earcons.play(Earcon.FOUND)
    _state.update { it.copy(phase = LabelsPhase.FOUND, code = found) }
    val text =
        when (found.kind) {
          CodeKind.PRODUCT -> str(R.string.labels_found_product)
          CodeKind.QR -> Codes.describeQr(found.raw) + " " + str(R.string.labels_qr_more)
          CodeKind.OTHER -> str(R.string.labels_found_other, Codes.spokenDigits(found.raw.take(24)))
        }
    if (found.kind == CodeKind.QR) hub.recentText.addPassage(ToolId.LABELS, found.raw, "qr")
    hub.reply(text)
  }

  // MARK: - Product lookup (the only network call)

  private fun lookUp() {
    val c = code
    val lookupCode = c?.productCode
    when {
      c == null && scanJob?.isActive == true -> return hub.reply(str(R.string.labels_still_searching))
      c == null -> return hub.reply(str(R.string.labels_no_code_yet))
      lookupCode == null -> return hub.reply(str(R.string.labels_not_product))
    }
    stopAll()
    _state.update { it.copy(phase = LabelsPhase.LOOKING_UP) }
    hub.reply(str(R.string.labels_looking_up))
    workJob = viewModelScope.launch {
      val ticker = launch { while (true) { delay(WORKING_TICK_MS); hub.earcons.play(Earcon.WORKING) } }
      val result =
          try {
            source.lookup(lookupCode!!)
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            LookupResult.Failed(e.message ?: "error")
          } finally {
            ticker.cancel()
          }
      Log.i(TAG, "lookup code=$lookupCode result=${result::class.simpleName}")
      _state.update { it.copy(phase = LabelsPhase.FOUND) }
      when (result) {
        is LookupResult.Found -> productFound(result.product)
        LookupResult.NotFound -> hub.warn(str(R.string.labels_not_found))
        LookupResult.Offline -> hub.warn(str(R.string.labels_offline))
        is LookupResult.Failed -> hub.warn(str(R.string.labels_lookup_failed))
      }
    }
  }

  private fun productFound(p: OffProduct) {
    product = p
    if (MedicineCheck.looksLikeMedicine(p.name.orEmpty(), p.categoryTags)) markMedicine(p.name)
    hub.earcons.play(Earcon.FOUND)
    if (medicine) {
      _state.update { it.copy(product = medicineName) }
      hub.reply(str(R.string.labels_medicine_name, medicineName!!) + " " + str(R.string.labels_medicine_dose))
      return
    }
    val summary = p.summary()
    _state.update { it.copy(product = summary) }
    hub.recentText.setTitle(ToolId.LABELS, p.name ?: summary)
    hub.recentText.addPassage(ToolId.LABELS, listOfNotNull(summary, p.ingredients?.let { "Ingredients: $it" }).joinToString("\n"), "product")
    hub.reply(summary + " " + str(R.string.labels_lookup_more))
  }

  // MARK: - Reading the label

  /**
   * Takes a fresh photo, reads it and adds it to the sides seen, then runs [then]. If the camera
   * isn't available but something is already known ([productIsEnough] or a side read before),
   * [then] answers from that.
   */
  private fun withFreshView(productIsEnough: Boolean = false, then: () -> Unit) {
    stopAll()
    if (!hub.camera.isStreaming.value) {
      if (views.isNotEmpty() || productIsEnough) then()
      else if (!hub.reconnectThen { withFreshView(productIsEnough, then) }) hub.explainNoGlasses()
      return
    }
    _state.update { it.copy(phase = LabelsPhase.READING) }
    if (views.isEmpty()) say(str(R.string.labels_reading)) else hub.earcons.play(Earcon.ACK)
    workJob = viewModelScope.launch {
      val ticker = launch { while (true) { delay(WORKING_TICK_MS); hub.earcons.play(Earcon.WORKING) } }
      var problem: String? = null
      try {
        val photo = hub.camera.capturePage()
        if (photo == null) {
          problem = str(R.string.labels_capture_failed)
        } else {
          val bmp = withContext(Dispatchers.Default) { argb(photo) }
          val issue = withContext(Dispatchers.Default) { imageIssue(bmp) }
          if (issue != null && issue.blocksOcr) {
            problem = imageHint(issue)
          } else {
            val started = System.nanoTime()
            val page = withContext(Dispatchers.Default) { ocr.recognize(bmp) }
            Log.i(TAG, "metric=labels_ocr ms=${(System.nanoTime() - started) / 1_000_000} lines=${page.lines.size}")
            val framing = FramingCheck.check(page)
            if (framing.isUnreadable) {
              problem =
                  if (issue != null && ImageCheck.explainsFramingFailure(issue, framing.issues)) imageHint(issue)
                  else if (FramingIssue.TOO_SMALL in framing.issues) str(R.string.labels_text_small)
                  else str(R.string.labels_no_text)
            } else {
              addView(page)
            }
          }
        }
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        Log.e(TAG, "label OCR failed", e)
        problem = str(R.string.labels_ocr_failed)
      } finally {
        ticker.cancel()
      }
      _state.update { it.copy(phase = if (code != null) LabelsPhase.FOUND else LabelsPhase.IDLE) }
      if (problem != null && views.isEmpty() && !productIsEnough) {
        hub.warn(problem)
      } else {
        if (problem != null) Log.i(TAG, "fresh view failed ($problem); answering from what's known")
        then()
      }
    }
  }

  private fun addView(page: OcrPage) {
    val lines = PageLayout.readingOrder(page.lines).map { LabelLine(it.text.trim(), it.box.height) }.filter { it.text.isNotEmpty() }
    val paragraphs =
        page.blocks
            .filter { it.lines.isNotEmpty() }
            .sortedWith(compareBy({ b -> (b.lines.minOf { it.box.top } / 20f).toInt() }, { b -> b.lines.minOf { it.box.left } }))
            .map { b -> b.lines.joinToString(" ") { it.text.trim() } }
    val view = LabelView(lines, paragraphs)
    views += view
    Log.i(TAG, "label view ${views.size}: ${view.text.take(120).replace('\n', '|')}")
    if (!medicine && MedicineCheck.looksLikeMedicine(view.text, product?.categoryTags.orEmpty())) {
      markMedicine(product?.name ?: LabelText.nameGuess(lines))
    }
    if (medicine) {
      // Nothing from a medicine label is shown, published or kept beyond its name.
      _state.update { it.copy(labelText = null) }
      hub.recentText.clear(ToolId.LABELS)
      medicineName?.let { hub.recentText.setTitle(ToolId.LABELS, it) }
    } else {
      _state.update { it.copy(labelText = view.text) }
      hub.recentText.addPassage(ToolId.LABELS, view.text, "side-${views.size}")
    }
  }

  private fun markMedicine(name: String?) {
    medicine = true
    medicineName = MedicineCheck.nameOnly(name ?: "")
    Log.i(TAG, "medicine detected; name only")
    _state.update { it.copy(isMedicine = true, medicineName = medicineName, labelText = null) }
  }

  /** Word for word, newest side. Medicine: the name and the refusal, nothing else. */
  private fun readAll() {
    if (medicine) return refuseMedicine()
    val view = views.lastOrNull() ?: return hub.reply(str(R.string.labels_no_text))
    speakAll(view.paragraphs + str(R.string.labels_read_more))
  }

  private fun sectionAnswer(section: LabelSection) {
    val text = views.asReversed().firstNotNullOfOrNull { LabelText.section(it.lines, section) }
    when {
      text != null ->
          speakAll(
              listOf(
                  when (section) {
                    LabelSection.INGREDIENTS -> "Ingredients: $text"
                    LabelSection.COOKING -> "Cooking instructions: $text"
                    LabelSection.ALLERGENS -> "Allergy advice: $text"
                  },
              ),
          )
      section == LabelSection.INGREDIENTS && product?.ingredients != null ->
          speakAll(listOf(str(R.string.labels_ingredients_from_off, product!!.ingredients!!)))
      else ->
          hub.reply(
              str(
                  when (section) {
                    LabelSection.INGREDIENTS -> R.string.labels_no_ingredients
                    LabelSection.COOKING -> R.string.labels_no_cooking
                    LabelSection.ALLERGENS -> R.string.labels_no_allergens
                  },
              ),
          )
    }
  }

  private fun allergenAnswer(query: String?) {
    val allLines = views.asReversed().flatMap { it.lines }
    if (query == null) {
      val summary = LabelText.allergenSummary(allLines.ifEmpty { null }, product)
      return if (summary != null) answer(summary) else hub.reply(str(R.string.labels_no_allergens))
    }
    val label = if (views.isEmpty()) null else allLines.joinToString("\n") { it.text }
    answer(LabelText.allergenAnswer(query, label, product))
  }

  private fun expiryAnswer(): String {
    val text = views.asReversed().joinToString("\n") { it.text }
    return LabelDates.answer(LabelDates.find(text, LocalDate.now()), LocalDate.now()) ?: str(R.string.labels_no_expiry)
  }

  private fun nameAnswer(): String =
      when {
        medicine -> str(R.string.labels_medicine_name, medicineName ?: "a medicine")
        product != null -> product!!.summary()
        views.isNotEmpty() -> LabelText.nameGuess(views.last().lines)?.let { str(R.string.labels_name_label, it) } ?: str(R.string.labels_no_name)
        else -> str(R.string.labels_no_name)
      }

  private fun refuseMedicine() {
    answer(
        str(R.string.labels_medicine_name, medicineName ?: "a medicine") + " " + str(R.string.labels_medicine_only_name) + " " +
            str(R.string.labels_medicine_dose),
    )
  }

  private fun doseRefusal() {
    stopAll()
    answer(str(R.string.labels_medicine_dose))
  }

  // MARK: - Speaking

  private fun answer(text: String) {
    onStatus(text)
    hub.reply(text)
  }

  /** The first part as a reply (cuts off what's playing), the rest queued; "stop" drops it all. */
  private fun speakAll(parts: List<String>) {
    val chunks = parts.flatMap { p -> SpeechChunker.sentences(p) }.filter { it.isNotBlank() }
    if (chunks.isEmpty()) return
    hub.reply(chunks.first())
    if (chunks.size == 1) return
    reading = true
    chunks.drop(1).forEachIndexed { i, c -> hub.speak(c, if (i == chunks.size - 2) TAG_LAST else "label") }
  }

  private fun stopAll() {
    scanJob?.cancel()
    scanJob = null
    workJob?.cancel()
    workJob = null
    tickJob?.cancel()
    if (reading) hub.hush()
    reading = false
  }

  // MARK: - Images

  private fun argb(bitmap: Bitmap): Bitmap =
      if (bitmap.config == Bitmap.Config.HARDWARE) bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: bitmap else bitmap

  private fun imageIssue(src: Bitmap): ImageIssue? {
    val gw = 48
    val gh = 72
    val luma = IntArray(gw * gh)
    for (y in 0 until gh) for (x in 0 until gw) {
      val c = src.getPixel(x * src.width / gw + src.width / (2 * gw), y * src.height / gh + src.height / (2 * gh))
      luma[y * gw + x] = (299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000
    }
    return ImageCheck.check(luma, gw, gh)
  }

  private fun imageHint(issue: ImageIssue): String =
      str(
          when (issue) {
            ImageIssue.COVERED -> R.string.labels_hint_covered
            ImageIssue.TOO_DARK -> R.string.labels_hint_dark
            ImageIssue.NOTHING_IN_VIEW -> R.string.labels_hint_nothing
            ImageIssue.GLARE -> R.string.labels_hint_glare
            ImageIssue.PARTLY_BLOCKED -> R.string.labels_hint_blocked
          },
      )

  class Factory(private val application: Application, private val hub: ToolHub) :
      ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
      @Suppress("UNCHECKED_CAST")
      return LabelsViewModel(application, hub) as T
    }
  }

  companion object {
    private const val TAG = "LabelReader"
    private const val TAG_LAST = "label-last"
    const val SEARCH_FPS = 2f
    const val TURN_HINT_MS = 5_000L
    const val GIVE_UP_MS = 15_000L
    const val WORKING_TICK_MS = 2_000L
  }
}
