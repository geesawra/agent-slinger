import SwiftUI

private enum AgentActionSheet: Identifiable {
  case send(threadID: String, text: String, images: [RemoteDraftImage], revision: Int)
  case uncertainSend(threadID: String)

  var id: String {
    switch self {
    case .send(let threadID, _, _, let revision): "send-\(threadID)-\(revision)"
    case .uncertainSend(let threadID): "uncertain-\(threadID)"
    }
  }

  var title: String {
    switch self {
    case .send(_, _, _, _): "Send to running agent?"
    case .uncertainSend(_): "Check the previous send"
    }
  }

  var message: String {
    switch self {
    case .send:
      "Steer when supported. The host may interrupt and restart the turn if steering is unavailable."
    case .uncertainSend:
      "This only clears Oesap’s local resend safeguard. It doesn’t cancel or remove the original message, and the host may still deliver it. Your draft stays here; sending it again could create a duplicate."
    }
  }
}

private enum AgentActionConfirmation: Identifiable {
  case stop(threadID: String, revision: Int)
  case permission(RemotePermission, allow: Bool)

  var id: String {
    switch self {
    case .stop(let threadID, let revision): "stop-\(threadID)-\(revision)"
    case .permission(let permission, let allow): "permission-\(permission.id)-\(allow)"
    }
  }

  var title: String {
    switch self {
    case .stop: "Stop this agent?"
    case .permission(_, let allow): allow ? "Allow this agent request?" : "Deny this agent request?"
    }
  }

  var message: String {
    switch self {
    case .stop: "Stop the current run? Your thread and draft will stay available."
    case .permission(let permission, _):
      [permission.title, permission.detail].compactMap { $0 }.joined(separator: "\n\n")
    }
  }
}

struct ChatView: View {
  @Bindable var model: OesapModel
  let threadID: String
  @State private var showsAgentSettings = false
  @State private var showsSessionInfo = false
  @State private var composerFocused = false
  @State private var viewportHeight: CGFloat = 0
  @State private var isNearBottom = true
  @State private var isUserScrolling = false
  @State private var expandedToolCallIDs: Set<String> = []
  @State private var actionSheet: AgentActionSheet?
  @State private var actionConfirmation: AgentActionConfirmation?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var thread: RemoteThread? { model.threads.first { $0.id == threadID } }

  private var latestThinkingTraceID: String? {
    model.messages.last(where: \.isThinkingTrace)?.id
  }

  private var agentActivityMessage: String? {
    guard model.connectionState == .connected, let thread else { return nil }
    let hasBufferedOutput = model.messages.contains { message in
      message.author == .agent && model.bufferedAgentMessageIDs.contains(message.id)
    }
    if thread.state == .running {
      return hasBufferedOutput || latestThinkingTraceID != nil ? nil : "Thinking…"
    }
    if model.agentSendFeedback(for: threadID)?.phase == .accepted {
      return "Waiting for the agent…"
    }
    if thread.state == .initializing { return "Starting agent…" }
    return nil
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if model.timelineHasOlder {
              Button {
                Task { await model.loadOlderMessages(threadID: threadID) }
              } label: {
                HStack {
                  if model.loadingOlderMessages { ProgressView().padding(.trailing, 6) }
                  Text("Load earlier messages")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .disabled(model.loadingOlderMessages)
              .accessibilityIdentifier("load-earlier-messages")
            }

            if model.connectionState != .connected {
              ConnectionBanner(model: model)
            }

            if model.connectionState == .connected && !model.agentControlAvailable(for: threadID) {
              InlineNotice(
                text:
                  "This host has no stable identity. Sending messages and stopping agents are unavailable.",
                symbol: "exclamationmark.triangle.fill", tint: .orange)
            }

            if let thread,
              thread.requiresAttention || thread.state == .waiting || thread.state == .failed
            {
              InlineNotice(
                text: thread.attentionReason
                  ?? (thread.state == .failed
                    ? "This agent run failed." : "This agent needs your attention."),
                symbol: thread.state == .failed
                  ? "exclamationmark.triangle.fill" : "hand.raised.fill",
                tint: .orange
              )
            }

            if let permission = model.permissions.first(where: { $0.agentID == threadID }) {
              PermissionCard(
                permission: permission,
                isResponding: model.answeringPermissionID == permission.id,
                onChoose: { allow in
                  actionConfirmation = .permission(permission, allow: allow)
                }
              )
            }

            if let error = model.permissionError {
              InlineNotice(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }

            if model.historyMayBeIncomplete {
              InlineNotice(
                text:
                  "This timeline may have a gap. Refresh it after reconnecting to load the latest history.",
                symbol: "arrow.clockwise",
                tint: .orange
              )
            }

            if let error = model.timelineError {
              VStack(alignment: .leading, spacing: 8) {
                InlineNotice(text: error, symbol: "wifi.exclamationmark", tint: .red)
                Button("Reconnect") { Task { await model.reconnect() } }
                  .buttonStyle(.bordered)
                  .disabled(model.connectionState.isBusy)
              }
            }

            if model.loadingHistory && model.messages.isEmpty {
              ProgressView("Loading conversation…")
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if model.messages.isEmpty && model.timelineError == nil {
              ContentUnavailableView(
                "No messages yet",
                systemImage: "text.bubble",
                description: Text("Send a message to start this agent thread.")
              )
              .frame(maxWidth: .infinity, minHeight: 150)
            }

            ForEach(model.messages) { message in
              if let toolCall = message.toolCall {
                ToolCallCard(
                  call: toolCall,
                  rowID: message.id,
                  isExpanded: Binding(
                    get: { expandedToolCallIDs.contains(message.id) },
                    set: { expanded in
                      if expanded {
                        expandedToolCallIDs.insert(message.id)
                      } else {
                        expandedToolCallIDs.remove(message.id)
                      }
                    }
                  )
                )
                .id(message.id)
              } else if message.isThinkingTrace {
                if message.id == latestThinkingTraceID {
                  ThinkingTraceView(
                    message: message,
                    isUpdating: model.connectionState == .connected && thread?.state == .running
                  )
                  .id(message.id)
                }
              } else {
                MessageBubble(
                  message: message,
                  threadID: threadID,
                  timelineGeneration: model.timelineGeneration,
                  buffersAgentOutput: model.bufferedAgentMessageIDs.contains(message.id),
                  loadRemoteImage: { source, imageThreadID in
                    try await model.loadRemoteImage(source: source, threadID: imageThreadID)
                  }
                )
                .equatable()
                .id(message.id)
              }
            }

            if let activity = agentActivityMessage {
              AgentActivityIndicator(message: activity)
                .id("agent-activity-\(threadID)")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if model.loadingHistory && !model.messages.isEmpty {
              ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            if let feedback = model.agentSendFeedback(for: threadID), feedback.phase != .accepted {
              AgentActionStatus(
                feedback: feedback,
                identifier: "agent-message-status-\(threadID)",
                canRetry: model.canRetryAgentMessage(for: threadID),
                requiresReview: model.requiresAgentMessageReview(for: threadID),
                isConnected: model.connectionState == .connected,
                onRetry: { Task { _ = await model.retryAgentMessage(threadID: threadID) } },
                onReview: {
                  composerFocused = false
                  actionSheet = .uncertainSend(threadID: threadID)
                },
                onRefresh: nil
              )
              .id("agent-message-status-\(threadID)")
            }
            if let feedback = model.agentStopFeedback(for: threadID) {
              AgentActionStatus(
                feedback: feedback,
                identifier: "agent-action-status-\(threadID)",
                canRetry: false,
                requiresReview: false,
                isConnected: model.connectionState == .connected,
                onRetry: nil,
                onReview: nil,
                onRefresh: feedback.phase == .stopWaiting
                  ? {
                    Task {
                      if let projectID = model.selectedProjectID {
                        await model.refreshThreads(projectID: projectID)
                      }
                    }
                  } : nil
              )
              .id("agent-action-status-\(threadID)")
            }

            Color.clear
              .frame(height: 1)
              .id("timeline-bottom")
          }
          .padding(.horizontal)
          .padding(.top, 12)
          .padding(.bottom, 20)
          .frame(maxWidth: 900)
          .frame(maxWidth: .infinity)
          .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: model.bufferedAgentMessageIDs
          )
          .background {
            // The full stack exists even when the lazy bottom row is offscreen.
            GeometryReader { geometry in
              Color.clear.preference(
                key: ScrollContentFrameKey.self,
                value: geometry.frame(in: .named("timelineScroll")))
            }
          }
        }
        .accessibilityIdentifier("chat-timeline-scroll")
        .modifier(TimelinePerformanceProgress(message: model.messages.last))
        .coordinateSpace(name: "timelineScroll")
        .scrollDismissesKeyboard(.interactively)
        .modifier(
          TimelineScrollTracking(
            isNearBottom: $isNearBottom, isUserScrolling: $isUserScrolling,
            viewportHeight: viewportHeight,
            onContentGrowth: {
              guard expandedToolCallIDs.isEmpty else { return }
              proxy.scrollTo("timeline-bottom", anchor: .bottom)
            })
        )
        .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
        .onChange(of: model.timelineStructureRevision) { _, _ in
          let liveToolCallIDs = Set(model.messages.filter { $0.toolCall != nil }.map(\.id))
          expandedToolCallIDs.formIntersection(liveToolCallIDs)
        }
        .onChange(of: model.agentSendFeedback(for: threadID)) { _, feedback in
          if feedback != nil { proxy.scrollTo("agent-message-status-\(threadID)", anchor: .bottom) }
        }
        .onChange(of: model.agentStopFeedback(for: threadID)) { _, feedback in
          if feedback != nil { proxy.scrollTo("agent-action-status-\(threadID)", anchor: .bottom) }
        }
        .onChange(of: threadID) { _, _ in expandedToolCallIDs.removeAll() }
        .onChange(of: thread?.requiresAttention) { _, requiresAttention in
          guard requiresAttention == true else { return }
          Task { await model.markThreadRead(threadID, reportsFailure: false) }
        }
        .onChange(of: model.selectedThreadID) { _, selectedID in
          if selectedID != threadID {
            actionConfirmation = nil
            actionSheet = nil
          }
        }
        .onChange(of: model.connectionState) { _, state in
          if state != .connected {
            actionConfirmation = nil
            actionSheet = nil
          }
        }
        .onChange(of: model.messages.last) { oldValue, newValue in
          guard let newValue else { return }
          if oldValue == nil {
            // Initial history has no prior reading position, including on the
            // iOS 17 baseline without separate scroll-anchor roles.
            isNearBottom = true
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
            return
          }
          guard isNearBottom, !isUserScrolling, expandedToolCallIDs.isEmpty else { return }
          // Streaming changes must not restart an animation for each token.
          // Animate only a newly inserted row; let native scrolling follow
          // content size changes while the user remains at the bottom.
          if reduceMotion || oldValue?.id == newValue.id {
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo("timeline-bottom", anchor: .bottom)
            }
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if !isNearBottom, !model.messages.isEmpty {
            Button {
              isNearBottom = true
              proxy.scrollTo("timeline-bottom", anchor: .bottom)
            } label: {
              Label("Latest", systemImage: "arrow.down")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Jump to latest message")
            .accessibilityIdentifier("chat-jump-to-latest")
            .padding()
          }
        }
        .composerSafeAreaBar {
          ChatComposerBar(
            draft: Binding(
              get: { model.draft(for: threadID) },
              set: { model.setDraft($0, for: threadID) }
            ),
            images: Binding(
              get: { model.draftImages(for: threadID) },
              set: { _ = model.setDraftImages($0, for: threadID) }
            ),
            isSending: model.isSendingAgentMessage(for: threadID),
            isConnected: model.agentControlAvailable(for: threadID),
            error: nil,
            focus: $composerFocused,
            send: submitThreadMessage,
            clearError: {},
            contextUsage: model.contextUsage(for: threadID),
            isLoadingContextUsage: model.loadingContextUsage,
            onShowContextUsage: {
              composerFocused = false
              showsAgentSettings = true
            },
            isAgentRunning: thread?.state == .running,
            isStopPending: model.isStopRequestPending(threadID),
            isStopEnabled: model.agentControlAvailable(for: threadID)
              && !model.isSendingAgentMessage(for: threadID),
            stopButtonIdentifier: "agent-stop-\(threadID)",
            onStop: {
              actionConfirmation = .stop(
                threadID: threadID,
                revision: model.threadStateRevision(for: threadID))
            },
            imageImportIdentity: "\(threadID)-\(model.timelineGeneration)",
            refocusAfterSend: thread?.state != .running
              && !model.hasUncertainAgentMessage(for: threadID)
          )
        }
        .navigationTitle(thread?.title ?? "Agent thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              composerFocused = false
              showsSessionInfo = true
            } label: {
              Image(systemName: "info.circle")
            }
            .accessibilityLabel("Session info")
            .accessibilityHint("Shows the session status, details, and usage.")
            .accessibilityIdentifier("session-info-button")
          }
        }
        .sheet(isPresented: $showsAgentSettings) {
          AgentSettingsSheet(model: model, threadID: threadID)
        }
        .sheet(isPresented: $showsSessionInfo) {
          SessionInfoSheet(model: model, threadID: threadID)
        }
        .sheet(item: $actionSheet) { action in
          AgentActionSheetView(
            action: action,
            canRetry: model.canRetryAgentMessage(for: threadID),
            isConnected: model.connectionState == .connected,
            onSteer: { confirmedThreadID, text, images, revision in
              actionSheet = nil
              composerFocused = false
              Task {
                _ = await model.send(
                  threadID: confirmedThreadID, text: text, behavior: .steer,
                  expectedStateRevision: revision, selectedDuringActiveTurn: true,
                  images: images)
              }
            },
            onInterrupt: { confirmedThreadID, text, images, revision in
              actionSheet = nil
              composerFocused = false
              Task {
                _ = await model.send(
                  threadID: confirmedThreadID, text: text, behavior: .interrupt,
                  expectedStateRevision: revision, selectedDuringActiveTurn: true,
                  images: images)
              }
            },
            onRetry: { confirmedThreadID in
              actionSheet = nil
              composerFocused = false
              Task { _ = await model.retryAgentMessage(threadID: confirmedThreadID) }
            },
            onClearWarning: { confirmedThreadID in
              model.discardUncertainAgentMessage(threadID: confirmedThreadID)
              actionSheet = nil
              composerFocused = false
            }
          )
          .presentationDetents([.large])
        }
        .task(id: "\(threadID)-\(model.timelineGeneration)") {
          viewportHeight = viewport.size.height
          Task { await model.markThreadRead(threadID, reportsFailure: false) }
          await model.watchTimeline(threadID: threadID)
        }
        .alert(
          actionConfirmation?.title ?? "Agent action",
          isPresented: Binding(
            get: { actionConfirmation != nil },
            set: { if !$0 { actionConfirmation = nil } }
          ),
          presenting: actionConfirmation
        ) { action in
          switch action {
          case .stop(let confirmedThreadID, let revision):
            Button("Stop agent", role: .destructive) {
              actionConfirmation = nil
              Task {
                await model.stopAgent(threadID: confirmedThreadID, expectedStateRevision: revision)
              }
            }
            Button("Cancel", role: .cancel) { actionConfirmation = nil }
          case .permission(let permission, let allow):
            let label =
              allow ? (permission.allowLabel ?? "Allow") : (permission.denyLabel ?? "Deny")
            Button(label, role: allow ? nil : .destructive) {
              actionConfirmation = nil
              Task { await model.answerPermission(permission, allow: allow) }
            }
            Button("Cancel", role: .cancel) { actionConfirmation = nil }
          }
        } message: { action in
          Text(action.message)
        }
      }
    }
  }

  private func submitThreadMessage(_ text: String, images: [RemoteDraftImage]) {
    guard let thread else { return }
    if model.hasUncertainAgentMessage(for: threadID) {
      actionSheet = .uncertainSend(threadID: threadID)
      return
    }
    let revision = model.threadStateRevision(for: threadID)
    if thread.state == .running {
      actionSheet = .send(threadID: threadID, text: text, images: images, revision: revision)
    } else {
      Task {
        _ = await model.send(
          threadID: threadID, text: text, behavior: .interrupt,
          expectedStateRevision: revision, selectedDuringActiveTurn: false,
          images: images)
      }
    }
  }
}

extension View {
  @ViewBuilder
  fileprivate func composerSafeAreaBar<Content: View>(@ViewBuilder content: () -> Content)
    -> some View
  {
    if #available(iOS 26.0, macOS 26.0, *) {
      self
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0, content: content)
    } else {
      safeAreaInset(edge: .bottom, spacing: 0, content: content)
    }
  }
}

private struct AgentActionSheetView: View {
  let action: AgentActionSheet
  let canRetry: Bool
  let isConnected: Bool
  var onSteer: (String, String, [RemoteDraftImage], Int) -> Void
  var onInterrupt: (String, String, [RemoteDraftImage], Int) -> Void
  var onRetry: (String) -> Void
  var onClearWarning: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(action.message)
            .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          switch action {
          case .send(let threadID, let text, let images, let revision):
            Button {
              dismiss()
              onSteer(threadID, text, images, revision)
            } label: {
              Text("Steer when supported")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("agent-send-steer")
            Button(role: .destructive) {
              dismiss()
              onInterrupt(threadID, text, images, revision)
            } label: {
              Text("Interrupt and send")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("agent-send-interrupt")
          case .uncertainSend(let threadID):
            if canRetry {
              Button {
                dismiss()
                onRetry(threadID)
              } label: {
                Text("Retry original")
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .disabled(!isConnected)
              .accessibilityIdentifier("agent-action-retry")
            }
            Button(role: .destructive) {
              dismiss()
              onClearWarning(threadID)
            } label: {
              Text("Clear send warning")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("agent-action-clear-warning")
          }
        }
      }
      .accessibilityIdentifier("agent-action-options")
      .navigationTitle(action.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("agent-action-cancel")
        }
      }
    }
  }
}

private struct AgentActionStatus: View {
  let feedback: RemoteAgentActionFeedback
  let identifier: String
  let canRetry: Bool
  let requiresReview: Bool
  let isConnected: Bool
  let onRetry: (() -> Void)?
  let onReview: (() -> Void)?
  let onRefresh: (() -> Void)?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) { contents }
      } else {
        HStack(alignment: .center, spacing: 8) { contents }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  @ViewBuilder
  private var contents: some View {
    if feedback.phase == .sending || feedback.phase == .stopping {
      ProgressView().accessibilityHidden(true)
    }
    Text(feedback.message)
      .font(.footnote)
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
    if canRetry, let onRetry {
      Button(action: onRetry) {
        Text("Retry original")
          .foregroundStyle(Color(uiColor: .label))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.bordered)
      .tint(Color(uiColor: .label))
      .disabled(!isConnected)
      .accessibilityIdentifier("agent-action-retry")
    }
    if requiresReview, let onReview {
      Button(action: onReview) {
        Text("Review send")
          .foregroundStyle(Color(uiColor: .label))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.bordered)
      .tint(Color(uiColor: .label))
      .accessibilityIdentifier("agent-action-review")
    }
    if let onRefresh {
      Button(action: onRefresh) {
        Text("Refresh status")
          .foregroundStyle(Color(uiColor: .label))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.bordered)
      .tint(Color(uiColor: .label))
      .disabled(!isConnected)
      .accessibilityIdentifier("agent-stop-refresh")
    }
  }
}

private struct ConnectionBanner: View {
  @Bindable var model: OesapModel

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text("Live connection paused").font(.subheadline.weight(.semibold))
        Text("Your draft stays here while the app is open. Reconnect to restore the timeline.")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
        if let reason = model.connectError {
          DisclosureGroup("Connection details") {
            ConnectionErrorNotice(message: reason, identifier: "chat-connection-error")
              .font(.footnote)
              .padding(.top, 6)
          }
          .font(.footnote)
          .accessibilityIdentifier("chat-connection-details")
        }
        Button {
          Task { await model.reconnect() }
        } label: {
          Text("Reconnect").frame(minHeight: 44).contentShape(Rectangle())
        }
        .font(.subheadline.weight(.semibold))
        .disabled(model.connectionState.isBusy || !model.hasSavedConnection)
        .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct PermissionCard: View {
  let permission: RemotePermission
  let isResponding: Bool
  var onChoose: (Bool) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text("Agent needs your attention").foregroundStyle(.primary)
      } icon: {
        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
      }
      .font(.headline)
      Text(permission.title).font(.subheadline.weight(.medium))
      if let detail = permission.detail {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
          .textSelection(.enabled)
      }
      Text("Request type: \(permission.kind)")
        .font(.caption)
        .foregroundStyle(Color.primary.opacity(0.75))
      if !permission.supportsSimpleDecision {
        Text("This request needs a structured response. Review and answer it in Paseo.")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      } else if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          denyButton
          allowButton
        }
      } else {
        HStack {
          denyButton
          allowButton
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  private var denyButton: some View {
    Button(role: .destructive) {
      onChoose(false)
    } label: {
      Text(permission.denyLabel ?? "Deny")
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.bordered)
    .disabled(isResponding)
    .accessibilityIdentifier("permission-deny-\(permission.id)")
  }

  private var allowButton: some View {
    Button {
      onChoose(true)
    } label: {
      Group {
        if isResponding {
          ProgressView()
        } else {
          Text(permission.allowLabel ?? "Review and allow")
        }
      }
      .frame(minHeight: 44)
      .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.borderedProminent)
    .disabled(isResponding)
    .accessibilityIdentifier("permission-allow-\(permission.id)")
  }
}

private struct MessageBubble: View, Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    let messageMatches =
      lhs.buffersAgentOutput && rhs.buffersAgentOutput
      ? lhs.message.id == rhs.message.id && lhs.message.author == rhs.message.author
      : lhs.message == rhs.message
    return messageMatches && lhs.buffersAgentOutput == rhs.buffersAgentOutput
      && lhs.threadID == rhs.threadID
      && lhs.timelineGeneration == rhs.timelineGeneration
  }

  let message: RemoteMessage
  let threadID: String
  let timelineGeneration: Int
  let buffersAgentOutput: Bool
  let loadRemoteImage: (String, String) async throws -> Data

  var body: some View {
    HStack {
      if message.author == .user { Spacer(minLength: 42) }
      VStack(alignment: .leading, spacing: 5) {
        if buffersAgentOutput {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Agent is thinking")
          .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
          MessageMarkdownView(
            source: message.text,
            cacheKey: "\(threadID)-\(timelineGeneration)-\(message.id)",
            threadID: threadID,
            deferUntilRendered: message.author == .agent,
            loadRemoteImage: loadRemoteImage
          )
          .id("\(threadID)-\(timelineGeneration)-\(message.id)")
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if !message.images.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(Array(message.images.enumerated()), id: \.element.id) { index, image in
                ImageAttachmentThumbnail(image: image)
                  .frame(width: 112, height: 112)
                  .accessibilityIdentifier("message-image-\(message.id)-\(index)")
              }
            }
          }
          .scrollIndicators(.hidden)
        }
        if let timestamp = message.timestamp {
          Text(timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .background(
        message.author == .user
          ? Color(uiColor: .secondarySystemBackground)
          : Color(uiColor: .tertiarySystemBackground),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      if message.author != .user { Spacer(minLength: 30) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-\(message.id)")
  }
}

private struct AgentActivityIndicator: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }
}

private struct ThinkingTraceView: View {
  let message: RemoteMessage
  let isUpdating: Bool

  @State private var isExpanded = false

  var body: some View {
    Group {
      if message.thinkingIsEncrypted {
        HStack(spacing: 8) {
          Image(systemName: "lock.fill")
            .accessibilityHidden(true)
          Text(isUpdating ? "Updating encrypted thinking…" : "Thinking is encrypted")
          if isUpdating {
            ProgressView().controlSize(.small)
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      } else if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        HStack(spacing: 8) {
          if isUpdating { ProgressView().controlSize(.small) }
          Text(isUpdating ? "Thinking…" : "Thinking text unavailable")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else {
        DisclosureGroup(isExpanded: $isExpanded) {
          Text(verbatim: message.text)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "brain")
              .accessibilityHidden(true)
            Text(isUpdating ? "Thinking…" : "Thinking")
            if isUpdating {
              ProgressView().controlSize(.small)
            }
          }
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("thinking-trace-\(message.id)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .textSelection(.enabled)
  }
}

private struct InlineNotice: View {
  let text: String
  let symbol: String
  let tint: Color

  var body: some View {
    Label {
      Text(text).foregroundStyle(.primary)
    } icon: {
      Image(systemName: symbol).foregroundStyle(tint)
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// The offline load fixture exposes progress independently of its virtualized
/// rows, so UI tests can verify ingestion while reading earlier messages.
private struct TimelinePerformanceProgress: ViewModifier {
  let message: RemoteMessage?

  @ViewBuilder
  func body(content: Content) -> some View {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--demo-performance") {
        content.accessibilityValue(
          String(message?.id == "demo-performance-stream" ? message?.text.utf8.count ?? 0 : 0))
      } else {
        content
      }
    #else
      content
    #endif
  }
}

/// Tracks the user's scroll intent separately from Markdown layout changes.
/// Content growing below a pinned viewport must not switch off auto-follow.
private struct TimelineScrollTracking: ViewModifier {
  @Binding var isNearBottom: Bool
  @Binding var isUserScrolling: Bool
  let viewportHeight: CGFloat
  let onContentGrowth: () -> Void
  @State private var previousContentFrame: CGRect?

  private struct Metrics: Equatable {
    let isNearBottom: Bool
    let contentHeight: CGFloat
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      content
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .onScrollPhaseChange { _, phase, context in
          let wasUserScrolling = isUserScrolling
          isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
          if isUserScrolling || wasUserScrolling {
            let geometry = context.geometry
            isNearBottom = geometry.visibleRect.maxY >= geometry.contentSize.height - 72
          }
        }
        .onScrollGeometryChange(for: Metrics.self) { geometry in
          Metrics(
            isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 72,
            contentHeight: geometry.contentSize.height)
        } action: { old, new in
          if isUserScrolling {
            isNearBottom = new.isNearBottom
          } else if isNearBottom, old.contentHeight != new.contentHeight {
            onContentGrowth()
          }
        }
    } else {
      content
        .defaultScrollAnchor(.top)
        .onPreferenceChange(ScrollContentFrameKey.self) { frame in
          guard let frame else { return }
          let decision = TimelineScrollFollowPolicy.evaluate(
            previousFrame: previousContentFrame, frame: frame,
            viewportHeight: viewportHeight, wasFollowing: isNearBottom)
          previousContentFrame = frame
          isNearBottom = decision.isNearBottom
          if decision.shouldFollowContent { onContentGrowth() }
        }
    }
  }
}

/// Legacy scroll geometry has no native phase information. A growing content
/// frame with the same top offset is a layout change, whereas a changed offset
/// represents scrolling. Only the former can preserve an existing follow intent.
enum TimelineScrollFollowPolicy {
  struct Decision: Equatable {
    let isNearBottom: Bool
    let shouldFollowContent: Bool
  }

  static func evaluate(
    previousFrame: CGRect?, frame: CGRect, viewportHeight: CGFloat, wasFollowing: Bool
  ) -> Decision {
    if let previousFrame, wasFollowing,
      abs(frame.minY - previousFrame.minY) < 0.5,
      abs(frame.height - previousFrame.height) > 0.5
    {
      return Decision(isNearBottom: true, shouldFollowContent: true)
    }
    return Decision(
      isNearBottom: frame.maxY <= viewportHeight + 72, shouldFollowContent: false)
  }
}

private struct ScrollContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect? = nil

  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
    if let next = nextValue() { value = next }
  }
}
