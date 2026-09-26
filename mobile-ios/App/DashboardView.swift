import SwiftUI
import TelemetryCore
import UniformTypeIdentifiers
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

            SettingsView(model: model)
                .tabItem { Label("Connection", systemImage: "network") }
        }
        .tint(TelemetryTheme.accent)
        .preferredColorScheme(.dark)
    }
}

private struct SettingsView: View {
    @Bindable var model: TelemetryModel
    @State private var credential = ""
    @State private var importingAdapterProfile = false
    @State private var exportDocument: MeasurementExportDocument?
    @State private var exportPresented = false
    @State private var csvExportDocument: MeasurementCSVExportDocument?
    @State private var csvExportPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Telemetry server") {
                    TextField("https://laptop.local:8443", text: $model.serverText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("server-url")
                    Text("Use a trusted HTTPS certificate. The Mac or Windows laptop must be reachable on the same network.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    HStack {
                        Button("Connect", action: model.connect)
                            .accessibilityIdentifier("connect-server")
                        Spacer()
                        Button("Disconnect", action: model.disconnect)
                    }
                    Text(model.connection)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.connection == "Connected" ? TelemetryTheme.valid : TelemetryTheme.warning)
                }
                Section("GPS upload authorization") {
                    SecureField("Pairing credential", text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Store securely") {
                        model.saveCredential(credential)
                        credential = ""
                    }
                    .disabled(credential.isEmpty)
                    Text(model.credentialSaved ? "Credential saved in Keychain" : "Not paired")
                    Text("GPS is recorded locally first. Only server-acknowledged events leave the pending queue.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                Section("Background collection") {
                    Text("Allow Always and Precise Location for a screen-lock test. Stop GPS ends collection. Force-quitting the app can stop collection; no background success is assumed without logs.")
                    Button("Open system settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Section("Local measurement export") {
                    Button("Export measurement JSON") {
                        Task {
                            guard let data = await model.exportMeasurementJSON() else { return }
                            exportDocument = MeasurementExportDocument(data: data)
                            exportPresented = true
                        }
                    }
                    .accessibilityIdentifier("export-measurement-json")
                    Button("Export measurement CSV") {
                        Task {
                            guard let data = await model.exportMeasurementCSV() else { return }
                            csvExportDocument = MeasurementCSVExportDocument(data: data)
                            csvExportPresented = true
                        }
                    }
                    .accessibilityIdentifier("export-measurement-csv")
                    Text(model.exportStatus)
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                        .accessibilityIdentifier("measurement-export-status")
                    Text("Exports the current SQLite-backed session with original measurement and receive timestamps.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                Section("CAN adapter profile") {
                    Text(model.adapterProfileStatus)
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    Button("Import adapter profile JSON") {
                        importingAdapterProfile = true
                    }
                    .accessibilityIdentifier("import-adapter-profile")
                    Button("Start live adapter", action: model.startLiveAdapter)
                        .accessibilityIdentifier("start-live-adapter")
                        .disabled(model.adapterProfile == nil)
                    Button("Stop live adapter", role: .destructive, action: model.stopLiveAdapter)
                    Text("BLE requires observed service/write/notify UUIDs. Wi-Fi requires an observed TCP endpoint. No adapter identifiers are guessed.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                Section("BLE discovery (read-only probe)") {
                    HStack {
                        Button("Scan BLE", action: model.scanBLE)
                            .accessibilityIdentifier("scan-ble-adapters")
                        Button("Stop", action: model.stopBLEScan)
                        Button("Copy observation", action: model.copyBLEObservation)
                    }
                    Text(model.bleDiscoveryStatus)
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    ForEach(model.bleDevices) { device in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(device.id.uuidString) · RSSI \(device.rssi) · \(device.state)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(TelemetryTheme.mutedText)
                            Button("Inspect GATT") {
                                model.inspectBLEDevice(device.id)
                            }
                            .font(.caption.weight(.semibold))
                            ForEach(device.services) { service in
                                Text("Service \(service.id)")
                                    .font(.caption2.monospaced())
                                ForEach(service.characteristics) { characteristic in
                                    Text("  \(characteristic.id) [\(characteristic.properties.joined(separator: ", "))]")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(TelemetryTheme.quietText)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                    Text("Scan lists advertisements. Inspect GATT connects only to the selected device, reads service metadata, and never writes commands or assumes ELM327 UUIDs.")
                        .font(.caption)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TelemetryTheme.background)
            .navigationTitle("Connection")
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
                isPresented: $exportPresented,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "telemetry-measurements"
            ) { result in
                if case .failure = result {
                    model.exportStatus = "Measurement export failed"
                }
            }
            .fileExporter(
                isPresented: $csvExportPresented,
                document: csvExportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "telemetry-measurements"
            ) { result in
                if case .failure = result {
                    model.exportStatus = "CSV export failed"
                }
            }
        }
    }
}
