// MailTool - the mail reader's registry entry and screen
//
// ToolRegistry lists [MailTool]; the router shows [MailScreen] when ToolHub.activeTool is this
// tool. Voice does everything; the screen mirrors it for sighted helpers, low-vision and TalkBack
// users: ToolScaffold (name, close, status, mic, last heard), then large labelled buttons (what is
// this letter, read it all, pause/carry on, back a sentence, next page, how much), what was found
// (kind, from, for, date, about, amount, due, pages) in large text, the sentence being read, and
// the letter's full text. Test tags: "mail_<button>_button", "mail_kind", "mail_from", "mail_for",
// "mail_amount", "mail_due", "mail_sentence", "mail_text".

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.mail

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.AttachTool
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolAccent
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScaffold
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolScreenContext
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolSpec
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.ToolId

val MailTool =
    ToolSpec(
        id = ToolId.MAIL,
        nameRes = R.string.mail_name,
        buttonRes = R.string.mail_button,
        buttonDescriptionRes = R.string.mail_button_description,
        icon = Icons.Filled.Email,
        content = { MailScreen(it) },
    )

@Composable
fun MailScreen(ctx: ToolScreenContext) {
  val app = LocalContext.current.applicationContext as Application
  val vm: MailViewModel = viewModel(factory = MailViewModel.Factory(app, ctx.hub))
  AttachTool(ctx.hub, vm, ctx.request)
  val ui by vm.ui.collectAsStateWithLifecycle()
  val mail by vm.mail.collectAsStateWithLifecycle()
  ToolScaffold(toolId = ToolId.MAIL, title = stringResource(R.string.mail_name), ui = ui, onClose = ctx.onClose) {
    Column(
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
      val looking = mail.phase == MailPhase.LOOKING
      BigButton(R.string.mail_action_summarise, "mail_summarise_button", enabled = !looking, onClick = vm::pressSummarise)
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        BigButton(
            if (mail.phase == MailPhase.READING) R.string.mail_action_pause
            else if (mail.phase == MailPhase.PAUSED) R.string.mail_action_resume
            else R.string.mail_action_read_all,
            "mail_read_all_button",
            enabled = !looking,
            modifier = Modifier.weight(1f),
            onClick = vm::pressPauseOrResume,
        )
        BigButton(R.string.mail_action_back, "mail_back_button", enabled = mail.letter != null, modifier = Modifier.weight(1f), onClick = vm::pressBack)
      }
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        BigButton(R.string.mail_action_next_page, "mail_next_page_button", enabled = mail.letter != null && !looking, modifier = Modifier.weight(1f), onClick = vm::pressNextPage)
        BigButton(R.string.mail_action_how_much, "mail_how_much_button", enabled = mail.letter != null && !looking, modifier = Modifier.weight(1f), onClick = vm::pressHowMuch)
      }
      mail.letter?.let { LetterFacts(it) }
      if (mail.sentence.isNotEmpty()) {
        Text(stringResource(R.string.mail_sentence_heading), color = Color.White, fontSize = 18.sp, modifier = Modifier.semantics { heading() })
        Text(mail.sentence, color = ToolAccent, fontSize = 24.sp, modifier = Modifier.testTag("mail_sentence"))
      }
      mail.letter?.let { letter ->
        Text(stringResource(R.string.mail_text_heading), color = Color.White, fontSize = 18.sp, modifier = Modifier.semantics { heading() })
        Text(letter.fullText, color = Color.White, fontSize = 20.sp, modifier = Modifier.testTag("mail_text"))
      }
    }
  }
}

@Composable
private fun LetterFacts(letter: Letter) {
  val unknown = stringResource(R.string.mail_unknown)
  Fact(R.string.mail_label_kind, if (letter.isEnvelope) "envelope" else LetterSpeech.kindPhrase(letter), "mail_kind")
  Fact(R.string.mail_label_from, letter.sender ?: unknown, "mail_from")
  Fact(R.string.mail_label_for, letter.recipient ?: letter.salutation ?: unknown, "mail_for")
  letter.date?.let { Fact(R.string.mail_label_date, it.spoken(), "mail_date") }
  letter.subject?.let { Fact(R.string.mail_label_about, it, "mail_about") }
  val amount =
      when (val a = letter.amount) {
        is AmountDue.Sure -> a.money.spoken()
        AmountDue.Unsure -> stringResource(R.string.mail_amount_unsure)
        AmountDue.Conflict -> stringResource(R.string.mail_amount_conflict)
        AmountDue.None -> null
      }
  amount?.let { Fact(R.string.mail_label_amount, it, "mail_amount") }
  letter.due?.let { Fact(R.string.mail_label_due, if (it.sure) it.spoken else stringResource(R.string.mail_amount_unsure), "mail_due") }
  if (letter.pages.size > 1) {
    Text(stringResource(R.string.mail_label_pages, letter.pages.size), color = Color.White, fontSize = 22.sp)
  }
}

@Composable
private fun Fact(label: Int, value: String, tag: String) {
  Text(
      stringResource(label, value),
      color = Color.White,
      fontSize = 22.sp,
      fontWeight = FontWeight.SemiBold,
      modifier = Modifier.testTag(tag),
  )
}

@Composable
private fun BigButton(
    label: Int,
    tag: String,
    enabled: Boolean,
    modifier: Modifier = Modifier.fillMaxWidth(),
    onClick: () -> Unit,
) {
  Button(
      onClick = onClick,
      enabled = enabled,
      modifier = modifier.heightIn(min = 64.dp).testTag(tag),
      colors = ButtonDefaults.buttonColors(containerColor = ToolAccent, contentColor = Color.Black),
  ) {
    Text(stringResource(label), fontSize = 20.sp, fontWeight = FontWeight.Bold)
  }
}
