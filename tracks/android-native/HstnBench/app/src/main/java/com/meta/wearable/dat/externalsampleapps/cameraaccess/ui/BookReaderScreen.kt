// BookReaderScreen - phone controls for the book reader
//
// The glasses do the reading and voice is the main control: while any tool screen is open ToolHub
// listens (the router starts it), and this screen's ViewModel is attached to it (BookTool). The buttons are a mirror for sighted helpers,
// low-vision users and TalkBack users, never the only way to do something. Built for TalkBack and low vision:
// big targets, every control labelled, each toggle one merged switch node, white or yellow on
// black, and the recognised text in large type with the sentence being spoken highlighted.
// Status changes aren't a live region: the reader already speaks them, and TalkBack would repeat.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.BookReaderUiState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.BookReaderViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.Microphone
import com.meta.wearable.dat.externalsampleapps.cameraaccess.bookreader.ReaderPhase
import java.util.Locale

private val ReaderBackground = Color.Black
private val ReaderAccent = AppColor.Yellow

@Composable
fun BookReaderScreen(
    viewModel: BookReaderViewModel,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
  val ui by viewModel.uiState.collectAsStateWithLifecycle()
  BackHandler(onBack = onClose)

  val close by rememberUpdatedState(onClose)
  LaunchedEffect(ui.closeRequested) { if (ui.closeRequested) close() }

  Column(
      modifier =
          modifier
              .fillMaxSize()
              .background(ReaderBackground)
              .statusBarsPadding()
              .navigationBarsPadding()
              .padding(horizontal = 16.dp, vertical = 8.dp)
              .testTag("book_reader_screen"),
      verticalArrangement = Arrangement.spacedBy(10.dp),
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text(
          text = stringResource(R.string.book_reader_title),
          color = Color.White,
          fontSize = 26.sp,
          fontWeight = FontWeight.Bold,
          modifier = Modifier.weight(1f).semantics { heading() },
      )
      IconButton(onClick = onClose, modifier = Modifier.size(56.dp).testTag("book_close")) {
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = stringResource(R.string.book_reader_close),
            tint = Color.White,
            modifier = Modifier.size(32.dp),
        )
      }
    }

    StatusLine(ui)

    BigButton(
        label =
            stringResource(
                when (ui.phase) {
                  ReaderPhase.IDLE -> R.string.book_start
                  ReaderPhase.PAUSED -> R.string.book_resume
                  ReaderPhase.WAITING, ReaderPhase.READING -> R.string.book_pause
                },
            ),
        onClick = viewModel::startOrPause,
        modifier = Modifier.testTag("book_start_pause"),
        container = ReaderAccent,
        content = Color.Black,
        height = 80,
        fontSize = 26,
    )

    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
      val nextDescription = stringResource(R.string.book_next_page_description)
      BigButton(
          label = stringResource(R.string.book_next_page),
          onClick = viewModel::nextPage,
          modifier =
              Modifier.weight(1f).testTag("book_next_page").semantics {
                contentDescription = nextDescription
              },
      )
      BigButton(
          label = stringResource(R.string.book_back_sentence),
          onClick = viewModel::backSentence,
          modifier = Modifier.weight(1f).testTag("book_back_sentence"),
      )
    }

    RateControl(rate = ui.speechRate, onRate = viewModel::setSpeechRate)

    ToggleRow(
        label = stringResource(R.string.book_read_furniture),
        checked = ui.readFurniture,
        onChange = viewModel::setReadFurniture,
        tag = "book_furniture_toggle",
    )
    ToggleRow(
        label = stringResource(R.string.book_auto_turn),
        checked = ui.autoTurn,
        onChange = viewModel::setAutoTurn,
        tag = "book_auto_turn_toggle",
    )

    PageText(ui, modifier = Modifier.weight(1f))
  }
}

@Composable
private fun StatusLine(ui: BookReaderUiState) {
  val status = ui.status.ifEmpty { stringResource(R.string.book_status_idle) }
  Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
    Text(
        text = status,
        color = ReaderAccent,
        fontSize = 22.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.testTag("book_status"),
    )
    Text(
        text = stringResource(R.string.book_pages_read, ui.pagesRead),
        color = Color.White,
        fontSize = 18.sp,
    )
    Text(
        text =
            stringResource(
                when (ui.microphone) {
                  Microphone.GLASSES -> R.string.voice_mic_glasses
                  Microphone.PHONE -> R.string.voice_mic_phone
                  Microphone.NONE -> R.string.voice_mic_none
                },
            ),
        color = Color.White,
        fontSize = 18.sp,
        modifier = Modifier.testTag("book_voice_mic"),
    )
    if (ui.heard.isNotEmpty()) {
      Text(
          text = stringResource(R.string.voice_heard, ui.heard),
          color = Color.White,
          fontSize = 18.sp,
          modifier = Modifier.testTag("book_voice_heard"),
      )
    }
    if (!ui.speechAvailable) {
      Text(
          text = stringResource(R.string.book_speech_unavailable),
          color = Color.White,
          fontSize = 18.sp,
      )
    }
  }
}

@Composable
private fun BigButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    container: Color = Color.White,
    content: Color = Color.Black,
    height: Int = 64,
    fontSize: Int = 20,
) {
  Button(
      onClick = onClick,
      modifier = modifier.fillMaxWidth().heightIn(min = height.dp),
      shape = RoundedCornerShape(16.dp),
      colors = ButtonDefaults.buttonColors(containerColor = container, contentColor = content),
  ) {
    Text(text = label, fontSize = fontSize.sp, fontWeight = FontWeight.Bold)
  }
}

@Composable
private fun RateControl(rate: Float, onRate: (Float) -> Unit) {
  val rateText = String.format(Locale.ROOT, "%.1f", rate)
  val label = stringResource(R.string.book_rate_label, rateText)
  val sliderDescription = stringResource(R.string.book_rate_slider_description)
  Column {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
      BigButton(
          label = stringResource(R.string.book_rate_slower),
          onClick = { onRate(rate - 0.25f) },
          modifier = Modifier.weight(1f).testTag("book_rate_slower"),
          height = 56,
          fontSize = 18,
      )
      Text(
          text = label,
          color = Color.White,
          fontSize = 22.sp,
          fontWeight = FontWeight.SemiBold,
          modifier = Modifier.testTag("book_rate_value"),
      )
      BigButton(
          label = stringResource(R.string.book_rate_faster),
          onClick = { onRate(rate + 0.25f) },
          modifier = Modifier.weight(1f).testTag("book_rate_faster"),
          height = 56,
          fontSize = 18,
      )
    }
    Slider(
        value = rate,
        onValueChange = onRate,
        valueRange = BookReaderViewModel.MIN_RATE..BookReaderViewModel.MAX_RATE,
        steps = 24,
        colors =
            SliderDefaults.colors(
                thumbColor = ReaderAccent,
                activeTrackColor = ReaderAccent,
                inactiveTrackColor = Color.White.copy(alpha = 0.5f),
            ),
        modifier =
            Modifier.fillMaxWidth().testTag("book_rate_slider").semantics {
              contentDescription = sliderDescription
              stateDescription = label
            },
    )
  }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit, tag: String) {
  Row(
      modifier =
          Modifier.fillMaxWidth()
              .heightIn(min = 56.dp)
              .toggleable(value = checked, role = Role.Switch, onValueChange = onChange)
              .testTag(tag),
      verticalAlignment = Alignment.CenterVertically,
  ) {
    Text(text = label, color = Color.White, fontSize = 20.sp, modifier = Modifier.weight(1f))
    Spacer(modifier = Modifier.size(12.dp))
    Switch(
        checked = checked,
        onCheckedChange = null,
        colors =
            SwitchDefaults.colors(
                checkedThumbColor = Color.Black,
                checkedTrackColor = ReaderAccent,
                uncheckedThumbColor = Color.White,
                uncheckedTrackColor = Color.DarkGray,
            ),
    )
  }
}

@Composable
private fun PageText(ui: BookReaderUiState, modifier: Modifier = Modifier) {
  val empty = stringResource(R.string.book_page_empty)
  val text =
      remember(ui.pageText, ui.chunks, ui.currentChunk) {
        highlighted(ui.pageText, ui.chunks, ui.currentChunk)
      }
  Box(
      modifier =
          modifier
              .fillMaxWidth()
              .background(Color(0xFF111111), RoundedCornerShape(12.dp))
              .padding(12.dp)
              .verticalScroll(rememberScrollState()),
  ) {
    Text(
        text = if (ui.pageText.isEmpty()) AnnotatedString(empty) else text,
        color = Color.White,
        fontSize = 26.sp,
        lineHeight = 38.sp,
        modifier = Modifier.testTag("book_page_text"),
    )
  }
}

/** The page with the chunk being spoken in black on yellow, so low-vision readers can follow. */
private fun highlighted(page: String, chunks: List<String>, current: Int): AnnotatedString =
    buildAnnotatedString {
      append(page)
      if (current !in chunks.indices) return@buildAnnotatedString
      var from = 0
      for (i in 0..current) {
        val at = page.indexOf(chunks[i], from)
        if (at < 0) return@buildAnnotatedString
        if (i == current) {
          addStyle(
              SpanStyle(background = ReaderAccent, color = Color.Black),
              at,
              at + chunks[i].length,
          )
        }
        from = at + chunks[i].length
      }
    }
