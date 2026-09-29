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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                        healthCard(at: timeline.date)
                        filterBar()
                        signalCatalog(at: timeline.date)
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
        let serverLive = model.connection == "Connected"
        let adapterLive = model.adapterStatus.localizedCaseInsensitiveContains("monitoring")
        let live = serverLive || adapterLive
        let color = live ? TelemetryTheme.valid : TelemetryTheme.warning
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Label("ACQUISITION HEALTH", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(TelemetryTheme.accent)
                Spacer()
                TelemetryStatusBadge(
                    title: live ? "Live" : "Idle",
                    color: color,
                    symbol: live ? "checkmark.circle.fill" : "pause.circle.fill"
                )
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(adapterLive ? "Local adapter" : model.canSource.uppercased())
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Server \(model.connection) · Adapter \(model.adapterStatus)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(TelemetryTheme.mutedText)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(frameAge(at: now))
                        .font(.headline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                    Text("FRAME AGE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TelemetryTheme.quietText)
                }
            }
            HStack(spacing: TelemetryTheme.Spacing.small) {
                healthValue("BAD", String(model.invalidFrameCount))
                healthValue("DROP", String(model.clientDrops + (model.frame?.status.drop ?? 0)))
                healthValue("PROFILE", model.adapterProfile?.name ?? "None")
            }
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.small)
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
            if model.adapterProfile == nil && model.frame == nil && model.connection != "Connected" {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No signal source", systemImage: "waveform.slash")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Connect the server or import an observed adapter profile. No placeholder values are shown.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
                .accessibilityIdentifier("signal-source-empty")
            } else if rows.isEmpty {
                ContentUnavailableView("No matching signals", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxWidth: .infinity)
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
        let color = fresh ? TelemetryTheme.valid : TelemetryTheme.warning
        return HStack(spacing: TelemetryTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(row.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(TelemetryTheme.quietText)
                    .lineLimit(1)
            }
            Spacer(minLength: TelemetryTheme.Spacing.small)
            VStack(alignment: .trailing, spacing: 4) {
                Text(format(value, decimals: row.decimals))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fresh ? .white : TelemetryTheme.mutedText)
                    .minimumScaleFactor(0.65)
                HStack(spacing: 4) {
                    Text(row.unit.isEmpty ? "-" : row.unit)
                    Text(fresh ? "VALID" : "STALE")
                        .foregroundStyle(color)
                }
                .font(.caption2.monospacedDigit().weight(.bold))
            }
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signal-row-\(row.id)")
    }

    private func rawCANCard() -> some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label(model.canSource == "Diagnostic" ? "DIAGNOSTIC RESPONSE" : "RAW CAN",
                      systemImage: model.canSource == "Diagnostic" ? "arrow.left.arrow.right" : "hexagon")
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
        .accessibilityIdentifier("adapter-controls")
    }

    private var signalRows: [SignalRow] {
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
            return matchesQuery && (!showStaleOnly || !isFresh(row, at: now))
        }
    }

    private func isFresh(_ row: SignalRow, at now: Date) -> Bool {
        if let received = model.localSignalReceivedAt[row.id],
           model.adapterStatus.localizedCaseInsensitiveContains("monitoring") {
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
