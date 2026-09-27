import SwiftUI

struct ProviderUsageView: View {
  @Bindable var model: OesapModel

  var body: some View {
    UsageListContent(model: model, contextThreadID: nil)
      .navigationTitle("Usage")
      .navigationBarTitleDisplayMode(.inline)
  }
}

struct UsageDetailsSheet: View {
  @Bindable var model: OesapModel
  let contextThreadID: String

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      UsageListContent(model: model, contextThreadID: contextThreadID)
        .navigationTitle("Usage details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("usage-details-done")
          }
        }
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

struct ContextUsageIndicator: View {
  let usage: RemoteContextUsage?
  var isLoading = false

  private var fraction: Double? {
    guard let fraction = usage?.fractionUsed, fraction.isFinite else { return nil }
    return fraction
  }

  var body: some View {
    HStack(spacing: 6) {
      if let fraction {
        Image(systemName: "chart.pie.fill")
          .font(.subheadline)
          .foregroundStyle(Color.primary)
          .accessibilityHidden(true)
        Text(fractionPercentLabel(fraction))
          .font(.subheadline.weight(.medium))
          .foregroundStyle(Color.primary)
      } else if isLoading {
        ProgressView()
          .controlSize(.small)
          .tint(Color.secondary)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "chart.pie")
          .font(.subheadline)
          .foregroundStyle(Color.secondary)
          .accessibilityHidden(true)
        Text("—")
          .font(.caption)
          .foregroundStyle(Color.primary)
      }
      disclosureIndicator
    }
    .frame(minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Last reported context usage")
    .accessibilityValue(
      fraction.map { "\(fractionPercentLabel($0)) used" }
        ?? (isLoading ? "Loading" : "Unavailable"))
  }

  private var disclosureIndicator: some View {
    Image(systemName: "chevron.right")
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color.secondary)
      .accessibilityHidden(true)
  }

}

private struct UsageValueRow: View {
  let label: String
  let value: String
  let font: Font

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: label)
            .foregroundStyle(Color.primary.opacity(0.75))
          Text(verbatim: value)
            .multilineTextAlignment(.leading)
        }
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: label)
          Spacer(minLength: 10)
          Text(verbatim: value)
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .font(font)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct UsageListContent: View {
  @Bindable var model: OesapModel
  let contextThreadID: String?

  private var contextThread: RemoteThread? {
    guard let contextThreadID else { return nil }
    return model.threads.first { $0.id == contextThreadID }
  }

  private var displayedProviders: [RemoteProviderUsage] {
    guard contextThreadID != nil else { return model.providerUsageProviders }
    guard let providerID = contextThread?.provider else { return [] }
    return model.providerUsageProviders.filter { $0.id == providerID }
  }

  var body: some View {
    List {
      if let contextThread {
        contextSection(thread: contextThread)
      }

      if model.connectionState != .connected {
        offlineSection
      } else if !displayedProviders.isEmpty
        && (model.providerUsageError != nil || model.providerUsageIsStale)
      {
        staleSection
      }

      if model.loadingProviderUsage && displayedProviders.isEmpty {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading provider usage…")
              .foregroundStyle(Color.primary.opacity(0.75))
          }
        }
      } else if displayedProviders.isEmpty {
        emptyProviderSection
      } else {
        ForEach(Array(displayedProviders.enumerated()), id: \.offset) { row in
          ProviderUsageSection(provider: row.element, rowIndex: row.offset)
        }
      }

      if !displayedProviders.isEmpty, let fetchedAt = model.providerUsageFetchedAt {
        Section {
          Text("Host report fetched \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
          Text("Paseo may return cached usage data.")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }
    }
    .refreshable { await refreshUsage() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await refreshUsage() }
        } label: {
          if model.loadingProviderUsage || model.loadingContextUsage {
            ProgressView()
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(
          model.loadingProviderUsage || model.loadingContextUsage
            || model.connectionState != .connected
        )
        .accessibilityLabel("Refresh usage")
        .accessibilityHint(
          "Asks the host for its usage report; the host may return cached results."
        )
        .accessibilityIdentifier("refresh-provider-usage")
      }
    }
    .task { await refreshUsage() }
  }

  private func refreshUsage() async {
    if contextThreadID != nil {
      await model.refreshUsageForSelectedThread()
    } else {
      await model.refreshProviderUsage()
    }
  }

  private func contextSection(thread: RemoteThread) -> some View {
    Section {
      if model.loadingContextUsage && model.contextUsage(for: thread.id) == nil {
        HStack(spacing: 10) {
          ProgressView()
          Text("Loading context usage…")
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      }

      if let usage = model.contextUsage(for: thread.id), !usage.isEmpty {
        if let fraction = usage.fractionUsed, fraction.isFinite {
          Gauge(value: visualFraction(fraction), in: 0...1) {
            Text("Context window used")
          } currentValueLabel: {
            Text(fractionPercentLabel(fraction))
          }
          .accessibilityIdentifier("context-usage-detail-gauge")
        }

        if let usedTokens = usage.usedTokens, usedTokens.isFinite {
          usageValue("Used", value: "\(tokenCountLabel(usedTokens)) tokens")
        }
        if let maxTokens = usage.maxTokens, maxTokens.isFinite {
          usageValue("Context window", value: "\(tokenCountLabel(maxTokens)) tokens")
        }
        if usage.fractionUsed == nil || !(usage.fractionUsed?.isFinite ?? false) {
          Text("A percentage needs both a used count and a positive context-window size.")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
        } else if let fraction = usage.fractionUsed, fraction > 1 {
          Text("Reported use is above the reported context window.")
            .font(.footnote)
            .foregroundStyle(Color.primary.opacity(0.75))
        }
      } else if !model.loadingContextUsage {
        Text("No context usage has been reported for this thread.")
          .font(.subheadline)
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      if let error = model.contextUsageError {
        Label {
          Text(verbatim: error).foregroundStyle(.primary)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.footnote)
      }

      Text("This is the host’s last report and may be from an earlier turn.")
        .font(.footnote)
        .foregroundStyle(Color.primary.opacity(0.75))
    } header: {
      Text("Last reported context")
    }
  }

  private var offlineSection: some View {
    Section {
      Label {
        Text("Host disconnected").foregroundStyle(.primary)
      } icon: {
        Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
      }
      .font(.headline)
      Text(
        displayedProviders.isEmpty
          ? "Reconnect to load provider usage."
          : "Showing the last reported provider usage. Reconnect to refresh it."
      )
      .font(.subheadline)
      .foregroundStyle(Color.primary.opacity(0.75))
      Button("Reconnect") { Task { await model.reconnect() } }
        .disabled(model.connectionState.isBusy || !model.hasSavedConnection)
    }
  }

  private var staleSection: some View {
    Section {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("Showing last reported provider usage")
            .font(.subheadline.weight(.semibold))
          Text(
            model.providerUsageError
              ?? "Paseo may serve cached results; check the host report time below."
          )
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
        }
        Spacer(minLength: 4)
        retryButton
      }
    }
  }

  private var emptyProviderSection: some View {
    Section {
      if !model.providerUsageSupported && model.connectionState == .connected {
        ContentUnavailableView(
          "Quotas unavailable",
          systemImage: "chart.bar.xaxis",
          description: Text(
            model.providerUsageError ?? "This Paseo host doesn’t report provider quota data."
          ).foregroundStyle(Color.primary.opacity(0.75))
        )
        .listRowSeparator(.hidden)
      } else if let error = contextThread == nil ? model.providerUsageError : contextError {
        VStack(alignment: .leading, spacing: 10) {
          ContentUnavailableView(
            "Provider usage unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(verbatim: error).foregroundStyle(Color.primary.opacity(0.75))
          )
          retryButton
        }
        .listRowSeparator(.hidden)
      } else {
        ContentUnavailableView(
          emptyProviderTitle,
          systemImage: "chart.bar.xaxis",
          description: Text(emptyProviderDescription).foregroundStyle(Color.primary.opacity(0.75))
        )
        .listRowSeparator(.hidden)
      }
    }
  }

  private var retryButton: some View {
    Button("Retry") { Task { await refreshUsage() } }
      .font(.subheadline.weight(.medium))
      .disabled(model.loadingProviderUsage || model.loadingContextUsage)
      .accessibilityIdentifier("retry-provider-usage")
  }

  private var contextError: String? {
    model.providerUsageError ?? model.contextUsageError
  }

  private var emptyProviderTitle: String {
    if contextThreadID != nil {
      return contextThread?.provider == nil
        ? "Provider not reported" : "Provider quota not reported"
    }
    return "No quota data reported"
  }

  private var emptyProviderDescription: String {
    if contextThreadID != nil {
      guard let providerID = contextThread?.provider else {
        return "This thread doesn’t identify a provider for quota lookup."
      }
      return "The host hasn’t reported quota for \(providerID)."
    }
    return "The host has not reported provider quota details."
  }

  private func usageValue(_ label: String, value: String) -> some View {
    UsageValueRow(label: label, value: value, font: .subheadline)
  }
}

private struct ProviderUsageSection: View {
  let provider: RemoteProviderUsage
  let rowIndex: Int

  var body: some View {
    Section {
      Label {
        Text(statusLabel).foregroundStyle(.primary)
      } icon: {
        Image(systemName: statusSymbol).foregroundStyle(statusColor)
      }
      .font(.subheadline.weight(.medium))

      if let planLabel = provider.planLabel {
        usageValue("Plan", value: planLabel)
      }
      if let sourceLabel = provider.sourceLabel {
        usageValue("Source", value: sourceLabel)
      }

      ForEach(Array(provider.windows.enumerated()), id: \.offset) { row in
        ProviderUsageWindowRow(
          window: row.element,
          accessibilityID: "provider-usage-window-\(rowIndex)-\(row.offset)")
      }

      ForEach(Array(provider.balances.enumerated()), id: \.offset) { row in
        ProviderUsageBalanceRow(
          balance: row.element,
          accessibilityID: "provider-usage-balance-\(rowIndex)-\(row.offset)")
      }

      ForEach(Array(provider.details.enumerated()), id: \.offset) { row in
        usageValue(row.element.label, value: row.element.value)
      }

      if let error = provider.error {
        Label {
          Text(verbatim: error).foregroundStyle(.primary)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .font(.footnote)
      }

      if provider.windows.isEmpty && provider.balances.isEmpty && provider.details.isEmpty
        && provider.error == nil
      {
        Text("This provider hasn’t reported quota details.")
          .font(.subheadline)
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      if let fetchedAt = provider.fetchedAt {
        Text("Host report fetched \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
      if let nextRefreshAt = provider.nextRefreshAt {
        Text("Next refresh \(nextRefreshAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
    } header: {
      Text(verbatim: provider.displayName)
        .accessibilityIdentifier("provider-usage-\(rowIndex)")
    }
  }

  private var statusLabel: String {
    switch provider.status {
    case .available: "Available"
    case .unavailable: "Unavailable"
    case .error: "Usage report error"
    case .unknown(let value): "Status: \(value)"
    }
  }

  private var statusSymbol: String {
    switch provider.status {
    case .available: "checkmark.circle.fill"
    case .unavailable: "minus.circle"
    case .error: "exclamationmark.circle.fill"
    case .unknown: "questionmark.circle"
    }
  }

  private var statusColor: Color {
    switch provider.status {
    case .available: .green
    case .unavailable: .secondary
    case .error: .red
    case .unknown: .secondary
    }
  }

  private func usageValue(_ label: String, value: String) -> some View {
    UsageValueRow(label: label, value: value, font: .subheadline)
  }
}

private struct ProviderUsageWindowRow: View {
  let window: RemoteProviderUsage.Window
  let accessibilityID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(verbatim: window.label)
        .font(.subheadline.weight(.medium))
        .accessibilityIdentifier(accessibilityID)

      if let remaining = validPercentage(window.remainingPct) {
        usageValue("Remaining", value: percentagePointLabel(remaining))
        Gauge(value: visualPercentage(remaining), in: 0...1) {
          Text("Quota remaining")
        } currentValueLabel: {
          Text(percentagePointLabel(remaining))
        }
        .accessibilityLabel("\(window.label) remaining")
        .tint(toneColor(window.tone))
      }
      if let used = validPercentage(window.usedPct) {
        usageValue("Used", value: percentagePointLabel(used))
        if window.remainingPct == nil {
          Gauge(value: visualPercentage(used), in: 0...1) {
            Text("Quota used")
          } currentValueLabel: {
            Text(percentagePointLabel(used))
          }
          .accessibilityLabel("\(window.label) used")
          .tint(toneColor(window.tone))
        }
      }
      if window.remainingPct == nil && window.usedPct == nil {
        Text("Percentage not reported")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }

      if let resetsAt = window.resetsAt {
        usageValue(
          "Resets", value: resetsAt.formatted(date: .abbreviated, time: .shortened), font: .footnote
        )
      }
      if let runsOutAt = window.runsOutAt {
        usageValue(
          "Runs out", value: runsOutAt.formatted(date: .abbreviated, time: .shortened),
          font: .footnote)
      }
      if let shortfall = validPercentage(window.shortfallPct) {
        usageValue("Shortfall", value: percentagePointLabel(shortfall), font: .footnote)
      }
    }
    .padding(.vertical, 4)
  }

  private func usageValue(_ label: String, value: String, font: Font = .subheadline) -> some View {
    UsageValueRow(label: label, value: value, font: font)
  }
}

private struct ProviderUsageBalanceRow: View {
  let balance: RemoteProviderUsage.Balance
  let accessibilityID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: balance.label)
        .font(.subheadline.weight(.medium))
        .accessibilityIdentifier(accessibilityID)
      if let remaining = validAmount(balance.remaining) {
        usageValue("Remaining", value: amountLabel(remaining, unit: balance.unit))
      }
      if let used = validAmount(balance.used) {
        usageValue("Used", value: amountLabel(used, unit: balance.unit))
      }
      if let limit = validAmount(balance.limit) {
        usageValue("Limit", value: amountLabel(limit, unit: balance.unit))
      }
      if balance.remaining == nil && balance.used == nil && balance.limit == nil {
        Text("Balance not reported")
          .font(.footnote)
          .foregroundStyle(Color.primary.opacity(0.75))
      }
      if let resetsAt = balance.resetsAt {
        usageValue(
          "Resets", value: resetsAt.formatted(date: .abbreviated, time: .shortened), font: .footnote
        )
      }
    }
    .padding(.vertical, 4)
  }

  private func usageValue(_ label: String, value: String, font: Font = .subheadline) -> some View {
    UsageValueRow(label: label, value: value, font: font)
  }
}

private func visualFraction(_ fraction: Double) -> Double {
  min(max(fraction, 0), 1)
}

private func visualPercentage(_ percentagePoints: Double) -> Double {
  min(max(percentagePoints / 100, 0), 1)
}

private func fractionPercentLabel(_ fraction: Double) -> String {
  fraction.formatted(.percent.precision(.fractionLength(0)))
}

private func percentagePointLabel(_ percentagePoints: Double) -> String {
  "\(percentagePoints.formatted(.number.precision(.fractionLength(0))))%"
}

private func validPercentage(_ value: Double?) -> Double? {
  guard let value, value.isFinite else { return nil }
  return value
}

private func validAmount(_ value: Double?) -> Double? {
  guard let value, value.isFinite else { return nil }
  return value
}

private func amountLabel(_ value: Double, unit: String) -> String {
  if unit.lowercased() == "usd" {
    return value.formatted(.currency(code: "USD").precision(.fractionLength(2...8)))
  }
  return "\(value.formatted(.number.precision(.fractionLength(0...8)))) \(unit)"
}

private func tokenCountLabel(_ value: Double) -> String {
  value.formatted(.number.precision(.fractionLength(0...2)))
}

private func toneColor(_ tone: RemoteProviderUsage.Tone?) -> Color {
  switch tone {
  case .default, .unknown, nil: .accentColor
  case .ok: .green
  case .warning: .orange
  case .danger: .red
  }
}
