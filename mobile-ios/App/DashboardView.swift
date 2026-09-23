import SwiftUI
import Charts

struct DashboardView: View {
    @Bindable var model: TelemetryModel
    var body: some View {
        TabView {
            NavigationStack {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    ScrollView {
                        VStack(spacing: 16) {
                            connectionSummary(at: timeline.date)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 12) {
                                gauge("FL", key: "ws_fl", unit: "km/h")
                                gauge("FR", key: "ws_fr", unit: "km/h")
                                gauge("RL", key: "ws_rl", unit: "km/h")
                                gauge("RR", key: "ws_rr", unit: "km/h")
                                gauge("Yaw", key: "yaw", unit: "deg/s")
                                gauge("Ay", key: "ay", unit: "m/s2")
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
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("SEQ \(model.frame?.status.seq.description ?? "-")").monospacedDigit()
                Text("Missing \(model.clientDrops) · Server \(model.frame?.status.drop ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
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
            }.navigationTitle("Connection")
        }
    }
}
