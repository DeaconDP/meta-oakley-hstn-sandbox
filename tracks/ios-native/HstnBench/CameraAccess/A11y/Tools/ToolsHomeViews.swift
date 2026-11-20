/*
 * ToolsHomeViews - the tools home on the main screen: the seven tools as big rows, the open tool's
 * header with Close, and the small optional glasses row (notes/tools-home-ios.md)
 *
 * Phone first: every tool works with the iPhone's camera. Each row is one VoiceOver button named
 * after the tool, with its one-line job as the hint. Rows are at least 60 pt and the text wraps at
 * every Dynamic Type size; at accessibility sizes the coin sits above the words (PathTileLabel).
 * Styled from A11y/Theme.
 */

import SwiftUI

extension ToolID {
  /// The coin's colour on the tools home, so the rows are told apart by more than their place.
  var tone: Tone {
    switch self {
    case .read: .neutral
    case .mail: .blue
    case .labels: .green
    case .watch: .purple
    case .ask: .orange
    case .light: .yellow
    case .reminders: .red
    }
  }

  /// The spoken command that opens it, for the "Say ..." line.
  var sayCommand: VoiceCommand { self == .read ? .read : VoiceCommand.open(self) }

  /// UI test identifier of its row. Read text keeps the old Read button's.
  var homeIdentifier: String { self == .read ? "read_button" : "tool_open_\(rawValue)" }
}

/// The seven tools. Read text comes first and reads at once, as the one Read button did.
struct ToolsHome: View {
  var openTool: (ToolID) -> Void
  /// "Status" in the VoiceOver actions on the Read text row.
  var status: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tools")
        .font(.rounded(.title3, weight: .heavy))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("tools_home_title")
      // In the user's order, without hidden tools ("put labels first", Customise/Words).
      ForEach(WordsArea.shared.visibleTools) { tool in
        row(tool)
      }
    }
  }

  @ViewBuilder
  private func row(_ tool: ToolID) -> some View {
    let isRead = tool == .read
    Button {
      openTool(tool)
    } label: {
      PathTileLabel(
        icon: tool.systemImage, title: tool.title, value: tool.summary, coin: isRead ? .neutral : tool.tone, isBig: isRead,
        say: tool.sayCommand)
    }
    .buttonStyle(isRead ? ChunkyButtonStyle(tone: .yellow, lipHeight: 8, radius: 30) : .a11ySecondary)
    .accessibilityLabel(tool.title)
    .accessibilityHint(isRead ? "Reads the text in front of you aloud, word for word." : "Opens it. \(tool.summary)")
    .accessibilityIdentifier(tool.homeIdentifier)
    .modifier(ReadQuickActions(enabled: isRead, status: status))
  }
}

/// The reader's VoiceOver actions on the Read text row, as the old Read button had.
private struct ReadQuickActions: ViewModifier {
  let enabled: Bool
  let status: () -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.cameraQuickActions(status: status)
    } else {
      content
    }
  }
}

/// The open tool's name, and Close back to the tools.
struct ToolPanelHeader: View {
  let tool: ToolID
  let isLargeText: Bool
  let close: () -> Void

  @ScaledMetric(relativeTo: .title3) private var coinSize: CGFloat = 48

  var body: some View {
    let layout =
      isLargeText
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    layout {
      HStack(spacing: 12) {
        TileCoin(icon: tool.systemImage, tone: tool.tone, size: min(coinSize, 80))
        Text(tool.title)
          .font(.rounded(.title2, weight: .heavy))
          .foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("tool_title")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: close) {
        Label("Close", systemImage: "xmark")
          .font(.rounded(.headline, weight: .heavy))
          .frame(maxWidth: isLargeText ? .infinity : nil)
      }
      .buttonStyle(ChunkyButtonStyle(tone: .neutral, lipHeight: 5))
      .fixedSize(horizontal: !isLargeText, vertical: false)
      .accessibilityLabel("Close \(tool.title)")
      .accessibilityHint("Back to the tools. You can also say close.")
      .accessibilityIdentifier("tool_close_button")
    }
  }
}

/// Meta glasses, as an optional extra: one small row. Not in the App Store build.
struct GlassesRow: View {
  var link: any GlassesLink
  var connected: Bool
  var connect: () -> Void

  private var state: String {
    if !link.isRegistered { return "Optional. Not linked." }
    return connected ? "Linked and connected." : "Linked. Not connected now."
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "eyeglasses")
        .font(.rounded(.title3, weight: .bold))
        .foregroundStyle(Theme.inkSoft)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Meta glasses")
          .font(.rounded(.headline, weight: .heavy))
          .foregroundStyle(Theme.ink)
        Text(state)
          .font(.rounded(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("glasses_row")
      if !link.isRegistered {
        Button("Connect", action: connect)
          .buttonStyle(.a11ySecondary)
          .fixedSize()
          .disabled(link.isConnecting)
          .accessibilityLabel("Connect glasses")
          .accessibilityHint("Optional. Opens the Meta AI app to link your glasses, then come back.")
          .accessibilityIdentifier("glasses_row_connect_button")
      }
    }
    .themeCard(padding: 12)
  }
}
