import SwiftUI
import Charts
import TelemetryCore

struct LiveCockpitView: View {
    @Bindable var model: TelemetryModel
    @Binding var editorPresented: Bool
    @Binding var selectedPageID: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                    connectionStrip(at: timeline.date)
                    primaryMetric(at: timeline.date)
                    wheelSpeedRail(at: timeline.date)
                    dynamicsCharts(at: timeline.date)
                    locationCard(at: timeline.date)
                    sessionBar()
                    adapterCard()
                    profileSection(at: timeline.date)

                    if let error = model.storageStatus {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TelemetryTheme.critical)
                            .telemetrySurface(.standard)
                    }
                }
                .padding(.horizontal, TelemetryTheme.Spacing.medium)
                .padding(.vertical, TelemetryTheme.Spacing.small)
            }
            .scrollIndicators(.hidden)
            .background(
                LinearGradient(
                    colors: [TelemetryTheme.background, TelemetryTheme.backgroundRaised],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
        }
    }

    private func connectionStrip(at now: Date) -> some View {
        let age = model.lastFrameAt.map { now.timeIntervalSince($0) }
        let fresh = model.connection == "Connected" && (age ?? .infinity) <= 1.5
        let stateColor = fresh ? TelemetryTheme.valid : TelemetryTheme.warning
        return HStack(spacing: TelemetryTheme.Spacing.small) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: fresh ? "antenna.radiowaves.left.and.right" : "wifi.exclamationmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("LIVE TELEMETRY")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(TelemetryTheme.mutedText)
                Text(model.connection.uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text("SEQ \(model.frame?.status.seq.description ?? "-")  ·  DROP \(model.clientDrops + (model.frame?.status.drop ?? 0))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(TelemetryTheme.quietText)
                Text(model.localRecordingStatus)
                    .font(.caption2)
                    .foregroundStyle(TelemetryTheme.quietText)
                    .lineLimit(1)
                    .accessibilityIdentifier("local-recording-status")
            }
            Spacer(minLength: TelemetryTheme.Spacing.small)
            TelemetryStatusBadge(
                title: fresh ? "Live" : "Stale",
                color: stateColor,
                symbol: fresh ? "checkmark.circle.fill" : "pause.circle.fill"
            )
        }
        .telemetrySurface(.raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-status-strip")
    }

    private func primaryMetric(at now: Date) -> some View {
        let fresh = canDataIsFresh(at: now)
        let value = model.frame?.sig["ws_fl"]
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRIMARY SIGNAL")
                        .font(.caption.weight(.bold))
                        .tracking(1.3)
                        .foregroundStyle(TelemetryTheme.accent)
                    Text("Speed")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("FRONT LEFT WHEEL")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(TelemetryTheme.mutedText)
                }
                Spacer()
                Text("CAN 10 HZ")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(format(value, decimals: 1))
                    .font(.system(size: 58, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fresh ? TelemetryTheme.accent : TelemetryTheme.mutedText)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                Text("km/h")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(TelemetryTheme.mutedText)
                Spacer()
                TelemetryStatusBadge(
                    title: fresh ? "Valid" : "Stale",
                    color: fresh ? TelemetryTheme.valid : TelemetryTheme.warning,
                    symbol: fresh ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
            }
            Text("Frame age \(formatAge(model.lastFrameAt, now: now))  ·  \(model.serverRecording?.text ?? "Server recording unknown")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("primary-metric")
    }

    private func wheelSpeedRail(at now: Date) -> some View {
        let fresh = canDataIsFresh(at: now)
        let metrics = [
            ("FL", "ws_fl"),
            ("FR", "ws_fr"),
            ("RL", "ws_rl"),
            ("RR", "ws_rr")
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: TelemetryTheme.Spacing.small)], spacing: TelemetryTheme.Spacing.small) {
            ForEach(metrics, id: \.1) { metric in
                TelemetryMetricCard(
                    label: "WHEEL \(metric.0)",
                    value: format(model.frame?.sig[metric.1], decimals: 1),
                    unit: "km/h",
                    state: fresh ? "VALID" : "STALE",
                    accent: fresh ? .white : TelemetryTheme.mutedText
                )
            }
        }
    }

    private func dynamicsCharts(at now: Date) -> some View {
        let stale = !canDataIsFresh(at: now)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: TelemetryTheme.Spacing.small) {
                TelemetryChartCard(title: "YAW RATE", points: model.points, signals: ["yaw"], now: now, units: "deg/s", stale: stale)
                TelemetryChartCard(title: "LATERAL ACCELERATION", points: model.points, signals: ["ay"], now: now, units: "m/s²", stale: stale)
            }
            VStack(spacing: TelemetryTheme.Spacing.small) {
                TelemetryChartCard(title: "YAW RATE", points: model.points, signals: ["yaw"], now: now, units: "deg/s", stale: stale)
                TelemetryChartCard(title: "LATERAL ACCELERATION", points: model.points, signals: ["ay"], now: now, units: "m/s²", stale: stale)
            }
        }
    }

    private func locationCard(at now: Date) -> some View {
        let fix = model.lastLocation
        let age = fix.map { max(0, now.timeIntervalSince1970 - $0.capturedAt) }
        let fresh = (age ?? .infinity) <= 4
        let color = fresh ? TelemetryTheme.valid : TelemetryTheme.warning
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label("GPS POSITION", systemImage: "location.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                TelemetryStatusBadge(
                    title: fresh ? "Fresh" : "No fix",
                    color: color,
                    symbol: fresh ? "location.fill" : "location.slash.fill"
                )
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(number(fix?.data.lat, digits: 6)), \(number(fix?.data.lon, digits: 6))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Spacer()
                Text(model.locationStatus.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(color)
            }
            HStack(spacing: TelemetryTheme.Spacing.small) {
                locationValue("SPEED", number(fix?.data.spd.map { $0 * 3.6 }) + " km/h")
                locationValue("HEADING", number(fix?.data.hdg) + "°")
                locationValue("ACCURACY", "±" + number(fix?.data.acc) + " m")
            }
            Text("Age \(number(age)) s  ·  Pending \(model.queueDepth)  ·  \(model.uploadStatus)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("location-card")
    }

    private func locationValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(TelemetryTheme.quietText)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionBar() -> some View {
        HStack(spacing: TelemetryTheme.Spacing.small) {
            Button(action: model.mark) {
                Label("MARK", systemImage: "flag.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(TelemetryTheme.warning)
            .disabled(model.storageStatus != nil)
            .accessibilityIdentifier("mark-event")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.localRecordingStatus.contains("active") || model.localRecordingStatus.contains("Writing") ? "RECORDING" : "READY")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(TelemetryTheme.valid)
                Text(model.lastMarkAt.map { "Last mark " + $0.formatted(date: .omitted, time: .standard) } ?? "No mark in session")
                    .font(.caption2)
                    .foregroundStyle(TelemetryTheme.mutedText)
                    .lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
        }
        .padding(.horizontal, TelemetryTheme.Spacing.small)
        .padding(.vertical, TelemetryTheme.Spacing.xSmall)
        .background(TelemetryTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous)
                .stroke(TelemetryTheme.warning.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-mark")
    }

    private func adapterCard() -> some View {
        HStack(spacing: TelemetryTheme.Spacing.small) {
            Image(systemName: "cable.connector.horizontal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TelemetryTheme.accent)
                .frame(width: 34, height: 34)
                .background(TelemetryTheme.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("CAN ADAPTER")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(TelemetryTheme.mutedText)
                Text(model.adapterStatus)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("RAW \(model.rawCANText)  ·  \(model.adapterSignalValue.map { String(format: "%.1f", $0) } ?? "-")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TelemetryTheme.quietText)
                    .lineLimit(1)
            }
            Spacer(minLength: TelemetryTheme.Spacing.xSmall)
            VStack(alignment: .trailing, spacing: TelemetryTheme.Spacing.xSmall) {
                Button("Demo adapter", action: model.startDemoAdapter)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.bordered)
                    .tint(TelemetryTheme.accent)
                    .accessibilityIdentifier("start-adapter-demo")
                Button("Stop", role: .destructive, action: model.stopDemoAdapter)
                    .font(.caption2.weight(.semibold))
            }
        }
        .telemetrySurface(.standard)
        .accessibilityIdentifier("adapter-status")
    }

    @ViewBuilder
    private func profileSection(at now: Date) -> some View {
        if let profile = model.dashboardProfile,
           let page = profile.pages.first(where: { $0.id == selectedPageID }) ?? profile.pages.first {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CUSTOM PROFILE")
                            .font(.caption.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(TelemetryTheme.accent)
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button("Edit", systemImage: "slider.horizontal.3") {
                        editorPresented = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("profile-edit-dashboard")
                }
                if profile.pages.count > 1 {
                    Picker("Dashboard page", selection: Binding(
                        get: { selectedPageID ?? page.id },
                        set: { selectedPageID = $0 }
                    )) {
                        ForEach(profile.pages) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(TelemetryTheme.accent)
                    .accessibilityIdentifier("live-page-picker")
                }
                dashboardCanvas(page, now: now)
            }
        } else {
            ContentUnavailableView("No dashboard profile loaded", systemImage: "rectangle.3.group")
                .foregroundStyle(TelemetryTheme.mutedText)
                .telemetrySurface(.standard)
        }
    }

    private func dashboardCanvas(_ page: DashboardPage, now: Date) -> some View {
        let columns = page.orientation == .portrait ? 4 : 6
        let maxRow = max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1)
        return GeometryReader { proxy in
            let cell = max(42, proxy.size.width / CGFloat(columns))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous)
                    .fill(TelemetryTheme.plot)
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

    private func numericWidget(_ widget: DashboardWidgetDefinition, value: Double?, fresh: Bool) -> some View {
        TelemetryMetricCard(
            label: widget.configuration.label,
            value: format(value, decimals: widget.configuration.decimals),
            unit: widget.configuration.unit,
            state: fresh ? "VALID" : "STALE",
            accent: valueColor(value, configuration: widget.configuration, fresh: fresh)
        )
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func circularWidget(_ widget: DashboardWidgetDefinition,
                                value: Double?, fresh: Bool, semi: Bool) -> some View {
        let progress = normalized(value, configuration: widget.configuration)
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return VStack(alignment: .leading, spacing: 5) {
            widgetHeader(widget, fresh: fresh)
            ZStack {
                Circle()
                    .trim(from: semi ? 0.5 : 0, to: semi ? 1 : 1)
                    .stroke(TelemetryTheme.grid, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(semi ? 0 : -90))
                Circle()
                    .trim(from: semi ? 0.5 : 0, to: semi ? 0.5 + 0.5 * progress : progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(semi ? 0 : -90))
                Text(format(value, decimals: widget.configuration.decimals))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(semi ? 1.7 : 1, contentMode: .fit)
            Text(widget.configuration.unit)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
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
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(color)
                            .frame(height: max(2, proxy.size.height * progress))
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView(value: progress)
                    .tint(color)
                Text(format(value, decimals: widget.configuration.decimals))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Text(widget.configuration.unit)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func ledWidget(_ widget: DashboardWidgetDefinition,
                           value: Double?, fresh: Bool) -> some View {
        let color = valueColor(value, configuration: widget.configuration, fresh: fresh)
        return HStack(spacing: 10) {
            Circle()
                .fill(fresh ? color : TelemetryTheme.quietText)
                .frame(width: 22, height: 22)
                .shadow(color: color.opacity(0.5), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(widget.configuration.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(fresh ? format(value, decimals: widget.configuration.decimals) : "STALE")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            Spacer()
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func statusWidget(_ widget: DashboardWidgetDefinition, fresh: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(fresh ? TelemetryTheme.valid : TelemetryTheme.warning)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(widget.configuration.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(fresh ? "VALID" : "STALE / DISCONNECTED")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            Spacer()
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func textWidget(_ widget: DashboardWidgetDefinition, value: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(widget.configuration.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(3)
            Text(status)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.quietText)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func timeSeriesWidget(_ widget: DashboardWidgetDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(widget.configuration.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TelemetryTheme.mutedText)
            Chart(model.points) { point in
                if let signalID = widget.signalID, let value = point.signals[signalID] {
                    LineMark(x: .value("Time", point.time), y: .value("Value", value))
                        .foregroundStyle(TelemetryTheme.accent)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 90)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func gpsWidget(_ widget: DashboardWidgetDefinition, map: Bool) -> some View {
        let fix = model.lastLocation
        return VStack(alignment: .leading, spacing: 5) {
            Label(widget.configuration.label, systemImage: map ? "map" : "location.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("\(number(fix?.data.lat, digits: 6)), \(number(fix?.data.lon, digits: 6))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
            Text("Speed \(number(fix?.data.spd.map { $0 * 3.6 })) km/h · ±\(number(fix?.data.acc)) m")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(fix == nil ? "NO FIX" : "GPS FIX")
                .font(.caption2.weight(.bold))
                .foregroundStyle(fix == nil ? TelemetryTheme.warning : TelemetryTheme.valid)
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func widgetHeader(_ widget: DashboardWidgetDefinition, fresh: Bool) -> some View {
        HStack {
            Text(widget.configuration.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TelemetryTheme.mutedText)
            Spacer()
            Text(fresh ? "VALID" : "STALE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(fresh ? TelemetryTheme.valid : TelemetryTheme.warning)
        }
    }

    private func canDataIsFresh(at now: Date) -> Bool {
        guard model.connection == "Connected", let lastFrameAt = model.lastFrameAt else { return false }
        return now.timeIntervalSince(lastFrameAt) <= 1.5
    }

    private func normalized(_ value: Double?, configuration: DashboardWidgetConfiguration) -> Double {
        guard let value, value.isFinite,
              let minimum = configuration.minimum,
              let maximum = configuration.maximum,
              maximum > minimum else { return 0 }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    private func valueColor(_ value: Double?, configuration: DashboardWidgetConfiguration,
                            fresh: Bool) -> Color {
        guard fresh, let value, value.isFinite else { return TelemetryTheme.mutedText }
        if let critical = configuration.criticalThreshold, value >= critical { return TelemetryTheme.critical }
        if let warning = configuration.warningThreshold, value >= warning { return TelemetryTheme.warning }
        return .white
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

    private func formatAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "-" }
        return String(format: "%.0f ms", max(0, now.timeIntervalSince(date) * 1000))
    }

    private func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.*f", digits, value)
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character = "0") -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
