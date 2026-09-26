import SwiftUI

struct ChatComposerBar: View {
  @Binding var draft: String
  let isSending: Bool
  let isConnected: Bool
  let error: String?
  var focus: FocusState<Bool>.Binding
  var send: (String) -> Void
  var clearError: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if let error {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(error).font(.footnote).foregroundStyle(.primary)
          Spacer(minLength: 0)
          Button {
            clearError()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss message error")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Message agent…", text: $draft, axis: .vertical)
          .lineLimit(1...5)
          .submitLabel(.send)
          .focused(focus)
          .accessibilityLabel("Message agent")
          .accessibilityIdentifier("chat-composer")
          .onSubmit(sendDraft)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
          )
          .onChange(of: draft) { _, _ in clearError() }

        Button(action: sendDraft) {
          Group {
            if isSending {
              ProgressView()
            } else {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
            }
          }
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.45)
        .accessibilityLabel("Send message")
        .accessibilityIdentifier("send-message")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .background(.bar)
  }

  private var canSend: Bool {
    isConnected && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sendDraft() {
    guard canSend else { return }
    send(draft)
    focus.wrappedValue = true
  }
}
