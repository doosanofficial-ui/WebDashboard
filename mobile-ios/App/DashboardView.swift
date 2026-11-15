import SwiftUI
import TelemetryCore
import UIKit

struct DashboardView: View {
    @Bindable var model: TelemetryModel
    @State private var editorPresented = false
    @State private var selectedPageID: String?
    @State private var languageStore = AppLanguageStore.shared

    var body: some View {
        TabView {
            NavigationStack {
                LiveCockpitView(
                    model: model,
                    editorPresented: $editorPresented,
                    selectedPageID: $selectedPageID
                )
                .navigationTitle(AppLocalization.text("Telemetry"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { HelpGuideView(guide: HelpGuide.all[1]) } label: {
                            Label(AppLocalization.text("Help"), systemImage: "questionmark.circle")
                        }.accessibilityIdentifier("live-help")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(AppLocalization.text("Edit"), systemImage: "slider.horizontal.3") {
                            editorPresented = true
                        }
                        .accessibilityIdentifier("edit-dashboard")
                    }
                }
                .sheet(isPresented: $editorPresented) {
                    DashboardEditorView(model: model)
                }
            }
            .tabItem { Label(AppLocalization.text("Live"), systemImage: "gauge.with.dots.needle.67percent") }

            SignalsView(model: model)
                .tabItem { Label(AppLocalization.text("Signals"), systemImage: "waveform.path.ecg") }

            SessionsView(model: model)
                .tabItem { Label(AppLocalization.text("Sessions"), systemImage: "record.circle") }

            SetupView(model: model)
                .tabItem { Label(AppLocalization.text("Setup"), systemImage: "slider.horizontal.3") }

            AppHelpView()
                .tabItem { Label(AppLocalization.text("Help"), systemImage: "questionmark.circle") }
        }
        .environment(\.locale, Locale(identifier: languageStore.language.rawValue))
        .tint(TelemetryTheme.accent)
        .preferredColorScheme(.dark)
    }
}

private struct SetupView: View {
    @Bindable var model: TelemetryModel
    @State private var credential = ""
    @State private var importingAdapterProfile = false
    @State private var exportingAdapterProfile = false
    @State private var adapterProfileDocument: MeasurementExportDocument?
    @State private var signalEditorPresented = false
    @State private var developerExpanded = false
    @State private var bleExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                    LanguagePicker().padding().telemetrySurface(.standard)
                    firstRunCard
                    RecordingActivitySettingsView(model: model)
                    permissionsCard
                    adapterCard
                    developerCard
                }
                .padding(.horizontal, TelemetryTheme.Spacing.medium)
                .padding(.vertical, TelemetryTheme.Spacing.small)
            }
            .scrollIndicators(.hidden)
            .background(TelemetryTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.text("Setup"))
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importingAdapterProfile, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.adapterProfileStatus = "Adapter profile could not be read"
                    return
                }
                model.importAdapterProfile(data)
            }
            .fileExporter(
                isPresented: $exportingAdapterProfile,
                document: adapterProfileDocument,
                contentType: .json,
                defaultFilename: "telemetry-adapter-profile"
            ) { result in
                switch result {
                case .success: model.adapterProfileStatus = "Adapter profile JSON saved"
                case .failure: model.adapterProfileStatus = "Adapter profile export cancelled or failed"
                }
                adapterProfileDocument = nil
            }
            .sheet(isPresented: $signalEditorPresented) {
                if let profile = model.adapterProfile {
                    SignalCatalogEditorView(model: model, profile: profile)
                }
            }
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label(AppLocalization.text("TELEMETRY SERVER"), systemImage: "network")
                    .font(.caption.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(TelemetryTheme.accent)
                Spacer()
                TelemetryStatusBadge(
                    title: model.connection == "Connected" ? "Connected" : "Offline",
                    color: model.connection == "Connected" ? TelemetryTheme.valid : TelemetryTheme.warning,
                    symbol: model.connection == "Connected" ? "checkmark.circle.fill" : "wifi.exclamationmark"
                )
            }
            TextField(AppLocalization.text("https://laptop.local:8443"), text: $model.serverText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("server-url")
            Text(AppLocalization.text("Use the trusted HTTPS origin on the same network. The server must be reachable from the iPhone."))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Button(AppLocalization.text("Connect"), action: model.connect)
                    .buttonStyle(.borderedProminent)
                    .tint(TelemetryTheme.accent)
                    .accessibilityIdentifier("connect-server")
                Button(AppLocalization.text("Disconnect"), action: model.disconnect)
                    .buttonStyle(.bordered)
                    .disabled(model.connection == "Disconnected")
            }
        }
        .telemetrySurface(.raised)
        .accessibilityIdentifier("setup-server-card")
    }

    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            TelemetryRunStatusView(model: model)
            Text(AppLocalization.text("FIRST-RUN CHECKLIST"))
                .font(.caption.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(TelemetryTheme.accent)
            Text(AppLocalization.text("CAN diagnostics, GPS, recording, CSV/JSON and Replay work locally without a server or account."))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            setupStep(
                number: "1",
                title: model.localRecordingEnabled ? "Stop recording" : "Start recording",
                detail: model.localRecordingEnabled ? model.localRecordingStatus : "Open a local SQLite session",
                ready: model.localRecordingEnabled
            ) {
                if model.localRecordingEnabled { model.stopRecording() } else { model.startRecording() }
            }
            setupStep(
                number: "2",
                title: model.collecting ? "Stop GPS" : "Start GPS",
                detail: model.collecting ? model.locationStatus : "Precise location permission required",
                ready: model.collecting
            ) {
                if model.collecting { model.stopLocation() } else { model.startLocation() }
            }
            Text(AppLocalization.text("Use the verified adapter profile below for local CAN diagnostics. Saved recordings and exports are in Sessions."))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-first-run")
    }

    private func setupStep(
        number: String,
        title: String,
        detail: String,
        ready: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Text(AppLocalization.text(number))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(TelemetryTheme.background)
                    .frame(width: 30, height: 30)
                    .background(ready ? TelemetryTheme.valid : TelemetryTheme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.text(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(AppLocalization.text(detail))
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: ready ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(ready ? TelemetryTheme.valid : TelemetryTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(AppLocalization.text(title)), \(AppLocalization.text(detail))")
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Label(AppLocalization.text("Location permissions"), systemImage: "location.shield")
                .font(.headline.weight(.semibold))
            Text(AppLocalization.text("Enable Precise Location for GPS recording. Background location supports an explicitly started session during app switching. No account or pairing credential is required."))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            Button(AppLocalization.text("Open system settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .telemetrySurface(.standard)
        .accessibilityIdentifier("setup-permissions-card")
    }

    private var adapterCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    adapterProfileHeading.fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    adapterProfileState.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                    adapterProfileHeading.fixedSize(horizontal: false, vertical: true)
                    adapterProfileState.fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(AppLocalization.text(model.adapterProfileStatus))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TelemetryTheme.Spacing.small) { adapterProfileActions(wrapping: false) }
                VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) { adapterProfileActions(wrapping: true) }
            }
            Text(AppLocalization.text(model.adapterStatus))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
                .accessibilityIdentifier("setup-live-adapter-status")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TelemetryTheme.Spacing.small) { liveAdapterActions(wrapping: false) }
                VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) { liveAdapterActions(wrapping: true) }
            }
            Text(AppLocalization.text("The profile must contain observed BLE UUIDs or a verified Wi-Fi endpoint. No ELM327 identifiers are guessed."))
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-adapter-card")
    }

    private var adapterProfileHeading: some View {
        Label(AppLocalization.text("ADAPTER PROFILE"), systemImage: "cable.connector.horizontal")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
    }

    private var adapterProfileState: some View {
        Text(AppLocalization.text(model.adapterProfile == nil ? "NOT CONFIGURED" : "LOADED"))
            .font(.caption2.weight(.bold))
            .foregroundStyle(model.adapterProfile == nil ? TelemetryTheme.warning : TelemetryTheme.valid)
    }

    @ViewBuilder private func adapterProfileActions(wrapping: Bool) -> some View {
        Button { importingAdapterProfile = true } label: {
            actionLabel("Import JSON", wrapping: wrapping)
        }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("import-adapter-profile")
        Button(action: exportAdapterProfile) {
            actionLabel("Export JSON", wrapping: wrapping)
        }
            .buttonStyle(.bordered)
            .disabled(model.adapterProfile == nil)
            .accessibilityIdentifier("export-adapter-profile")
        Button { signalEditorPresented = true } label: {
            actionLabel("Edit signals", wrapping: wrapping)
        }
            .buttonStyle(.bordered)
            .disabled(model.adapterProfile == nil)
            .accessibilityIdentifier("edit-signal-catalog")
    }

    @ViewBuilder private func liveAdapterActions(wrapping: Bool) -> some View {
        Button(action: model.startLiveAdapter) {
            actionLabel("Start live adapter", wrapping: wrapping)
        }
        .buttonStyle(.borderedProminent)
        .tint(TelemetryTheme.accent)
        .disabled(model.adapterProfile == nil || model.runMode == .replay)
        .accessibilityIdentifier("start-live-adapter")
        Button(role: .destructive, action: model.stopLiveAdapter) {
            actionLabel("Stop", wrapping: wrapping)
        }
        .buttonStyle(.bordered)
        .disabled(model.runMode == .replay)
        .accessibilityIdentifier("stop-live-adapter")
    }

    private func actionLabel(_ key: String, wrapping: Bool) -> some View {
        Text(AppLocalization.text(key))
            .fixedSize(horizontal: !wrapping, vertical: true)
            .frame(maxWidth: wrapping ? .infinity : nil, alignment: .leading)
    }

    private func exportAdapterProfile() {
        guard let profile = model.adapterProfile else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            adapterProfileDocument = MeasurementExportDocument(data: try encoder.encode(profile))
            exportingAdapterProfile = true
        } catch {
            model.adapterProfileStatus = "Adapter profile export could not be prepared"
        }
    }

    private var developerCard: some View {
        DisclosureGroup(isExpanded: $developerExpanded) {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                DisclosureGroup(isExpanded: $bleExpanded) {
                    VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                        HStack(spacing: TelemetryTheme.Spacing.small) {
                            Button(AppLocalization.text("Scan BLE"), action: model.scanBLE)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("scan-ble-adapters")
                            Button(AppLocalization.text("Stop"), action: model.stopBLEScan)
                                .buttonStyle(.bordered)
                            Button(AppLocalization.text("Copy"), action: model.copyBLEObservation)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("copy-ble-observation")
                            Button(AppLocalization.text("Save"), action: model.saveBLEObservation)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("save-ble-observation")
                        }
                        Text(AppLocalization.text(model.bleDiscoveryStatus))
                            .font(.caption)
                            .foregroundStyle(TelemetryTheme.mutedText)
                            .accessibilityIdentifier("ble-discovery-status")
                        ForEach(model.bleDevices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(AppLocalization.text("\(device.id.uuidString) · RSSI \(device.rssi) · \(device.state)"))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(TelemetryTheme.mutedText)
                                Button(AppLocalization.text("Inspect GATT")) {
                                    model.inspectBLEDevice(device.id)
                                }
                                .buttonStyle(.bordered)
                                Button(AppLocalization.text("Use as Santa Fe diagnostic profile")) {
                                    model.createSantaFeDiagnosticProfile(from: device.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(device.services.isEmpty)
                                .accessibilityIdentifier("use-ble-profile-\(device.id.uuidString)")
                                ForEach(device.services) { service in
                                    Text(AppLocalization.text("Service \(service.id)"))
                                        .font(.caption2.monospaced())
                                    ForEach(service.characteristics) { characteristic in
                                        Text(AppLocalization.text("\(characteristic.id) [\(characteristic.properties.joined(separator: ", "))]"))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(TelemetryTheme.quietText)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.top, TelemetryTheme.Spacing.xSmall)
                } label: {
                    Label(AppLocalization.text("BLE discovery (read-only)"), systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text(AppLocalization.text("Exports are in Sessions. Demo adapter controls stay out of the operator setup path."))
                    .font(.caption)
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            .padding(.top, TelemetryTheme.Spacing.xSmall)
        } label: {
            Label(AppLocalization.text("Developer / diagnostics"), systemImage: "wrench.and.screwdriver")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(TelemetryTheme.Spacing.medium)
        .background(TelemetryTheme.surface, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-developer-card")
    }
}
