// AskTestData - the real dictionary asset and book text for the ask tests
//
// JVM tests run in the app module directory, so the committed asset is read from
// src/main/assets/ask/wordnet.wnask (the same bytes the APK ships), once for all tests. The text is
// the book fixtures' public-domain pages (Conan Doyle, Wells), as the book reader publishes them.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.book.BookFixtures
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import java.io.File

object AskTestData {

  val assetFile: File = listOf("src/main/assets/ask/wordnet.wnask", "app/src/main/assets/ask/wordnet.wnask")
      .map(::File).first { it.exists() }

  val dictionary: Dictionary by lazy { assetFile.inputStream().use(Dictionary::load) }

  val houndPage: String = BookFixtures.houndParagraphs.joinToString("\n\n")
  val timePage: String = BookFixtures.spreadParagraphs.joinToString("\n\n")

  /** The next Hound page (BookFixtures.houndNextPage) as the reader would publish it. */
  val houndNextPage: String =
      "\"How did you know what I was doing? I believe you have eyes in the back of your head.\"\n\n" +
          "\"I have, at least, a well-polished, silver-plated coffee-pot in front of me,\" said he. " +
          "\"But, tell me, Watson, what do you make of our visitor's stick? Since we have been so " +
          "unfortunate as to miss him and have no notion of his errand, this accidental souvenir " +
          "becomes of importance. Let me hear you reconstruct the man by an examination of it.\""

  fun snapshot(vararg passages: String, current: String? = null, tool: ToolId = ToolId.BOOK) =
      RecentText.Snapshot(tool, passages.toList(), current, null, 0L)
}
