import SwiftUI

struct ToolCallCard: View {
  let call: RemoteToolCall
  let rowID: String
  @Binding var isExpanded: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var presentedSection: RemoteToolCallSection?

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 14) {
        if hasNoDetails {
          Text("This tool has not provided additional details.")
            .font(.subheadline)
            .foregroundStyle(Color.primary.opacity(0.75))
        }

        if let command = call.command, !command.isEmpty {
          ToolCallSectionCard(
            callID: rowID,
            section: RemoteToolCallSection(
              id: "command", kind: .code, title: "Command", content: command, language: "shell")
          ) {
            presentedSection = RemoteToolCallSection(
              id: "command", kind: .code, title: "Command", content: command, language: "shell")
          }
        }

        if let cwd = call.cwd, !cwd.isEmpty {
          ToolCallSectionCard(
            callID: rowID,
            section: RemoteToolCallSection(
              id: "cwd", kind: .filePreview, title: "Working directory", content: cwd)
          ) {
            presentedSection = RemoteToolCallSection(
              id: "cwd", kind: .filePreview, title: "Working directory", content: cwd)
          }
        }

        if let exitCode = call.exitCode {
          Label {
            Text("Exit code \(exitCode)").foregroundStyle(.primary)
          } icon: {
            Image(systemName: exitCode == 0 ? "checkmark.circle" : "xmark.circle")
              .foregroundStyle(exitCode == 0 ? Color.green : Color.red)
          }
          .font(.subheadline)
        }

        ForEach(call.sections) { section in
          ToolCallSectionCard(callID: rowID, section: section) {
            presentedSection = section
          }
        }

        if let errorText = call.errorText, !errorText.isEmpty {
          ToolCallSectionCard(
            callID: rowID,
            section: RemoteToolCallSection(
              id: "error-\(rowID)", kind: .text, title: "Error", content: errorText)
          ) {
            presentedSection = RemoteToolCallSection(
              id: "error-\(rowID)", kind: .text, title: "Error", content: errorText)
          }
        }
      }
      .padding(.top, 12)
      .multilineTextAlignment(.leading)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        callHeader

        if let summary = call.summary, !summary.isEmpty,
          summary != call.command
        {
          Text(verbatim: summary)
            .font(.subheadline)
            .foregroundStyle(Color.primary.opacity(0.75))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !isExpanded, let command = call.command, !command.isEmpty {
          Text(verbatim: command)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !isExpanded, let cwd = call.cwd, !cwd.isEmpty {
          HStack(spacing: 5) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text(verbatim: cwd)
          }
          .font(.caption)
          .foregroundStyle(Color.primary.opacity(0.75))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .multilineTextAlignment(.leading)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("tool-call-disclosure-\(rowID)")
    }
    .tint(.primary)
    .padding(14)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .sheet(item: $presentedSection) { section in
      ToolCallFullSectionSheet(section: section)
    }
  }

  @ViewBuilder
  private var callHeader: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 8) {
        callTitle
        callStatusBadge
      }
    } else {
      HStack(alignment: .top, spacing: 10) {
        callStatusIcon
        callTitle
        Spacer(minLength: 4)
        callStatusBadge
      }
    }
  }

  private var callStatusIcon: some View {
    Image(systemName: call.status.symbol)
      .font(.title3.weight(.semibold))
      .foregroundStyle(call.status.color)
      .frame(width: 26)
      .accessibilityHidden(true)
  }

  private var callTitle: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: call.title.isEmpty ? call.name : call.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        .fixedSize(horizontal: false, vertical: true)
      if call.name.localizedCaseInsensitiveCompare(call.title) != .orderedSame {
        Text(verbatim: call.name)
          .font(.caption)
          .foregroundStyle(Color.primary.opacity(0.75))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      }
    }
  }

  private var callStatusBadge: some View {
    Text(verbatim: call.status.label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(call.status.color.opacity(0.12), in: Capsule())
  }

  private var hasNoDetails: Bool {
    (call.command?.isEmpty ?? true)
      && (call.cwd?.isEmpty ?? true)
      && call.exitCode == nil
      && (call.errorText?.isEmpty ?? true)
      && call.sections.isEmpty
  }

}

private struct ToolCallSectionCard: View {
  let callID: String
  let section: RemoteToolCallSection
  var onOpenFull: () -> Void

  private let previewCharacterLimit = 1_800
  private let previewLineLimit = 12

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var boundedPreview: (text: String, hasMore: Bool) {
    let end =
      section.content.index(
        section.content.startIndex,
        offsetBy: previewCharacterLimit,
        limitedBy: section.content.endIndex
      ) ?? section.content.endIndex
    let prefix = String(section.content[..<end])
    let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
    let hasMore = end < section.content.endIndex || lines.count > previewLineLimit
    var text = lines.prefix(previewLineLimit).joined(separator: "\n")
    if hasMore { text += "\n…" }
    return (text, hasMore)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 3) {
            sectionHeading
            sectionLanguage
          }
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            sectionHeading
            sectionLanguage
          }
        }
      }

      if let path = section.path, !path.isEmpty {
        Text(verbatim: path)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Color.primary.opacity(0.75))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      let location = [
        section.offset.map { "Offset \($0)" },
        section.limit.map { "Limit \($0)" },
      ].compactMap { $0 }.joined(separator: " · ")
      if !location.isEmpty {
        Text(location)
          .font(.caption2)
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      switch section.kind {
      case .text:
        Text(verbatim: boundedPreview.text)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      case .code, .filePreview:
        ToolMonospacedBlock(content: boundedPreview.text)
      case .diff:
        ToolDiffBlock(content: boundedPreview.text)
      }

      if boundedPreview.hasMore {
        Button(action: onOpenFull) {
          Label(
            section.title.localizedCaseInsensitiveCompare("output") == .orderedSame
              ? "View full output" : "View full details",
            systemImage: "arrow.up.left.and.arrow.down.right"
          )
          .font(.subheadline.weight(.medium))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("tool-call-full-\(callID)-\(section.id)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .multilineTextAlignment(.leading)
  }

  private var sectionHeading: some View {
    Text(verbatim: section.title.isEmpty ? "Details" : section.title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color.primary.opacity(0.75))
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      .multilineTextAlignment(.leading)
  }

  @ViewBuilder
  private var sectionLanguage: some View {
    if let language = section.language, !language.isEmpty {
      Text(verbatim: language)
        .font(.caption2)
        .foregroundStyle(Color.primary.opacity(0.75))
    }
  }
}

private struct ToolMonospacedBlock: View {
  let content: String

  var body: some View {
    Text(verbatim: content)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(.primary)
      .textSelection(.enabled)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct ToolDiffBlock: View {
  let content: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(
        Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
        id: \.offset
      ) {
        _, line in
        Text(verbatim: String(line).isEmpty ? " " : String(line))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(color(for: line))
          .textSelection(.enabled)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 1)
          .background(backgroundColor(for: line))
      }
    }
    .padding(.vertical, 8)
    .multilineTextAlignment(.leading)
    .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
  }

  private func color(for _: Substring) -> Color { .primary }

  private func backgroundColor(for line: Substring) -> Color {
    if line.hasPrefix("+") { return .green.opacity(0.08) }
    if line.hasPrefix("-") { return .red.opacity(0.08) }
    return .clear
  }
}

private struct ToolCallFullSectionSheet: View {
  let section: RemoteToolCallSection

  @Environment(\.dismiss) private var dismiss
  @State private var visibleRanges: [Range<String.Index>]
  private let rangesPerPage = 2

  init(section: RemoteToolCallSection) {
    self.section = section
    _visibleRanges = State(
      initialValue: Self.nextRanges(
        in: section.content, startingAt: section.content.startIndex, count: 2)
    )
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if let path = section.path, !path.isEmpty {
            Text(verbatim: path)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(Color.primary.opacity(0.75))
              .lineLimit(3)
              .textSelection(.enabled)
          }

          ForEach(Array(visibleRanges.enumerated()), id: \.offset) { _, range in
            let content = String(section.content[range])
            switch section.kind {
            case .text:
              Text(verbatim: content)
                .font(.body)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            case .code, .filePreview:
              ToolMonospacedBlock(content: content)
            case .diff:
              ToolDiffBlock(content: content)
            }
          }

          if let lastRange = visibleRanges.last, lastRange.upperBound < section.content.endIndex {
            Button {
              visibleRanges.append(
                contentsOf: Self.nextRanges(
                  in: section.content, startingAt: lastRange.upperBound, count: rangesPerPage))
            } label: {
              Text(
                section.title.localizedCaseInsensitiveCompare("output") == .orderedSame
                  ? "Load more output" : "Load more details"
              )
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("tool-call-load-more-output")
          }
        }
        .padding()
      }
      .navigationTitle(Text(verbatim: section.title.isEmpty ? "Tool details" : section.title))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("tool-call-full-output-done")
        }
      }
    }
    .presentationDetents([.large])
  }

  private static func nextRanges(
    in content: String,
    startingAt start: String.Index,
    count: Int,
    size: Int = 5_000
  ) -> [Range<String.Index>] {
    guard !content.isEmpty else { return [content.startIndex..<content.endIndex] }
    var ranges: [Range<String.Index>] = []
    var cursor = start
    for _ in 0..<count where cursor < content.endIndex {
      let end =
        content.index(cursor, offsetBy: size, limitedBy: content.endIndex) ?? content.endIndex
      ranges.append(cursor..<end)
      cursor = end
    }
    return ranges
  }
}

extension RemoteToolCall.Status {
  fileprivate var label: String {
    switch self {
    case .running: "Running"
    case .completed: "Completed"
    case .failed: "Failed"
    case .canceled: "Canceled"
    case .unknown(let value): value.isEmpty ? "Unknown" : value
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .running: "arrow.clockwise"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .canceled: "slash.circle.fill"
    case .unknown: "questionmark.circle"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .running: .blue
    case .completed: .green
    case .failed: .red
    case .canceled, .unknown: .secondary
    }
  }
}
