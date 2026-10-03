import Foundation
import SwiftUI
import TelemetryCore

struct SignalsView: View {
    @Bindable var model: TelemetryModel
    @State private var signalEditorPresented = false
    @State private var searchText = ""
    @State private var showStaleOnly = false
    @State private var showDeveloperControls = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let displayDate = model.replayTimestamp.map(Date.init(timeIntervalSince1970:)) ?? timeline.date
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                        healthCard(at: displayDate)
                        filterBar()
                        signalCatalog(at: displayDate)
                        rawCANCard()
                        developerControls()
                    }
                    .padding(.horizontal, TelemetryTheme.Spacing.medium)
                    .padding(.vertical, TelemetryTheme.Spacing.small)
                }
                .scrollIndicators(.hidden)
                .background(TelemetryTheme.background.ignoresSafeArea())
            }
            .navigationTitle("Signals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "slider.horizontal.3") {
                        signalEditorPresented = true
                    }
                    .disabled(model.adapterProfile == nil)
                    .accessibilityIdentifier("signals-edit-catalog")
                }
            }
            .sheet(isPresented: $signalEditorPresented) {
                if let profile = model.adapterProfile {
                    SignalCatalogEditorView(model: model, profile: profile)
                }
            }
        }
    }

    private func healthCard(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            TelemetryRunStatusView(model: model)
            Text(model.runMode == .replay ? "Recorded values · acquisition off" : model.adapterStatus)
                .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            HStack {
                healthValue(model.runMode == .replay ? "RECORDED AGE" : "FRAME AGE", frameAge(at: now))
                healthValue("PROFILE", model.runMode == .replay ? "Recorded signals" : model.adapterProfile?.name ?? "None")
                if model.runMode != .replay { healthValue("INVALID FRAMES", String(model.invalidFrameCount)) }
            }
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signals-health-card")
    }

    private func healthValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(TelemetryTheme.quietText)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterBar() -> some View {
        HStack(spacing: TelemetryTheme.Spacing.small) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(TelemetryTheme.quietText)
                TextField("Filter signal, CAN ID, source", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, TelemetryTheme.Spacing.small)
            .padding(.vertical, 10)
            .background(TelemetryTheme.surface, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.small, style: .continuous))
            Button(showStaleOnly ? "ALL" : "STALE") {
                showStaleOnly.toggle()
            }
            .font(.caption2.weight(.bold))
            .buttonStyle(.bordered)
            .tint(showStaleOnly ? TelemetryTheme.warning : TelemetryTheme.mutedText)
            .accessibilityLabel(showStaleOnly ? "Show all signals" : "Show stale signals")
            .accessibilityIdentifier("signals-stale-filter")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signals-filter-bar")
    }

    private func signalCatalog(at now: Date) -> some View {
        let rows = filteredRows(at: now)
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Text("SIGNAL CATALOG")
                    .font(.caption.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(TelemetryTheme.accent)
                Spacer()
                Text("\(rows.count) ITEMS")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(TelemetryTheme.quietText)
            }
            if (model.runMode == .replay && signalRows.isEmpty) || (model.adapterProfile == nil && model.frame == nil && model.connection != "Connected") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.runMode == .replay ? "No recorded signal at this time" : "No signal source", systemImage: "waveform.slash")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(model.runMode == .replay ? "Seek forward to a recorded signal. Acquisition remains off." : "Choose a saved recording or import a verified adapter profile. No placeholder values are shown.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
                .accessibilityIdentifier("signal-source-empty")
            } else if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showStaleOnly && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No confirmed stale signals" : "No matching signals")
                        .font(.headline)
                    if showStaleOnly && model.runMode == .replay && model.replaySignalFreshness.values.contains(.unknown) {
                        Text("Freshness is unknown for this recording.")
                            .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
                    }
                    Button("Show all signals") { searchText = ""; showStaleOnly = false }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("signals-clear-filters")
                }
                .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
            } else {
                ForEach(rows) { row in
                    signalRow(row, at: now)
                }
            }
        }
        .accessibilityIdentifier("signal-catalog")
    }

    private func signalRow(_ row: SignalRow, at now: Date) -> some View {
        let value = model.frame?.sig[row.id]
        let fresh = isFresh(row, at: now)
        let label = TelemetryDisplayState.signalLabel(value, liveFresh: fresh,
            isReplay: model.runMode == .replay, replayQuality: model.replaySignalQuality[row.id])
        let color = label.contains("INVALID") ? TelemetryTheme.critical
            : model.runMode == .replay ? TelemetryTheme.mutedText : fresh ? TelemetryTheme.valid : TelemetryTheme.warning
        return VStack(alignment: .leading, spacing: 7) {
            Text(row.name)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(format(value, decimals: row.decimals))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(value?.isFinite == true ? .white : TelemetryTheme.mutedText)
                Text(row.unit.isEmpty ? "-" : row.unit)
                    .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            }
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
            if model.runMode == .replay {
                Text(TelemetryDisplayState.freshnessLabel(model.replaySignalFreshness[row.id]))
                    .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            }
            Text(row.detail).font(.caption2.monospaced()).foregroundStyle(TelemetryTheme.quietText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signal-row-\(row.id)")
    }

    private func rawCANCard() -> some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label(model.showingDiagnosticResponse ? "DIAGNOSTIC RESPONSE" : "RAW CAN",
                      systemImage: model.showingDiagnosticResponse ? "arrow.left.arrow.right" : "hexagon")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("READ ONLY")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(TelemetryTheme.warning)
            }
            Text(model.rawCANText)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(2)
            Text("Receive timestamp is the adapter/iPhone arrival time, not a bus transmission timestamp.")
                .font(.caption2)
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.plot)
        .accessibilityIdentifier("raw-can-card")
    }

    private func developerControls() -> some View {
        DisclosureGroup(isExpanded: $showDeveloperControls) {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                HStack(spacing: TelemetryTheme.Spacing.small) {
                    Button("Demo adapter", action: model.startDemoAdapter)
                        .buttonStyle(.borderedProminent)
                        .tint(TelemetryTheme.accentMuted)
                        .accessibilityIdentifier("start-adapter-demo")
                    Button("Stop", role: .destructive, action: model.stopDemoAdapter)
                        .buttonStyle(.bordered)
                }
                HStack(spacing: TelemetryTheme.Spacing.small) {
                    Button("Start live", action: model.startLiveAdapter)
                        .buttonStyle(.bordered)
                        .disabled(model.adapterProfile == nil)
                        .accessibilityIdentifier("start-live-adapter")
                    Button("Stop live", role: .destructive, action: model.stopLiveAdapter)
                        .buttonStyle(.bordered)
                }
                Text("Live adapters require an observed profile; no ELM327 UUIDs or commands are guessed.")
                    .font(.caption)
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            .padding(.top, TelemetryTheme.Spacing.xSmall)
        } label: {
            Label("Developer / Adapter", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(TelemetryTheme.accent)
        }
        .padding(TelemetryTheme.Spacing.small)
        .background(TelemetryTheme.surface, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adapter-controls")
    }

    private var signalRows: [SignalRow] {
        if model.runMode == .replay {
            return model.replaySignalUnits.keys.sorted().map { id in
                SignalRow(id: id, name: id, unit: model.replaySignalUnits[id] ?? "", decimals: 1,
                    detail: "REPLAY · original timestamps · not live acquisition")
            }
        }
        if model.runMode == .demo {
            return (model.frame?.sig.keys.sorted() ?? []).map { id in
                SignalRow(id: id, name: id == "demo.signal" ? "Demo signal" : id,
                    unit: id == "demo.signal" ? "demo" : unit(for: id), decimals: 1,
                    detail: "Synthetic CAN · generated demo signal")
            }
        }
        if let profile = model.adapterProfile {
            let rawRows = profile.signals.map {
                SignalRow(
                    id: $0.id,
                    name: $0.name,
                    unit: $0.unit,
                    decimals: decimals(for: $0.factor),
                    detail: "0x\(String($0.canID, radix: 16, uppercase: true)) · \($0.byteOrder.rawValue.uppercased()) · \($0.bitLength) bit"
                )
            }
            let diagnosticRows = profile.diagnosticQueries.flatMap { query in
                query.signals.map { signal in
                    SignalRow(
                        id: signal.id,
                        name: signal.name,
                        unit: signal.unit,
                        decimals: decimals(for: signal.factor),
                        detail: "DIAGNOSTIC · 0x\(String(query.requestCANID, radix: 16, uppercase: true)) → 0x\(String(query.responseCANID, radix: 16, uppercase: true)) · \(query.service.rawValue) \(query.command) · \(query.pollInterval)s"
                    )
                }
            }
            var rowsByID: [String: SignalRow] = [:]
            for row in rawRows + diagnosticRows { rowsByID[row.id] = row }
            return rowsByID.values.sorted { $0.id < $1.id }
        }
        guard model.frame != nil || model.connection == "Connected" else { return [] }
        return ["ws_fl", "ws_fr", "ws_rl", "ws_rr", "yaw", "ax", "ay"].map { id in
            SignalRow(id: id, name: displayName(for: id), unit: unit(for: id), decimals: 1, detail: "SERVER SNAPSHOT · 10 Hz")
        }
    }

    private func filteredRows(at now: Date) -> [SignalRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return signalRows.filter { row in
            let matchesQuery = query.isEmpty
                || row.id.lowercased().contains(query)
                || row.name.lowercased().contains(query)
                || row.detail.lowercased().contains(query)
                || row.unit.lowercased().contains(query)
            return matchesQuery && (!showStaleOnly || TelemetryDisplayState.matchesStaleFilter(
                model.frame?.sig[row.id], liveFresh: isFresh(row, at: now), isReplay: model.runMode == .replay,
                replayFreshness: model.replaySignalFreshness[row.id]))
        }
    }

    private func isFresh(_ row: SignalRow, at now: Date) -> Bool {
        if model.runMode == .replay { return model.replaySignalFreshness[row.id] == .fresh }
        if let received = model.localSignalReceivedAt[row.id],
           (model.runMode == .replay || model.adapterStatus.localizedCaseInsensitiveContains("monitoring")) {
            let timeout = model.localSignalTimeouts[row.id] ?? 1.5
            return now.timeIntervalSince1970 >= received && now.timeIntervalSince1970 - received <= timeout
        }
        guard model.connection == "Connected", model.frame?.sig[row.id] != nil,
              let received = model.lastFrameAt else { return false }
        return now.timeIntervalSince(received) <= 1.5
    }

    private func frameAge(at now: Date) -> String {
        guard let lastFrameAt = model.lastFrameAt else { return "-" }
        return String(format: "%.0f ms", max(0, now.timeIntervalSince(lastFrameAt) * 1000))
    }

    private func format(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.*f", decimals, value)
    }

    private func decimals(for factor: Double) -> Int {
        abs(factor) < 0.1 ? 2 : 1
    }

    private func displayName(for id: String) -> String {
        switch id {
        case "ws_fl": return "Wheel speed FL"
        case "ws_fr": return "Wheel speed FR"
        case "ws_rl": return "Wheel speed RL"
        case "ws_rr": return "Wheel speed RR"
        case "yaw": return "Yaw rate"
        case "ax": return "Longitudinal accel"
        case "ay": return "Lateral accel"
        default: return id
        }
    }

    private func unit(for id: String) -> String {
        switch id {
        case "ws_fl", "ws_fr", "ws_rl", "ws_rr": return "km/h"
        case "yaw": return "deg/s"
        default: return "m/s2"
        }
    }
}

private struct SignalRow: Identifiable {
    let id: String
    let name: String
    let unit: String
    let decimals: Int
    let detail: String
}
