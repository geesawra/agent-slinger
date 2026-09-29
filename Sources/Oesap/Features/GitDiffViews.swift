import SwiftUI

struct GitChangesIndicator: View {
  let status: RemoteGitStatus?
  let isLoading: Bool
  let error: String?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.left.arrow.right")
        .font(.subheadline)
        .accessibilityHidden(true)
      if let status {
        changeCount(status.additions, prefix: "+", color: .green)
        changeCount(status.deletions, prefix: "−", color: .red)
      } else if isLoading {
        ProgressView().controlSize(.small)
          .accessibilityHidden(true)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: 44)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Git changes")
    .accessibilityValue(
      status.map { "\($0.additions) additions, \($0.deletions) deletions" }
        ?? (isLoading ? "Loading" : error == nil ? "Unavailable" : "Error"))
  }

  private func changeCount(_ count: Int, prefix: String, color: Color) -> some View {
    Text("\(prefix)\(count)")
      .font(.system(.subheadline, design: .monospaced).weight(.semibold))
      .foregroundStyle(color)
      .fixedSize()
  }
}

struct GitChangesListSheet: View {
  @Bindable var model: OesapModel
  let threadID: String

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if model.loadingGitStatus && model.gitStatus == nil {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading Git status…")
              .foregroundStyle(.secondary)
          }
        } else if let status = model.gitStatus {
          if status.files.isEmpty {
            ContentUnavailableView(
              "Working tree is clean",
              systemImage: "checkmark.circle",
              description: Text("There are no changed files in this repository.")
            )
            .listRowSeparator(.hidden)
          } else {
            Section {
              ForEach(status.files) { file in
                NavigationLink(value: file.path) {
                  GitChangedFileRow(file: file)
                }
                .accessibilityIdentifier("git-diff-file-\(file.id)")
              }
            } header: {
              HStack {
                Text("Changed files")
                Spacer()
                Text("+\(status.additions)  −\(status.deletions)")
                  .font(.system(.caption, design: .monospaced).weight(.semibold))
                  .foregroundStyle(.secondary)
              }
            }
          }
        } else if let error = model.gitStatusError {
          ContentUnavailableView {
            Label("Git status unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(verbatim: error)
          } actions: {
            Button("Try again") { refresh() }
              .disabled(model.loadingGitStatus)
          }
          .listRowSeparator(.hidden)
        } else {
          ContentUnavailableView(
            "Git status unavailable",
            systemImage: "arrow.clockwise",
            description: Text("Refresh to check this agent’s working tree.")
          )
          .listRowSeparator(.hidden)
        }
      }
      .navigationTitle("Git changes")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: String.self) { path in
        GitDiffFileDetailView(model: model, threadID: threadID, path: path)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: refresh) {
            if model.loadingGitStatus {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(model.loadingGitStatus)
          .accessibilityLabel("Refresh Git status")
          .accessibilityIdentifier("git-diff-refresh")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("git-diff-done")
        }
      }
    }
    .presentationDetents([.large])
  }

  private func refresh() {
    Task { await model.refreshGitStatus(threadID: threadID) }
  }
}

private struct GitChangedFileRow: View {
  let file: RemoteGitChangedFile

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: file.path)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let fileStatus = file.status, !fileStatus.isEmpty {
          Text(verbatim: fileStatus)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 4)

      HStack(spacing: 7) {
        Text("+\(file.additions)").foregroundStyle(.green)
        Text("−\(file.deletions)").foregroundStyle(.red)
      }
      .font(.system(.caption, design: .monospaced).weight(.semibold))
      .fixedSize()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(file.additions) additions, \(file.deletions) deletions")
    }
    .padding(.vertical, 3)
  }
}

private struct GitDiffFileDetailView: View {
  @Bindable var model: OesapModel
  let threadID: String
  let path: String

  @State private var wrapsLines = true

  private var diff: String? { model.gitDiffByPath[path] }
  private var error: String? { model.gitDiffErrorByPath[path] }
  private var isBusy: Bool { model.loadingGitStatus }

  var body: some View {
    Group {
      if let diff {
        ScrollView {
          ToolDiffBlock(content: diff, wrapsLines: wrapsLines)
            .padding()
        }
        .accessibilityIdentifier("git-diff-content")
      } else if isBusy {
        ProgressView("Loading diff…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = error ?? model.gitStatusError {
        ContentUnavailableView {
          Label("Diff unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(verbatim: error)
        } actions: {
          Button("Try again") { refreshAndLoadDiff() }
            .disabled(isBusy)
        }
      } else if model.gitStatus?.files.contains(where: { $0.path == path }) == false {
        ContentUnavailableView(
          "File no longer changed",
          systemImage: "checkmark.circle",
          description: Text("Refresh the file list to choose another change.")
        )
      } else {
        ProgressView("Loading diff…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(path.components(separatedBy: "/").last ?? path)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          wrapsLines.toggle()
        } label: {
          Label(
            wrapsLines ? "Disable line wrapping" : "Enable line wrapping",
            systemImage: wrapsLines ? "text.alignleft" : "text.justify"
          )
        }
        .accessibilityIdentifier("git-diff-toggle-line-wrapping")
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: refreshAndLoadDiff) {
          if isBusy {
            ProgressView()
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(isBusy)
        .accessibilityLabel("Refresh file diff")
        .accessibilityIdentifier("git-diff-file-refresh")
      }
    }
    .task(id: "\(threadID)-\(path)") {
      await model.loadGitDiff(threadID: threadID, path: path)
    }
  }

  private func refreshAndLoadDiff() {
    Task {
      await model.refreshGitStatus(threadID: threadID)
      await model.loadGitDiff(threadID: threadID, path: path)
    }
  }
}
