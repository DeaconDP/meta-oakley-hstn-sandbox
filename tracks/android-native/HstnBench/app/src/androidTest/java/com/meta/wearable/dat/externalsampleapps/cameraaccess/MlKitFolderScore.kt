// MlKitFolderScore - ML Kit OCR accuracy over a folder of book photos
//
// Harness for the book-reader resolution experiment (notes/book-reader.md > Experiment). Reads
// every image listed in <folder>/manifest.tsv, runs ML Kit Text Recognition v2 (the same MlKitOcr
// the reader uses), and logs CER/WER against the ground truth under the logcat tag BookOcrScore.
// Results also go to <app external files>/book-ocr-results.tsv for `adb pull`.
//
// Run (tracks/android-native/book-ocr.sh does push + run + pull):
//   adb shell am instrument -w -e class \
//     com.meta.wearable.dat.externalsampleapps.cameraaccess.MlKitFolderScore \
//     -e folder /sdcard/Download/book-ocr \
//     com.deaco.hstnbench.test/androidx.test.runner.AndroidJUnitRunner
//
// manifest.tsv: one row per image, tab-separated: <image> <ground-truth .txt> [anything else].
// Paths are relative to the folder unless absolute. Blank lines, '#' comments and a header row
// whose first cell is "image" are skipped. With no manifest, every image is paired with the .txt
// of the same base name.
//
// Two scores per image: "raw" is ML Kit's text in its own line order; "layout" is after the book
// layout pass (spread split, header/page-number removal, hyphen rejoin). Use whichever matches how
// the ground truth was transcribed. Files are read through the shell (uiAutomation), so any folder
// adb can write to works without storage permissions. Device paths can't contain spaces.
//
// With -e dumpLines true, each image's ML Kit lines (corner points + text) also go to
// <app external files>/mlkit-lines/<image>.json in the format experiments/book-reader-resolution
// expects, so the desktop scorer can grade ML Kit with the same oracle layout as its proxy OCR.

package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.graphics.BitmapFactory
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.FramingCheck
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.OcrLine
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.PageLayout
import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.TextDistance
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.MlKitOcr
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MlKitFolderScore {

  companion object {
    private const val TAG = "BookOcrScore"
    private const val DEFAULT_FOLDER = "/sdcard/Download/book-ocr"
    private val IMAGE_EXT = setOf("png", "jpg", "jpeg", "webp", "bmp", "heic")
  }

  private data class Item(val image: String, val truth: String)

  private data class Score(
      val image: String,
      val width: Int,
      val height: Int,
      val ocrMs: Long,
      val lines: Int,
      val cerRaw: Float,
      val werRaw: Float,
      val cerLayout: Float,
      val werLayout: Float,
      val framing: String,
  )

  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val dumpEnabled = InstrumentationRegistry.getArguments().getString("dumpLines") == "true"

  @Test
  fun scoreFolder() {
    val args = InstrumentationRegistry.getArguments()
    val explicit = args.containsKey("folder")
    val folder = args.getString("folder", DEFAULT_FOLDER).trimEnd('/')
    val manifestName = args.getString("manifest", "manifest.tsv")
    val items = loadItems(folder, manifestName)
    Log.i(TAG, "folder=$folder items=${items.size}")
    val message = "No images found in $folder (manifest $manifestName)"
    // In a plain connectedAndroidTest run (no -e folder) an absent dataset skips, not fails.
    if (explicit) assertTrue(message, items.isNotEmpty()) else assumeTrue(message, items.isNotEmpty())

    val scores = mutableListOf<Score>()
    MlKitOcr().use { ocr ->
      for (item in items) {
        val score =
            try {
              scoreOne(ocr, item)
            } catch (e: Exception) {
              Log.e(TAG, "image=${item.image} error=${e.javaClass.simpleName}: ${e.message}")
              null
            }
        score ?: continue
        scores += score
        Log.i(
            TAG,
            "image=${score.image} size=${score.width}x${score.height} ms=${score.ocrMs} " +
                "lines=${score.lines} cer_raw=${fmt(score.cerRaw)} wer_raw=${fmt(score.werRaw)} " +
                "cer_layout=${fmt(score.cerLayout)} wer_layout=${fmt(score.werLayout)} " +
                "framing=${score.framing}",
        )
      }
    }

    if (scores.isNotEmpty()) {
      Log.i(
          TAG,
          "summary images=${scores.size} failed=${items.size - scores.size} " +
              "mean_cer_raw=${fmt(scores.map { it.cerRaw }.average())} " +
              "mean_wer_raw=${fmt(scores.map { it.werRaw }.average())} " +
              "mean_cer_layout=${fmt(scores.map { it.cerLayout }.average())} " +
              "mean_wer_layout=${fmt(scores.map { it.werLayout }.average())} " +
              "median_cer_raw=${fmt(median(scores.map { it.cerRaw }))} " +
              "median_cer_layout=${fmt(median(scores.map { it.cerLayout }))}",
      )
    }
    writeResults(scores)
    assertTrue("Every image failed to load or OCR", scores.isNotEmpty())
  }

  private fun scoreOne(ocr: MlKitOcr, item: Item): Score? {
    val bytes = readShell(item.image)
    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    if (bitmap == null) {
      Log.e(TAG, "image=${item.image} error=undecodable bytes=${bytes.size}")
      return null
    }
    val truth = String(readShell(item.truth), Charsets.UTF_8)
    if (truth.isBlank()) Log.w(TAG, "image=${item.image} warning=empty ground truth ${item.truth}")
    val started = System.nanoTime()
    val page = runBlocking { ocr.recognize(bitmap) }
    val ms = (System.nanoTime() - started) / 1_000_000
    val raw = page.rawText
    if (dumpEnabled) dumpLines(item.image.substringAfterLast('/'), page.lines)
    val laidOut = PageLayout.layout(page).bodyText()
    val framing = FramingCheck.check(page).issues.joinToString(",").ifEmpty { "ok" }
    return Score(
        image = item.image.substringAfterLast('/'),
        width = bitmap.width,
        height = bitmap.height,
        ocrMs = ms,
        lines = page.lines.size,
        cerRaw = TextDistance.cer(truth, raw),
        werRaw = TextDistance.wer(truth, raw),
        cerLayout = TextDistance.cer(truth, laidOut),
        werLayout = TextDistance.wer(truth, laidOut),
        framing = framing,
    )
  }

  private fun dumpLines(image: String, lines: List<OcrLine>) {
    val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "mlkit-lines")
    dir.mkdirs()
    val boxes = JSONArray()
    val txts = JSONArray()
    for (line in lines) {
      val b = line.box
      boxes.put(
          JSONArray(
              listOf(
                  JSONArray(listOf(b.left, b.top)),
                  JSONArray(listOf(b.right, b.top)),
                  JSONArray(listOf(b.right, b.bottom)),
                  JSONArray(listOf(b.left, b.bottom)),
              )
          )
      )
      txts.put(line.text)
    }
    File(dir, "$image.json").writeText(JSONObject().put("boxes", boxes).put("txts", txts).toString())
  }

  private fun loadItems(folder: String, manifestName: String): List<Item> {
    fun resolve(path: String) = if (path.startsWith("/")) path else "$folder/$path"
    val manifest = String(readShell(resolve(manifestName)), Charsets.UTF_8)
    if (manifest.isNotBlank()) {
      return manifest
          .lines()
          .map { it.trim() }
          .filter { it.isNotEmpty() && !it.startsWith("#") }
          .map { it.split('\t') }
          .filter { cols -> cols.size >= 2 && !cols[0].equals("image", ignoreCase = true) }
          .map { cols -> Item(resolve(cols[0].trim()), resolve(cols[1].trim())) }
    }
    Log.i(TAG, "no $manifestName; pairing images with same-name .txt files")
    val names = String(readShell(folder, list = true), Charsets.UTF_8).lines().map { it.trim() }
    val texts = names.filter { it.endsWith(".txt") }.toSet()
    return names
        .filter { it.substringAfterLast('.', "").lowercase(Locale.ROOT) in IMAGE_EXT }
        .mapNotNull { name ->
          val txt = name.substringBeforeLast('.') + ".txt"
          if (txt in texts) Item("$folder/$name", "$folder/$txt") else null
        }
  }

  /**
   * Reads a device file (or lists a folder) as the shell user, which can read /sdcard.
   * executeShellCommand splits on whitespace without a shell, so quotes would become part of the
   * path: device paths must not contain spaces.
   */
  private fun readShell(path: String, list: Boolean = false): ByteArray {
    require(' ' !in path) { "Device paths can't contain spaces: $path" }
    val pfd = instrumentation.uiAutomation.executeShellCommand(if (list) "ls -1 $path" else "cat $path")
    return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes() }
  }

  private fun writeResults(scores: List<Score>) {
    val dir = instrumentation.targetContext.getExternalFilesDir(null) ?: return
    val out = File(dir, "book-ocr-results.tsv")
    out.printWriter().use { w ->
      w.println("image\twidth\theight\tocr_ms\tlines\tcer_raw\twer_raw\tcer_layout\twer_layout\tframing")
      for (s in scores) {
        w.println(
            listOf(s.image, s.width, s.height, s.ocrMs, s.lines, fmt(s.cerRaw), fmt(s.werRaw), fmt(s.cerLayout), fmt(s.werLayout), s.framing)
                .joinToString("\t"),
        )
      }
    }
    Log.i(TAG, "results=${out.absolutePath}")
  }

  private fun fmt(v: Number) = String.format(Locale.ROOT, "%.4f", v.toDouble())

  private fun median(values: List<Float>): Float = values.sorted()[values.size / 2]
}
