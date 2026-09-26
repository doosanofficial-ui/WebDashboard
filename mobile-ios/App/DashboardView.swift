import SwiftUI
import Charts
import TelemetryCore
import UniformTypeIdentifiers

struct DashboardView: View {
    @Bindable var model: TelemetryModel
    @State private var editorPresented = false
    @State private var selectedPageID: String?
    var body: some View {
        TabView {
            NavigationStack {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    ScrollView {
                        VStack(spacing: 16) {
                            connectionSummary(at: timeline.date)
                            adapterCard()
                            if let profile = model.dashboardProfile,
                               let page = profile.pages.first(where: { $0.id == selectedPageID }) ?? profile.pages.first {
                                if profile.pages.count > 1 {
                                    Picker("Dashboard page", selection: Binding(
                                        get: { selectedPageID ?? page.id },
                                        set: { selectedPageID = $0 }
                                    )) {
                                        ForEach(profile.pages) { page in
                                            Text(page.name).tag(page.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .accessibilityIdentifier("live-page-picker")
                                }
                                dashboardCanvas(page)
                                Button("Edit Dashboard") { editorPresented = true }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("edit-dashboard")
                            } else {
                                Text("No dashboard profile loaded")
                                    .foregroundStyle(.secondary)
                            }
                            SignalChart(title: "Wheel speed", points: model.points,
                                        signals: ["ws_fl", "ws_fr"], now: timeline.date)
                            SignalChart(title: "Dynamics", points: model.points,
                                        signals: ["yaw", "ay"], now: timeline.date)
                            locationCard(at: timeline.date)
                            Button(action: model.mark) {
                                Label("MARK EVENT", systemImage: "flag.fill").frame(maxWidth: .infinity).padding(12)
                            }.buttonStyle(.borderedProminent).tint(.orange).disabled(model.storageStatus != nil)
                                .accessibilityIdentifier("mark-event")
                            if let time = model.lastMarkAt {
                                Text("Last mark: \(time.formatted(date: .omitted, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("last-mark")
                            }
                            if let error = model.storageStatus { Text(error).foregroundStyle(.red) }
                            Text("CAN values come from the selected server. Verify its source before a vehicle test.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding()
                    }
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Telemetry")
                .sheet(isPresented: $editorPresented) {
                    DashboardEditorView(model: model)
                }
            }.tabItem { Label("Live", systemImage: "gauge.with.dots.needle.67percent") }
            SettingsView(model: model).tabItem { Label("Connection", systemImage: "network") }
        }.tint(.cyan)
    }

    private func connectionSummary(at now: Date) -> some View {
        let age = model.lastFrameAt.map { now.timeIntervalSince($0) }
        let stale = model.connection != "Connected" || (age ?? .infinity) > 1.5
        return HStack {
            Circle().fill(stale ? .orange : .green).frame(width: 9, height: 9)
            VStack(alignment: .leading) {
                Text(model.connection).font(.headline)
                Text(stale ? "CAN stale" : "CAN live").font(.caption).foregroundStyle(.secondary)
                Text(model.serverRecording?.text ?? "Server CSV status unknown")
                    .font(.caption)
                    .foregroundStyle(model.serverRecording?.isWarning == true ? Color.orange : Color.secondary)
                Text(model.localRecordingStatus)
                    .font(.caption)
                    .foregroundStyle(model.localRecordingStatus.contains("failed") ? Color.red : Color.secondary)
                    .accessibilityIdentifier("local-recording-status")
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("SEQ \(model.frame?.status.seq.description ?? "-")").monospacedDigit()
                Text("Missing \(model.clientDrops) · Server \(model.frame?.status.drop ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func adapterCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("CAN adapter", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Text(model.adapterStatus)
                    .font(.caption)
                    .foregroundStyle(model.adapterStatus.contains("error") ? .red : .secondary)
                    .accessibilityIdentifier("adapter-status")
            }
            Text("RAW \(model.rawCANText)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("Demo signal: \(model.adapterSignalValue.map { String(format: "%.1f", $0) } ?? "-") demo")
                .monospacedDigit()
            Text("Demo only. Live BLE/Wi-Fi requires an observed adapter profile.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(model.adapterProfileStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start demo adapter", action: model.startDemoAdapter)
                    .accessibilityIdentifier("start-adapter-demo")
                Button("Stop adapter", role: .destructive, action: model.stopDemoAdapter)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func gauge(_ title: String, key: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(model.frame?.sig[key].map { String(format: "%.1f", $0) } ?? "-")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.1), value: model.frame?.sig[key])
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func dashboardWidget(_ widget: DashboardWidgetDefinition) -> some View {
        let value = widget.signalID.flatMap { model.frame?.sig[$0] }
        let decimals = widget.configuration.decimals
        return VStack(alignment: .leading, spacing: 5) {
            Text(widget.configuration.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.*f", decimals, $0) } ?? "-")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.1), value: value)
            Text(widget.configuration.unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func dashboardCanvas(_ page: DashboardPage) -> some View {
        let columns = page.orientation == .portrait ? 4 : 6
        let maxRow = max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1)
        return GeometryReader { proxy in
            let cell = max(42, proxy.size.width / CGFloat(columns))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.secondarySystemGroupedBackground))
                ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                    dashboardWidget(widget)
                        .frame(width: max(36, cell * CGFloat(widget.rect.width) - 8),
                               height: max(36, cell * CGFloat(widget.rect.height) - 8),
                               alignment: .topLeading)
                        .position(
                            x: cell * (CGFloat(widget.rect.x) + CGFloat(widget.rect.width) / 2),
                            y: cell * (CGFloat(widget.rect.y) + CGFloat(widget.rect.height) / 2)
                        )
                }
            }
            .frame(height: cell * CGFloat(maxRow), alignment: .top)
        }
        .frame(minHeight: page.orientation == .portrait ? 420 : 300,
               maxHeight: page.orientation == .portrait ? 660 : 500)
        .accessibilityIdentifier("dashboard-canvas-\(page.id)")
    }

    private func locationCard(at now: Date) -> some View {
        let fix = model.lastLocation
        let age = fix.map { max(0, now.timeIntervalSince1970 - $0.capturedAt) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Location", systemImage: "location.fill").font(.headline)
                Spacer()
                Text((age ?? .infinity) > 4 ? "STALE" : "FRESH").font(.caption.weight(.bold))
                    .foregroundStyle((age ?? .infinity) > 4 ? .orange : .green)
            }
            Text(model.locationStatus).font(.subheadline)
            Text("\(number(fix?.data.lat, digits: 6)), \(number(fix?.data.lon, digits: 6))")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text("\(number(fix?.data.spd.map { $0 * 3.6 })) km/h")
                Spacer()
                Text("\(number(fix?.data.hdg)) deg")
                Spacer()
                Text("±\(number(fix?.data.acc)) m")
            }.monospacedDigit()
            Text("Age \(number(age)) s · Pending \(model.queueDepth)")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.uploadStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Start GPS", action: model.startLocation).disabled(model.collecting || model.storageStatus != nil)
                Button("Stop", role: .destructive, action: model.stopLocation).disabled(!model.collecting)
                Spacer()
                Button("Retry upload") { Task { await model.flush(force: true) } }
            }.buttonStyle(.bordered)
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.*f", digits, value)
    }
}

private struct SignalChart: View {
    let title: String
    let points: [CanPoint]
    let signals: [String]
    let now: Date
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Chart(points) { point in
                ForEach(signals, id: \.self) { key in
                    if let value = point.signals[key] {
                        LineMark(x: .value("Time", point.time), y: .value(key, value), series: .value("Signal", key))
                            .foregroundStyle(by: .value("Signal", key))
                    }
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-60)...now)
            .chartXAxis(.hidden)
            .frame(height: 135)
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SettingsView: View {
    @Bindable var model: TelemetryModel
    @State private var credential = ""
    @State private var importingAdapterProfile = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Telemetry server") {
                    TextField("https://laptop.local:8443", text: $model.serverText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("server-url")
                    Text("Use a trusted HTTPS certificate. The Mac or Windows laptop must be reachable on the same network.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Connect", action: model.connect)
                            .accessibilityIdentifier("connect-server")
                        Spacer()
                        Button("Disconnect", action: model.disconnect)
                    }
                    Text(model.connection)
                }
                Section("GPS upload authorization") {
                    SecureField("Pairing credential", text: $credential)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Store securely") {
                        model.saveCredential(credential)
                        credential = ""
                    }.disabled(credential.isEmpty)
                    Text(model.credentialSaved ? "Credential saved in Keychain" : "Not paired")
                    Text("GPS is recorded locally first. Only server-acknowledged events leave the pending queue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Background collection") {
                    Text("Allow Always and Precise Location for a screen-lock test. Stop GPS ends collection. Force-quitting the app can stop collection; no background success is assumed without logs.")
                    Button("Open system settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("CAN adapter profile") {
                    Text(model.adapterProfileStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }.navigationTitle("Connection")
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
        }
    }
}
