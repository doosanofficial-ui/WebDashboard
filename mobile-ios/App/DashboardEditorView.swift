import SwiftUI
import TelemetryCore

struct DashboardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: TelemetryModel
    @State private var selectedPageID: String?
    @State private var selectedWidgetID: String?
    @State private var configurationExpanded = false
    @State private var draftLabel = ""
    @State private var draftSignalID = ""
    @State private var draftUnit = ""
    @State private var draftDecimals = "1"
    @State private var draftMinimum = ""
    @State private var draftMaximum = ""
    @State private var draftWarning = ""
    @State private var draftCritical = ""
    @State private var draftConditionEnabled = false
    @State private var draftConditionOperator: DashboardConditionOperator = .greaterThan
    @State private var draftConditionThreshold = ""
    @State private var draftConditionUpper = ""
    @State private var draftConditionBit = ""
    @State private var draftConditionHysteresis = "0"
    @State private var draftConditionHold = "0"
    @State private var draftConditionStaleActive = false
    @State private var confirmPageDelete = false
    @State private var confirmWidgetDelete = false
    @State private var pendingPageDeleteID: String?
    @State private var pendingWidgetDelete: (pageID: String, widgetID: String)?

    private var selectedPage: DashboardPage? {
        guard let profile = model.dashboardProfile else { return nil }
        return profile.pages.first { $0.id == (selectedPageID ?? profile.pages.first?.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let error = model.dashboardSaveError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry save", action: model.retryDashboardSave)
                            .accessibilityIdentifier("retry-dashboard-save")
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("dashboard-save-error")
                }
                if let profile = model.dashboardProfile, let page = selectedPage {
                    if !dynamicTypeSize.isAccessibilitySize {
                        pageControls(profile: profile, page: page)
                    }
                    ScrollView {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 12) {
                                pageControls(profile: profile, page: page)
                                DashboardEditorCanvas(model: model, page: page,
                                                       selectedWidgetID: $selectedWidgetID)
                                    .padding(.horizontal)
                            }
                        } else {
                            DashboardEditorCanvas(model: model, page: page,
                                                   selectedWidgetID: $selectedWidgetID)
                                .padding(.horizontal)
                        }
                    }
                    .accessibilityIdentifier("dashboard-editor-scroll")
                    selectionControls(page: page)
                } else {
                    ContentUnavailableView("No dashboard profile", systemImage: "rectangle.3.group")
                }
            }
            .navigationTitle("Dashboard Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: model.undoDashboardLayout)
                        .labelStyle(.iconOnly).disabled(!model.canUndoDashboardLayout)
                        .accessibilityIdentifier("undo-dashboard-layout")
                    Button("Redo", systemImage: "arrow.uturn.forward", action: model.redoDashboardLayout)
                        .labelStyle(.iconOnly).disabled(!model.canRedoDashboardLayout)
                        .accessibilityIdentifier("redo-dashboard-layout")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if selectedPageID == nil { selectedPageID = model.dashboardProfile?.pages.first?.id }
                loadDraftFromSelection()
            }
            .onChange(of: selectedWidgetID) { _, _ in configurationExpanded = false; loadDraftFromSelection() }
            .onChange(of: selectedPageID) { _, _ in configurationExpanded = false; loadDraftFromSelection() }
            .confirmationDialog("Delete page?", isPresented: $confirmPageDelete, titleVisibility: .visible) {
                Button("Delete page", role: .destructive) { deletePendingPage() }
            } message: {
                Text("This removes the page and its widget layout.")
            }
            .confirmationDialog("Delete widget?", isPresented: $confirmWidgetDelete, titleVisibility: .visible) {
                Button("Delete widget", role: .destructive) { deletePendingWidget() }
            } message: {
                Text("This removes the selected widget from the profile.")
            }
        }
    }

    private func deletePendingPage() {
        guard let pageID = pendingPageDeleteID else { return }
        model.deleteDashboardPage(pageID: pageID)
        selectedPageID = model.dashboardProfile?.pages.first?.id
        selectedWidgetID = nil
        pendingPageDeleteID = nil
    }

    private func deletePendingWidget() {
        guard let pendingWidgetDelete else { return }
        model.deleteDashboardWidget(pageID: pendingWidgetDelete.pageID, widgetID: pendingWidgetDelete.widgetID)
        selectedWidgetID = nil
        self.pendingWidgetDelete = nil
    }

    private func pageControls(profile: DashboardProfile, page: DashboardPage) -> some View {
        VStack(spacing: 8) {
            Picker("Page", selection: Binding(
                get: { selectedPageID ?? profile.pages.first?.id ?? page.id },
                set: { selectedPageID = $0 }
            )) {
                ForEach(profile.pages) { page in
                    Text(page.name + " · " + page.orientation.rawValue.capitalized).tag(page.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("dashboard-page-picker")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                Button("Add page", action: model.addDashboardPage)
                    .accessibilityIdentifier("add-dashboard-page")
                Menu("Add widget", systemImage: "plus.square") {
                    ForEach(DashboardWidgetType.allCases, id: \.self) { type in
                        Button(widgetLabel(type)) {
                            model.addDashboardWidget(pageID: page.id, type: type)
                        }
                    }
                }
                .accessibilityIdentifier("add-dashboard-widget")
                Menu("Orientation") {
                    Button("Portrait") {
                        model.setDashboardOrientation(pageID: page.id, orientation: .portrait)
                    }
                    Button("Landscape") {
                        model.setDashboardOrientation(pageID: page.id, orientation: .landscape)
                    }
                }
                Button("Snap") { model.snapDashboard(pageID: page.id) }
                Button("Delete page", role: .destructive) {
                    pendingPageDeleteID = page.id
                    confirmPageDelete = true
                }
                .disabled(profile.pages.count == 1)
            }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    private func widgetLabel(_ type: DashboardWidgetType) -> String {
        switch type {
        case .numericGauge: return "Numeric Gauge"
        case .circularGauge: return "Circular Gauge"
        case .semiCircularGauge: return "Semi Gauge"
        case .horizontalBar: return "Horizontal Bar"
        case .verticalBar: return "Vertical Bar"
        case .led: return "LED Indicator"
        case .statusIcon: return "Status"
        case .rawCANHex: return "Raw CAN"
        case .bitView: return "Bit View"
        case .timeSeries: return "Time Series"
        case .gps: return "GPS Info"
        case .map: return "Route Track"
        }
    }

    @ViewBuilder
    private func selectionControls(page: DashboardPage) -> some View {
        if let selectedWidgetID,
           let widget = page.widgets.first(where: { $0.id == selectedWidgetID }) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                    Text(widget.configuration.label).font(.caption.weight(.semibold))
                    Spacer()
                    Button("Front") {
                        model.bringDashboardWidgetToFront(pageID: page.id, widgetID: widget.id)
                    }
                    Button("Duplicate") {
                        model.duplicateDashboardWidget(pageID: page.id, widgetID: widget.id)
                    }
                    Menu("Align") {
                        ForEach(DashboardAlignment.allCases, id: \.self) { alignment in
                            Button(alignmentLabel(alignment)) {
                                let columns = page.orientation == .portrait ? 4 : 6
                                model.alignDashboardWidget(
                                    pageID: page.id,
                                    widgetID: widget.id,
                                    alignment: alignment,
                                    columns: columns
                                )
                            }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        pendingWidgetDelete = (page.id, widget.id)
                        confirmWidgetDelete = true
                    }
                }
                }
                .buttonStyle(.bordered)

                DisclosureGroup(isExpanded: $configurationExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Label", text: $draftLabel)
                                Menu("Bind signal") {
                                    if model.availableSignalIDs.isEmpty {
                                        Text("No profile signals")
                                    } else {
                                        ForEach(model.availableSignalIDs, id: \.self) { signalID in
                                            Button(signalID) { draftSignalID = signalID }
                                        }
                                    }
                                }
                                .accessibilityIdentifier("bind-dashboard-signal")
                            }
                            HStack {
                                TextField("Signal ID", text: $draftSignalID)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HStack {
                                TextField("Unit", text: $draftUnit)
                                TextField("Decimals", text: $draftDecimals)
                                    .keyboardType(.numberPad)
                            }
                            HStack {
                                TextField("Min", text: $draftMinimum).keyboardType(.numbersAndPunctuation)
                                TextField("Max", text: $draftMaximum).keyboardType(.numbersAndPunctuation)
                                TextField("Warn", text: $draftWarning).keyboardType(.numbersAndPunctuation)
                                TextField("Critical", text: $draftCritical).keyboardType(.numbersAndPunctuation)
                            }
                            Toggle("Condition enabled", isOn: $draftConditionEnabled)
                            if draftConditionEnabled {
                                Picker("Condition", selection: $draftConditionOperator) {
                                    Text("Equals").tag(DashboardConditionOperator.equals)
                                    Text("Greater than").tag(DashboardConditionOperator.greaterThan)
                                    Text("Less than").tag(DashboardConditionOperator.lessThan)
                                    Text("Within range").tag(DashboardConditionOperator.withinRange)
                                    Text("Bit set").tag(DashboardConditionOperator.bitSet)
                                }
                                HStack {
                                    TextField("Threshold", text: $draftConditionThreshold)
                                        .keyboardType(.numbersAndPunctuation)
                                    if draftConditionOperator == .withinRange {
                                        TextField("Upper", text: $draftConditionUpper)
                                            .keyboardType(.numbersAndPunctuation)
                                    }
                                    if draftConditionOperator == .bitSet {
                                        TextField("Bit 0-63", text: $draftConditionBit)
                                            .keyboardType(.numberPad)
                                    }
                                }
                                HStack {
                                    TextField("Hysteresis", text: $draftConditionHysteresis)
                                        .keyboardType(.numbersAndPunctuation)
                                    TextField("Hold seconds", text: $draftConditionHold)
                                        .keyboardType(.numbersAndPunctuation)
                                }
                                Toggle("Stale is active", isOn: $draftConditionStaleActive)
                            }
                            Button("Apply widget configuration") {
                                applyDraft(pageID: page.id, widgetID: widget.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("apply-widget-configuration")
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 300)
                } label: {
                    Text("Widget configuration").font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("widget-configuration-disclosure")
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private func loadDraftFromSelection() {
        guard let page = selectedPage,
              let selectedWidgetID,
              let widget = page.widgets.first(where: { $0.id == selectedWidgetID }) else { return }
        draftLabel = widget.configuration.label
        draftSignalID = widget.signalID ?? ""
        draftUnit = widget.configuration.unit
        draftDecimals = String(widget.configuration.decimals)
        draftMinimum = widget.configuration.minimum.map { String($0) } ?? ""
        draftMaximum = widget.configuration.maximum.map { String($0) } ?? ""
        draftWarning = widget.configuration.warningThreshold.map { String($0) } ?? ""
        draftCritical = widget.configuration.criticalThreshold.map { String($0) } ?? ""
        if let condition = widget.configuration.condition {
            draftConditionEnabled = true
            draftConditionOperator = condition.op
            draftConditionThreshold = condition.threshold.map { String($0) } ?? ""
            draftConditionUpper = condition.upperThreshold.map { String($0) } ?? ""
            draftConditionBit = condition.bit.map { String($0) } ?? ""
            draftConditionHysteresis = String(condition.hysteresis)
            draftConditionHold = String(condition.holdTime)
            draftConditionStaleActive = condition.staleIsActive
        } else {
            draftConditionEnabled = false
            draftConditionThreshold = ""
            draftConditionUpper = ""
            draftConditionBit = ""
            draftConditionHysteresis = "0"
            draftConditionHold = "0"
            draftConditionStaleActive = false
        }
    }

    private func applyDraft(pageID: String, widgetID: String) {
        guard let decimals = Int(draftDecimals.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let condition: DashboardCondition? = draftConditionEnabled
            ? DashboardCondition(
                op: draftConditionOperator,
                threshold: optionalDouble(draftConditionThreshold),
                upperThreshold: optionalDouble(draftConditionUpper),
                bit: Int(draftConditionBit),
                hysteresis: optionalDouble(draftConditionHysteresis) ?? 0,
                holdTime: optionalDouble(draftConditionHold) ?? 0,
                staleIsActive: draftConditionStaleActive
            )
            : nil
        let configuration = DashboardWidgetConfiguration(
            label: draftLabel.isEmpty ? "Signal" : draftLabel,
            unit: draftUnit,
            decimals: decimals,
            minimum: optionalDouble(draftMinimum),
            maximum: optionalDouble(draftMaximum),
            warningThreshold: optionalDouble(draftWarning),
            criticalThreshold: optionalDouble(draftCritical),
            condition: condition
        )
        let signal = draftSignalID.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateDashboardWidgetBinding(
            pageID: pageID,
            widgetID: widgetID,
            signalID: signal.isEmpty ? nil : signal,
            configuration: configuration
        )
    }

    private func optionalDouble(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Double(value)
    }

    private func alignmentLabel(_ alignment: DashboardAlignment) -> String {
        switch alignment {
        case .left: return "Left"
        case .centerHorizontal: return "Center horizontally"
        case .right: return "Right"
        case .top: return "Top"
        case .centerVertical: return "Center vertically"
        case .bottom: return "Bottom"
        }
    }
}
