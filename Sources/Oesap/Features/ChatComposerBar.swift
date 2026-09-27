import SwiftUI

struct ChatComposerBar: View {
  @Binding var draft: String
  let isSending: Bool
  let isConnected: Bool
  let error: String?
  var focus: FocusState<Bool>.Binding
  var send: (String) -> Void
  var clearError: () -> Void
  var contextUsage: RemoteContextUsage? = nil
  var isLoadingContextUsage = false
  var onShowContextUsage: (() -> Void)? = nil
  var isAgentRunning = false
  var isStopPending = false
  var isStopEnabled = false
  var stopButtonIdentifier = "agent-stop"
  var onStop: (() -> Void)? = nil
  var refocusAfterSend = true

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    controls
  }

  @ViewBuilder
  private var controls: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 4) {
        controlContents
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    } else {
      controlContents
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
  }

  private var controlContents: some View {
    VStack(spacing: 8) {
      if let error {
        errorRow(error)
      }

      accessoryRow

      HStack(alignment: .bottom, spacing: 8) {
        messageField
        sendControl
      }
    }
  }

  @ViewBuilder
  private var accessoryRow: some View {
    if onShowContextUsage != nil || ((isAgentRunning || isStopPending) && onStop != nil) {
      HStack(spacing: 8) {
        contextUsageControl
        Spacer(minLength: 0)
        stopControl
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("chat-composer-accessory")
    }
  }

  @ViewBuilder
  private var contextUsageControl: some View {
    if let onShowContextUsage {
      if #available(iOS 26.0, *) {
        makeContextUsageButton(action: onShowContextUsage, style: .glass)
      } else {
        makeContextUsageButton(action: onShowContextUsage, style: .bordered)
      }
    }
  }

  private func makeContextUsageButton<Style: PrimitiveButtonStyle>(
    action: @escaping () -> Void, style: Style
  ) -> some View {
    Button(action: action) {
      ContextUsageIndicator(usage: contextUsage, isLoading: isLoadingContextUsage)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(style)
    .tint(Color(uiColor: .label))
    .accessibilityIdentifier("context-usage-button")
  }

  @ViewBuilder
  private var stopControl: some View {
    if let onStop, isAgentRunning || isStopPending {
      if #available(iOS 26.0, *) {
        makeStopButton(action: onStop, style: .glass)
      } else {
        makeStopButton(action: onStop, style: .bordered)
      }
    }
  }

  private func makeStopButton<Style: PrimitiveButtonStyle>(
    action: @escaping () -> Void, style: Style
  )
    -> some View
  {
    Button(action: action) {
      Group {
        if isStopPending {
          ProgressView()
            .tint(Color.secondary)
        } else if dynamicTypeSize.isAccessibilitySize {
          Image(systemName: "square.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary)
        } else {
          Label("Stop", systemImage: "square.fill")
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .foregroundStyle(Color.primary)
        }
      }
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      .foregroundStyle(Color.primary)
    }
    .buttonStyle(style)
    .tint(Color(uiColor: .label))
    .disabled(!isStopEnabled || isStopPending)
    .accessibilityLabel(isStopPending ? "Stopping agent" : "Stop agent")
    .accessibilityIdentifier(stopButtonIdentifier)
  }

  @ViewBuilder
  private var messageField: some View {
    let field = TextField("Message agent…", text: $draft, axis: .vertical)
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1...2 : 1...5)
      .submitLabel(.send)
      .focused(focus)
      .accessibilityLabel("Message agent")
      .accessibilityIdentifier("chat-composer")
      .onSubmit(sendDraft)
      .onChange(of: draft) { _, _ in clearError() }
      .textFieldStyle(.plain)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(minHeight: 48, alignment: .leading)

    if #available(iOS 26.0, *) {
      field.glassEffect(
        .regular,
        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    } else {
      field.background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }

  @ViewBuilder
  private var sendControl: some View {
    if #available(iOS 26.0, *) {
      makeSendButton(style: .glassProminent)
    } else {
      makeSendButton(style: .borderedProminent)
    }
  }

  private func makeSendButton<Style: PrimitiveButtonStyle>(style: Style) -> some View {
    Button(action: sendDraft) {
      Group {
        if isSending {
          ProgressView()
        } else {
          Image(systemName: "arrow.up")
            .font(.system(size: 18, weight: .semibold))
        }
      }
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(style)
    .buttonBorderShape(.circle)
    .disabled(!canSend)
    .accessibilityLabel(isSending ? "Sending message" : "Send message")
    .accessibilityIdentifier("send-message")
  }

  @ViewBuilder
  private func errorRow(_ error: String) -> some View {
    let row = HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(error)
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      errorDismissControl
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

    if #available(iOS 26.0, *) {
      row
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    } else {
      row
        .padding(.horizontal, 8)
    }
  }

  @ViewBuilder
  private var errorDismissControl: some View {
    if #available(iOS 26.0, *) {
      makeErrorDismissButton(style: .glass)
    } else {
      makeErrorDismissButton(style: .plain)
    }
  }

  private func makeErrorDismissButton<Style: PrimitiveButtonStyle>(style: Style) -> some View {
    Button(action: clearError) {
      Image(systemName: "xmark")
        .foregroundStyle(Color.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(style)
    .tint(Color(uiColor: .secondaryLabel))
    .accessibilityLabel("Dismiss message error")
  }

  private var canSend: Bool {
    isConnected && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sendDraft() {
    guard canSend else { return }
    send(draft)
    focus.wrappedValue = refocusAfterSend
  }
}
