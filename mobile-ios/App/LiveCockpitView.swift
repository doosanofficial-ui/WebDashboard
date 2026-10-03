import SwiftUI
import Charts
import MapKit
import TelemetryCore

struct LiveCockpitView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingReplayDetails = false
    @Bindable var model: TelemetryModel
    @Binding var editorPresented: Bool
    @Binding var selectedPageID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let displayDate = model.replayTimestamp.map(Date.init(timeIntervalSince1970:)) ?? timeline.date
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                    connectionStrip(at: displayDate)
                    if model.dashboardProfile != nil {
                        profileSection(at: displayDate)
                    } else {
                        primaryMetric(at: displayDate)
                        wheelSpeedRail(at: displayDate)
                        dynamicsCharts(at: displayDate)
                    }
                    locationCard(at: displayDate)

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sessionBar()
                    .padding(.horizontal, TelemetryTheme.Spacing.small)
                    .padding(.top, TelemetryTheme.Spacing.xSmall)
                    .padding(.bottom, TelemetryTheme.Spacing.xSmall)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private func connectionStrip(at now: Date) -> some View {
        let age = model.lastFrameAt.map { max(0, now.timeIntervalSince($0)) }
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            TelemetryRunStatusView(model: model)
            if model.runMode != .replay {
                Text(model.adapterStatus)
                    .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            }
            HStack(spacing: TelemetryTheme.Spacing.small) {
                telemetryStat(model.runMode == .replay ? "ROW" : "SEQ", model.frame?.status.seq.description ?? "-")
                telemetryStat(model.runMode == .replay ? "RECORDED AGE" : "FRAME AGE",
                    age.map { String(format: "%.0f ms", $0 * 1000) } ?? "NO SAMPLE")
                if TelemetryProductScope.allowsRemoteDelivery {
                    telemetryStat("DROP", String(model.clientDrops + (model.frame?.status.drop ?? 0)))
                    telemetryStat("RTT", model.serverRTTMilliseconds.map { String(format: "%.0f ms", $0) } ?? "-")
                }
            }
        }
        .telemetrySurface(.raised, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.runMode == .replay ? "replay-banner" : "live-status-strip")
    }

    private func telemetryStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(TelemetryTheme.quietText)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(model.runMode == .replay ? "RECORDED" : "UI TARGET 10 HZ")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(format(value, decimals: 1))
                    .font(TelemetryTypography.primaryMeasurement)
                    .monospacedDigit()
                    .foregroundStyle(fresh ? TelemetryTheme.accent : TelemetryTheme.mutedText)
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(TelemetryTheme.mutedText)
                Spacer()
                TelemetryStatusBadge(
                    title: TelemetryDisplayState.signalLabel(value, liveFresh: fresh, isReplay: model.runMode == .replay, replayQuality: model.replaySignalQuality["ws_fl"]),
                    color: fresh ? TelemetryTheme.valid : TelemetryTheme.warning,
                    symbol: fresh ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
            }
            Text("Frame age \(formatAge(model.lastFrameAt, now: now)) · Local recording \(model.localRecordingEnabled ? "on" : "off")")
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
                    state: signalState(metric.1, value: model.frame?.sig[metric.1], fresh: fresh),
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
        let age = fix.map { now.timeIntervalSince1970 - $0.capturedAt }
        let state = TelemetryDisplayState.gpsLabel(hasSample: fix != nil, isReplay: model.runMode == .replay, age: age)
        let fresh = state == "FRESH FIX"
        let color = model.runMode == .replay ? TelemetryTheme.accent : fresh ? TelemetryTheme.valid : TelemetryTheme.warning
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack {
                Label("GPS POSITION", systemImage: "location.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                TelemetryStatusBadge(
                    title: state,
                    color: color,
                    symbol: fresh ? "location.fill" : "location.slash.fill"
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number(fix?.data.lat, digits: 6)), \(number(fix?.data.lon, digits: 6))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Text(model.locationStatus.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(color)
            }
            (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: TelemetryTheme.Spacing.small))
                : AnyLayout(HStackLayout(spacing: TelemetryTheme.Spacing.small))) {
                locationValue("SPEED", number(fix?.data.spd.map { $0 * 3.6 }) + " km/h")
                locationValue("HEADING", number(fix?.data.hdg) + "°")
                locationValue("ACCURACY", "±" + number(fix?.data.acc) + " m")
            }
            Text(model.runMode == .replay ? "Recorded GPS · not current position" : "Age \(number(age)) s · Stored locally")
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
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sessionBar() -> some View {
        if model.runMode == .replay { replaySessionBar() }
        else { recordingSessionBar() }
    }

    private func replaySessionBar() -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                Text("REPLAY" + (model.replayController.recordingMode.map { " · " + $0.rawValue } ?? ""))
                    .font(.caption2.weight(.bold)).foregroundStyle(TelemetryTheme.accent)
                Text(String(format: "%.1f / %.1f s", model.replayController.position, model.replayController.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(TelemetryTheme.mutedText)
                .accessibilityLabel("Recorded time")
                .accessibilityValue(String(format: "%.1f of %.1f seconds", model.replayController.position, model.replayController.duration))
                .accessibilityIdentifier("cockpit-replay-position")
            }
            HStack(spacing: 4) {
                if model.replayController.isPlaying {
                    Button(action: model.pauseReplayPlayback) {
                        Image(systemName: "pause.fill").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Pause").accessibilityIdentifier("cockpit-replay-pause")
                } else {
                    Button(action: model.playReplay) {
                        Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Play").accessibilityIdentifier("cockpit-replay-play")
                        .disabled(model.replayController.position >= model.replayController.duration)
                }
                Button { Task { await model.seekReplay(to: 0) } } label: {
                    Image(systemName: "backward.end.fill").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Start").accessibilityIdentifier("cockpit-replay-start")
                    .disabled(model.replayController.duration <= 0)
                Button(action: model.stopReplay) {
                    Image(systemName: "stop.fill").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Stop Replay").accessibilityIdentifier("cockpit-replay-stop")
                Button { showingReplayDetails = true } label: {
                    Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Playback details").accessibilityIdentifier("cockpit-replay-details")
            }
            .font(.body).buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(TelemetryTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-cockpit-controls")
        .sheet(isPresented: $showingReplayDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(TelemetryDisplayState.modeTitle(.replay, recordingMode: model.replayController.recordingMode))
                        Text(String(format: "%.1f / %.1f recorded seconds", model.replayController.position, model.replayController.duration))
                        Text("Vehicle and GPS acquisition are off during replay")
                        Text("Playback rate: \(model.replayController.playbackRate)x")
                    }.padding()
                }
                .navigationTitle("Playback details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingReplayDetails = false } } }
            }
        }
    }

    func recordingSessionBar() -> some View {
        RecordingSessionBar(model: model)
    }

    @ViewBuilder
    private func profileSection(at now: Date) -> some View {
        if let profile = model.dashboardProfile,
           let page = profile.pages.first(where: { $0.id == selectedPageID }) ?? profile.pages.first {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SELECTED DASHBOARD")
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

    @ViewBuilder
    private func dashboardCanvas(_ page: DashboardPage, now: Date) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
                ForEach(page.widgets.sorted {
                    ($0.rect.y, $0.rect.x, $0.zIndex, $0.id) < ($1.rect.y, $1.rect.x, $1.zIndex, $1.id)
                }) { widget in
                    dashboardWidget(widget, now: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: widget.type == .verticalBar ? 180 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard-canvas-\(page.id)")
        } else {
            dashboardGrid(page, now: now)
        }
    }

    // Eager production grid, shared by the canvas and hosted rendering tests.
    func dashboardGrid(_ page: DashboardPage, now: Date) -> some View {
        let columns = page.orientation == .portrait ? 4 : 6
        let maxRow = max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1)
        return DashboardGridLayout(columns: columns, rows: maxRow) {
            ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                dashboardWidget(widget, now: now)
                    .layoutValue(key: DashboardGridRectKey.self, value: widget.rect)
            }
        }
        .background(TelemetryTheme.plot,
                    in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-canvas-\(page.id)")
    }

    @ViewBuilder
    // Internal so hosted display tests render the production widget without a lazy scroll container.
    func dashboardWidget(_ widget: DashboardWidgetDefinition, now: Date, allowsMapTiles: Bool = true) -> some View {
        let value = widget.signalID.flatMap { model.frame?.sig[$0] }
        let fresh = signalDataIsFresh(widget.signalID, at: now, fallback: canDataIsFresh(at: now))
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
            statusWidget(widget, value: value, fresh: fresh)
        case .rawCANHex:
            textWidget(widget, value: model.rawCANText, status: model.adapterStatus)
        case .bitView:
            textWidget(widget, value: bitText, status: model.adapterStatus)
        case .timeSeries:
            timeSeriesWidget(widget)
        case .gps, .map:
            gpsWidget(widget, map: widget.type == .map, allowsMapTiles: allowsMapTiles)
        }
    }

    private func numericWidget(_ widget: DashboardWidgetDefinition, value: Double?, fresh: Bool) -> some View {
        TelemetryMetricCard(
            label: widget.configuration.label,
            value: format(value, decimals: widget.configuration.decimals),
            unit: widget.configuration.unit,
            state: signalState(widget.signalID, value: value, fresh: fresh),
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
                    .font(TelemetryTypography.gaugeMeasurement)
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
                    .font(TelemetryTypography.gaugeMeasurement)
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
        let hasCondition = widget.configuration.condition != nil
        let conditionActive = model.conditionStates[widget.id]
        let state = hasCondition
            ? TelemetryDisplayState.conditionLabel(isReplay: model.runMode == .replay, evaluatedActive: conditionActive, fresh: fresh)
            : signalState(widget.signalID, value: value, fresh: fresh)
        let color: Color
        if state == "NOT EVALUATED" || !fresh { color = TelemetryTheme.quietText }
        else if hasCondition { color = conditionActive == true ? TelemetryTheme.warning : TelemetryTheme.valid }
        else { color = valueColor(value, configuration: widget.configuration, fresh: fresh) }
        return HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .shadow(color: color.opacity(0.5), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(widget.configuration.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(hasCondition ? state : format(value, decimals: widget.configuration.decimals))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TelemetryTheme.mutedText)
                if !hasCondition {
                    Text(state).font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
                }
            }
            Spacer()
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityIdentifier("profile-widget-\(widget.id)")
    }

    private func statusWidget(_ widget: DashboardWidgetDefinition, value: Double?, fresh: Bool) -> some View {
        let state = signalState(widget.signalID, value: value, fresh: fresh)
        let neutral = value == nil || value?.isFinite == false || state.contains("INVALID") || state.contains("UNKNOWN")
        let recordedFresh = widget.signalID.flatMap { model.replaySignalFreshness[$0] } == .fresh
        let valid = !neutral && fresh && (model.runMode != .replay || recordedFresh)
        return HStack(spacing: 10) {
            Image(systemName: neutral ? "questionmark.circle" : valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(neutral ? TelemetryTheme.quietText : valid ? TelemetryTheme.valid : TelemetryTheme.warning)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(widget.configuration.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(state)
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

    @ViewBuilder
    private func timeSeriesWidget(_ widget: DashboardWidgetDefinition) -> some View {
        if model.runMode == .replay {
            RecordedSignalHistoryView(title: widget.configuration.label,
                history: widget.signalID.flatMap { model.replayController.recordedHistory(for: $0) })
                .accessibilityIdentifier("profile-widget-\(widget.id)")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(widget.configuration.label).font(.subheadline.weight(.semibold))
                    .foregroundStyle(TelemetryTheme.mutedText)
                Chart(model.points) { point in
                    if let signalID = widget.signalID, let value = point.signals[signalID] {
                        LineMark(x: .value("Time", point.time), y: .value("Value", value))
                            .foregroundStyle(TelemetryTheme.accent)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 90)
            }
            .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
            .accessibilityIdentifier("profile-widget-\(widget.id)")
        }
    }

    @ViewBuilder
    private func gpsWidget(_ widget: DashboardWidgetDefinition, map: Bool, allowsMapTiles: Bool) -> some View {
        let fix = model.lastLocation
        if map && model.runMode == .replay {
            RecordedRouteView(title: widget.configuration.label, history: model.replayController.recordedLocations())
                .accessibilityIdentifier("profile-widget-\(widget.id)")
        } else if map {
            TrackMapView(
                title: widget.configuration.label,
                coordinate: fix.flatMap { coordinate(from: $0) },
                track: model.locationTrack, showsBasemap: allowsMapTiles
            )
            .accessibilityIdentifier("profile-widget-\(widget.id)")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Label(widget.configuration.label, systemImage: "location.fill")
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
    }

    private func coordinate(from event: TelemetryEvent) -> CLLocationCoordinate2D? {
        guard let latitude = event.data.lat, let longitude = event.data.lon else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func widgetHeader(_ widget: DashboardWidgetDefinition, fresh: Bool) -> some View {
        let value = widget.signalID.flatMap { model.frame?.sig[$0] }
        let state = signalState(widget.signalID, value: value, fresh: fresh)
        return VStack(alignment: .leading, spacing: 4) {
            Text(widget.configuration.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TelemetryTheme.mutedText)
            Text(state)
                .font(.caption2.weight(.bold))
                .foregroundStyle(state.contains("INVALID") ? TelemetryTheme.critical : TelemetryTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signalState(_ id: String?, value: Double?, fresh: Bool) -> String {
        let quality = id.flatMap { model.replaySignalQuality[$0] }
        let label = TelemetryDisplayState.signalLabel(value, liveFresh: fresh,
            isReplay: model.runMode == .replay, replayQuality: quality)
        guard model.runMode == .replay, let value, value.isFinite else { return label }
        return label + "\n" + TelemetryDisplayState.freshnessLabel(id.flatMap { model.replaySignalFreshness[$0] })
    }

    private func canDataIsFresh(at now: Date) -> Bool {
        if model.runMode == .replay { return model.frame != nil }
        let adapterLive = model.adapterStatus.localizedCaseInsensitiveContains("monitoring")
        guard (model.runMode == .replay || model.connection == "Connected" || adapterLive),
              let lastFrameAt = model.lastFrameAt else { return false }
        return now.timeIntervalSince(lastFrameAt) <= 1.5
    }

    private func signalDataIsFresh(_ signalID: String?, at now: Date, fallback: Bool) -> Bool {
        if model.runMode == .replay { return signalID.flatMap { model.replaySignalQuality[$0] } == .valid }
        guard let signalID,
              let timeout = model.localSignalTimeouts[signalID],
              let receivedAt = model.localSignalReceivedAt[signalID] else {
            return fallback
        }
        guard model.runMode == .replay || model.adapterStatus.localizedCaseInsensitiveContains("monitoring") else {
            return false
        }
        return now.timeIntervalSince1970 >= receivedAt
            && now.timeIntervalSince1970 - receivedAt <= timeout
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
        if model.showingDiagnosticResponse {
            return "Diagnostic response; passive CAN bits unavailable"
        }
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

private struct TrackMapView: View {
    let title: String
    let coordinate: CLLocationCoordinate2D?
    let track: [CLLocationCoordinate2D]
    let showsBasemap: Bool
    @State private var position: MapCameraPosition

    init(title: String, coordinate: CLLocationCoordinate2D?, track: [CLLocationCoordinate2D], showsBasemap: Bool = true) {
        self.title = title
        self.coordinate = coordinate
        self.track = track
        self.showsBasemap = showsBasemap
        if let coordinate {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            )))
        } else {
            _position = State(initialValue: .automatic)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "map")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if let coordinate {
                if showsBasemap {
                Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
                    if track.count > 1 {
                        MapPolyline(coordinates: track)
                            .stroke(TelemetryTheme.accent, lineWidth: 4)
                    }
                    Marker("GPS", coordinate: coordinate)
                        .tint(TelemetryTheme.warning)
                }
                .frame(minHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: TelemetryTheme.Radius.small, style: .continuous))
                .onChange(of: coordinate.latitude) { _, _ in follow(coordinate) }
                .onChange(of: coordinate.longitude) { _, _ in follow(coordinate) }
                } else {
                    Canvas { context, size in
                        let points = track.isEmpty ? [coordinate] : track
                        let lat = points.map(\.latitude); let lon = points.map(\.longitude)
                        let minLat = lat.min() ?? 0; let minLon = lon.min() ?? 0
                        let latSpan = max(0.0001, (lat.max() ?? minLat) - minLat)
                        let lonSpan = max(0.0001, (lon.max() ?? minLon) - minLon)
                        var path = Path()
                        for (index, point) in points.enumerated() {
                            let p = CGPoint(x: 12 + (point.longitude - minLon) / lonSpan * max(0, size.width - 24),
                                            y: size.height - 12 - (point.latitude - minLat) / latSpan * max(0, size.height - 24))
                            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.cyan))
                        }
                        context.stroke(path, with: .color(.cyan), lineWidth: 3)
                    }
                    .frame(minHeight: 170)
                    .background(TelemetryTheme.plot)
                    .accessibilityLabel("Local route preview")
                }
                Text("\(String(format: "%.6f", coordinate.latitude)), \(String(format: "%.6f", coordinate.longitude))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TelemetryTheme.mutedText)
            } else {
                ContentUnavailableView("No GPS fix", systemImage: "location.slash")
                    .frame(minHeight: 170)
            }
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
    }

    private func follow(_ coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 600,
            longitudinalMeters: 600
        ))
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character = "0") -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}

/// Evaluates content-size-dependent footer layout inside the SwiftUI environment.
private struct RecordingSessionBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: TelemetryModel

    var body: some View {
        VStack(spacing: TelemetryTheme.Spacing.xSmall) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.runMode == .demo ? "DEMO" : "LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TelemetryTheme.accent)
                        .accessibilityIdentifier("cockpit-recording-mode")
                    Text((model.localRecordingEnabled ? "RECORDING" : "REC OFF") + " · " + (model.collecting ? "GPS ON" : "GPS OFF"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TelemetryTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.lastMarkAt.map { "Last mark " + $0.formatted(date: .omitted, time: .shortened) } ?? "No mark")
                        .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: TelemetryTheme.Spacing.small) {
                    Text(model.runMode == .demo ? "DEMO" : "LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TelemetryTheme.accent)
                        .accessibilityIdentifier("cockpit-recording-mode")
                    Text(model.localRecordingEnabled ? "RECORDING" : "REC OFF")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
                    Text(model.collecting ? "GPS ON" : "GPS OFF")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(model.collecting ? TelemetryTheme.accent : TelemetryTheme.quietText)
                    Spacer()
                    Text(model.lastMarkAt.map { "Last mark " + $0.formatted(date: .omitted, time: .shortened) } ?? "No mark")
                        .font(.caption2)
                        .foregroundStyle(TelemetryTheme.mutedText)
                        .lineLimit(1)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                recordingActions().labelStyle(.iconOnly)
            } else {
                recordingActions()
            }

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

    private func recordingActions() -> some View {
        HStack(spacing: TelemetryTheme.Spacing.xSmall) {
            Button(action: model.mark) {
                Label("MARK", systemImage: "flag.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 4 : 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(TelemetryTheme.warning)
            .disabled(model.storageStatus != nil || model.runMode == .replay)
            .accessibilityIdentifier("mark-event")

            Button {
                if model.localRecordingEnabled {
                    model.stopRecording()
                } else {
                    model.startRecording()
                }
            } label: {
                Label(model.localRecordingEnabled ? "STOP" : "REC",
                      systemImage: model.localRecordingEnabled ? "stop.fill" : "record.circle")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 4 : 11)
            }
            .buttonStyle(.bordered)
            .tint(model.localRecordingEnabled ? TelemetryTheme.critical : TelemetryTheme.valid)
            .accessibilityIdentifier("toggle-recording")
            .disabled(model.runMode == .replay)

            Button {
                if model.collecting {
                    model.stopLocation()
                } else {
                    model.startLocation()
                }
            } label: {
                Label("GPS", systemImage: model.collecting ? "location.fill" : "location")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 4 : 11)
            }
            .buttonStyle(.bordered)
            .tint(model.collecting ? TelemetryTheme.accent : TelemetryTheme.mutedText)
            .disabled(model.storageStatus != nil || model.runMode == .replay)
            .accessibilityLabel(model.collecting ? "Stop GPS" : "Start GPS")
            .accessibilityIdentifier("toggle-gps")
        }
    }
}
