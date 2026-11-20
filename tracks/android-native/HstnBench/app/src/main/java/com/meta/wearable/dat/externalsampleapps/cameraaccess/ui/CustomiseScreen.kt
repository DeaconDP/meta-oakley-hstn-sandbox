// CustomiseScreen - "Make it your own" on the phone screen (helper view)
//
// Mirrors every setting the voice can change (notes/customisation-android.md), for a sighted helper
// or a TalkBack user. Changes here are saved at once (a deliberate change, not a passing tweak),
// can be undone, and are spoken to the user while voice is running ("every change is spoken").
// Opened from the camera screen's menu ("Make it your own") or by saying "open settings".
//
// Accessibility (WCAG 2.2 AA): every control is at least 56 dp, labelled, and reports its value in
// words (stateDescription); headings are marked as headings for TalkBack's heading navigation;
// choices are radio groups (Role.RadioButton), switches are whole-row toggles (Role.Switch);
// colours are the SpeakUp palette (Paper on Night/Dusk, 13:1+); state is never colour alone.
// English only, like the voice grammars.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ToolHub
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Area
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Controls
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Ear
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Pacing
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Preset
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsCommand
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SettingsStore
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.SetupSpeech
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Shortcuts
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Speech
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Verbosity
import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Words
import java.util.Locale

@Composable
fun CustomiseScreen(hub: ToolHub, onClose: () -> Unit) {
  BackHandler(onBack = onClose)
  val view by hub.settingsView.collectAsStateWithLifecycle()
  val s = view.setup
  val context = LocalContext.current
  var message by remember { mutableStateOf("") }
  fun say(text: String) {
    message = text
    hub.sayFromScreen(text)
  }
  fun change(spoken: String, f: (com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Setup) -> com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.Setup) {
    if (view.locked) {
      say("Settings are locked. Unlock them first.")
      return
    }
    message = SetupSpeech.sentence(spoken)
    hub.changeFromScreen(spoken, f)
  }
  fun outcome(o: SettingsStore.Outcome) =
      say(
          when (o) {
            SettingsStore.Outcome.Locked -> "Settings are locked. Unlock them first."
            is SettingsStore.Outcome.Changed -> o.spoken
            is SettingsStore.Outcome.Unchanged -> o.spoken
          },
      )

  Column(
      modifier =
          Modifier.fillMaxSize()
              .background(SpeakUpColors.Night)
              .statusBarsPadding()
              .navigationBarsPadding()
              .testTag("customise_screen"),
  ) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
      Text(
          "Make it your own",
          color = SpeakUpColors.Paper,
          style = MaterialTheme.typography.headlineSmall,
          modifier = Modifier.weight(1f).padding(start = 8.dp).semantics { heading() },
      )
      IconButton(onClick = onClose, modifier = Modifier.size(56.dp).testTag("customise_close")) {
        Icon(Icons.Filled.Close, contentDescription = "Close settings", tint = SpeakUpColors.Paper)
      }
    }
    Column(
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(SpeakUpDimens.Gap),
    ) {
      // Status and the always-there actions.
      SpeakUpCard {
        Text(
            buildString {
              append("Profile: ${view.profile}.")
              if (view.unkept) append(" Some changes are for this session only.")
              if (view.locked) append(" Settings are locked.")
            },
            color = SpeakUpColors.Paper,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.testTag("customise_status"),
        )
        if (message.isNotEmpty()) {
          Text(message, color = SpeakUpColors.SignalYellow, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.testTag("customise_message"))
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          SpeakUpButton("Undo", onClick = { outcome(hub.settings.undo()) }, enabled = view.canUndo, kind = ButtonKind.SECONDARY, modifier = Modifier.testTag("customise_undo"))
          SpeakUpButton("Keep changes", onClick = { outcome(hub.settings.keep()) }, enabled = view.unkept, modifier = Modifier.testTag("customise_keep"))
          SpeakUpButton("What's my setup", onClick = { say(hub.settingsVoice.whatsMySetup()) }, kind = ButtonKind.SECONDARY)
        }
        ToggleRow("Lock settings", view.locked, "customise_lock") { on -> outcome(if (on) hub.settings.lock() else hub.settings.unlock()) }
      }

      Section("Profiles") {
        Choice("Profile", view.profiles, view.profile, { it }) { p -> outcome(hub.settings.switchProfile(p)) }
        var name by remember { mutableStateOf("") }
        TextRow("New profile name", name, { name = it }, "customise_profile_name")
        SpeakUpButton("Save as profile", onClick = { if (name.isNotBlank()) outcome(hub.settings.saveProfile(name)).also { name = "" } }, kind = ButtonKind.SECONDARY)
        if (view.profile != SettingsStore.HOME) {
          SpeakUpButton("Delete ${view.profile}", onClick = { outcome(hub.settings.deleteProfile(view.profile)) }, kind = ButtonKind.DANGER)
        }
      }

      Section("Speech") {
        Choice("Preset", Preset.entries, s.speech.preset, { it.spoken }) { p ->
          change("${p.spoken} speech") { it.copy(speech = it.speech.copy(preset = p, rate = p.rate, pitch = p.pitch, pauseMs = p.pauseMs, verbosity = p.verbosity)) }
        }
        SliderRow("Speed", s.speech.rate, Speech.MIN_RATE..Speech.MAX_RATE, 24, { SetupSpeech.rate(it) }, "customise_rate") { v ->
          change("${SetupSpeech.rate(Speech.clampRate(v))} speed") { it.copy(speech = it.speech.copy(rate = Speech.clampRate(v))) }
        }
        val bookRate = s.speech.tools["book"]?.rate
        ToggleRow("The book has its own speed", bookRate != null, "customise_book_own_rate") { on ->
          change(if (on) "the book has its own speed" else "the book uses the main speed") {
            it.copy(speech = it.speech.withTool("book") { t -> t.copy(rate = if (on) it.speech.rate else null) })
          }
        }
        if (bookRate != null) {
          SliderRow("Book speed", bookRate, Speech.MIN_RATE..Speech.MAX_RATE, 24, { SetupSpeech.rate(it) }, "customise_book_rate") { v ->
            change("the book at ${SetupSpeech.rate(Speech.clampRate(v))}") { it.copy(speech = it.speech.withTool("book") { t -> t.copy(rate = Speech.clampRate(v)) }) }
          }
        }
        SliderRow("Pitch", s.speech.pitch, Speech.MIN_PITCH..Speech.MAX_PITCH, 14, { SetupSpeech.pitch(it) }, "customise_pitch") { v ->
          change(SetupSpeech.pitch(Speech.clampPitch(v))) { it.copy(speech = it.speech.copy(pitch = Speech.clampPitch(v))) }
        }
        SliderRow("Pause after each sentence", s.speech.pauseMs.toFloat(), 0f..1200f, 23, { "${it.toInt()} milliseconds" }, "customise_pause") { v ->
          val ms = (Math.round(v / 50f) * 50)
          change(SetupSpeech.pauses(ms)) { it.copy(speech = it.speech.copy(pauseMs = ms)) }
        }
        Choice("Detail", Verbosity.entries, s.speech.verbosity, { it.spoken }) { v ->
          change("${v.spoken} replies") { it.copy(speech = it.speech.copy(verbosity = v)) }
        }
        for (tool in Words.DEFAULT_MENU) {
          val current = s.speech.tools[tool]?.verbosity
          Choice("Detail for ${SetupSpeech.toolName(tool)}", listOf<Verbosity?>(null) + Verbosity.entries, current, { it?.spoken ?: "same" }) { v ->
            change("${SetupSpeech.toolName(tool)}: ${v?.spoken ?: "same as everywhere"}") { it.copy(speech = it.speech.withTool(tool) { t -> t.copy(verbosity = v) }) }
          }
        }
        ToggleRow("Book: read page numbers", s.bookPageNumbers, "customise_page_numbers") { on ->
          change(if (on) "page numbers read out" else "page numbers skipped") { it.copy(speech = it.speech.withTool("book") { t -> t.copy(pageNumbers = on.takeIf { b -> b }) }) }
        }
        ToggleRow("Book: turn pages automatically", s.bookAutoTurn, "customise_auto_turn") { on ->
          change(if (on) "automatic page turns on" else "automatic page turns off") { it.copy(speech = it.speech.withTool("book") { t -> t.copy(autoTurn = if (on) null else false) }) }
        }
        VoicePicker(hub, s.speech.voice) { name, label -> change(label) { it.copy(speech = it.speech.copy(voice = name)) } }
      }

      Section("Sounds") {
        ToggleRow("Sounds (earcons)", s.sounds.earcons, "customise_earcons") { on -> change(if (on) "sounds on" else "sounds off") { it.copy(sounds = it.sounds.copy(earcons = on)) } }
        SliderRow("Sound volume", s.sounds.volume, 0.1f..1f, 8, { SetupSpeech.percent(it) }, "customise_earcon_volume") { v ->
          val vol = Math.round(v * 10f) / 10f
          change("sounds at ${SetupSpeech.percent(vol)}") { it.copy(sounds = it.sounds.copy(volume = vol)) }
        }
        ToggleRow("Sounds instead of short replies", s.sounds.earconsOnly, "customise_earcons_only") { on ->
          change(if (on) "sounds instead of short replies" else "words for short replies") { it.copy(sounds = it.sounds.copy(earconsOnly = on)) }
        }
        ToggleRow("Say what sounds mean (learning)", s.sounds.speakEarcons, "customise_speak_earcons") { on ->
          change(if (on) "sounds said as words" else "sounds played") { it.copy(sounds = it.sounds.copy(speakEarcons = on)) }
        }
        Choice("Watch for text ticks", listOf(10, 20, 30, 0), s.sounds.watchTickSeconds, { if (it == 0) "off" else "$it s" }) { t ->
          change(SetupSpeech.ticks(t)) { it.copy(sounds = it.sounds.copy(watchTickSeconds = t)) }
        }
      }

      Section("Ears") {
        SliderRow("Balance", s.ears.balance, -1f..1f, 19, { SetupSpeech.balance(it) }, "customise_balance") { v ->
          val b = Math.round(v * 10f) / 10f
          change(SetupSpeech.balance(b)) { it.copy(ears = it.ears.copy(balance = b)) }
        }
        Choice("Speech in", Ear.entries, s.ears.speech, ::earName) { e -> change(SetupSpeech.ear("speech", e)) { it.copy(ears = it.ears.copy(speech = e)) } }
        Choice("Sounds in", Ear.entries, s.ears.earcons, ::earName) { e -> change(SetupSpeech.ear("sounds", e)) { it.copy(ears = it.ears.copy(earcons = e)) } }
        Choice("Direction cues in", Ear.entries, s.ears.cues, ::earName) { e -> change(SetupSpeech.ear("direction cues", e)) { it.copy(ears = it.ears.copy(cues = e)) } }
        ToggleRow("I use mono", s.ears.mono, "customise_mono") { on -> change(if (on) "mono on" else "stereo") { it.copy(ears = it.ears.copy(mono = on)) } }
        ToggleRow("Clear speech (slower, louder, crisper)", s.ears.clearSpeech, "customise_clear_speech") { on ->
          change(if (on) "clear speech on" else "clear speech off") { it.copy(ears = it.ears.copy(clearSpeech = on)) }
        }
        SpeakUpButton("Someone's talking to me (conversation mode)", onClick = { hub.runSettings(SettingsCommand.ConversationStart) }, kind = ButtonKind.SECONDARY)
      }

      Section("Words") {
        Text(Shortcuts.listLine(s.words).ifEmpty { "No shortcuts yet." }, color = SpeakUpColors.Paper, style = MaterialTheme.typography.bodyLarge)
        for (k in s.words.aliases.keys + s.words.macros.keys) {
          SpeakUpButton("Forget $k", onClick = {
            (Shortcuts.forget(k, s.words) as? Shortcuts.Result.Added)?.let { r -> change(r.spoken) { it.copy(words = r.words) } }
          }, kind = ButtonKind.SECONDARY)
        }
        var phrase by remember { mutableStateOf("") }
        var command by remember { mutableStateOf("") }
        TextRow("When I say", phrase, { phrase = it }, "customise_alias_phrase")
        TextRow("Do this (for several, separate with then)", command, { command = it }, "customise_alias_command")
        SpeakUpButton("Add shortcut", onClick = {
          if (phrase.isNotBlank() && command.isNotBlank()) {
            when (val r = Shortcuts.define(SettingsCommand.DefineShortcut(Shortcuts.key(phrase), command, "$phrase $command"), s.words)) {
              is Shortcuts.Result.Added -> {
                change(r.spoken) { it.copy(words = r.words) }
                phrase = ""
                command = ""
              }
              is Shortcuts.Result.Refused -> say(r.spoken)
            }
          }
        })
        Text("Home menu", color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() })
        val order = s.words.normalisedOrder()
        for ((i, tool) in order.withIndex()) {
          val hidden = tool in s.words.menuHidden
          Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "${i + 1}. ${SetupSpeech.toolName(tool)}" + if (hidden) " (hidden)" else "",
                color = SpeakUpColors.Paper,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
            SpeakUpButton("Up", onClick = {
              if (i > 0) change("${SetupSpeech.toolName(tool)} moved up") { st -> st.copy(words = st.words.copy(menuOrder = order.toMutableList().apply { add(i - 1, removeAt(i)) })) }
            }, enabled = i > 0, kind = ButtonKind.SECONDARY, modifier = Modifier.semantics { contentDescription = "Move ${SetupSpeech.toolName(tool)} up" })
            SpeakUpButton(if (hidden) "Show" else "Hide", onClick = {
              val next = if (hidden) s.words.menuHidden - tool else s.words.menuHidden + tool
              if (next.size >= Words.DEFAULT_MENU.size) say("I'll keep at least one tool on the menu.")
              else change("${SetupSpeech.toolName(tool)} ${if (hidden) "back on the menu" else "hidden from the menu"}") { st -> st.copy(words = st.words.copy(menuHidden = next)) }
            }, kind = ButtonKind.SECONDARY, modifier = Modifier.semantics { contentDescription = "${if (hidden) "Show" else "Hide"} ${SetupSpeech.toolName(tool)}" })
          }
        }
        var address by remember(s.words.address) { mutableStateOf(s.words.address ?: "") }
        TextRow("Extra name I answer to", address, { address = it }, "customise_address")
        SpeakUpButton("Save name", onClick = {
          val a = address.trim().lowercase(Locale.ROOT).takeIf { it.isNotEmpty() }
          change(if (a == null) "only the usual names" else "I answer to $a") { it.copy(words = it.words.copy(address = a)) }
        }, kind = ButtonKind.SECONDARY)
      }

      Section("Tips") {
        Choice("Tips and reminders", Pacing.entries, s.tips.pacing, { it.spoken }) { p -> change(p.spoken) { it.copy(tips = it.tips.copy(pacing = p)) } }
      }

      Section("Descriptions") {
        Choice("Description detail", Verbosity.entries, s.descriptions.detail, { it.spoken }) { v -> change("${v.spoken} descriptions") { it.copy(descriptions = it.descriptions.copy(detail = v)) } }
        ToggleRow("Read any text first", s.descriptions.textFirst, "customise_text_first") { on -> change(if (on) "text read first" else "text not read first") { it.copy(descriptions = it.descriptions.copy(textFirst = on)) } }
        ToggleRow("Mention colours", s.descriptions.colours, "customise_colours") { on -> change(if (on) "colours mentioned" else "colours skipped") { it.copy(descriptions = it.descriptions.copy(colours = on)) } }
        Choice("Directions", listOf("leftRight", "clock"), s.descriptions.directions, { if (it == "clock") "clock face" else "left and right" }) { d ->
          change(if (d == "clock") "clock-face directions" else "left and right directions") { it.copy(descriptions = it.descriptions.copy(directions = d)) }
        }
        Text("Saying how sure I am, and refusing medicine doses and money amounts I can't read, always stay on.", color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
      }

      Section("Glasses controls (experimental)") {
        ToggleRow("Use the glasses buttons", s.controls.enabled, "customise_controls") { on ->
          change(if (on) "glasses controls on" else "glasses controls off") { it.copy(controls = it.controls.copy(enabled = on)) }
        }
        for (event in Controls.EVENTS) {
          var action by remember(s.controls.map[event]) { mutableStateOf(s.controls.map[event] ?: "") }
          TextRow(Controls.SPOKEN_EVENT[event] ?: event, action, { action = it }, "customise_control_$event")
          if (action != (s.controls.map[event] ?: "")) {
            SpeakUpButton("Save", onClick = {
              val a = action.trim()
              val known = a.isEmpty() || com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings.CommandCatalog.understands(a) ||
                  Shortcuts.key(a) in s.words.aliases || Shortcuts.key(a) in s.words.macros
              if (!known) say("I don't know how to $a.")
              else change("${Controls.SPOKEN_EVENT[event]}: ${a.ifEmpty { "nothing" }}") { it.copy(controls = it.controls.copy(map = it.controls.map + (event to a))) }
            }, kind = ButtonKind.SECONDARY)
          }
        }
        Text("Touching and holding the side of the glasses belongs to Meta: it pauses or ends the session.", color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
      }

      Section("Share and carry") {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          SpeakUpButton("Share setup", onClick = { shareSetup(context, hub.settings.exportJson(), hub.settings.exportCode()) }, modifier = Modifier.testTag("customise_share"))
          SpeakUpButton("Copy code", onClick = {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("SpeakUp setup", hub.settings.exportCode()))
            say("Setup code copied.")
          }, kind = ButtonKind.SECONDARY)
        }
        var pasted by remember { mutableStateOf("") }
        TextRow("Paste a setup code or file", pasted, { pasted = it }, "customise_import_text")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          SpeakUpButton("Paste", onClick = {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            pasted = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString() ?: pasted
          }, kind = ButtonKind.SECONDARY)
          SpeakUpButton("Import", onClick = { if (pasted.isNotBlank()) outcome(hub.settings.import(pasted)).also { pasted = "" } }, modifier = Modifier.testTag("customise_import"))
        }
      }

      Section("Start again") {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          for (a in Area.entries) {
            SpeakUpButton("Reset ${a.spoken}", onClick = { outcome(hub.settings.reset(a)) }, kind = ButtonKind.SECONDARY)
          }
          SpeakUpButton("Reset everything", onClick = { outcome(hub.settings.resetAll()) }, kind = ButtonKind.DANGER)
        }
        Text("Every reset can be undone.", color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
      }

      Section("Experimental") {
        var busOn by remember { mutableStateOf(hub.audioBusOn) }
        ToggleRow("One audio output (mixes speech, sounds and tones)", busOn, "customise_audio_bus") { on ->
          busOn = on
          hub.setAudioBus(on)
          say(if (on) "One audio output on." else "One audio output off.")
        }
        Text(
            "Off by default: speech then waits for the voice engine to make its first sound. Balance and ears work either way.",
            color = SpeakUpColors.PaperMuted,
            style = MaterialTheme.typography.bodyMedium,
        )
      }
      Spacer(Modifier.size(24.dp))
    }
  }
}

/** The share sheet with the code and the full file (for another phone, or iOS). */
fun shareSetup(context: Context, json: String, code: String) {
  val send =
      Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, "My SpeakUp setup")
        putExtra(Intent.EXTRA_TEXT, "My SpeakUp setup code:\n$code\n\nFull setup:\n$json")
      }
  context.startActivity(Intent.createChooser(send, "Share your setup").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

private fun earName(e: Ear): String =
    when (e) {
      Ear.LEFT -> "left"
      Ear.BOTH -> "both"
      Ear.RIGHT -> "right"
    }

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
  SpeakUpCard(modifier = Modifier.fillMaxWidth()) {
    Text(title, color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
    content()
  }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
  Row(
      modifier =
          Modifier.fillMaxWidth()
              .heightIn(min = SpeakUpDimens.MinTouchTarget)
              .toggleable(value = checked, role = Role.Switch, onValueChange = onChange)
              .testTag(tag),
      verticalAlignment = Alignment.CenterVertically,
  ) {
    Text(label, color = SpeakUpColors.Paper, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
    Spacer(Modifier.size(12.dp))
    Switch(
        checked = checked,
        onCheckedChange = null,
        colors =
            SwitchDefaults.colors(
                checkedThumbColor = SpeakUpColors.Night,
                checkedTrackColor = SpeakUpColors.SignalYellow,
                checkedBorderColor = SpeakUpColors.SignalYellow,
                uncheckedThumbColor = SpeakUpColors.PaperMuted,
                uncheckedTrackColor = SpeakUpColors.Dusk,
                uncheckedBorderColor = SpeakUpColors.PaperMuted,
            ),
    )
  }
}

/** A radio group: label, then one 56 dp chip per option. The chosen one is filled and says "selected". */
@Composable
private fun <T> Choice(label: String, options: List<T>, selected: T, name: (T) -> String, onPick: (T) -> Unit) {
  Text(label, color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium)
  FlowRow(
      modifier = Modifier.selectableGroup().semantics { contentDescription = label },
      horizontalArrangement = Arrangement.spacedBy(8.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    for (o in options) {
      val on = o == selected
      Row(
          modifier =
              Modifier.heightIn(min = SpeakUpDimens.MinTouchTarget)
                  .clip(MaterialTheme.shapes.medium)
                  .background(if (on) SpeakUpColors.SignalYellow else SpeakUpColors.Night)
                  .border(2.dp, if (on) SpeakUpColors.SignalYellow else SpeakUpColors.PaperMuted, MaterialTheme.shapes.medium)
                  .selectable(selected = on, role = Role.RadioButton, onClick = { if (!on) onPick(o) })
                  .padding(horizontal = 16.dp),
          verticalAlignment = Alignment.CenterVertically,
      ) {
        Text(
            (if (on) "✓ " else "") + name(o),
            color = if (on) SpeakUpColors.OnAccent else SpeakUpColors.Paper,
            style = MaterialTheme.typography.labelLarge,
        )
      }
    }
  }
}

/** A slider that reports its value in words and saves when let go. */
@Composable
private fun SliderRow(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    steps: Int,
    describe: (Float) -> String,
    tag: String,
    onDone: (Float) -> Unit,
) {
  var v by remember { mutableFloatStateOf(value) }
  LaunchedEffect(value) { v = value }
  Text("$label: ${describe(v)}", color = SpeakUpColors.Paper, style = MaterialTheme.typography.titleMedium)
  Slider(
      value = v,
      onValueChange = { v = it },
      onValueChangeFinished = { onDone(v) },
      valueRange = range,
      steps = steps,
      colors =
          SliderDefaults.colors(
              thumbColor = SpeakUpColors.SignalYellow,
              activeTrackColor = SpeakUpColors.SignalYellow,
              inactiveTrackColor = SpeakUpColors.DuskLine,
              activeTickColor = SpeakUpColors.Night,
              inactiveTickColor = SpeakUpColors.PaperMuted,
          ),
      modifier =
          Modifier.fillMaxWidth().heightIn(min = SpeakUpDimens.MinTouchTarget).testTag(tag).semantics {
            contentDescription = label
            stateDescription = describe(v)
          },
  )
}

@Composable
private fun TextRow(label: String, value: String, onChange: (String) -> Unit, tag: String) {
  OutlinedTextField(
      value = value,
      onValueChange = onChange,
      label = { Text(label) },
      singleLine = true,
      colors =
          OutlinedTextFieldDefaults.colors(
              focusedTextColor = SpeakUpColors.Paper,
              unfocusedTextColor = SpeakUpColors.Paper,
              focusedLabelColor = SpeakUpColors.SignalYellow,
              unfocusedLabelColor = SpeakUpColors.PaperMuted,
              focusedBorderColor = SpeakUpColors.SignalYellow,
              unfocusedBorderColor = SpeakUpColors.PaperMuted,
              cursorColor = SpeakUpColors.SignalYellow,
          ),
      modifier = Modifier.fillMaxWidth().heightIn(min = SpeakUpDimens.MinTouchTarget).testTag(tag),
  )
}

/** The installed voices for the speech language; picking one plays it (the change is spoken in it). */
@Composable
private fun VoicePicker(hub: ToolHub, current: String?, onPick: (String?, String) -> Unit) {
  var open by remember { mutableStateOf(false) }
  SpeakUpButton(if (open) "Hide voices" else "Choose a voice", onClick = { open = !open }, kind = ButtonKind.SECONDARY, modifier = Modifier.testTag("customise_voices"))
  if (!open) return
  val voices = remember { hub.settingsVoice.let { _ -> hubVoices(hub) } }
  Choice("Voice", listOf<String?>(null) + voices.map { it.first }, current, { n -> if (n == null) "default" else voices.firstOrNull { it.first == n }?.second ?: n }) { n ->
    onPick(n, if (n == null) "the default voice" else "this voice, ${voices.firstOrNull { it.first == n }?.second ?: ""}")
  }
  if (voices.isEmpty()) Text("Only the default voice is installed for this language.", color = SpeakUpColors.PaperMuted, style = MaterialTheme.typography.bodyMedium)
}

private fun hubVoices(hub: ToolHub): List<Pair<String, String>> = hub.voices().map { it.name to it.label }
