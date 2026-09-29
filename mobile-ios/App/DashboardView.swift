import SwiftUI
import TelemetryCore
import UIKit

struct DashboardView: View {
    @Bindable var model: TelemetryModel
    @State private var editorPresented = false
    @State private var selectedPageID: String?

    var body: some View {
        TabView {
            NavigationStack {
                LiveCockpitView(
                    model: model,
                    editorPresented: $editorPresented,
                    selectedPageID: $selectedPageID
                )
                .navigationTitle("Telemetry")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit", systemImage: "slider.horizontal.3") {
                            editorPresented = true
                        }
                        .accessibilityIdentifier("edit-dashboard")
                    }
                }
                .sheet(isPresented: $editorPresented) {
                    DashboardEditorView(model: model)
                }
            }
            .tabItem { Label("Live", systemImage: "gauge.with.dots.needle.67percent") }

            SignalsView(model: model)
                .tabItem { Label("Signals", systemImage: "waveform.path.ecg") }

            SessionsView(model: model)
                .tabItem { Label("Sessions", systemImage: "record.circle") }

            SetupView(model: model)
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
        }
        .tint(TelemetryTheme.accent)
        .preferredColorScheme(.dark)
    }
}

private struct SetupView: View {
    @Bindable var model: TelemetryModel
    @State private var credential = ""
    @State private var importingAdapterProfile = false
    @State private var signalEditorPresented = false
    @State private var developerExpanded = false
    @State private var bleExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                    serverCard
                    firstRunCard
                    permissionsCard
                    adapterCard
                    developerCard
                }
                .padding(.horizontal, TelemetryTheme.Spacing.medium)
                .padding(.vertical, TelemetryTheme.Spacing.small)
            }
            .scrollIndicators(.hidden)
            .background(TelemetryTheme.background.ignoresSafeArea())
            .navigationTitle("Setup")
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
                Label("TELEMETRY SERVER", systemImage: "network")
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
            TextField("https://laptop.local:8443", text: $model.serverText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("server-url")
            Text("Use the trusted HTTPS origin on the same network. The server must be reachable from the iPhone.")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Button("Connect", action: model.connect)
                    .buttonStyle(.borderedProminent)
                    .tint(TelemetryTheme.accent)
                    .accessibilityIdentifier("connect-server")
                Button("Disconnect", action: model.disconnect)
                    .buttonStyle(.bordered)
                    .disabled(model.connection == "Disconnected")
            }
        }
        .telemetrySurface(.raised)
        .accessibilityIdentifier("setup-server-card")
    }

    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text("FIRST-RUN CHECKLIST")
                .font(.caption.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(TelemetryTheme.accent)
            setupStep(
                number: "1",
                title: "Connect to server",
                detail: model.connection,
                ready: model.connection == "Connected"
            ) {
                model.connect()
            }
            setupStep(
                number: "2",
                title: "Start GPS",
                detail: model.collecting ? model.locationStatus : "Precise location permission required",
                ready: model.collecting
            ) {
                if model.collecting { model.stopLocation() } else { model.startLocation() }
            }
            setupStep(
                number: "3",
                title: "Start recording",
                detail: model.localRecordingEnabled ? model.localRecordingStatus : "Open a local SQLite session before driving",
                ready: model.localRecordingEnabled
            ) {
                if model.localRecordingEnabled { model.stopRecording() } else { model.startRecording() }
            }
        }
        .telemetrySurface(.standard)
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
                Text(number)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(TelemetryTheme.background)
                    .frame(width: 30, height: 30)
                    .background(ready ? TelemetryTheme.valid : TelemetryTheme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(detail)
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
        .accessibilityLabel("\(title), \(detail)")
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                    SecureField("Pairing credential", text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Store securely") {
                        model.saveCredential(credential)
                        credential = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(credential.isEmpty)
                    Text(model.credentialSaved ? "Credential saved in Keychain" : "Not paired")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    Text("GPS is recorded locally first. Only server-acknowledged events leave the pending queue.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    Button("Open system settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, TelemetryTheme.Spacing.xSmall)
            } label: {
                Label("Permissions & credentials", systemImage: "lock.shield")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text("Always and Precise Location are required for a locked-screen collection trial.")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityIdentifier("setup-permissions-card")
    }

    private var adapterCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label("ADAPTER PROFILE", systemImage: "cable.connector.horizontal")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(model.adapterProfile == nil ? "NOT CONFIGURED" : "LOADED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(model.adapterProfile == nil ? TelemetryTheme.warning : TelemetryTheme.valid)
            }
            Text(model.adapterProfileStatus)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            HStack(spacing: TelemetryTheme.Spacing.small) {
                Button("Import JSON") { importingAdapterProfile = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("import-adapter-profile")
                Button("Edit signals") { signalEditorPresented = true }
                    .buttonStyle(.bordered)
                    .disabled(model.adapterProfile == nil)
                    .accessibilityIdentifier("edit-signal-catalog")
            }
            Text("The profile must contain observed BLE UUIDs or a verified Wi-Fi endpoint. No ELM327 identifiers are guessed.")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard)
        .accessibilityIdentifier("setup-adapter-card")
    }

    private var developerCard: some View {
        DisclosureGroup(isExpanded: $developerExpanded) {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                HStack(spacing: TelemetryTheme.Spacing.small) {
                    Button("Start live adapter", action: model.startLiveAdapter)
                        .buttonStyle(.borderedProminent)
                        .tint(TelemetryTheme.accent)
                        .disabled(model.adapterProfile == nil)
                        .accessibilityIdentifier("start-live-adapter")
                    Button("Stop", role: .destructive, action: model.stopLiveAdapter)
                        .buttonStyle(.bordered)
                }
                DisclosureGroup(isExpanded: $bleExpanded) {
                    VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                        HStack(spacing: TelemetryTheme.Spacing.small) {
                            Button("Scan BLE", action: model.scanBLE)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("scan-ble-adapters")
                            Button("Stop", action: model.stopBLEScan)
                                .buttonStyle(.bordered)
                            Button("Copy", action: model.copyBLEObservation)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("copy-ble-observation")
                            Button("Save", action: model.saveBLEObservation)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("save-ble-observation")
                        }
                        Text(model.bleDiscoveryStatus)
                            .font(.caption)
                            .foregroundStyle(TelemetryTheme.mutedText)
                            .accessibilityIdentifier("ble-discovery-status")
                        ForEach(model.bleDevices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.subheadline.weight(.semibold))
                                Text("\(device.id.uuidString) · RSSI \(device.rssi) · \(device.state)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(TelemetryTheme.mutedText)
                                Button("Inspect GATT") {
                                    model.inspectBLEDevice(device.id)
                                }
                                .buttonStyle(.bordered)
                                Button("Use as Santa Fe diagnostic profile") {
                                    model.createSantaFeDiagnosticProfile(from: device.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(device.services.isEmpty)
                                .accessibilityIdentifier("use-ble-profile-\(device.id.uuidString)")
                                ForEach(device.services) { service in
                                    Text("Service \(service.id)")
                                        .font(.caption2.monospaced())
                                    ForEach(service.characteristics) { characteristic in
                                        Text("\(characteristic.id) [\(characteristic.properties.joined(separator: ", "))]")
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
                    Label("BLE discovery (read-only)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text("Exports are in Sessions. Demo adapter controls stay out of the operator setup path.")
                    .font(.caption)
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            .padding(.top, TelemetryTheme.Spacing.xSmall)
        } label: {
            Label("Developer / diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(TelemetryTheme.Spacing.medium)
        .background(TelemetryTheme.surface, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-developer-card")
    }
}
