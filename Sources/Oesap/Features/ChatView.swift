import SwiftUI

struct ChatView: View {
  @Bindable var model: OesapModel
  let threadID: String
  @State private var permissionToConfirm: RemotePermission?
  @State private var permissionChoice = true
  @State private var showsUsageDetails = false
  @FocusState private var composerFocused: Bool
  @State private var viewportHeight: CGFloat = 0
  @State private var isNearBottom = true
  @State private var expandedToolCallIDs: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var thread: RemoteThread? { model.threads.first { $0.id == threadID } }

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

            if let thread {
              AgentStatusCard(
                thread: thread,
                contextUsage: model.contextUsage(for: threadID),
                isLoadingContextUsage: model.loadingContextUsage,
                onShowUsage: { showsUsageDetails = true }
              )
            }

            if let permission = model.permissions.first(where: { $0.agentID == threadID }) {
              PermissionCard(
                permission: permission,
                isResponding: model.answeringPermissionID == permission.id,
                onChoose: { allow in
                  permissionChoice = allow
                  permissionToConfirm = permission
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
              } else {
                MessageBubble(message: message)
                  .id(message.id)
              }
            }

            if model.loadingHistory && !model.messages.isEmpty {
              ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Color.clear
              .frame(height: 1)
              .id("timeline-bottom")
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: ScrollContentBottomKey.self,
                    value: geometry.frame(in: .named("timelineScroll")).maxY
                  )
                }
              }
          }
          .padding(.horizontal)
          .padding(.top, 12)
          .padding(.bottom, 20)
        }
        .accessibilityIdentifier("chat-timeline-scroll")
        .coordinateSpace(name: "timelineScroll")
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(ScrollContentBottomKey.self) { bottom in
          isNearBottom = bottom <= viewportHeight + 72
        }
        .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
        .onChange(of: model.messages.map(\.id)) { _, _ in
          let liveToolCallIDs = Set(model.messages.filter { $0.toolCall != nil }.map(\.id))
          expandedToolCallIDs.formIntersection(liveToolCallIDs)
        }
        .onChange(of: threadID) { _, _ in expandedToolCallIDs.removeAll() }
        .onChange(of: model.messages.last) { _, newValue in
          guard isNearBottom, expandedToolCallIDs.isEmpty, let newValue else { return }
          if reduceMotion {
            proxy.scrollTo(newValue.id, anchor: .bottom)
          } else {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(newValue.id, anchor: .bottom) }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          ChatComposerBar(
            draft: Binding(
              get: { model.draft(for: threadID) },
              set: { model.setDraft($0, for: threadID) }
            ),
            isSending: model.sendingMessage,
            isConnected: model.connectionState == .connected,
            error: model.messageError,
            focus: $composerFocused,
            send: { text in
              Task { _ = await model.send(threadID: threadID, text: text) }
            },
            clearError: model.clearMessageError
          )
        }
        .navigationTitle(thread?.title ?? "Agent thread")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsUsageDetails) {
          UsageDetailsSheet(model: model, contextThreadID: threadID)
        }
        .task(id: "\(threadID)-\(model.timelineGeneration)") {
          viewportHeight = viewport.size.height
          await model.watchTimeline(threadID: threadID)
        }
        .confirmationDialog(
          permissionChoice ? "Allow this agent request?" : "Deny this agent request?",
          isPresented: Binding(
            get: { permissionToConfirm != nil },
            set: { if !$0 { permissionToConfirm = nil } }
          ),
          titleVisibility: .visible,
          presenting: permissionToConfirm
        ) { permission in
          Button(
            permissionChoice
              ? (permission.allowLabel ?? "Allow") : (permission.denyLabel ?? "Deny"),
            role: permissionChoice ? .none : .destructive
          ) {
            Task { await model.answerPermission(permission, allow: permissionChoice) }
            permissionToConfirm = nil
          }
          Button("Cancel", role: .cancel) { permissionToConfirm = nil }
        } message: { permission in
          Text([permission.title, permission.detail].compactMap { $0 }.joined(separator: "\n\n"))
        }
      }
    }
  }
}

private struct AgentStatusCard: View {
  let thread: RemoteThread
  let contextUsage: RemoteContextUsage?
  let isLoadingContextUsage: Bool
  var onShowUsage: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          statusInformation.frame(maxWidth: .infinity, alignment: .leading)
          HStack {
            Spacer(minLength: 0)
            usageButton
          }
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          statusInformation
          Spacer(minLength: 0)
          usageButton
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var statusInformation: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: thread.state.symbol)
        .font(.title2)
        .foregroundStyle(thread.requiresAttention ? Color.orange : Color.accentColor)
        .frame(width: 34)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(thread.state.label).font(.headline)
          if thread.requiresAttention {
            Label("Attention", systemImage: "hand.raised.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.orange)
          }
        }
        if let reason = thread.attentionReason {
          Text(verbatim: reason).font(.subheadline).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
          if let provider = thread.provider { Text(verbatim: provider) }
          if let model = thread.model {
            Text("·")
            Text(verbatim: model)
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var usageButton: some View {
    Button(action: onShowUsage) {
      ContextUsageIndicator(usage: contextUsage, isLoading: isLoadingContextUsage)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("context-usage-button")
  }
}

private struct ConnectionBanner: View {
  @Bindable var model: OesapModel

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text("Live connection paused").font(.subheadline.weight(.semibold))
        Text("Your draft is saved. Reconnect to restore the timeline.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Reconnect") { Task { await model.reconnect() } }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Agent needs your attention", systemImage: "hand.raised.fill")
        .font(.headline)
        .foregroundStyle(.orange)
      Text(permission.title).font(.subheadline.weight(.medium))
      if let detail = permission.detail {
        Text(detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Text("Request type: \(permission.kind)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !permission.supportsSimpleDecision {
        Text("This request needs a structured response. Review and answer it in Paseo.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        HStack {
          Button(permission.denyLabel ?? "Deny", role: .destructive) { onChoose(false) }
            .buttonStyle(.bordered)
            .disabled(isResponding)
          Button {
            onChoose(true)
          } label: {
            if isResponding {
              ProgressView()
            } else {
              Text(permission.allowLabel ?? "Review and allow")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isResponding)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
  }
}

private struct MessageBubble: View {
  let message: RemoteMessage

  var body: some View {
    HStack {
      if message.author == .user { Spacer(minLength: 42) }
      VStack(alignment: .leading, spacing: 5) {
        Text(message.author.label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(
            message.author == .user ? Color.white.opacity(0.78) : Color(uiColor: .secondaryLabel))
        Text(message.text)
          .font(.body)
          .textSelection(.enabled)
          .foregroundStyle(message.author == .user ? Color.white : Color.primary)
        if let timestamp = message.timestamp {
          Text(timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(
              message.author == .user ? Color.white.opacity(0.72) : Color(uiColor: .tertiaryLabel))
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        message.author == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      if message.author != .user { Spacer(minLength: 30) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("message-\(message.id)")
  }
}

extension RemoteMessage.Author {
  fileprivate var label: String {
    switch self {
    case .user: "You"
    case .agent: "Agent"
    case .system: "Paseo"
    }
  }
}

private struct InlineNotice: View {
  let text: String
  let symbol: String
  let tint: Color

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.subheadline)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityElement(children: .combine)
  }
}

private struct ScrollContentBottomKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
