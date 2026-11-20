/*
 * LightGrammar - what the user says inside the light and colour tool
 *
 * Port of Android's tools/light/LightGrammar.kt. Commands: "how bright is it", "where's the light",
 * "is it blinking", "again" (measure again), "colour mode" / "what colour is this", "light mode",
 * and "tone off" / "tone on" ("quiet" and "pause" too: the tool gets them before nothing else would
 * stop the tone, but see notes/labels-and-light-ios.md for how they meet the global grammar).
 * Whole-phrase matches after LabelsPhrases.normalize (apostrophes closed up: "whats", "wheres").
 * The tool's opening phrases are ToolID.light.openPhrases (SpeakUpTool.swift).
 */

import Foundation

enum LightCommand: Equatable, Sendable {
  /// Speak the brightness level (a camera estimate).
  case howBright
  /// Which way the light is ("brighter to your left").
  case whereBright
  /// Is something in view blinking?
  case isBlinking
  /// Measure again: the colour in colour mode, the level in light mode.
  case again
  /// Switch to colour mode and name the colour now.
  case colour
  /// Switch to the light probe.
  case light
  case toneOff
  case toneOn
}

enum LightGrammar {
  private static let colour = LabelsRegex(
    "what colou?r is (?:this|it|that|the .+)|whats the colou?r(?: of (?:this|that|it|the .+))?|what is the colou?r(?: of (?:this|that|it|the .+))?|"
      + "which colou?r is (?:this|it|that)|what colou?r|(?:open |start |switch to )?(?:the )?colou?r (?:mode|detector|reader)")

  private static let light = LabelsRegex(
    "(?:open |start |switch to )?(?:the )?light (?:detector|probe|meter|sensor|mode)|"
      + "is (?:the |a )?lights? on|are (?:the )?lights on|is it (?:light|dark)(?: in here)?|"
      + "where(?:s| is) the light|is there (?:a )?light(?: on)?|(?:open )?light and colou?r")

  private static let howBright = LabelsRegex(
    "how (?:bright|light|dark|sunny) is it(?: in here| here| now)?|how bright|how light|how dark|"
      + "(?:whats the |what is the )?(?:light|brightness) level|brightness|is (?:the |a |that )?lights? on|"
      + "are (?:the )?lights on|is it (?:light|dark|bright)(?: in here)?|is it on|"
      + "are the curtains (?:open|closed|shut)|is the (?:screen|lamp|torch) on")
  private static let whereBright = LabelsRegex(
    "where(?:s| is) the (?:light|window|lamp|brightest(?: bit| part)?)|which way is (?:the )?(?:light|window)|where(?:s| is) it brightest")
  private static let blink = LabelsRegex(
    "is (?:it|that|the light|something|anything) (?:blinking|flashing|flickering)|(?:any(?:thing)? )?blinking|flashing|is it on or off")
  private static let again = LabelsRegex(
    "again|(?:check|measure|look|try|do it|test) again|once more|what about (?:now|this|this one|that)|and (?:now|this|this one)|check (?:it|this)|next one")
  private static let colourCommand = LabelsRegex("colou?rs?|(?:check|name|tell me) the colou?r|colou?r please|colou?r check")
  private static let lightCommand = LabelsRegex(
    "(?:back to |go to )?(?:the )?(?:light|tone|probe)(?: mode)?|light probe|light detector")
  private static let toneOff = LabelsRegex(
    "(?:turn )?(?:the )?tone off|(?:turn )?off the tone|stop the tone|mute|silence|no tone|quiet the tone|quiet|pause")
  private static let toneOn = LabelsRegex(
    "(?:turn )?(?:the )?tone (?:on|back on)|(?:turn )?on the tone|unmute|start the tone|tone please|carry on|resume")

  /// A command inside the tool, or nil. Takes the raw transcript.
  static func parse(_ transcript: String) -> LightCommand? {
    parseNormalized(LabelsPhrases.normalize(transcript))
  }

  static func parseNormalized(_ t: String) -> LightCommand? {
    if t.isEmpty { return nil }
    if toneOff.matches(t) { return .toneOff }
    if toneOn.matches(t) { return .toneOn }
    if again.matches(t) { return .again }
    if colour.matches(t) || colourCommand.matches(t) { return .colour }
    if whereBright.matches(t) { return .whereBright }
    if blink.matches(t) { return .isBlinking }
    if howBright.matches(t) { return .howBright }
    if lightCommand.matches(t) || light.matches(t) { return .light }
    return nil
  }
}
