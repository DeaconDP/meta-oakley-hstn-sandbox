/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// SpeakUp design system: colour tokens, type, shapes and sizes, and the SpeakUpTheme wrapper.
//
// Dark-first and high contrast. Measured WCAG contrast (sRGB relative luminance):
//   Paper      on Night 18.4:1, on Dusk 15.6:1
//   PaperMuted on Night 10.4:1, on Dusk  9.2:1  (Paper at 75% over Night, as a solid colour so it
//                                                 holds on Dusk cards too; brief asks for >= 7:1)
//   Signal Yellow on Night 13.8:1 (and Night on Yellow 13.8:1), on Dusk 11.7:1
//   Listen Cyan   on Night 11.4:1, on Dusk  9.7:1
//   Voice Coral   on Night  7.0:1, on Dusk  5.9:1  (Night on Coral 7.0:1)
// Body text is Paper or PaperMuted. Colour never carries state alone: every coloured state also
// has words or an icon next to it.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.R

/** SpeakUp colour tokens. */
object SpeakUpColors {
  /** Page background. */
  val Night = Color(0xFF0B0B1A)
  /** Cards and raised surfaces. */
  val Dusk = Color(0xFF1E1A3D)
  /** Outlines and dividers (decorative; never the only edge of a control that matters). */
  val DuskLine = Color(0xFF3A3470)
  /** Primary and main actions. Always with Night text on it. */
  val SignalYellow = Color(0xFFFFD60A)
  /** Body text. */
  val Paper = Color(0xFFFFF8E7)
  /** Secondary text: 10.4:1 on Night, 9.2:1 on Dusk. */
  val PaperMuted = Color(0xFFC2BDB4)
  /** Speaking, warnings, destructive actions. */
  val VoiceCoral = Color(0xFFFF6B5B)
  /** Listening. */
  val ListenCyan = Color(0xFF3DD9EB)

  /** Text and icons on Signal Yellow, Voice Coral or Listen Cyan. */
  val OnAccent = Night
  /** Disabled control fill and content: still readable (PaperMuted on Dusk is 9.2:1). */
  val DisabledContainer = Dusk
  val DisabledContent = PaperMuted
  /** Dim veil over the live camera feed so text on top stays legible. */
  val Scrim = Night.copy(alpha = 0.78f)
}

/** Atkinson Hyperlegible, designed for low-vision readers (res/font). */
val AtkinsonHyperlegible =
    FontFamily(
        Font(R.font.atkinson_hyperlegible_regular, FontWeight.Normal),
        Font(R.font.atkinson_hyperlegible_bold, FontWeight.Bold),
    )

/** Sizes shared by every screen. */
object SpeakUpDimens {
  /** Smallest touch target anywhere in the app. */
  val MinTouchTarget = 56.dp
  /** The main action on a screen. */
  val HeroButtonHeight = 72.dp
  val ScreenPadding = 20.dp
  val CardPadding = 18.dp
  val Gap = 12.dp
}

private fun style(size: Int, line: Int, weight: FontWeight, spacing: Double = 0.0) =
    TextStyle(
        fontFamily = AtkinsonHyperlegible,
        fontWeight = weight,
        fontSize = size.sp,
        lineHeight = line.sp,
        letterSpacing = spacing.sp,
    )

/**
 * Big, bold, all in sp so the user's font scale applies. Body and labels are 20sp or more; only
 * labelSmall (status chips over the camera feed) is 18sp.
 */
val SpeakUpTypography =
    Typography(
        displayLarge = style(52, 60, FontWeight.Bold, -0.5),
        displayMedium = style(44, 52, FontWeight.Bold, -0.25),
        displaySmall = style(38, 46, FontWeight.Bold),
        headlineLarge = style(34, 42, FontWeight.Bold),
        headlineMedium = style(30, 38, FontWeight.Bold),
        headlineSmall = style(26, 34, FontWeight.Bold),
        titleLarge = style(26, 34, FontWeight.Bold),
        titleMedium = style(22, 30, FontWeight.Bold),
        titleSmall = style(20, 28, FontWeight.Bold),
        bodyLarge = style(22, 32, FontWeight.Normal),
        bodyMedium = style(20, 30, FontWeight.Normal),
        bodySmall = style(20, 28, FontWeight.Normal),
        labelLarge = style(22, 28, FontWeight.Bold, 0.2),
        labelMedium = style(20, 26, FontWeight.Bold, 0.2),
        labelSmall = style(18, 24, FontWeight.Bold, 0.3),
    )

val SpeakUpShapes =
    Shapes(
        extraSmall = RoundedCornerShape(8.dp),
        small = RoundedCornerShape(12.dp),
        medium = RoundedCornerShape(20.dp),
        large = RoundedCornerShape(28.dp),
        extraLarge = RoundedCornerShape(36.dp),
    )

val SpeakUpColorScheme =
    darkColorScheme(
        primary = SpeakUpColors.SignalYellow,
        onPrimary = SpeakUpColors.OnAccent,
        primaryContainer = SpeakUpColors.SignalYellow,
        onPrimaryContainer = SpeakUpColors.OnAccent,
        secondary = SpeakUpColors.ListenCyan,
        onSecondary = SpeakUpColors.OnAccent,
        secondaryContainer = SpeakUpColors.Dusk,
        onSecondaryContainer = SpeakUpColors.Paper,
        tertiary = SpeakUpColors.VoiceCoral,
        onTertiary = SpeakUpColors.OnAccent,
        tertiaryContainer = SpeakUpColors.Dusk,
        onTertiaryContainer = SpeakUpColors.Paper,
        background = SpeakUpColors.Night,
        onBackground = SpeakUpColors.Paper,
        surface = SpeakUpColors.Night,
        onSurface = SpeakUpColors.Paper,
        surfaceVariant = SpeakUpColors.Dusk,
        onSurfaceVariant = SpeakUpColors.PaperMuted,
        surfaceTint = SpeakUpColors.Night,
        surfaceContainerLowest = SpeakUpColors.Night,
        surfaceContainerLow = SpeakUpColors.Dusk,
        surfaceContainer = SpeakUpColors.Dusk,
        surfaceContainerHigh = SpeakUpColors.Dusk,
        surfaceContainerHighest = SpeakUpColors.Dusk,
        inverseSurface = SpeakUpColors.Paper,
        inverseOnSurface = SpeakUpColors.Night,
        inversePrimary = SpeakUpColors.Night,
        error = SpeakUpColors.VoiceCoral,
        onError = SpeakUpColors.OnAccent,
        errorContainer = SpeakUpColors.Dusk,
        onErrorContainer = SpeakUpColors.Paper,
        outline = SpeakUpColors.PaperMuted,
        outlineVariant = SpeakUpColors.DuskLine,
        scrim = SpeakUpColors.Night,
    )

/** Wrap every SpeakUp screen in this (MainActivity does). */
@Composable
fun SpeakUpTheme(content: @Composable () -> Unit) {
  MaterialTheme(
      colorScheme = SpeakUpColorScheme,
      typography = SpeakUpTypography,
      shapes = SpeakUpShapes,
      content = content,
  )
}

/**
 * The bench's original colour names, kept so older call sites compile. Each now points at a
 * SpeakUp token; new code should use [SpeakUpColors] or MaterialTheme.colorScheme.
 */
object AppColor {
  /** Was "active" green: listening/active is Listen Cyan. */
  val Green = SpeakUpColors.ListenCyan
  val Red = SpeakUpColors.VoiceCoral
  val Yellow = SpeakUpColors.SignalYellow
  /** Was the primary button colour. */
  val DeepBlue = SpeakUpColors.SignalYellow
  val DestructiveBackground = SpeakUpColors.VoiceCoral
  val DestructiveForeground = SpeakUpColors.OnAccent
  val RecordAccent = SpeakUpColors.VoiceCoral
  val UpdateRequiredBackground = SpeakUpColors.Dusk
  val UpdateRequiredForeground = SpeakUpColors.Paper
}
