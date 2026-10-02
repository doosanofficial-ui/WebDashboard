import SwiftUI
import UniformTypeIdentifiers
import TelemetryCore

struct SessionsView: View {
    @Bindable var model: TelemetryModel
    @State private var exportDocument: MeasurementExportDocument?
    @State private var exportPresented = false
    @State private var csvExportDocument: MeasurementCSVExportDocument?
    @State private var csvExportPresented = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                        sessionHero
                        sessionControls
                        sessionStats
                        savedSessionCard
                        exportCard
                    }
                    .padding(.horizontal, TelemetryTheme.Spacing.medium)
                    .padding(.vertical, TelemetryTheme.Spacing.small)
                }
                .scrollIndicators(.hidden)
                .background(TelemetryTheme.background.ignoresSafeArea())
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.runMode == .replay {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Stop Replay", action: model.stopReplay)
                            .accessibilityIdentifier("stop-replay-header")
                    }
                }
            }
            .task { await model.refreshSavedSessions() }
            .fileExporter(
                isPresented: $exportPresented,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "telemetry-measurements"
            ) { result in
                if case .failure = result { model.exportStatus = "Measurement export failed" }
            }
            .fileExporter(
                isPresented: $csvExportPresented,
                document: csvExportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "telemetry-measurements"
            ) { result in
                if case .failure = result { model.exportStatus = "CSV export failed" }
            }
        }
    }

    private var savedSessionCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Label("SAVED SESSIONS", systemImage: "archivebox")
                .font(.headline)
            Picker("Session", selection: $model.selectedSavedSessionID) {
                Text("Current recording / last stopped").tag(nil as String?)
                ForEach(model.savedSessions, id: \.sessionID) { session in
                    Text("\(Date(timeIntervalSince1970: session.startedAt).formatted(date: .abbreviated, time: .standard)) · \(session.mode.rawValue)\(session.endedAt == nil ? " · OPEN" : "")")
                        .tag(Optional(session.sessionID))
                }
            }
            .disabled(model.localRecordingEnabled)
            .accessibilityIdentifier("saved-session-picker")
            HStack {
                Button("Refresh") { Task { await model.refreshSavedSessions() } }
                    .accessibilityIdentifier("refresh-saved-sessions")
                Button("Replay snapshot") { Task { await model.replaySelectedSession() } }
                    .disabled(model.selectedSavedSessionID == nil || model.localRecordingEnabled)
                    .accessibilityIdentifier("replay-saved-session")
            }
            .buttonStyle(.bordered)
            if model.runMode == .replay {
                Button("Stop Replay", action: model.stopReplay)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stop-replay")
            }
            Text(model.archiveStatus).font(.caption)
            Text("Replay shows the recorded final snapshot, not live data. Select a saved session for CSV/JSON export. Playback and seeking are not yet supported.")
                .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-sessions-card")
        .onChange(of: model.selectedSavedSessionID) { _, _ in model.stopReplay() }
    }

    private var sessionHero: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.runMode == .replay ? "REPLAY SNAPSHOT" : model.localRecordingEnabled ? "RECORDING" : "READY TO RECORD")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.accent)
                    Text(model.runMode == .replay ? "Saved recording; acquisition is off" : model.localRecordingEnabled ? "Measurement session active" : "Local-first measurement storage")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: model.localRecordingEnabled ? "record.circle.fill" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
            }
            Text(model.runMode == .replay ? "Acquisition and recording are off" : model.localRecordingStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(TelemetryTheme.mutedText)
            if let storageStatus = model.storageStatus {
                Label(storageStatus, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TelemetryTheme.critical)
            }
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.large)
        .accessibilityIdentifier("sessions-hero")
    }

    private var sessionControls: some View {
        HStack(spacing: TelemetryTheme.Spacing.small) {
            Button {
                if model.localRecordingEnabled { model.stopRecording() } else { model.startRecording() }
            } label: {
                Label(model.localRecordingEnabled ? "Stop recording" : "Start recording",
                      systemImage: model.localRecordingEnabled ? "stop.fill" : "record.circle")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
            .disabled(model.storageStatus != nil || model.runMode == .replay)
            .accessibilityIdentifier("sessions-toggle-recording")

            Button(action: model.mark) {
                Label("Mark", systemImage: "flag.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.bordered)
            .tint(TelemetryTheme.warning)
            .disabled(model.storageStatus != nil || model.runMode == .replay)
            .accessibilityIdentifier("sessions-mark-event")
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
    }

    private var sessionStats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: TelemetryTheme.Spacing.small) {
            sessionStat("DURATION", model.recordingElapsedSeconds.map(formatDuration) ?? "--:--", "timer")
            sessionStat("MODE", model.runMode.rawValue, "switch.2")
            sessionStat("PENDING", String(model.queueDepth), "arrow.up.circle")
            sessionStat("GPS", model.runMode == .replay ? (model.lastLocation == nil ? "NO SAMPLE" : "RECORDED") : model.locationStatus.uppercased(), "location.fill")
            sessionStat("LAST MARK", model.lastMarkAt?.formatted(date: .omitted, time: .shortened) ?? "NONE", "flag.fill")
        }
        .accessibilityIdentifier("sessions-stats")
    }

    private func sessionStat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(label, systemImage: symbol)
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label("EXPORT", systemImage: "square.and.arrow.up")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("SQLITE BACKED")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(TelemetryTheme.quietText)
            }
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Button("JSON") {
                    Task {
                        guard let data = await model.exportMeasurementJSON() else { return }
                        exportDocument = MeasurementExportDocument(data: data)
                        exportPresented = true
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessions-export-json")
                Button("CSV") {
                    Task {
                        guard let data = await model.exportMeasurementCSV() else { return }
                        csvExportDocument = MeasurementCSVExportDocument(data: data)
                        csvExportPresented = true
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessions-export-csv")
            }
            Text(model.exportStatus)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            Text("Exports preserve original measurement timestamps, receive timestamps, raw CAN frames, decoded signals, GPS, and system events.")
                .font(.caption2)
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.standard)
        .accessibilityIdentifier("sessions-export-card")
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
