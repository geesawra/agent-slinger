import Foundation

/// Converts Paseo's extensible tool-call payload into a stable display model.
/// Raw protocol JSON stays at the adapter boundary, including unknown detail kinds.
/// Merge behavior follows Paseo packages/app/src/types/stream.ts at commit
/// 8cd989529e2d86bb6d1c8a775bf695fa5970c997 (Apache-2.0).
enum RemoteToolCallMapper {
  /// Mirrors Paseo's tool lifecycle reducer for canonical snapshots. Fields
  /// absent from a later same-kind detail do not erase an earlier value.
  static func merge(
    _ existing: [String: PaseoJSONValue], with incoming: [String: PaseoJSONValue]
  ) -> [String: PaseoJSONValue] {
    var result = existing
    for (key, value) in incoming { result[key] = value }

    let priorStatus = existing["status"]?.stringValue ?? "running"
    let newStatus = incoming["status"]?.stringValue ?? priorStatus
    let finalStatus = mergedStatus(priorStatus, newStatus)
    result["status"] = .string(finalStatus)
    if finalStatus == "failed" {
      result["error"] =
        nonnull(incoming["error"]) ?? nonnull(existing["error"])
        ?? .object(["message": .string("Tool call failed")])
    } else {
      result["error"] = .null
    }

    if let priorMetadata = existing["metadata"]?.objectValue,
      let nextMetadata = incoming["metadata"]?.objectValue
    {
      result["metadata"] = .object(priorMetadata.merging(nextMetadata) { _, next in next })
    } else if incoming["metadata"] == nil {
      result["metadata"] = existing["metadata"]
    }

    result["detail"] = mergeDetail(existing["detail"], incoming["detail"])
    return result
  }

  static func map(_ item: [String: PaseoJSONValue], turnID: String? = nil) -> RemoteToolCall? {
    guard let callID = item["callId"]?.stringValue, !callID.isEmpty else { return nil }
    let name = item["name"]?.stringValue ?? "Tool"
    let status = status(item["status"]?.stringValue)
    let detail = item["detail"]?.objectValue ?? [:]
    let kind = detail["type"]?.stringValue
    var call = RemoteToolCall(
      callID: callID, turnID: turnID, name: name,
      title: title(name: name, kind: kind, detail: detail),
      summary: summary(name: name, kind: kind, detail: detail, metadata: item["metadata"]),
      status: status,
      command: kind == "shell" ? detail["command"]?.stringValue : nil,
      cwd: kind == "shell" ? detail["cwd"]?.stringValue : nil,
      exitCode: kind == "shell" ? detail["exitCode"]?.intValue : nil,
      errorText: status == .failed ? errorText(item["error"]) : nil
    )

    switch kind {
    case "shell":
      add(&call, id: "output", kind: .code, title: "Output", value: detail["output"])
    case "read":
      add(
        &call, id: "content", kind: .filePreview, title: "File content",
        value: detail["content"], path: detail["filePath"]?.stringValue,
        offset: detail["offset"]?.intValue, limit: detail["limit"]?.intValue)
    case "edit":
      let path = detail["filePath"]?.stringValue
      add(
        &call, id: "diff", kind: .diff, title: "Changes",
        value: detail["unifiedDiff"], path: path)
      if detail["unifiedDiff"]?.stringValue == nil {
        add(
          &call, id: "before", kind: .code, title: "Before", value: detail["oldString"], path: path)
        add(&call, id: "after", kind: .code, title: "After", value: detail["newString"], path: path)
      }
    case "write":
      add(
        &call, id: "content", kind: .filePreview, title: "Written content",
        value: detail["content"], path: detail["filePath"]?.stringValue)
    case "search":
      add(&call, id: "matches", kind: .code, title: "Matches", value: detail["content"])
      let counts = [
        detail["numFiles"]?.intValue.map { "Files: \($0)" },
        detail["numMatches"]?.intValue.map { "Matches: \($0)" },
      ].compactMap { $0 }
      if !counts.isEmpty {
        call.sections.append(
          RemoteToolCallSection(
            id: "counts", kind: .text, title: "Result count",
            content: counts.joined(separator: " · ")))
      }
      if let paths = stringArray(detail["filePaths"]), !paths.isEmpty {
        call.sections.append(
          RemoteToolCallSection(
            id: "files", kind: .text, title: "Files", content: paths.joined(separator: "\n")))
      }
      if let results = objectArray(detail["webResults"]), !results.isEmpty {
        let lines = results.compactMap { result -> String? in
          guard let url = result["url"]?.stringValue else { return nil }
          return [result["title"]?.stringValue, url].compactMap { $0 }.joined(separator: " — ")
        }
        if !lines.isEmpty {
          call.sections.append(
            RemoteToolCallSection(
              id: "web-results", kind: .text, title: "Web results",
              content: lines.joined(separator: "\n")))
        }
      }
      if let annotations = stringArray(detail["annotations"]), !annotations.isEmpty {
        call.sections.append(
          RemoteToolCallSection(
            id: "annotations", kind: .text, title: "Notes",
            content: annotations.joined(separator: "\n")))
      }
    case "fetch":
      add(&call, id: "prompt", kind: .text, title: "Request", value: detail["prompt"])
      add(&call, id: "result", kind: .text, title: "Result", value: detail["result"])
      if let code = detail["code"]?.intValue {
        call.sections.append(
          RemoteToolCallSection(
            id: "http-status", kind: .text, title: "HTTP status",
            content: [String(code), detail["codeText"]?.stringValue].compactMap { $0 }
              .joined(separator: " ")))
      }
    case "worktree_setup":
      add(&call, id: "log", kind: .code, title: "Setup log", value: detail["log"])
      if let commands = objectArray(detail["commands"]) {
        for command in commands {
          guard let index = command["index"]?.intValue else { continue }
          let body = [
            command["command"]?.stringValue,
            command["cwd"]?.stringValue.map { "Directory: \($0)" },
            command["status"]?.stringValue.map { "Status: \($0)" },
            command["exitCode"]?.intValue.map { "Exit code: \($0)" },
            command["log"]?.stringValue,
          ].compactMap { $0 }.joined(separator: "\n")
          if !body.isEmpty {
            call.sections.append(
              RemoteToolCallSection(
                id: "command-\(index)", kind: .code,
                title: "Command \(index)", content: body))
          }
        }
      }
    case "sub_agent":
      add(&call, id: "log", kind: .text, title: "Agent activity", value: detail["log"])
      if let actions = objectArray(detail["actions"]), !actions.isEmpty {
        let lines = actions.compactMap { action -> String? in
          guard let tool = action["toolName"]?.stringValue else { return nil }
          return [tool, action["summary"]?.stringValue].compactMap { $0 }
            .joined(separator: " — ")
        }
        if !lines.isEmpty {
          call.sections.append(
            RemoteToolCallSection(
              id: "actions", kind: .text, title: "Actions",
              content: lines.joined(separator: "\n")))
        }
      }
    case "plain_text":
      add(
        &call, id: "text", kind: .text, title: detail["label"]?.stringValue ?? "Details",
        value: detail["text"])
    case "plan":
      add(&call, id: "plan", kind: .text, title: "Plan", value: detail["text"])
    case "unknown":
      add(&call, id: "input", kind: .text, title: "Input", value: detail["input"])
      add(&call, id: "output", kind: .text, title: "Output", value: detail["output"])
    default:
      if let rawDetail = item["detail"] {
        add(&call, id: "details", kind: .text, title: "Details", value: rawDetail)
      }
    }
    if kind == "search" || kind == "worktree_setup",
      case .bool(true) = detail["truncated"]
    {
      call.sections.append(
        RemoteToolCallSection(
          id: "truncated", kind: .text, title: "Output limit",
          content: "The host truncated this tool output."))
    }
    return call
  }

  private static func status(_ value: String?) -> RemoteToolCall.Status {
    switch value {
    case "running": .running
    case "completed": .completed
    case "failed": .failed
    case "canceled": .canceled
    case .some(let value): .unknown(value)
    case nil: .unknown("updated")
    }
  }

  private static func mergedStatus(_ existing: String, _ incoming: String) -> String {
    if existing == "failed" || incoming == "failed" { return "failed" }
    if existing == "canceled" { return "canceled" }
    if incoming == "canceled" { return existing == "completed" ? "completed" : "canceled" }
    if existing == "completed" || incoming == "completed" { return "completed" }
    return incoming == "running" ? "running" : incoming
  }

  private static func mergeDetail(
    _ existing: PaseoJSONValue?, _ incoming: PaseoJSONValue?
  ) -> PaseoJSONValue? {
    guard let incoming else { return existing }
    guard let old = existing?.objectValue, let new = incoming.objectValue else { return incoming }
    let oldKind = old["type"]?.stringValue
    let newKind = new["type"]?.stringValue
    if oldKind == "unknown", newKind != "unknown" { return incoming }
    if newKind == "unknown", oldKind != "unknown" { return existing }
    guard oldKind == newKind else { return incoming }
    var merged = old.merging(new) { _, next in next }
    if newKind == "unknown" {
      for key in ["input", "output"] {
        if let oldValue = old[key], let newValue = new[key],
          newValue == .null || (!isNonemptyObject(newValue) && isNonemptyObject(oldValue))
        {
          merged[key] = oldValue
        }
      }
    }
    return .object(merged)
  }

  private static func nonnull(_ value: PaseoJSONValue?) -> PaseoJSONValue? {
    guard let value, value != .null else { return nil }
    return value
  }

  private static func isNonemptyObject(_ value: PaseoJSONValue) -> Bool {
    value.objectValue?.isEmpty == false
  }

  private static func title(
    name: String, kind: String?, detail: [String: PaseoJSONValue]
  ) -> String {
    switch kind {
    case "shell": "Shell"
    case "read": "Read"
    case "edit": "Edit"
    case "write": "Write"
    case "search": "Search"
    case "fetch": "Fetch"
    case "worktree_setup": "Worktree setup"
    case "sub_agent": detail["subAgentType"]?.stringValue ?? "Task"
    case "plan": "Plan"
    default:
      switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "task": "Task"
      case "thinking": "Thinking"
      case "terminal": "Terminal"
      default: humanize(name)
      }
    }
  }

  private static func summary(
    name: String, kind: String?, detail: [String: PaseoJSONValue],
    metadata: PaseoJSONValue?
  ) -> String? {
    switch kind {
    case "shell": detail["command"]?.stringValue
    case "read", "edit", "write": detail["filePath"]?.stringValue
    case "search": detail["query"]?.stringValue
    case "fetch": detail["url"]?.stringValue
    case "worktree_setup": detail["branchName"]?.stringValue
    case "sub_agent": detail["description"]?.stringValue
    case "plain_text": detail["label"]?.stringValue
    case "unknown" where name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "task":
      metadata?["subAgentActivity"]?.stringValue
    default: nil
    }
  }

  private static func humanize(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Tool" }
    if trimmed.contains(":") || trimmed.contains("/") || trimmed.contains("__") {
      return trimmed
    }
    let words = trimmed.replacingOccurrences(
      of: #"[._-]+"#, with: " ", options: .regularExpression
    ).split(separator: " ")
    let lower = words.joined(separator: " ").lowercased()
    guard let first = lower.first else { return trimmed }
    return String(first).uppercased() + lower.dropFirst()
  }

  private static func add(
    _ call: inout RemoteToolCall, id: String, kind: RemoteToolCallSection.Kind,
    title: String, value: PaseoJSONValue?, path: String? = nil,
    offset: Int? = nil, limit: Int? = nil
  ) {
    guard let content = displayText(value), !content.isEmpty else { return }
    call.sections.append(
      RemoteToolCallSection(
        id: id, kind: kind, title: title, content: content,
        path: path, offset: offset, limit: limit))
  }

  private static func displayText(_ value: PaseoJSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .null: return nil
    case .string(let text): return text
    default:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard let data = try? encoder.encode(value) else { return nil }
      return String(decoding: data, as: UTF8.self)
    }
  }

  private static func errorText(_ value: PaseoJSONValue?) -> String? {
    if let content = value?["content"]?.stringValue { return content }
    return displayText(value)
  }

  private static func stringArray(_ value: PaseoJSONValue?) -> [String]? {
    guard case .array(let values) = value else { return nil }
    return values.compactMap(\.stringValue)
  }

  private static func objectArray(_ value: PaseoJSONValue?) -> [[String: PaseoJSONValue]]? {
    guard case .array(let values) = value else { return nil }
    return values.compactMap(\.objectValue)
  }
}
