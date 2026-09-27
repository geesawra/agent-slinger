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
  @State private var isCompactPreview = false
  @State private var showsExpandedComposer = false
  @State private var expandedStartsInPreview = false
  @State private var expandedShouldRestoreFocus = false
  @State private var compactPreviewShouldRestoreFocus = false
  @State private var sendAfterExpandedDismiss = false

  var body: some View {
    controls
      .sheet(isPresented: $showsExpandedComposer, onDismiss: expandedComposerDidDismiss) {
        ExpandedComposerView(
          draft: $draft,
          canSend: canSend,
          startsInPreview: expandedStartsInPreview,
          onDismiss: { showsExpandedComposer = false },
          onSend: {
            sendAfterExpandedDismiss = true
            showsExpandedComposer = false
          }
        )
      }
      .onChange(of: draft) { _, _ in clearError() }
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
        messageInput
        sendControl
      }
    }
  }

  @ViewBuilder
  private var compactModeControl: some View {
    let button = Button(action: toggleCompactMode) {
      Image(systemName: isCompactPreview ? "square.and.pencil" : "eye")
        .font(.system(size: 16, weight: .medium))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(isCompactPreview ? "Write draft" : "Preview draft")
    .accessibilityValue(isCompactPreview ? "Preview" : "Write")
    .accessibilityIdentifier("chat-composer-mode")

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(Color(uiColor: .label))
    } else {
      button.buttonStyle(.bordered).buttonBorderShape(.circle)
    }
  }

  private var messageInput: some View {
    Group {
      if isCompactPreview {
        compactPreview
      } else {
        messageField
      }
    }
  }

  @ViewBuilder
  private var expandControl: some View {
    let button = Button(action: openExpandedComposer) {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.primary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Expand message composer")
    .accessibilityIdentifier("chat-composer-expand")

    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(Color(uiColor: .label))
    } else {
      button.buttonStyle(.bordered).buttonBorderShape(.circle)
    }
  }

  private var compactPreview: some View {
    ScrollView {
      Group {
        if draft.isEmpty {
          Text("Nothing to preview yet")
            .foregroundStyle(Color.secondary)
        } else {
          MessageMarkdownView(source: draft)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .frame(minHeight: 48, maxHeight: dynamicTypeSize.isAccessibilitySize ? 220 : 144)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat-composer-preview")
  }

  private var accessoryRow: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(spacing: 4) {
          if hasAgentStatusControls {
            HStack(spacing: 8) {
              contextUsageControl
              Spacer(minLength: 0)
              stopControl
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }

          HStack(spacing: 8) {
            compactModeControl
            expandControl
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
      } else {
        HStack(spacing: 8) {
          contextUsageControl
          compactModeControl
          expandControl
          Spacer(minLength: 0)
          stopControl
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat-composer-accessory")
  }

  private var hasAgentStatusControls: Bool {
    onShowContextUsage != nil || ((isAgentRunning || isStopPending) && onStop != nil)
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

  private func toggleCompactMode() {
    if isCompactPreview {
      isCompactPreview = false
      if compactPreviewShouldRestoreFocus {
        Task { @MainActor in
          await Task.yield()
          focus.wrappedValue = true
        }
      }
    } else {
      compactPreviewShouldRestoreFocus = focus.wrappedValue
      focus.wrappedValue = false
      isCompactPreview = true
    }
  }

  private func openExpandedComposer() {
    expandedStartsInPreview = isCompactPreview
    expandedShouldRestoreFocus = !isCompactPreview && focus.wrappedValue
    focus.wrappedValue = false
    showsExpandedComposer = true
  }

  private func expandedComposerDidDismiss() {
    if sendAfterExpandedDismiss {
      sendAfterExpandedDismiss = false
      sendDraft()
    } else if expandedShouldRestoreFocus {
      Task { @MainActor in
        await Task.yield()
        focus.wrappedValue = true
      }
    }
  }
}

private struct ExpandedComposerView: View {
  @Binding var draft: String
  let canSend: Bool
  let startsInPreview: Bool
  let onDismiss: () -> Void
  let onSend: () -> Void

  @FocusState private var editorFocused: Bool
  @State private var isPreview = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Picker("Message view", selection: $isPreview) {
          Text("Write").tag(false)
          Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("expanded-composer-mode")

        if isPreview {
          preview
        } else {
          editor
        }
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .navigationTitle("Compose message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done", action: onDismiss)
            .accessibilityIdentifier("expanded-composer-done")
        }
        ToolbarItem(placement: .topBarTrailing) {
          sendButton
        }
      }
      .onChange(of: isPreview) { _, previewing in
        guard !previewing else {
          editorFocused = false
          return
        }
        Task { @MainActor in
          await Task.yield()
          editorFocused = true
        }
      }
      .onAppear {
        isPreview = startsInPreview
        guard !startsInPreview else { return }
        Task { @MainActor in
          await Task.yield()
          editorFocused = true
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  private var editor: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $draft)
        .focused($editorFocused)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Message agent")
        .accessibilityIdentifier("expanded-chat-composer")

      if draft.isEmpty {
        Text("Write a message. Markdown is supported.")
          .foregroundStyle(Color.secondary)
          .padding(.leading, 5)
          .padding(.top, 8)
          .accessibilityHidden(true)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  private var preview: some View {
    ScrollView {
      Group {
        if draft.isEmpty {
          Text("Nothing to preview yet")
            .foregroundStyle(Color.secondary)
        } else {
          MessageMarkdownView(source: draft)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    .accessibilityIdentifier("expanded-composer-preview")
  }

  @ViewBuilder
  private var sendButton: some View {
    let button = Button("Send", action: onSend)
      .disabled(!canSend)
      .accessibilityIdentifier("expanded-send-message")
    if #available(iOS 26.0, *) {
      button.buttonStyle(.glassProminent)
    } else {
      button.buttonStyle(.borderedProminent)
    }
  }
}
