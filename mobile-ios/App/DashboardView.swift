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
                                dashboardCanvas(page, now: timeline.date)
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

    @ViewBuilder
    private func dashboardWidget(_ widget: DashboardWidgetDefinition, now: Date) -> some View {
        let value = widget.signalID.flatMap { model.frame?.sig[$0] }
        let fresh = canDataIsFresh(at: now)
        switch widget.type {
        case .numericGauge:
            numericWidget(widget, value: value, fresh: fresh)
        case .circularGauge:
            circularWidget(widget, value: value, fresh: fresh, semi: false)
        case .semiCircularGauge:
            circularWidget(widget, value: value, fresh: fresh, semi: true)
        case .horizontalBar:
            barWidget(widget, value: value, fresh: fresh, vertical: false)
        case .verticalBar:
            barWidget(widget, value: value, fresh: fresh, vertical: true)
        case .led:
            ledWidget(widget, value: value, fresh: fresh)
        case .statusIcon:
            statusWidget(widget, fresh: fresh)
        case .rawCANHex:
            textWidget(widget, value: model.rawCANText, status: model.adapterStatus)
        case .bitView:
            textWidget(widget, value: bitText, status: model.adapterStatus)
        case .timeSeries:
            timeSeriesWidget(widget)
        case .gps, .map:
            gpsWidget(widget, map: widget.type == .map)
        }
    }

    private func dashboardCanvas(_ page: DashboardPage, now: Date) -> some View {
        let columns = page.orientation == .portrait ? 4 : 6
        let maxRow = max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1)
        return GeometryReader { proxy in
            let cell = max(42, proxy.size.width / CGFloat(columns))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.secondarySystemGroupedBackground))
                ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                    dashboardWidget(widget, now: now)
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

    private func canDataIsFresh(at now: Date) -> Bool {
        guard model.connection == "Connected", let lastFrameAt = model.lastFrameAt else { return false }
        return now.timeIntervalSince(lastFrameAt) <= 1.5
    }

    private func numericWidget(_ widget: DashboardWidgetDefinition,
                               value: Double?, fresh: Bool) -> some View {
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return VStack(alignment: .leading, spacing: 5) {
            widgetHeader(widget, fresh: fresh)
            Text(format(value, decimals: widget.configuration.decimals))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.1), value: value)
            Text(widget.configuration.unit).font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func circularWidget(_ widget: DashboardWidgetDefinition,
                                value: Double?, fresh: Bool, semi: Bool) -> some View {
        let progress = normalized(value, configuration: widget.configuration)
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return VStack(alignment: .leading, spacing: 4) {
            widgetHeader(widget, fresh: fresh)
            ZStack {
                Circle()
                    .trim(from: semi ? 0.5 : 0, to: semi ? 1 : 1)
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(semi ? 0 : -90))
                Circle()
                    .trim(from: semi ? 0.5 : 0, to: semi ? 0.5 + 0.5 * progress : progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(semi ? 0 : -90))
                Text(format(value, decimals: widget.configuration.decimals))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(semi ? 1.7 : 1, contentMode: .fit)
            Text(widget.configuration.unit).font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func barWidget(_ widget: DashboardWidgetDefinition,
                           value: Double?, fresh: Bool, vertical: Bool) -> some View {
        let progress = normalized(value, configuration: widget.configuration)
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return VStack(alignment: .leading, spacing: 6) {
            widgetHeader(widget, fresh: fresh)
            if vertical {
                GeometryReader { proxy in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color)
                            .frame(height: max(2, proxy.size.height * progress))
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView(value: progress)
                    .tint(color)
                Text(format(value, decimals: widget.configuration.decimals))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(widget.configuration.unit).font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func ledWidget(_ widget: DashboardWidgetDefinition,
                           value: Double?, fresh: Bool) -> some View {
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return HStack(spacing: 10) {
            Circle().fill(fresh ? color : .gray).frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text(widget.configuration.label).font(.subheadline.weight(.semibold))
                Text(fresh ? format(value, decimals: widget.configuration.decimals) : "STALE")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func statusWidget(_ widget: DashboardWidgetDefinition, fresh: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(fresh ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading) {
                Text(widget.configuration.label).font(.subheadline.weight(.semibold))
                Text(fresh ? "VALID" : "STALE / DISCONNECTED")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func textWidget(_ widget: DashboardWidgetDefinition,
                            value: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(widget.configuration.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func timeSeriesWidget(_ widget: DashboardWidgetDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(widget.configuration.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Chart(model.points) { point in
                if let signalID = widget.signalID, let value = point.signals[signalID] {
                    LineMark(x: .value("Time", point.time), y: .value("Value", value))
                        .foregroundStyle(.cyan)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func gpsWidget(_ widget: DashboardWidgetDefinition, map: Bool) -> some View {
        let fix = model.lastLocation
        return VStack(alignment: .leading, spacing: 5) {
            Label(widget.configuration.label, systemImage: map ? "map" : "location.fill")
                .font(.subheadline.weight(.semibold))
            Text("\(number(fix?.data.lat, digits: 6)), \(number(fix?.data.lon, digits: 6))")
                .font(.system(.caption, design: .monospaced))
            Text("Speed \(number(fix?.data.spd.map { $0 * 3.6 })) km/h · ±\(number(fix?.data.acc)) m")
                .font(.caption).foregroundStyle(.secondary)
            Text(fix == nil ? "NO FIX" : "GPS FIX")
                .font(.caption2.weight(.bold))
                .foregroundStyle(fix == nil ? .orange : .green)
        }
        .cardStyle()
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func widgetHeader(_ widget: DashboardWidgetDefinition, fresh: Bool) -> some View {
        HStack {
            Text(widget.configuration.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(fresh ? "VALID" : "STALE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(fresh ? .green : .orange)
        }
    }

    private func normalized(_ value: Double?, configuration: DashboardWidgetConfiguration) -> Double {
        guard let value, value.isFinite else { return 0 }
        guard let minimum = configuration.minimum, let maximum = configuration.maximum,
              maximum > minimum else { return 0 }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    private func valueColor(_ value: Double?, configuration: DashboardWidgetConfiguration,
                            fresh: Bool) -> Color {
        guard fresh, let value, value.isFinite else { return .secondary }
        if let critical = configuration.criticalThreshold, value >= critical { return .red }
        if let warning = configuration.warningThreshold, value >= warning { return .orange }
        return .primary
    }

    private var bitText: String {
        guard let payload = model.rawCANText.split(separator: "  ").last else { return "-" }
        return payload.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            .map { String($0, radix: 2).leftPadded(to: 8) }
            .joined(separator: " ")
    }

    private func format(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.*f", decimals, value)
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

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character = "0") -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
