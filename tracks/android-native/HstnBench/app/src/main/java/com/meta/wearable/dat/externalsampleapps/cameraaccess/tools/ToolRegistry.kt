// ToolRegistry - every tool the app can open, in one list
//
// The camera screen shows a button per entry, the router shows the entry's screen for
// ToolHub.activeTool, and ToolHub says the entry's name when switching. All five tools are registered
// up front (the four new ones as stubs), so building a tool means editing only its own package
// (tools/<id>/), its strings_<id>.xml and its grammar, never this file. The launcher alias, deep link
// and intent extra for each id are in AndroidManifest.xml and tools/core/ToolId.kt (ToolLaunch).

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.BookTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels.LabelsTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.light.LightTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail.MailTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.watch.WatchTool

/** One tool: its id, names, camera-screen button, and screen. */
class ToolSpec(
    val id: ToolId,
    /** Spoken and shown name ("Mail reader"). */
    @StringRes val nameRes: Int,
    /** Short label for the camera-screen button ("Mail"). */
    @StringRes val buttonRes: Int,
    /** TalkBack description of that button. */
    @StringRes val buttonDescriptionRes: Int,
    val icon: ImageVector,
    /** The tool's screen. Must call AttachTool for its ViewModel. */
    val content: @Composable (ToolScreenContext) -> Unit,
) {
  /** Test tag of the camera-screen button. The book keeps its original tag. */
  val buttonTag: String
    get() = if (id == ToolId.BOOK) "book_reader_button" else "tool_button_${id.id}"
}

object ToolRegistry {
  val all: List<ToolSpec> by lazy { listOf(BookTool, MailTool, WatchTool, LabelsTool, LightTool) }

  fun spec(id: ToolId): ToolSpec = all.first { it.id == id }
}
