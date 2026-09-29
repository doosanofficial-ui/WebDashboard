import Foundation

/// Small, version-pinned diagnostic catalog for the user's Santa Fe MX5 HEV.
///
/// The definitions are imported from OBDb's Hyundai-Santa-Fe-Hybrid signal set,
/// commit c14ff9dd8a87482604200a859d7d734234d98892. They are candidates until
/// a response from the physical vehicle proves support; `dbgfilter` metadata is
/// deliberately not used as runtime proof.
public enum SantaFeMX5HybridQueryCatalog {
    public static func hvBatterySOC() throws -> OBDQueryDefinition {
        try query(
            id: "santafe-mx5-hev-hv-soc",
            name: "Santa Fe MX5 HEV HV battery charge",
            requestCANID: 0x7E4,
            responseCANID: 0x7EC,
            service: .service22,
            command: "0101",
            pollInterval: 1,
            flowControl: true,
            signals: [try signal(
                id: "SANTAFEHYB_HVBAT_SOC",
                name: "HV battery charge",
                startBit: 32,
                bitLength: 8,
                factor: 0.5,
                minimum: 0,
                maximum: 100,
                unit: "percent",
                suggestedMetric: "stateOfCharge",
                path: "Battery"
            )]
        )
    }

    /// Baseline queries are run before manufacturer-specific queries. A query
    /// scheduler may stop after the first supported baseline response.
    public static func baselineQueries() throws -> [OBDQueryDefinition] {
        [
            try query(
                id: "obd-mode01-supported-00",
                name: "OBD-II supported PIDs 01-20",
                requestCANID: 0x7DF,
                responseCANID: 0x7E8,
                service: .mode01,
                command: "00",
                pollInterval: 5,
                flowControl: false,
                signals: [try signal(
                    id: "OBD_SUPPORTED_PIDS_00",
                    name: "Supported PIDs 01-20",
                    startBit: 0,
                    bitLength: 32,
                    factor: 1,
                    minimum: 0,
                    maximum: 4_294_967_295,
                    unit: "bitmask",
                    suggestedMetric: nil,
                    path: "OBD-II"
                )]
            ),
            try query(
                id: "obd-mode01-rpm",
                name: "Engine speed",
                requestCANID: 0x7DF,
                responseCANID: 0x7E8,
                service: .mode01,
                command: "0C",
                pollInterval: 1,
                flowControl: false,
                signals: [try signal(
                    id: "OBD_ENGINE_RPM",
                    name: "Engine speed",
                    startBit: 0,
                    bitLength: 16,
                    factor: 0.25,
                    minimum: 0,
                    maximum: 16_383.75,
                    unit: "rpm",
                    suggestedMetric: "engineSpeed",
                    path: "Engine"
                )]
            ),
            try query(
                id: "obd-mode01-coolant",
                name: "Engine coolant temperature",
                requestCANID: 0x7DF,
                responseCANID: 0x7E8,
                service: .mode01,
                command: "05",
                pollInterval: 1,
                flowControl: false,
                signals: [try signal(
                    id: "OBD_COOLANT_C",
                    name: "Engine coolant temperature",
                    startBit: 0,
                    bitLength: 8,
                    factor: 1,
                    offset: -40,
                    minimum: -40,
                    maximum: 215,
                    unit: "degC",
                    suggestedMetric: "coolantTemperature",
                    path: "Engine"
                )]
            ),
            try query(
                id: "obd-mode01-speed",
                name: "Vehicle speed",
                requestCANID: 0x7DF,
                responseCANID: 0x7E8,
                service: .mode01,
                command: "0D",
                pollInterval: 0.25,
                flowControl: false,
                signals: [try signal(
                    id: "OBD_VEHICLE_SPEED_KMH",
                    name: "Vehicle speed",
                    startBit: 0,
                    bitLength: 8,
                    factor: 1,
                    minimum: 0,
                    maximum: 255,
                    unit: "km/h",
                    suggestedMetric: "speed",
                    path: "Movement"
                )]
            )
        ]
    }

    /// Additional candidates remain opt-in until the physical vehicle proves
    /// each response. They are not automatically activated by the initial flow.
    public static func expandedQueries() throws -> [OBDQueryDefinition] {
        [
            try query(
                id: "santafe-mx5-hev-wheel-speeds",
                name: "Santa Fe MX5 HEV wheel speeds",
                requestCANID: 0x7E7,
                responseCANID: 0x7EF,
                service: .service22,
                command: "C101",
                pollInterval: 0.25,
                flowControl: false,
                signals: [
                    try signal(id: "SANTAFEHYB_TIRE_FL_SPD", name: "Front left wheel speed", startBit: 88, bitLength: 8, factor: 1, minimum: 0, maximum: 255, unit: "km/h", suggestedMetric: "frontLeftWheelSpeed", path: "Movement"),
                    try signal(id: "SANTAFEHYB_TIRE_FR_SPD", name: "Front right wheel speed", startBit: 96, bitLength: 8, factor: 1, minimum: 0, maximum: 255, unit: "km/h", suggestedMetric: "frontRightWheelSpeed", path: "Movement"),
                    try signal(id: "SANTAFEHYB_TIRE_RL_SPD", name: "Rear left wheel speed", startBit: 104, bitLength: 8, factor: 1, minimum: 0, maximum: 255, unit: "km/h", suggestedMetric: "rearLeftWheelSpeed", path: "Movement"),
                    try signal(id: "SANTAFEHYB_TIRE_RR_SPD", name: "Rear right wheel speed", startBit: 112, bitLength: 8, factor: 1, minimum: 0, maximum: 255, unit: "km/h", suggestedMetric: "rearRightWheelSpeed", path: "Movement")
                ]
            ),
            try query(
                id: "santafe-mx5-hev-tire-pressure",
                name: "Santa Fe MX5 HEV tire pressure",
                requestCANID: 0x7A0,
                responseCANID: 0x7A8,
                service: .service22,
                command: "C00B",
                pollInterval: 15,
                flowControl: true,
                signals: [
                    try signal(id: "SANTAFEHYB_TP_FL", name: "Front left tire pressure", startBit: 32, bitLength: 8, factor: 0.2, minimum: 0, maximum: 51, unit: "psi", suggestedMetric: "frontLeftTirePressure", path: "Tires"),
                    try signal(id: "SANTAFEHYB_TP_FR", name: "Front right tire pressure", startBit: 64, bitLength: 8, factor: 0.2, minimum: 0, maximum: 51, unit: "psi", suggestedMetric: "frontRightTirePressure", path: "Tires"),
                    try signal(id: "SANTAFEHYB_TP_RL", name: "Rear left tire pressure", startBit: 96, bitLength: 8, factor: 0.2, minimum: 0, maximum: 51, unit: "psi", suggestedMetric: "rearLeftTirePressure", path: "Tires"),
                    try signal(id: "SANTAFEHYB_TP_RR", name: "Rear right tire pressure", startBit: 128, bitLength: 8, factor: 0.2, minimum: 0, maximum: 51, unit: "psi", suggestedMetric: "rearRightTirePressure", path: "Tires")
                ]
            ),
            try query(
                id: "santafe-mx5-hev-12v-charge",
                name: "Santa Fe MX5 HEV 12V battery charge",
                requestCANID: 0x7E2,
                responseCANID: 0x7EA,
                service: .service22,
                command: "E004",
                pollInterval: 1,
                flowControl: false,
                signals: [try signal(
                    id: "SANTAFEHYB_VPWR",
                    name: "12V battery charge",
                    startBit: 152,
                    bitLength: 8,
                    factor: 1,
                    minimum: 0,
                    maximum: 100,
                    unit: "percent",
                    suggestedMetric: "auxiliaryBatteryCharge",
                    path: "Battery"
                )]
            )
        ]
    }

    private static func query(
        id: String,
        name: String,
        requestCANID: UInt32,
        responseCANID: UInt32,
        service: OBDService,
        command: String,
        pollInterval: Double,
        flowControl: Bool,
        signals: [OBDSignalDefinition]
    ) throws -> OBDQueryDefinition {
        try OBDQueryDefinition(
            id: id,
            name: name,
            requestCANID: requestCANID,
            responseCANID: responseCANID,
            isExtended: false,
            service: service,
            command: command,
            pollInterval: pollInterval,
            timeout: max(3, pollInterval * 2),
            flowControl: flowControl,
            sourceRepository: "OBDb/Hyundai-Santa-Fe-Hybrid",
            sourcePath: "signalsets/v3/default.json",
            sourceCommit: "c14ff9dd8a87482604200a859d7d734234d98892",
            signals: signals
        )
    }

    private static func signal(
        id: String,
        name: String,
        startBit: Int,
        bitLength: Int,
        byteOrder: ByteOrder = .intel,
        isSigned: Bool = false,
        factor: Double,
        offset: Double = 0,
        minimum: Double?,
        maximum: Double?,
        unit: String,
        suggestedMetric: String?,
        path: String?
    ) throws -> OBDSignalDefinition {
        try OBDSignalDefinition(
            id: id,
            name: name,
            startBit: startBit,
            bitLength: bitLength,
            byteOrder: byteOrder,
            isSigned: isSigned,
            factor: factor,
            offset: offset,
            minimum: minimum,
            maximum: maximum,
            unit: unit,
            timeout: 3,
            suggestedMetric: suggestedMetric,
            path: path
        )
    }
}
