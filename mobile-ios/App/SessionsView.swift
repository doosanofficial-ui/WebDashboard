import SwiftUI
import UniformTypeIdentifiers
import TelemetryCore

struct SessionsView: View {
    @Bindable var model: TelemetryModel
    @State private var scrubSeconds = 0.0
    @State private var isScrubbing = false
    #if DEBUG
    @State private var scrubStartPosition = 0.0
    @State private var playbackAdvancedDuringScrub = false
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingSessionPicker = false
    @State private var seekText = ""
    @State private var seekError: String?
    @FocusState private var seekFieldFocused: Bool
    @State private var exportRequest = MeasurementExportRequest()

    var body: some View {
        let request = exportRequest.request
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                        if model.runMode == .replay {
                            replayHeader()
                            compactReplayControls()
                            ReplayAnalysisView(model: model)
                            replayTimeCard
                            savedSessionCard
                            DisclosureGroup(AppLocalization.text("Session details")) { sessionStats }
                        } else {
                            sessionHero
                            sessionControls
                            sessionStats
                            savedSessionCard
                        }
                        exportCard
                    }
                    .padding(.horizontal, TelemetryTheme.Spacing.medium)
                    .padding(.vertical, TelemetryTheme.Spacing.small)
                }
                .scrollIndicators(.hidden)
                .background(TelemetryTheme.background.ignoresSafeArea())
            }
            .navigationTitle(AppLocalization.text("Sessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.runMode == .replay {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(AppLocalization.text("Stop Replay"), action: model.stopReplay)
                            .accessibilityIdentifier("stop-replay-header")
                    }
                }
            }
            .task { await model.refreshSavedSessions() }
            .sheet(isPresented: $showingSessionPicker) { sessionPickerSheet }
            .fileExporter(
                isPresented: $exportRequest.presented,
                document: exportRequest.data.map { MeasurementExportDocument(data: $0) },
                contentType: request?.format == .csv ? .commaSeparatedText : .json,
                defaultFilename: request?.filename ?? "telemetry-measurements"
            ) { result in
                guard let request, exportRequest.acceptsCompletion(requestID: request.id) else { return }
                let format = request.format == .json ? "JSON" : "CSV"
                switch result {
                case .success: model.exportStatus = "\(format) file saved"
                case .failure: model.exportStatus = "\(format) export cancelled or failed"
                }
                exportRequest.finish(requestID: request.id)
            }
            .onChange(of: exportRequest.presented) { old, new in
                if old && !new, let request = exportRequest.request { exportRequest.finish(requestID: request.id) }
            }
            .onChange(of: model.measurementContextGeneration) { _, _ in exportRequest.cancel() }
            .onChange(of: model.localRecordingEnabled) { _, _ in exportRequest.cancel() }
            .onDisappear { exportRequest.cancel() }

        }
    }

    // Eager header allows hosted rendering of the actual Replay warning region.
    func replayHeader() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TelemetryRunStatusView(model: model)
            if let storageStatus = model.storageStatus {
                Label(AppLocalization.text(storageStatus), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TelemetryTheme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("replay-storage-error")
            }
        }
    }

    // Quick analysis controls reuse the recorded-time controller. Detailed seeking remains below.
    private func compactReplayControls() -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if model.replayController.isPlaying {
                Button { model.pauseReplayPlayback() } label: {
                    Label(AppLocalization.text("Pause"), systemImage: "pause.fill").frame(minHeight: 44)
                }
                .accessibilityIdentifier("session-replay-pause")
            } else {
                Button { model.playReplay() } label: {
                    Label(AppLocalization.text("Play"), systemImage: "play.fill").frame(minHeight: 44)
                }
                .disabled(model.replayController.position >= model.replayController.duration)
                .accessibilityIdentifier("session-replay-play")
            }
            Text(AppLocalization.text(String(format: "%.1f / %.1f s", model.replayController.position, model.replayController.duration)))
                .font(.caption.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(AppLocalization.text("Recorded time"))
                .accessibilityValue(AppLocalization.text(String(format: "%.1f of %.1f seconds", model.replayController.position, model.replayController.duration)))
                .accessibilityIdentifier("session-replay-position")
            Menu {
                ForEach([0.5, 1.0, 2.0], id: \.self) { rate in
                    Button(AppLocalization.text(String(format: "%g×", rate))) { model.setReplayPlaybackRate(rate) }
                }
            } label: {
                Label(AppLocalization.text(String(format: "%g×", model.replayController.playbackRate)), systemImage: "speedometer")
                    .frame(minHeight: 44)
            }
            .disabled(model.replayController.duration <= 0)
            .accessibilityLabel(AppLocalization.text("Replay speed"))
            .accessibilityValue(AppLocalization.text(String(format: "%g times", model.replayController.playbackRate)))
            .accessibilityIdentifier("session-replay-speed")
        }
        .buttonStyle(.bordered).tint(TelemetryTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-replay-quick-controls")
    }

    private var savedSessionCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Label(AppLocalization.text("SAVED SESSIONS"), systemImage: "archivebox")
                .font(.headline)
            Button { showingSessionPicker = true } label: {
                Text(AppLocalization.text(selectedSessionDescription))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.localRecordingEnabled || exportRequest.busy)
            .accessibilityIdentifier("saved-session-picker")
            let actionsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            actionsLayout {
                Button(AppLocalization.text("Refresh")) { Task { await model.refreshSavedSessions() } }
                    .accessibilityIdentifier("refresh-saved-sessions")
                Button(AppLocalization.text("Open Replay")) { Task { await model.replaySelectedSession() } }
                    .disabled(model.selectedSavedSessionID == nil || model.localRecordingEnabled)
                    .accessibilityIdentifier("replay-saved-session")
            }
            .buttonStyle(.bordered)
            if model.runMode == .replay {
                Button(AppLocalization.text("Stop Replay"), action: model.stopReplay)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stop-replay")
            }
            Text(AppLocalization.text(model.archiveStatus)).font(.caption)
            if model.replayController.loading {
                HStack {
                    ProgressView(AppLocalization.text("Loading recording"))
                    Button(AppLocalization.text("Cancel loading"), action: model.stopReplay)
                        .accessibilityIdentifier("cancel-replay-loading")
                }
            }
            Text(AppLocalization.text("Explore recorded time without acquisition or recording. Use CSV/JSON to preserve the original measurements. Play advances only recorded time; seek pauses playback."))
                .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-sessions-card")

    }

    private func sessionDescription(_ session: PersistedMeasurementSession) -> String {
        "\(Date(timeIntervalSince1970: session.startedAt).formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second().locale(Locale(identifier: AppLanguageStore.shared.language.rawValue)))) · \(session.mode.rawValue)\(session.endedAt == nil ? " · " + AppLocalization.text("OPEN") : "")"
    }

    private var selectedSessionDescription: String {
        guard let session = model.savedSessions.first(where: { $0.sessionID == model.selectedSavedSessionID }) else {
            return "Current recording / last stopped"
        }
        return sessionDescription(session)
    }

    private var sessionPickerSheet: some View {
        NavigationStack {
            List {
                Button(AppLocalization.text("Current recording / last stopped")) {
                    model.selectedSavedSessionID = nil
                    showingSessionPicker = false
                }
                ForEach(model.savedSessions, id: \.sessionID) { session in
                    Button {
                        model.selectedSavedSessionID = session.sessionID
                        showingSessionPicker = false
                    } label: {
                        Text(AppLocalization.text(sessionDescription(session)))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("saved-session-" + session.sessionID)
                    .accessibilityAddTraits(session.sessionID == model.selectedSavedSessionID ? .isSelected : [])
                }
            }
            .navigationTitle(AppLocalization.text("Saved sessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.text("Cancel")) { showingSessionPicker = false }
                }
            }
        }
    }

    private var replayTimeCard: some View {
        let hasTimeRange = model.replayController.duration > 0
        let controlsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Label(AppLocalization.text("RECORDED TIME"), systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text(AppLocalization.text(model.replayController.recordingMode == .demo ? "DEMO recording · acquisition off" : "Saved recording · acquisition off"))
                .foregroundStyle(TelemetryTheme.accent)
                .accessibilityIdentifier("replay-recording-origin")
            Text(AppLocalization.text(String(format: "%.1f / %.1f seconds", model.replayController.position, model.replayController.duration)))
                .monospacedDigit()
                .accessibilityIdentifier("replay-position")
            if !hasTimeRange && !model.replayController.loading && model.replayController.snapshot != nil {
                Text(AppLocalization.text(model.replayController.measurementCount == 0
                     ? "No recorded samples · no time range"
                     : "Single recorded instant · no time range"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TelemetryTheme.mutedText)
                    .accessibilityIdentifier("replay-single-instant-hint")
            }
            controlsLayout {
                if model.replayController.isPlaying {
                    Button(AppLocalization.text("Pause")) { model.pauseReplayPlayback() }
                        .accessibilityIdentifier("replay-pause")
                } else {
                    Button(AppLocalization.text("Play")) { model.playReplay() }
                        .disabled(model.replayController.position >= model.replayController.duration)
                        .accessibilityIdentifier("replay-play")
                }
                Picker(AppLocalization.text("Speed"), selection: Binding(get: { model.replayController.playbackRate },
                    set: { model.setReplayPlaybackRate($0) })) {
                    Text(AppLocalization.text("0.5×")).tag(0.5)
                    Text(AppLocalization.text("1×")).tag(1.0)
                    Text(AppLocalization.text("2×")).tag(2.0)
                }
                .pickerStyle(.segmented)
                .disabled(!hasTimeRange)
                .accessibilityIdentifier("replay-speed")
            }
            .buttonStyle(.bordered).controlSize(.large)
            Slider(value: $scrubSeconds, in: 0...max(model.replayController.duration, 0.000_001)) { editing in
                if editing {
                    isScrubbing = true
                    #if DEBUG
                    scrubStartPosition = model.replayController.position
                    playbackAdvancedDuringScrub = false
                    #endif
                    model.pauseReplayPlayback()
                } else {
                    let target = scrubSeconds
                    isScrubbing = false
                    Task { await model.seekReplay(to: target) }
                }
            }
            .disabled(!hasTimeRange)
            .frame(minHeight: 44)
            .accessibilityLabel(AppLocalization.text("Recorded time"))
            .accessibilityValue(AppLocalization.text(String(format: "%.1f of %.1f seconds", model.replayController.position, model.replayController.duration)))
            .accessibilityHint(AppLocalization.text("Adjust recorded time; seeking pauses playback."))
            .accessibilityAdjustableAction { direction in
                let step = max(0.1, model.replayController.duration / 100)
                let target: Double
                switch direction {
                case .increment: target = model.replayController.position + step
                case .decrement: target = model.replayController.position - step
                @unknown default: return
                }
                Task { await model.seekReplay(to: target) }
            }
            .accessibilityIdentifier("replay-time-slider")
            controlsLayout {
                Button(AppLocalization.text("Start")) { Task { await model.seekReplay(to: 0) } }
                    .frame(maxWidth: .infinity)
                    .disabled(!hasTimeRange)
                    .accessibilityIdentifier("replay-seek-start")
                Button(AppLocalization.text("End")) { let end = model.replayController.duration; Task { await model.seekReplay(to: end) } }
                    .frame(maxWidth: .infinity)
                    .disabled(!hasTimeRange)
                    .accessibilityIdentifier("replay-seek-end")
            }
            .buttonStyle(.bordered).controlSize(.large)
            controlsLayout {
                TextField(AppLocalization.text("Seconds"), text: $seekText)
                    .textFieldStyle(.roundedBorder)
                    .focused($seekFieldFocused)
                    .submitLabel(.go)
                    .onSubmit(performSeekFromText)
                    .disabled(!hasTimeRange)
                    .accessibilityLabel(AppLocalization.text("Seek to recorded seconds"))
                    .accessibilityIdentifier("replay-seek-seconds")
                Button(AppLocalization.text("Go"), action: performSeekFromText)
                    .disabled(!hasTimeRange)
                    .accessibilityIdentifier("replay-seek-go")
            }
            .buttonStyle(.bordered).controlSize(.large)
            if let seekError {
                Text(AppLocalization.text(seekError)).font(.caption).foregroundStyle(TelemetryTheme.critical)
                    .accessibilityIdentifier("replay-seek-error")
            }
            if hasTimeRange {
                Text(AppLocalization.text(String(format: "Recorded range: 0–%.1f seconds. Values outside this range seek to the nearest end.", model.replayController.duration)))
                    .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            }
            if model.replayController.duration > 0 && model.replayController.position >= model.replayController.duration {
                Text(AppLocalization.text("End reached · Start to replay"))
                    .font(.caption.weight(.semibold)).foregroundStyle(TelemetryTheme.accent)
                    .accessibilityIdentifier("replay-end-hint")
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--audit-ui-layout") {
                Text(AppLocalization.text("Dynamic Type: " + String(describing: dynamicTypeSize)))
                    .accessibilityIdentifier("ui-dynamic-type-audit")
            }
            #endif
            if model.replayController.seeking { ProgressView(AppLocalization.text("Seeking recorded time")) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--audit-replay-slider") {
                Text(AppLocalization.text(playbackAdvancedDuringScrub ? "Playback advanced during editing" : "Playback held during editing"))
                    .accessibilityIdentifier("slider-editing-audit")
            }
            #endif
            Text(AppLocalization.text("Play and seek rebuild recorded values and MARK without acquisition. Seek pauses playback. Signal freshness is unknown when the recording has no timeout policy. Values and original timestamps remain unchanged."))
                .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-time-card")
        .onAppear { if !isScrubbing { scrubSeconds = model.replayController.position } }
        .onDisappear { isScrubbing = false; seekFieldFocused = false }
        .onChange(of: model.replayController.sessionID) { _, _ in
            seekText = ""; seekError = nil; isScrubbing = false
        }
        .onChange(of: model.replayController.position) { _, value in
            #if DEBUG
            if isScrubbing && value != scrubStartPosition { playbackAdvancedDuringScrub = true }
            #endif
            guard !isScrubbing else { return }
            scrubSeconds = value
        }
    }

    private func performSeekFromText() {
        guard let seconds = Double(seekText), seconds.isFinite else {
            seekError = "Enter a finite number of seconds."
            return
        }
        seekError = nil
        seekFieldFocused = false
        Task { await model.seekReplay(to: seconds) }
    }

    private var sessionHero: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            TelemetryRunStatusView(model: model)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppLocalization.text(model.runMode == .replay ? "REPLAY SNAPSHOT" : model.localRecordingEnabled ? "RECORDING" : "READY TO RECORD"))
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.accent)
                    Text(AppLocalization.text(model.runMode == .replay ? "Saved recording; acquisition is off" : model.localRecordingEnabled ? "Measurement session active" : "Local-first measurement storage"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: model.localRecordingEnabled ? "record.circle.fill" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
            }
            Text(AppLocalization.text(model.runMode == .replay ? "Acquisition and recording are off" : model.localRecordingStatus))
                .font(.caption.monospacedDigit())
                .foregroundStyle(TelemetryTheme.mutedText)
            if let storageStatus = model.storageStatus {
                Label(AppLocalization.text(storageStatus), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TelemetryTheme.critical)
            }
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.large)
        .accessibilityIdentifier("sessions-hero")
    }

    private var sessionControls: some View {
        (dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: TelemetryTheme.Spacing.small))
            : AnyLayout(HStackLayout(spacing: TelemetryTheme.Spacing.small))) {
            Button {
                if model.localRecordingEnabled { model.stopRecording() } else { model.startRecording() }
            } label: {
                Label(AppLocalization.text(model.localRecordingEnabled ? "Stop recording" : "Start recording"),
                      systemImage: model.localRecordingEnabled ? "stop.fill" : "record.circle")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
            .disabled(model.storageStatus != nil || model.runMode == .replay)
            .disabled(exportRequest.busy)
            .accessibilityIdentifier("sessions-toggle-recording")

            Button(action: model.mark) {
                Label(AppLocalization.text("Mark"), systemImage: "flag.fill")
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: TelemetryTheme.Spacing.small) {
            sessionStat("DURATION", model.recordingElapsedSeconds.map(formatDuration) ?? "--:--", "timer")
            sessionStat("MODE", model.runMode.rawValue, "switch.2")
            if TelemetryProductScope.allowsRemoteDelivery { sessionStat("PENDING", String(model.queueDepth), "arrow.up.circle") }
            sessionStat("GPS", model.runMode == .replay ? (model.lastLocation == nil ? "NO SAMPLE" : "RECORDED") : AppLocalization.text(model.locationStatus).uppercased(), "location.fill")
            sessionStat("LAST MARK", model.lastMarkAt?.formatted(date: .omitted, time: .shortened) ?? "NONE", "flag.fill")
        }
        .accessibilityIdentifier("sessions-stats")
    }

    private func sessionStat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(AppLocalization.text(label), systemImage: symbol)
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(AppLocalization.text(value))
                .accessibilityIdentifier("sessions-stat-value-" + label)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
    }

    private func prepareExport(_ format: MeasurementExportRequest.Format) {
        guard let request = exportRequest.begin(format: format, sessionID: model.selectedSavedSessionID, contextGeneration: model.measurementContextGeneration) else { return }
        Task {
            let data = await (format == .json ? model.exportMeasurementJSON() : model.exportMeasurementCSV())
            guard let data else { exportRequest.finish(requestID: request.id); return }
            _ = exportRequest.accept(data, request: request, selectedSessionID: model.selectedSavedSessionID, contextGeneration: model.measurementContextGeneration)
        }
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label(AppLocalization.text("EXPORT"), systemImage: "square.and.arrow.up")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(AppLocalization.text("SQLITE BACKED"))
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(TelemetryTheme.quietText)
            }
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Button(AppLocalization.text("JSON")) { prepareExport(.json) }
                .disabled(exportRequest.busy)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessions-export-json")
                Button(AppLocalization.text("CSV")) { prepareExport(.csv) }
                .disabled(exportRequest.busy)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("sessions-export-csv")
            }
            Text(AppLocalization.text(model.exportStatus))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(AppLocalization.text("Exports preserve original measurement timestamps, receive timestamps, raw CAN frames, decoded signals, GPS, and system events."))
                .font(.caption2)
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions-export-card")
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
