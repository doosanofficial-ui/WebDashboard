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
    @State private var draftValidationError: DashboardNumericDraft.ValidationError?
    @FocusState private var numericInputFocus: DashboardNumericDraft.Field?
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
                        Label(AppLocalization.text(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(AppLocalization.text("Retry save"), action: model.retryDashboardSave)
                            .accessibilityIdentifier("retry-dashboard-save")
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("dashboard-save-error")
                }
                if let profile = model.dashboardProfile, let page = selectedPage {
                    if dynamicTypeSize.isAccessibilitySize && configurationExpanded {
                        // The expanded form owns the visible viewport, not a nested footer scroll.
                        ScrollView {
                            selectionControls(page: page, scrollsConfiguration: false)
                        }
                        .accessibilityIdentifier("dashboard-widget-configuration-scroll")
                    } else {
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
                    }
                } else {
                    ContentUnavailableView("No dashboard profile", systemImage: "rectangle.3.group")
                }
            }
            .navigationTitle(AppLocalization.text("Dashboard Editor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(AppLocalization.text("Undo"), systemImage: "arrow.uturn.backward", action: model.undoDashboardLayout)
                        .labelStyle(.iconOnly).disabled(!model.canUndoDashboardLayout)
                        .accessibilityIdentifier("undo-dashboard-layout")
                    Button(AppLocalization.text("Redo"), systemImage: "arrow.uturn.forward", action: model.redoDashboardLayout)
                        .labelStyle(.iconOnly).disabled(!model.canRedoDashboardLayout)
                        .accessibilityIdentifier("redo-dashboard-layout")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.text("Done")) { dismiss() }
                        .accessibilityIdentifier("dashboard-editor-done")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if numericInputFocus != nil {
                        Spacer()
                        Button(AppLocalization.text("Done")) { numericInputFocus = nil }
                            .accessibilityIdentifier("dashboard-numeric-keyboard-done")
                    }
                }
            }
            .onAppear {
                if selectedPageID == nil { selectedPageID = model.dashboardProfile?.pages.first?.id }
                loadDraftFromSelection()
            }
            .onChange(of: selectedWidgetID) { _, _ in configurationExpanded = false; loadDraftFromSelection() }
            .onChange(of: selectedPageID) { _, _ in configurationExpanded = false; loadDraftFromSelection() }
            .confirmationDialog(AppLocalization.text("Delete page?"), isPresented: $confirmPageDelete, titleVisibility: .visible) {
                Button(AppLocalization.text("Delete page"), role: .destructive) { deletePendingPage() }
            } message: {
                Text(AppLocalization.text("This removes the page and its widget layout."))
            }
            .confirmationDialog(AppLocalization.text("Delete widget?"), isPresented: $confirmWidgetDelete, titleVisibility: .visible) {
                Button(AppLocalization.text("Delete widget"), role: .destructive) { deletePendingWidget() }
            } message: {
                Text(AppLocalization.text("This removes the selected widget from the profile."))
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
            let selectedTitle = page.name + " · " + AppLocalization.text(page.orientation.rawValue.capitalized)
            Menu {
                Picker(AppLocalization.text("Page"), selection: Binding(
                    get: { selectedPageID ?? profile.pages.first?.id ?? page.id },
                    set: { selectedPageID = $0 }
                )) {
                    ForEach(profile.pages) { page in
                        Text(verbatim: page.name + " · " + AppLocalization.text(page.orientation.rawValue.capitalized)).tag(page.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: selectedTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(AppLocalization.text("Page") + ", " + selectedTitle)
            .accessibilityIdentifier("dashboard-page-picker")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                Button(AppLocalization.text("Add page"), action: model.addDashboardPage)
                    .accessibilityIdentifier("add-dashboard-page")
                Menu(AppLocalization.text("Add widget"), systemImage: "plus.square") {
                    ForEach(DashboardWidgetType.allCases, id: \.self) { type in
                        Button(AppLocalization.text(widgetLabel(type))) {
                            model.addDashboardWidget(pageID: page.id, type: type)
                        }
                    }
                }
                .accessibilityIdentifier("add-dashboard-widget")
                Menu(AppLocalization.text("Orientation")) {
                    Button(AppLocalization.text("Portrait")) {
                        model.setDashboardOrientation(pageID: page.id, orientation: .portrait)
                    }
                    Button(AppLocalization.text("Landscape")) {
                        model.setDashboardOrientation(pageID: page.id, orientation: .landscape)
                    }
                }
                Button(AppLocalization.text("Snap")) { model.snapDashboard(pageID: page.id) }
                Button(AppLocalization.text("Delete page"), role: .destructive) {
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
    private func selectionControls(page: DashboardPage, scrollsConfiguration: Bool = true) -> some View {
        if let selectedWidgetID,
           let widget = page.widgets.first(where: { $0.id == selectedWidgetID }) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                    Text(widget.configuration.label).font(.caption.weight(.semibold))
                    Spacer()
                    Button(AppLocalization.text("Front")) {
                        model.bringDashboardWidgetToFront(pageID: page.id, widgetID: widget.id)
                    }
                    Button(AppLocalization.text("Duplicate")) {
                        model.duplicateDashboardWidget(pageID: page.id, widgetID: widget.id)
                    }
                    Menu(AppLocalization.text("Align")) {
                        ForEach(DashboardAlignment.allCases, id: \.self) { alignment in
                            Button(AppLocalization.text(alignmentLabel(alignment))) {
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
                    Button(AppLocalization.text("Delete"), role: .destructive) {
                        pendingWidgetDelete = (page.id, widget.id)
                        confirmWidgetDelete = true
                    }
                }
                }
                .buttonStyle(.bordered)

                let fields = VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField(AppLocalization.text("Label"), text: $draftLabel)
                                    .accessibilityIdentifier("dashboard-widget-label")
                                Menu(AppLocalization.text("Bind signal")) {
                                    if model.availableSignalIDs.isEmpty {
                                        Text(AppLocalization.text("No profile signals"))
                                    } else {
                                        ForEach(model.availableSignalIDs, id: \.self) { signalID in
                                            Button(signalID) { draftSignalID = signalID }
                                        }
                                    }
                                }
                                .accessibilityIdentifier("bind-dashboard-signal")
                            }
                            HStack {
                                TextField(AppLocalization.text("Signal ID"), text: $draftSignalID)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HStack {
                                TextField(AppLocalization.text("Unit"), text: $draftUnit)
                                TextField(AppLocalization.text("Decimals"), text: $draftDecimals)
                                    .keyboardType(.numberPad)
                                    .focused($numericInputFocus, equals: .decimals)
                                    .accessibilityIdentifier("dashboard-widget-decimals")
                            }
                            numericRangeInputs
                            Toggle(AppLocalization.text("Condition enabled"), isOn: $draftConditionEnabled)
                            if draftConditionEnabled {
                                Picker(AppLocalization.text("Condition"), selection: $draftConditionOperator) {
                                    Text(AppLocalization.text("Equals")).tag(DashboardConditionOperator.equals)
                                    Text(AppLocalization.text("Greater than")).tag(DashboardConditionOperator.greaterThan)
                                    Text(AppLocalization.text("Less than")).tag(DashboardConditionOperator.lessThan)
                                    Text(AppLocalization.text("Within range")).tag(DashboardConditionOperator.withinRange)
                                    Text(AppLocalization.text("Bit set")).tag(DashboardConditionOperator.bitSet)
                                }
                                HStack {
                                    TextField(AppLocalization.text("Threshold"), text: $draftConditionThreshold)
                                        .keyboardType(.numbersAndPunctuation)
                                    if draftConditionOperator == .withinRange {
                                        TextField(AppLocalization.text("Upper"), text: $draftConditionUpper)
                                            .keyboardType(.numbersAndPunctuation)
                                    }
                                    if draftConditionOperator == .bitSet {
                                        TextField(AppLocalization.text("Bit 0-63"), text: $draftConditionBit)
                                            .keyboardType(.numberPad)
                                    }
                                }
                                HStack {
                                    TextField(AppLocalization.text("Hysteresis"), text: $draftConditionHysteresis)
                                        .keyboardType(.numbersAndPunctuation)
                                    TextField(AppLocalization.text("Hold seconds"), text: $draftConditionHold)
                                        .keyboardType(.numbersAndPunctuation)
                                }
                                Toggle(AppLocalization.text("Stale is active"), isOn: $draftConditionStaleActive)
                            }
                            if let error = draftValidationError {
                                Text(numericValidationMessage(error))
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("dashboard-widget-numeric-error")
                            }
                            Button(AppLocalization.text("Apply widget configuration")) {
                                applyDraft(pageID: page.id, widgetID: widget.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("apply-widget-configuration")
                }
                .padding(.vertical, 6)
                if scrollsConfiguration {
                    DisclosureGroup(isExpanded: $configurationExpanded) {
                        ScrollView { fields }
                            .frame(maxHeight: 300)
                            .accessibilityIdentifier("dashboard-widget-configuration-scroll")
                    } label: {
                        Text(AppLocalization.text("Widget configuration")).font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("widget-configuration-disclosure")
                } else {
                    Button {
                        numericInputFocus = nil
                        configurationExpanded = false
                    } label: {
                        HStack {
                            Text(AppLocalization.text("Widget configuration")).font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.up").accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("widget-configuration-disclosure")
                    fields
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private var numericRangeInputs: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout())
        return layout {
            numericRangeInput("Min", text: $draftMinimum, field: .minimum, identifier: "minimum")
            numericRangeInput("Max", text: $draftMaximum, field: .maximum, identifier: "maximum")
            numericRangeInput("Warn", text: $draftWarning, field: .warning, identifier: "warning")
            numericRangeInput("Critical", text: $draftCritical, field: .critical, identifier: "critical")
        }
    }

    private func numericRangeInput(_ title: String, text: Binding<String>,
                                   field: DashboardNumericDraft.Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(AppLocalization.text(title))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dashboard-widget-" + identifier + "-label")
            }
            TextField(AppLocalization.text(title), text: text)
                .keyboardType(.numbersAndPunctuation)
                .focused($numericInputFocus, equals: field)
                .accessibilityIdentifier("dashboard-widget-" + identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadDraftFromSelection() {
        draftValidationError = nil
        numericInputFocus = nil
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
        numericInputFocus = nil
        let numbers: DashboardNumericDraft.Values
        switch DashboardNumericDraft(decimals: draftDecimals, minimum: draftMinimum, maximum: draftMaximum,
                                     warning: draftWarning, critical: draftCritical).validated() {
        case .failure(let error):
            draftValidationError = error
            return
        case .success(let values):
            numbers = values
        }
        draftValidationError = nil
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
            decimals: numbers.decimals,
            minimum: numbers.minimum,
            maximum: numbers.maximum,
            warningThreshold: numbers.warning,
            criticalThreshold: numbers.critical,
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

    private func numericValidationMessage(_ error: DashboardNumericDraft.ValidationError) -> String {
        switch error {
        case .invalidDecimals:
            return AppLocalization.text("Decimal places must be a whole number from 0 to 6.")
        case .invalidNumber(let field):
            return String(format: AppLocalization.text("%@ must be a finite number or empty."),
                          AppLocalization.text(field.rawValue))
        }
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
