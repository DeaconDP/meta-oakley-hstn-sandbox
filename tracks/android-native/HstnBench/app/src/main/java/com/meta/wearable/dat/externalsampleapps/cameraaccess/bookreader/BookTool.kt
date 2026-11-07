// BookTool - the book reader's entry in the tool registry
//
// The book reader was the first tool; it keeps its own screen (ui/BookReaderScreen) and ViewModel
// (BookReaderViewModel, a ToolHost), and is opened like every other tool: the "Book Reader"
// launcher alias, hstnbench://book, `--ez book_reader true` or `--es tool book`, the camera-screen
// button, or by voice from any tool ("open the book reader", "read a book").

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader

import android.app.Application
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.AttachTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolSpec
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId
import com.meta.wearable.dat.externalsampleapps.cameraaccess.ui.BookReaderScreen

val BookTool =
    ToolSpec(
        id = ToolId.BOOK,
        nameRes = R.string.book_reader_title,
        buttonRes = R.string.book_reader_open,
        buttonDescriptionRes = R.string.book_reader_open_description,
        icon = Icons.AutoMirrored.Filled.MenuBook,
        content = { ctx ->
          val app = LocalContext.current.applicationContext as Application
          val vm: BookReaderViewModel = viewModel(factory = BookReaderViewModel.Factory(app, ctx.hub))
          AttachTool(ctx.hub, vm, ctx.request)
          BookReaderScreen(viewModel = vm, onClose = ctx.onClose)
        },
    )
