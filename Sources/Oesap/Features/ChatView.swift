import SwiftUI

private enum AgentActionSheet: Identifiable {
  case uncertainSend(threadID: String)

  var id: String {
    switch self {
    case .uncertainSend(let threadID): "uncertain-\(threadID)"
    }
  }

  var title: String { "Check the previous send" }

  var message: String {
    "This only clears Agent Slinger’s local resend safeguard. It doesn’t cancel or remove the original message, and the host may still deliver it. Your draft stays here; sending it again could create a duplicate."
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

private enum ChatTimelineRow: Identifiable {
  case message(RemoteMessage)
  case tools([RemoteMessage])

  var id: String {
    switch self {
    case .message(let message): message.id
    case .tools(let messages): "tools-\(messages.first?.id ?? "empty")"
    }
  }

  static func grouped(_ messages: [RemoteMessage], hiding hiddenIDs: Set<String>) -> [Self] {
    var rows: [Self] = []
    var tools: [RemoteMessage] = []
    for message in messages where !message.isThinkingTrace && !hiddenIDs.contains(message.id) {
      if message.toolCall != nil {
        tools.append(message)
      } else {
        if !tools.isEmpty {
          rows.append(.tools(tools))
          tools.removeAll(keepingCapacity: true)
        }
        rows.append(.message(message))
      }
    }
    if !tools.isEmpty { rows.append(.tools(tools)) }
    return rows
  }
}

struct ChatView: View {
  @Bindable var model: OesapModel
  let threadID: String
  @State private var showsSessionInfo = false
  @State private var showsGitChanges = false
  @State private var showsSubagents = false
  @State private var composerFocused = false
  @State private var isNearBottom = true
  @State private var isUserScrolling = false
  @State private var jumpToLatestRequested = false
  @State private var expandedToolCallIDs: Set<String> = []
  @State private var collapsedRunningToolCallIDs: Set<String> = []
  @State private var expandedToolGroupIDs: Set<String> = []
  @State private var actionSheet: AgentActionSheet?
  @State private var actionConfirmation: AgentActionConfirmation?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var thread: RemoteThread? { model.threads.first { $0.id == threadID } }
  private var managedSubagents: [RemoteThread] {
    model.agentOverviewGroups.flatMap(\.threads).filter { $0.parentAgentID == threadID }
  }
  private var providerSubagents: [RemoteProviderSubagent] {
    model.providerSubagentsByParent[threadID] ?? []
  }
  private var pendingPermission: RemotePermission? {
    model.permissions.first { $0.agentID == threadID }
  }
  private var timelineRows: [ChatTimelineRow] {
    ChatTimelineRow.grouped(model.messages, hiding: model.bufferedAgentMessageIDs)
  }

  private var latestThinkingTrace: RemoteMessage? {
    let start =
      model.messages.lastIndex(where: { $0.author == .user })
      .map { model.messages.index(after: $0) } ?? model.messages.startIndex
    return model.messages[start...].last(where: \.isThinkingTrace)
  }

  private var agentActivityMessage: String? {
    guard model.connectionState == .connected, let thread else { return nil }
    if thread.state == .running {
      return latestThinkingTrace == nil ? "Thinking…" : nil
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

            if let permission = pendingPermission, permission.questions == nil {
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

            ForEach(timelineRows) { row in
              timelineRow(row)
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

            if let trace = latestThinkingTrace {
              ThinkingTraceView(
                message: trace,
                isUpdating: model.connectionState == .connected && thread?.state == .running,
                threadID: threadID,
                timelineGeneration: model.timelineGeneration,
                loadRemoteImage: { source, imageThreadID in
                  try await model.loadRemoteImage(source: source, threadID: imageThreadID)
                }
              )
              .id(trace.id)
              .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let activity = agentActivityMessage {
              AgentActivityIndicator(message: activity)
                .id("agent-activity-\(threadID)")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let permission = pendingPermission, let questions = permission.questions {
              AgentQuestionCard(
                permission: permission,
                questions: questions,
                isResponding: model.answeringPermissionID == permission.id,
                onSubmit: { answers in
                  Task { await model.answerQuestion(permission, answers: answers) }
                },
                onDismiss: {
                  Task { await model.answerQuestion(permission, answers: nil) }
                }
              )
              .id(permission.id)
            }

            Color.clear
              .frame(height: 1)
              .id("timeline-bottom")
          }
          .padding(.horizontal)
          .padding(.top, 12)
          .padding(.bottom, 20)
          // Keep short conversations at the top of the viewport. Otherwise a
          // bottom scroll anchor can leave space above the first message.
          .frame(minHeight: viewport.size.height, alignment: .top)
          .frame(maxWidth: 900)
          .frame(maxWidth: .infinity)
          .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: model.bufferedAgentMessageIDs
          )
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: latestThinkingTrace?.id)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: agentActivityMessage)
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
        .modifier(TimelinePerformanceProgress(streamBytes: model.performanceFixtureStreamBytes))
        .coordinateSpace(name: "timelineScroll")
        .scrollDismissesKeyboard(.interactively)
        .modifier(
          TimelineScrollTracking(
            isNearBottom: $isNearBottom, isUserScrolling: $isUserScrolling,
            jumpToLatestRequested: $jumpToLatestRequested,
            viewportHeight: viewport.size.height,
            hasExpandedToolCall: !expandedToolCallIDs.isEmpty || !expandedToolGroupIDs.isEmpty)
        )
        .onChange(of: model.timelineStructureRevision) { _, _ in
          let standaloneToolCallIDs = Set(
            timelineRows.compactMap { row -> String? in
              if case .tools(let messages) = row, messages.count == 1 {
                return messages.first?.id
              }
              return nil
            })
          expandedToolCallIDs.formIntersection(standaloneToolCallIDs)
          let runningStandaloneIDs = Set(
            timelineRows.compactMap { row -> String? in
              if case .tools(let messages) = row, messages.count == 1,
                let message = messages.first, message.toolCall?.status == .running
              {
                return message.id
              }
              return nil
            })
          collapsedRunningToolCallIDs.formIntersection(runningStandaloneIDs)
          let liveGroupIDs = Set(
            timelineRows.compactMap { row -> String? in
              if case .tools(let messages) = row, messages.count > 1 { return row.id }
              return nil
            })
          expandedToolGroupIDs.formIntersection(liveGroupIDs)
          followLatestIfNeeded(proxy)
        }
        .onChange(of: threadID) { _, _ in
          expandedToolCallIDs.removeAll()
          collapsedRunningToolCallIDs.removeAll()
          expandedToolGroupIDs.removeAll()
          isNearBottom = true
          isUserScrolling = false
          jumpToLatestRequested = false
        }
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
          guard newValue != nil else { return }
          if oldValue == nil {
            // Initial history has no prior reading position, including on the
            // iOS 17 baseline without separate scroll-anchor roles.
            isNearBottom = true
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
          } else {
            followLatestIfNeeded(proxy)
          }
        }
        .onChange(of: pendingPermission) { _, _ in followLatestIfNeeded(proxy) }
        .onChange(of: latestThinkingTrace) { _, _ in followLatestIfNeeded(proxy) }
        .onChange(of: agentActivityMessage) { _, _ in followLatestIfNeeded(proxy) }
        .onChange(of: model.bufferedAgentMessageIDs) { _, _ in followLatestIfNeeded(proxy) }
        .onChange(of: viewport.size.height) { oldHeight, newHeight in
          if newHeight < oldHeight { followLatestIfNeeded(proxy) }
        }
        .modifier(
          TimelineJumpControls(
            isNearBottom: $isNearBottom, isUserScrolling: $isUserScrolling,
            jumpToLatestRequested: $jumpToLatestRequested, proxy: proxy,
            hasMessages: !model.messages.isEmpty, reduceMotion: reduceMotion)
        )
        .navigationTitle(thread?.title ?? "Agent thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              composerFocused = false
              showsSessionInfo = true
            } label: {
              ContextUsageIndicator(
                usage: model.contextUsage(for: threadID),
                isLoading: model.loadingContextUsage,
                showsDisclosureIndicator: false
              )
              .frame(width: 32, height: 32)
            }
            .accessibilityHint("Shows the session status, details, and usage.")
            .accessibilityIdentifier("context-usage-button")
          }
        }
        .sheet(isPresented: $showsSessionInfo) {
          SessionInfoSheet(model: model, threadID: threadID)
        }
        .sheet(item: $actionSheet) { action in
          AgentActionSheetView(
            action: action,
            canRetry: model.canRetryAgentMessage(for: threadID),
            isConnected: model.connectionState == .connected,
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
    .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
    .sheet(isPresented: $showsGitChanges) {
      GitChangesListSheet(model: model, threadID: threadID)
    }
    .sheet(isPresented: $showsSubagents) {
      SubagentViewerSheet(model: model, parentID: threadID)
    }
    .task(id: threadID) {
      await model.refreshGitStatus(threadID: threadID)
      await model.refreshProviderSubagents(parentAgentID: threadID)
    }
    .onChange(of: model.connectionState) { _, state in
      guard state == .connected else { return }
      Task {
        await model.refreshGitStatus(threadID: threadID)
        await model.refreshProviderSubagents(parentAgentID: threadID)
      }
    }
    .onChange(of: thread?.state) { oldState, newState in
      guard oldState == .running, newState != .running else { return }
      Task {
        await model.refreshGitStatus(threadID: threadID)
        await model.refreshProviderSubagents(parentAgentID: threadID)
      }
    }
  }

  private var composerBar: some View {
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
      interrupt: interruptThreadMessage,
      clearError: {},
      agentTasks: model.agentTasks(for: threadID),
      subagentCount: managedSubagents.count + providerSubagents.count,
      onShowSubagents: {
        composerFocused = false
        showsSubagents = true
      },
      gitStatus: model.gitStatus,
      isLoadingGitStatus: model.loadingGitStatus,
      gitStatusError: model.gitStatusError,
      onShowGitChanges: model.gitStatus?.files.isEmpty == false
        ? {
          composerFocused = false
          showsGitChanges = true
        } : nil,
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

  @ViewBuilder
  private func timelineRow(_ row: ChatTimelineRow) -> some View {
    switch row {
    case .tools(let messages):
      if messages.count > 1 {
        ToolCallGroupCard(
          messages: messages,
          isExpanded: Binding(
            get: { expandedToolGroupIDs.contains(row.id) },
            set: { expanded in
              if expanded {
                expandedToolGroupIDs.insert(row.id)
              } else {
                expandedToolGroupIDs.remove(row.id)
              }
            }
          )
        )
        .id(row.id)
      } else if let message = messages.first, let toolCall = message.toolCall {
        ToolCallCard(
          call: toolCall, rowID: message.id,
          isExpanded: Binding(
            get: {
              toolCall.status == .running
                ? !collapsedRunningToolCallIDs.contains(message.id)
                : expandedToolCallIDs.contains(message.id)
            },
            set: { expanded in
              if toolCall.status == .running {
                if expanded {
                  collapsedRunningToolCallIDs.remove(message.id)
                } else {
                  collapsedRunningToolCallIDs.insert(message.id)
                }
              } else if expanded {
                expandedToolCallIDs.insert(message.id)
              } else {
                expandedToolCallIDs.remove(message.id)
              }
            }
          )
        )
        .id(row.id)
      }
    case .message(let message):
      if let compaction = message.compaction {
        CompactionCard(compaction: compaction)
          .id(message.id)
      } else {
        MessageBubble(
          message: message,
          threadID: threadID,
          timelineGeneration: model.timelineGeneration,
          loadRemoteImage: { source, imageThreadID in
            try await model.loadRemoteImage(source: source, threadID: imageThreadID)
          }
        )
        .equatable()
        .id(message.id)
      }
    }
  }

  private func followLatestIfNeeded(_ proxy: ScrollViewProxy) {
    guard
      TimelineScrollFollowPolicy.shouldFollowUpdates(
        isNearBottom: isNearBottom, isUserScrolling: isUserScrolling,
        hasExpandedToolCall: !expandedToolCallIDs.isEmpty || !expandedToolGroupIDs.isEmpty)
    else { return }
    Task { @MainActor in
      await Task.yield()
      guard
        TimelineScrollFollowPolicy.shouldFollowUpdates(
          isNearBottom: isNearBottom, isUserScrolling: isUserScrolling,
          hasExpandedToolCall: !expandedToolCallIDs.isEmpty || !expandedToolGroupIDs.isEmpty)
      else { return }
      proxy.scrollTo("timeline-bottom", anchor: .bottom)
    }
  }

  private func submitThreadMessage(_ text: String, images: [RemoteDraftImage]) {
    guard let thread else { return }
    if model.hasUncertainAgentMessage(for: threadID) {
      actionSheet = .uncertainSend(threadID: threadID)
      return
    }
    let isRunning = thread.state == .running
    sendThreadMessage(
      text, images: images, behavior: isRunning ? .steer : .interrupt,
      selectedDuringActiveTurn: isRunning)
  }

  private func interruptThreadMessage(_ text: String, images: [RemoteDraftImage]) {
    guard let thread else { return }
    if model.hasUncertainAgentMessage(for: threadID) {
      actionSheet = .uncertainSend(threadID: threadID)
      return
    }
    let isRunning = thread.state == .running
    sendThreadMessage(
      text, images: images, behavior: .interrupt,
      selectedDuringActiveTurn: isRunning)
  }

  private func sendThreadMessage(
    _ text: String, images: [RemoteDraftImage], behavior: RemoteActiveTurnBehavior,
    selectedDuringActiveTurn: Bool
  ) {
    let revision = model.threadStateRevision(for: threadID)
    Task {
      _ = await model.send(
        threadID: threadID, text: text,
        behavior: behavior,
        expectedStateRevision: revision, selectedDuringActiveTurn: selectedDuringActiveTurn,
        images: images)
    }
  }
}

private struct TimelineJumpControls: ViewModifier {
  @Binding var isNearBottom: Bool
  @Binding var isUserScrolling: Bool
  @Binding var jumpToLatestRequested: Bool
  let proxy: ScrollViewProxy
  let hasMessages: Bool
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    content
      .onChange(of: isUserScrolling) { _, scrolling in
        if !scrolling && jumpToLatestRequested { jumpToLatest() }
      }
      .onChange(of: isNearBottom) { _, nearBottom in
        if nearBottom && !isUserScrolling { jumpToLatestRequested = false }
      }
      .overlay(alignment: .bottomTrailing) {
        if !isNearBottom && hasMessages {
          Button {
            InteractionFeedback.selection()
            jumpToLatestRequested = true
            jumpToLatest()
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
          .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isNearBottom)
  }

  private func jumpToLatest() {
    proxy.scrollTo("timeline-bottom", anchor: .bottom)
    Task { @MainActor in
      await Task.yield()
      guard jumpToLatestRequested && !isUserScrolling else { return }
      proxy.scrollTo("timeline-bottom", anchor: .bottom)
      if isNearBottom { jumpToLatestRequested = false }
    }
  }
}

private struct AgentActionSheetView: View {
  let action: AgentActionSheet
  let canRetry: Bool
  let isConnected: Bool
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
          if case .uncertainSend(let threadID) = action {
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
        Text("This request needs a structured response that Oesap can’t render yet.")
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

struct MessageBubble: View, Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.message == rhs.message && lhs.threadID == rhs.threadID
      && lhs.timelineGeneration == rhs.timelineGeneration
  }

  let message: RemoteMessage
  let threadID: String
  let timelineGeneration: Int
  let loadRemoteImage: (String, String) async throws -> Data

  var body: some View {
    HStack {
      if message.author == .user { Spacer(minLength: 42) }
      VStack(alignment: .leading, spacing: 5) {
        MessageMarkdownView(
          source: message.text,
          cacheKey: "\(threadID)-\(timelineGeneration)-\(message.id)",
          threadID: threadID,
          loadRemoteImage: loadRemoteImage
        )
        .id("\(threadID)-\(timelineGeneration)-\(message.id)")
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
    .padding(12)
    .accessibilityElement(children: .combine)
  }
}

private struct CompactionCard: View {
  let compaction: RemoteCompaction

  private var isLoading: Bool { compaction.status == .loading }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.body.weight(.semibold))
        .foregroundStyle(.tint)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(isLoading ? "Compacting context…" : "Context compacted")
            .font(.subheadline.weight(.semibold))
          if isLoading { ProgressView().controlSize(.small) }
        }
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(
      Color.accentColor.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.18))
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("compaction-card")
  }

  private var detail: String {
    let trigger = compaction.trigger == "manual" ? "Requested by you" : "Conversation memory"
    guard let preTokens = compaction.preTokens, preTokens > 0 else { return trigger }
    return "\(trigger) · \(preTokens.formatted()) tokens before compaction"
  }
}

private struct ThinkingTraceView: View {
  let message: RemoteMessage
  let isUpdating: Bool
  let threadID: String
  let timelineGeneration: Int
  let loadRemoteImage: (String, String) async throws -> Data

  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false

  private var backgroundColor: Color {
    colorScheme == .dark ? Color.gray.opacity(0.22) : Color.gray.opacity(0.10)
  }

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
          MessageMarkdownView(
            source: message.text,
            cacheKey: "\(threadID)-\(timelineGeneration)-thinking-\(message.id)",
            threadID: threadID,
            loadRemoteImage: loadRemoteImage
          )
          .id("\(threadID)-\(timelineGeneration)-thinking-\(message.id)")
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
    .background(
      backgroundColor,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
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
  let streamBytes: Int

  @ViewBuilder
  func body(content: Content) -> some View {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--demo-performance") {
        content.accessibilityValue(String(streamBytes))
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
  @Binding var jumpToLatestRequested: Bool
  let viewportHeight: CGFloat
  let hasExpandedToolCall: Bool
  @State private var previousContentFrame: CGRect?
  @State private var previousViewportHeight: CGFloat?
  @State private var scrollSettleTask: Task<Void, Never>?

  private struct Metrics: Equatable {
    let isNearBottom: Bool
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
  }

  private var sizeChangeAnchor: UnitPoint {
    TimelineScrollFollowPolicy.shouldFollowUpdates(
      isNearBottom: isNearBottom, isUserScrolling: isUserScrolling,
      hasExpandedToolCall: hasExpandedToolCall) ? .bottom : .top
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      content
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
        .onScrollPhaseChange { _, phase, context in
          if phase == .tracking || phase == .interacting {
            jumpToLatestRequested = false
          }
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
            contentHeight: geometry.contentSize.height,
            viewportHeight: geometry.visibleRect.height)
        } action: { old, new in
          isNearBottom = TimelineScrollFollowPolicy.updatedFollowIntent(
            wasFollowing: isNearBottom, isUserScrolling: isUserScrolling,
            contentSizeChanged: old.contentHeight != new.contentHeight,
            viewportSizeChanged: old.viewportHeight != new.viewportHeight,
            isNearBottom: new.isNearBottom)
        }
    } else {
      content
        .defaultScrollAnchor(sizeChangeAnchor)
        .simultaneousGesture(
          DragGesture(minimumDistance: 2)
            .onChanged { _ in
              scrollSettleTask?.cancel()
              jumpToLatestRequested = false
              isUserScrolling = true
            }
            .onEnded { _ in
              scheduleScrollSettle()
            }
        )
        .onPreferenceChange(ScrollContentFrameKey.self) { frame in
          guard let frame else { return }
          if isUserScrolling, let previousContentFrame,
            abs(frame.minY - previousContentFrame.minY) > 0.5
          {
            scheduleScrollSettle()
          }
          let decision = TimelineScrollFollowPolicy.evaluate(
            previousFrame: previousContentFrame, frame: frame,
            viewportHeight: viewportHeight, previousViewportHeight: previousViewportHeight,
            wasFollowing: isNearBottom)
          previousContentFrame = frame
          previousViewportHeight = viewportHeight
          isNearBottom = decision.isNearBottom
        }
        .onDisappear { scrollSettleTask?.cancel() }
    }
  }

  private func scheduleScrollSettle() {
    scrollSettleTask?.cancel()
    scrollSettleTask = Task { @MainActor in
      // iOS 17 has no scroll phase callback. Wait until the scroll offset
      // stops changing, including after a fast swipe starts decelerating.
      try? await Task.sleep(for: .milliseconds(180))
      if !Task.isCancelled { isUserScrolling = false }
    }
  }
}

/// Preserve the reader's intent while text grows and choose the native anchor
/// that holds either the latest content or the current reading position.
enum TimelineScrollFollowPolicy {
  struct Decision: Equatable {
    let isNearBottom: Bool
  }

  static func shouldFollowUpdates(
    isNearBottom: Bool, isUserScrolling: Bool, hasExpandedToolCall: Bool
  ) -> Bool {
    isNearBottom && !isUserScrolling && !hasExpandedToolCall
  }

  static func updatedFollowIntent(
    wasFollowing: Bool, isUserScrolling: Bool, contentSizeChanged: Bool,
    viewportSizeChanged: Bool = false, isNearBottom: Bool
  ) -> Bool {
    // A pinned viewport can briefly measure above the bottom before the native
    // size-change anchor has applied. Preserve intent for that layout pass.
    if wasFollowing && !isUserScrolling && (contentSizeChanged || viewportSizeChanged)
      && !isNearBottom
    {
      return true
    }
    return isNearBottom
  }

  static func evaluate(
    previousFrame: CGRect?, frame: CGRect, viewportHeight: CGFloat,
    previousViewportHeight: CGFloat? = nil, wasFollowing: Bool
  ) -> Decision {
    if let previousViewportHeight, let previousFrame, wasFollowing,
      viewportHeight < previousViewportHeight,
      abs(frame.minY - previousFrame.minY) < 0.5
    {
      return Decision(isNearBottom: true)
    }
    if let previousFrame, wasFollowing,
      abs(frame.minY - previousFrame.minY) < 0.5,
      abs(frame.height - previousFrame.height) > 0.5
    {
      return Decision(isNearBottom: true)
    }
    return Decision(isNearBottom: frame.maxY <= viewportHeight + 72)
  }
}

private struct ScrollContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect? = nil

  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
    if let next = nextValue() { value = next }
  }
}
