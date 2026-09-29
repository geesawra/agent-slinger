import Foundation

enum RemoteQuestionMapper {
  static func map(_ input: PaseoJSONValue?) -> [RemoteQuestion]? {
    guard let input, case .array(let rawQuestions)? = input["questions"], !rawQuestions.isEmpty
    else {
      return nil
    }

    var questions: [RemoteQuestion] = []
    for (index, rawQuestion) in rawQuestions.enumerated() {
      guard case .object(let fields) = rawQuestion,
        let prompt = (fields["question"]?.stringValue ?? fields["prompt"]?.stringValue)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !prompt.isEmpty
      else { return nil }

      let header =
        fields["header"]?.stringValue
        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        ?? prompt
      let id =
        fields["id"]?.stringValue
        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        ?? "question-\(index + 1)"
      let options = parseOptions(fields["options"])
      let allowsOtherAnswer =
        boolean(fields["allowOther"]) == true
        || boolean(fields["allowFreeform"]) == true
        || boolean(fields["freeText"]) == true
        || options.isEmpty

      questions.append(
        RemoteQuestion(
          id: id,
          answerKey: header,
          header: header,
          prompt: prompt,
          options: options,
          allowsMultipleSelection:
            boolean(fields["multiSelect"]) ?? boolean(fields["multi"]) ?? false,
          allowsOtherAnswer: allowsOtherAnswer,
          isRequired: boolean(fields["required"]) ?? true,
          placeholder: fields["placeholder"]?.stringValue
        ))
    }
    return questions
  }

  private static func parseOptions(_ value: PaseoJSONValue?) -> [RemoteQuestionOption] {
    guard case .array(let rows)? = value else { return [] }
    return rows.compactMap { row in
      switch row {
      case .string(let label):
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RemoteQuestionOption(label: label, description: nil)
      case .object(let fields):
        guard let label = fields["label"]?.stringValue,
          !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return RemoteQuestionOption(label: label, description: fields["description"]?.stringValue)
      default:
        return nil
      }
    }
  }

  private static func boolean(_ value: PaseoJSONValue?) -> Bool? {
    guard case .bool(let result) = value else { return nil }
    return result
  }
}
