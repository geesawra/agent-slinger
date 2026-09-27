import SwiftUI

struct ChatComposerBar: View {
  @Binding var draft: String
  @Binding var images: [RemoteDraftImage]
  let isSending: Bool
  let isConnected: Bool
  let error: String?
  var focus: Binding<Bool>
  var send: (String, [RemoteDraftImage]) -> Void
  var clearError: () -> Void
  var contextUsage: RemoteContextUsage? = nil
  var isLoadingContextUsage = false
  var onShowContextUsage: (() -> Void)? = nil
  var isAgentRunning = false
  var isStopPending = false
  var isStopEnabled = false
  var stopButtonIdentifier = "agent-stop"
  var onStop: (() -> Void)? = nil
  var imageImportIdentity = "composer"
  var refocusAfterSend = true

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showsExpandedComposer = false
  @State private var expandedShouldRestoreFocus = false
  @State private var pendingExpandedSend: (String, [RemoteDraftImage])?
  @State private var pendingImageOperations = 0
  @State private var imagePreparationError: String?
  @State private var imageImportGeneration = 0
  @State private var imagePreparationTasks: [UUID: Task<Void, Never>] = [:]

  var body: some View {
    controls
      .sheet(isPresented: $showsExpandedComposer, onDismiss: expandedComposerDidDismiss) {
        ExpandedComposerView(
          draft: $draft,
          images: $images,
          canSend: canSend,
          pendingImageOperations: pendingImageOperations,
          imageError: imagePreparationError,
          imageImportIdentity: imageImportIdentity,
          onDismiss: { showsExpandedComposer = false },
          onImageOperationStarted: beginImageOperation,
          onImageLoaded: { data, fileName, generation in
            prepareImage(data, fileName: fileName, generation: generation)
          },
          onImageOperationFailed: { message, generation in
            finishImageOperation(message, generation: generation)
          },
          onRemoveImage: removeImage,
          onSend: {
            pendingExpandedSend = (draft, images)
            showsExpandedComposer = false
          }
        )
      }
      .onChange(of: draft) { _, _ in clearError() }
      .onChange(of: imageImportIdentity) { _, _ in invalidateImageOperations() }
      .onChange(of: isConnected) { _, connected in
        if !connected { invalidateImageOperations() }
      }
      .onDisappear {
        Task { @MainActor in
          await Task.yield()
          invalidateImageOperations()
        }
      }
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

      messageField
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
            imagePicker
            expandControl
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
      } else {
        HStack(spacing: 8) {
          contextUsageControl
          imagePicker
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

  private var remainingImageCount: Int {
    max(0, RemoteImageLimits.maximumCount - images.count - pendingImageOperations)
  }

  private var imagePicker: some View {
    ComposerImagePickerButton(
      remainingCount: remainingImageCount,
      imageImportIdentity: imageImportIdentity,
      onOperationStarted: beginImageOperation,
      onImageLoaded: { data, fileName, generation in
        prepareImage(data, fileName: fileName, generation: generation)
      },
      onOperationFailed: { message, generation in
        finishImageOperation(message, generation: generation)
      }
    )
  }

  private var imageDraftStrip: some View {
    ComposerImageDraftStrip(
      images: $images,
      isPreparing: pendingImageOperations > 0,
      error: imagePreparationError,
      onRemove: removeImage
    )
  }

  private func beginImageOperation() -> Int {
    pendingImageOperations += 1
    imagePreparationError = nil
    return imageImportGeneration
  }

  private func prepareImage(_ data: Data, fileName: String?, generation: Int) {
    guard generation == imageImportGeneration else { return }
    let taskID = UUID()
    imagePreparationTasks[taskID] = Task { @MainActor in
      defer { imagePreparationTasks[taskID] = nil }
      do {
        guard data.count <= RemoteImageLimits.maximumInputBytes else {
          throw ImageImportServiceError.tooLarge
        }
        let image = try await ImagePreparationService().prepare(data: data, fileName: fileName)
        guard generation == imageImportGeneration else { return }
        guard images.count < RemoteImageLimits.maximumCount else {
          imagePreparationError = "Attach up to six images."
          pendingImageOperations = max(0, pendingImageOperations - 1)
          return
        }
        images.append(image)
        imagePreparationError = nil
      } catch {
        guard generation == imageImportGeneration else { return }
        imagePreparationError = error.localizedDescription
      }
      if generation == imageImportGeneration {
        pendingImageOperations = max(0, pendingImageOperations - 1)
      }
    }
  }

  private func finishImageOperation(_ message: String, generation: Int) {
    guard generation == imageImportGeneration else { return }
    imagePreparationError = message
    pendingImageOperations = max(0, pendingImageOperations - 1)
  }

  private func invalidateImageOperations() {
    imageImportGeneration += 1
    for task in imagePreparationTasks.values {
      task.cancel()
    }
    imagePreparationTasks.removeAll()
    pendingImageOperations = 0
  }

  private func removeImage(_ id: String) {
    images.removeAll { $0.id == id }
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
    let input = VStack(spacing: 0) {
      imageDraftStrip

      HStack(alignment: .bottom, spacing: 4) {
        compactEditor
        sendControl
      }
      .padding(.leading, 8)
      .padding(.vertical, 4)
      .padding(.trailing, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat-composer-surface")

    if #available(iOS 26.0, *) {
      input.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    } else {
      input.background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
  }

  private var compactEditor: some View {
    ZStack(alignment: .topLeading) {
      NativeImagePasteTextView(
        text: $draft,
        isFocused: focus,
        accessibilityLabel: "Message agent",
        accessibilityIdentifier: "chat-composer",
        isExpanded: false,
        canSubmit: canSend,
        onSubmit: sendDraft,
        onPasteImage: { data, generation in
          prepareImage(data, fileName: nil, generation: generation)
        },
        onPasteStarted: beginImageOperation,
        onPasteFailed: { message, generation in
          finishImageOperation(message, generation: generation)
        }
      )
      .frame(minHeight: 48)

      if draft.isEmpty {
        Text("Message agent…")
          .font(.body)
          .foregroundStyle(Color.secondary)
          .padding(.horizontal, 14)
          .padding(.top, 12)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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
    .controlSize(.small)
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
    isConnected && !isSending && pendingImageOperations == 0
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
  }

  private func sendDraft() {
    guard canSend else { return }
    send(draft, images)
    focus.wrappedValue = refocusAfterSend
  }

  private func openExpandedComposer() {
    expandedShouldRestoreFocus = focus.wrappedValue
    focus.wrappedValue = false
    showsExpandedComposer = true
  }

  private func expandedComposerDidDismiss() {
    if let pendingExpandedSend {
      self.pendingExpandedSend = nil
      guard canSend else { return }
      send(pendingExpandedSend.0, pendingExpandedSend.1)
      focus.wrappedValue = refocusAfterSend
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
  @Binding var images: [RemoteDraftImage]
  let canSend: Bool
  let pendingImageOperations: Int
  let imageError: String?
  let imageImportIdentity: String
  let onDismiss: () -> Void
  let onImageOperationStarted: () -> Int
  let onImageLoaded: (Data, String?, Int) -> Void
  let onImageOperationFailed: (String, Int) -> Void
  let onRemoveImage: (String) -> Void
  let onSend: () -> Void

  @State private var editorFocused = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        ComposerImagePickerButton(
          remainingCount: max(
            0, RemoteImageLimits.maximumCount - images.count - pendingImageOperations),
          imageImportIdentity: imageImportIdentity,
          onOperationStarted: onImageOperationStarted,
          onImageLoaded: onImageLoaded,
          onOperationFailed: onImageOperationFailed
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        editor
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
      }
      .onAppear {
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
    VStack(spacing: 8) {
      ComposerImageDraftStrip(
        images: $images,
        isPreparing: pendingImageOperations > 0,
        error: imageError,
        onRemove: onRemoveImage
      )

      HStack(alignment: .bottom, spacing: 4) {
        expandedEditor
        sendButton
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("expanded-composer-surface")
  }

  private var expandedEditor: some View {
    ZStack(alignment: .topLeading) {
      NativeImagePasteTextView(
        text: $draft,
        isFocused: $editorFocused,
        accessibilityLabel: "Message agent",
        accessibilityIdentifier: "expanded-chat-composer",
        isExpanded: true,
        canSubmit: canSend,
        onSubmit: onSend,
        onPasteImage: { data, generation in onImageLoaded(data, nil, generation) },
        onPasteStarted: onImageOperationStarted,
        onPasteFailed: onImageOperationFailed
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if draft.isEmpty {
        Text("Write a message. Markdown is supported.")
          .foregroundStyle(Color.secondary)
          .padding(.leading, 14)
          .padding(.top, 10)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var sendButton: some View {
    let button = Button(action: onSend) {
      Image(systemName: "arrow.up")
        .font(.system(size: 18, weight: .semibold))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .disabled(!canSend)
    .controlSize(.small)
    .buttonBorderShape(.circle)
    .accessibilityLabel("Send message")
    .accessibilityIdentifier("expanded-send-message")
    if #available(iOS 26.0, *) {
      button.buttonStyle(.glassProminent)
    } else {
      button.buttonStyle(.borderedProminent)
    }
  }
}
