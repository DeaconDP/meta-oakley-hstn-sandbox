// AskMemory - the end of the book's recent text, kept next to the bookmark across app restarts
//
// "What happened last time?" after closing the app needs the text from the last session, and
// RecentText lives in memory only. The book reader saves the last ~3 000 characters it has read
// (ReadText.tail: whole sentences, up to the sentence being read) in its own preferences file, next
// to the bookmark, every time it saves the bookmark. AskProvider reads it once when the app starts,
// before this session overwrites it. Local only: never sent anywhere (the optional Claude path gets
// this session's text, and only if an API key is configured).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import android.content.Context
import android.content.SharedPreferences
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.RecentText

object AskMemory {
  /** The book reader's preferences file (where the bookmark is). */
  const val PREFS = "book_reader"
  const val KEY_RECENT_TEXT = "recent_text"

  /** Adds the read-so-far tail of [snapshot] to [editor] (the bookmark's edit). */
  fun save(editor: SharedPreferences.Editor, snapshot: RecentText.Snapshot?): SharedPreferences.Editor {
    ReadText.tail(snapshot)?.let { editor.putString(KEY_RECENT_TEXT, it) }
    return editor
  }

  /** What the last session read, or null. */
  fun load(context: Context): String? =
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_RECENT_TEXT, null)
}
