import SwiftUI

struct AgentQuestionCard: View {
  let permission: RemotePermission
  let questions: [RemoteQuestion]
  let isResponding: Bool
  let onSubmit: ([String: String]) -> Void
  let onDismiss: () -> Void

  @State private var activeQuestionIndex = 0
  @State private var selections: [String: Set<String>] = [:]
  @State private var otherAnswers: [String: String] = [:]

  private var activeQuestion: RemoteQuestion? {
    guard !questions.isEmpty else { return nil }
    return questions[min(activeQuestionIndex, questions.count - 1)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label {
        Text("Agent has a question").foregroundStyle(.primary)
      } icon: {
        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
      }
      .font(.headline)

      if permission.title.localizedCaseInsensitiveCompare("Question") != .orderedSame {
        Text(permission.title)
          .font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
      }
      if let detail = permission.detail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
          .textSelection(.enabled)
      }

      if questions.count > 1 {
        questionNavigation
      }

      if let question = activeQuestion {
        VStack(alignment: .leading, spacing: 12) {
          Text(question.prompt)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("agent-question-prompt-\(question.id)")

          if !question.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(question.options) { option in
                optionButton(option, for: question)
              }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(question.prompt)
          }

          if question.allowsOtherAnswer {
            TextField(
              question.placeholder ?? (question.options.isEmpty ? "Your answer" : "Other"),
              text: otherAnswerBinding(for: question),
              axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .disabled(isResponding)
            .accessibilityLabel(question.prompt)
            .accessibilityIdentifier("agent-question-other-\(question.id)")
          }
        }
      }

      HStack {
        Button("Dismiss", role: .cancel, action: onDismiss)
          .buttonStyle(.bordered)
          .disabled(isResponding)
          .accessibilityIdentifier("agent-question-dismiss-\(permission.id)")

        Spacer(minLength: 8)

        if isResponding {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Sending answer")
        }

        Button(questions.indices.contains(activeQuestionIndex + 1) ? "Next" : "Submit") {
          if activeQuestionIndex + 1 < questions.count {
            activeQuestionIndex += 1
          } else {
            onSubmit(completedAnswers)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isResponding || !canContinue)
        .accessibilityIdentifier("agent-question-primary-action")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-question-card-\(permission.id)")
  }

  private var canContinue: Bool {
    guard let activeQuestion else { return false }
    if activeQuestionIndex + 1 < questions.count {
      return isAnswered(activeQuestion)
    }
    return questions.allSatisfy(isAnswered)
  }

  private var questionNavigation: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)],
      alignment: .leading,
      spacing: 8
    ) {
      ForEach(questions.indices, id: \.self) { index in
        questionTab(questions[index], at: index)
      }
    }
  }

  private func questionTab(_ question: RemoteQuestion, at index: Int) -> some View {
    let isSelected = index == activeQuestionIndex
    let hasAnswer = isAnswered(question)
    return Button {
      activeQuestionIndex = index
    } label: {
      HStack(spacing: 6) {
        if hasAnswer {
          Image(systemName: "checkmark.circle.fill")
            .accessibilityHidden(true)
        }
        Text(question.header)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .tint(isSelected ? .accentColor : .secondary)
    .disabled(isResponding)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityLabel("Question \(index + 1) of \(questions.count): \(question.header)")
    .accessibilityIdentifier("agent-question-tab-\(index + 1)")
  }

  private var completedAnswers: [String: String] {
    var result: [String: String] = [:]
    for question in questions {
      let selected = question.options
        .filter { selections[question.id, default: []].contains($0.label) }
        .map(\.label)
      let other = otherAnswers[question.id, default: ""]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let values = selected + (other.isEmpty ? [] : [other])
      if !values.isEmpty {
        result[question.answerKey] = values.joined(separator: ", ")
      }
    }
    return result
  }

  private func optionButton(_ option: RemoteQuestionOption, for question: RemoteQuestion)
    -> some View
  {
    let isSelected = selections[question.id, default: []].contains(option.label)
    return Button {
      var selected = selections[question.id, default: []]
      if question.allowsMultipleSelection {
        if !selected.insert(option.label).inserted {
          selected.remove(option.label)
        }
      } else {
        selected = isSelected ? [] : [option.label]
        if !selected.isEmpty {
          otherAnswers[question.id] = ""
        }
      }
      selections[question.id] = selected
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: selectionSymbol(
            isSelected: isSelected, multi: question.allowsMultipleSelection)
        )
        .font(.body.weight(.medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(option.label)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          if let description = option.description, !description.isEmpty {
            Text(description)
              .font(.footnote)
              .foregroundStyle(Color.primary.opacity(0.75))
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(
        isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isResponding)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("agent-question-option-\(question.id)-\(option.label)")
  }

  private func selectionSymbol(isSelected: Bool, multi: Bool) -> String {
    if multi { return isSelected ? "checkmark.square.fill" : "square" }
    return isSelected ? "largecircle.fill.circle" : "circle"
  }

  private func isAnswered(_ question: RemoteQuestion) -> Bool {
    guard question.isRequired else { return true }
    return !selections[question.id, default: []].isEmpty
      || !otherAnswers[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
  }

  private func otherAnswerBinding(for question: RemoteQuestion) -> Binding<String> {
    Binding(
      get: { otherAnswers[question.id, default: ""] },
      set: {
        otherAnswers[question.id] = $0
        if !question.allowsMultipleSelection, !$0.isEmpty {
          selections[question.id] = []
        }
      }
    )
  }
}
