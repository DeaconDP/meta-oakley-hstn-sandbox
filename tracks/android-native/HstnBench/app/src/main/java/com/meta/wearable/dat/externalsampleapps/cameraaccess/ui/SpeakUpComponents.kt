// SpeakUp building blocks: the voice ribbon (the brand's signature motion), buttons and cards.
//
// The voice ribbon is a soft, glowing waveform that mirrors what the voice is doing:
//   IDLE      calm Signal Yellow, low and slow
//   LISTENING Listen Cyan, breathing (amplitude swells and settles about every 3 s)
//   SPEAKING  Voice Coral, flowing faster with a moving, speech-like envelope
//   THINKING  Signal Yellow with a slow highlight sweeping across it
// It is decorative: TalkBack skips it (clearAndSetSemantics), because every screen also says the
// state in words. It honours reduced motion: when Android's animator duration scale is 0 (Settings >
// Accessibility > Remove animations, or Developer options), it draws one still frame and runs no
// frame loop. The frame loop uses withInfiniteAnimationFrameNanos, so Compose UI tests never wait on
// it, and it only runs while the screen is visible.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.animation.ValueAnimator
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.math.PI
import kotlin.math.sin

/** What the voice is doing, for the ribbon. */
enum class VoiceState {
  IDLE,
  LISTENING,
  SPEAKING,
  THINKING,
}

private data class RibbonLook(
    val color: Color,
    /** Wave height as a share of half the ribbon height. */
    val amplitude: Float,
    /** Phase speed, radians per second. */
    val speed: Float,
)

private fun lookFor(state: VoiceState): RibbonLook =
    when (state) {
      VoiceState.IDLE -> RibbonLook(SpeakUpColors.SignalYellow, 0.30f, 0.9f)
      VoiceState.LISTENING -> RibbonLook(SpeakUpColors.ListenCyan, 0.62f, 1.6f)
      VoiceState.SPEAKING -> RibbonLook(SpeakUpColors.VoiceCoral, 0.85f, 4.2f)
      VoiceState.THINKING -> RibbonLook(SpeakUpColors.SignalYellow, 0.40f, 0.7f)
    }

/**
 * False when the user has turned animations off (animator duration scale 0). Re-checked each time
 * the screen resumes, so changing the setting and coming back takes effect.
 */
@Composable
fun rememberAnimationsEnabled(): Boolean {
  val lifecycleOwner = LocalLifecycleOwner.current
  var enabled by remember { mutableStateOf(ValueAnimator.areAnimatorsEnabled()) }
  DisposableEffect(lifecycleOwner) {
    val observer = LifecycleEventObserver { _, event ->
      if (event == Lifecycle.Event.ON_RESUME) enabled = ValueAnimator.areAnimatorsEnabled()
    }
    lifecycleOwner.lifecycle.addObserver(observer)
    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
  }
  return enabled
}

/**
 * The voice ribbon. Decorative (hidden from TalkBack); show the state in text next to it.
 * [height] is the drawing's height, not a text container.
 */
@Composable
fun VoiceRibbon(
    state: VoiceState,
    modifier: Modifier = Modifier,
    height: Dp = 64.dp,
) {
  val animate = rememberAnimationsEnabled()
  val look = lookFor(state)
  val color by
      animateColorAsState(
          targetValue = look.color,
          animationSpec = if (animate) tween(durationMillis = 700) else snap(),
          label = "ribbonColor",
      )
  val amplitude by
      animateFloatAsState(
          targetValue = look.amplitude,
          animationSpec = if (animate) tween(durationMillis = 900) else snap(),
          label = "ribbonAmplitude",
      )
  val speed by rememberUpdatedState(look.speed)

  // Seconds since the ribbon appeared, and the accumulated wave phase. Read only while drawing, so
  // each frame redraws the canvas without recomposing anything.
  val clock = remember { mutableFloatStateOf(STILL_TIME) }
  val phase = remember { mutableFloatStateOf(STILL_PHASE) }
  if (animate) {
    LaunchedEffect(Unit) {
      var last = 0L
      while (true) {
        withInfiniteAnimationFrameNanos { now ->
          if (last != 0L) {
            val dt = ((now - last) / 1_000_000_000f).coerceAtMost(0.1f)
            clock.floatValue += dt
            // Wrapped at 20 full turns: every strand's speed factor (1, 0.7, 0.45) times 20 is a
            // whole number of turns, so the wrap is seamless and the float keeps its precision.
            phase.floatValue = (phase.floatValue + dt * speed) % (2f * PI.toFloat() * 20f)
          }
          last = now
        }
      }
    }
  }

  Canvas(modifier = modifier.fillMaxWidth().height(height).clearAndSetSemantics {}) {
    // Animations off: one still frame, the same every time.
    val t = if (animate) clock.floatValue else STILL_TIME
    val p = if (animate) phase.floatValue else STILL_PHASE
    val swell =
        when (state) {
          // Breathing: about one breath every 3.2 s.
          VoiceState.LISTENING -> if (animate) 0.72f + 0.28f * sin(2f * PI.toFloat() * t / 3.2f) else 0.9f
          // Speech-like: two beating rhythms.
          VoiceState.SPEAKING -> if (animate) 0.70f + 0.30f * sin(t * 5.3f) * sin(t * 2.1f + 1f) else 0.85f
          else -> 1f
        }
    drawRibbon(
        color = color,
        amplitude = amplitude * swell,
        phase = p,
        shimmerAt = if (state == VoiceState.THINKING) ((t * 0.28f) % 1.4f) - 0.2f else null,
    )
  }
}

private const val STILL_TIME = 0.8f
private const val STILL_PHASE = 1.1f

private fun DrawScope.drawRibbon(color: Color, amplitude: Float, phase: Float, shimmerAt: Float?) {
  val w = size.width
  val mid = size.height / 2f
  val maxA = size.height * 0.40f * amplitude
  val strands =
      // (frequency, phase offset, speed factor, alpha, stroke width dp)
      listOf(
          Strand(1.6f, 0.0f, 1.0f, 1.00f, 3.5f),
          Strand(2.3f, 1.9f, -0.7f, 0.55f, 2.5f),
          Strand(1.1f, 3.4f, 0.45f, 0.35f, 2.0f),
      )
  val main = strandPath(w, mid, maxA, strands[0], phase)
  // Soft glow: the main strand drawn wide and faint underneath.
  drawPath(main, color.copy(alpha = 0.10f), style = Stroke(width = 22.dp.toPx(), cap = StrokeCap.Round))
  drawPath(main, color.copy(alpha = 0.18f), style = Stroke(width = 11.dp.toPx(), cap = StrokeCap.Round))
  for (strand in strands.drop(1).reversed()) {
    drawPath(
        strandPath(w, mid, maxA * 0.8f, strand, phase),
        color.copy(alpha = strand.alpha),
        style = Stroke(width = strand.width.dp.toPx(), cap = StrokeCap.Round),
    )
  }
  val brush: Brush =
      if (shimmerAt == null) {
        Brush.horizontalGradient(listOf(color, color))
      } else {
        val dim = color.copy(alpha = 0.55f)
        val at = shimmerAt.coerceIn(-0.2f, 1.2f)
        Brush.horizontalGradient(
            0f to dim,
            (at - 0.18f).coerceIn(0f, 1f) to dim,
            at.coerceIn(0f, 1f) to SpeakUpColors.Paper,
            (at + 0.18f).coerceIn(0f, 1f) to dim,
            1f to dim,
            startX = 0f,
            endX = w,
        )
      }
  drawPath(main, brush, style = Stroke(width = strands[0].width.dp.toPx(), cap = StrokeCap.Round))
}

private data class Strand(
    val frequency: Float,
    val offset: Float,
    val speedFactor: Float,
    val alpha: Float,
    val width: Float,
)

private fun strandPath(w: Float, mid: Float, maxA: Float, s: Strand, phase: Float): Path {
  val path = Path()
  val steps = 72
  for (i in 0..steps) {
    val x = w * i / steps
    val u = i.toFloat() / steps
    // Tapered ends so the ribbon fades into the page instead of stopping at the edge.
    val taper = sin(PI.toFloat() * u)
    val y = mid + maxA * taper * sin(2f * PI.toFloat() * s.frequency * u + s.offset + phase * s.speedFactor)
    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
  }
  return path
}

/** How a [SpeakUpButton] looks. */
enum class ButtonKind {
  /** Signal Yellow with Night text: the main action. */
  PRIMARY,
  /** Dusk with a light outline and Paper text. */
  SECONDARY,
  /** Voice Coral with Night text: disconnect, end, stop. */
  DANGER,
}

/**
 * The SpeakUp button: at least 56dp tall (grows with the font scale, never clips), bold label,
 * optional leading icon. Disabled stays readable (PaperMuted on Dusk, 9.2:1).
 */
@Composable
fun SpeakUpButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.PRIMARY,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    minHeight: Dp = SpeakUpDimens.MinTouchTarget,
) {
  val (container, content) =
      when (kind) {
        ButtonKind.PRIMARY -> SpeakUpColors.SignalYellow to SpeakUpColors.OnAccent
        ButtonKind.SECONDARY -> SpeakUpColors.Dusk to SpeakUpColors.Paper
        ButtonKind.DANGER -> SpeakUpColors.VoiceCoral to SpeakUpColors.OnAccent
      }
  Button(
      onClick = onClick,
      enabled = enabled,
      modifier = modifier.heightIn(min = minHeight.coerceAtLeast(SpeakUpDimens.MinTouchTarget)),
      shape = MaterialTheme.shapes.medium,
      colors =
          ButtonDefaults.buttonColors(
              containerColor = container,
              contentColor = content,
              disabledContainerColor = SpeakUpColors.DisabledContainer,
              disabledContentColor = SpeakUpColors.DisabledContent,
          ),
      border =
          when {
            !enabled -> BorderStroke(2.dp, SpeakUpColors.DuskLine)
            kind == ButtonKind.SECONDARY -> BorderStroke(2.dp, SpeakUpColors.PaperMuted)
            else -> null
          },
      contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
  ) {
    if (icon != null) {
      Icon(imageVector = icon, contentDescription = null, modifier = Modifier.size(26.dp))
      Spacer(modifier = Modifier.width(10.dp))
    }
    Text(text = label, style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center)
  }
}

/** A Dusk card with a quiet outline. */
@Composable
fun SpeakUpCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
  Column(
      modifier =
          modifier
              .clip(MaterialTheme.shapes.medium)
              .background(SpeakUpColors.Dusk)
              .border(1.dp, SpeakUpColors.DuskLine, MaterialTheme.shapes.medium)
              .padding(SpeakUpDimens.CardPadding),
      verticalArrangement = Arrangement.spacedBy(8.dp),
      content = content,
  )
}

/** A coloured dot plus words: state is never colour alone. Used over the camera feed. */
@Composable
fun StateDotLabel(
    text: String,
    dot: Color,
    modifier: Modifier = Modifier,
    filled: Boolean = true,
) {
  Row(
      modifier = modifier,
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Canvas(modifier = Modifier.size(12.dp)) {
      if (filled) {
        drawCircle(dot)
      } else {
        drawCircle(dot, style = Stroke(width = 2.dp.toPx()))
      }
    }
    Text(text = text, style = MaterialTheme.typography.labelSmall, color = SpeakUpColors.Paper)
  }
}

/** Shape used for pills over the camera feed. */
val PillShape = RoundedCornerShape(percent = 50)
