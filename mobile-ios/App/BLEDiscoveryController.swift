import CoreBluetooth
import Foundation

struct BLEDiscoveredCharacteristic: Codable, Equatable, Identifiable {
    let id: String
    let properties: [String]
}

struct BLEDiscoveredService: Codable, Equatable, Identifiable {
    let id: String
    var characteristics: [BLEDiscoveredCharacteristic]
}

struct BLEDiscoveredDevice: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var state: String
    var services: [BLEDiscoveredService]
}

/// Discovery-only BLE probe. It records observed GATT structure but never
/// guesses UUIDs, writes to a peripheral, or starts an ELM327 session.
@MainActor
final class BLEDiscoveryController: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    var onUpdate: (([BLEDiscoveredDevice], String) -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: BLEDiscoveredDevice] = [:]
    private var scanning = false

    override init() {
        super.init()
    }

    func start() {
        if central == nil {
            scanning = true
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionShowPowerAlertKey: true
            ])
            publish("Requesting Bluetooth permission")
            return
        }
        guard let central, central.state == .poweredOn else {
            publish(status(for: self.central?.state))
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        publish("Scanning BLE peripherals")
    }

    func stop() {
        scanning = false
        central?.stopScan()
        for peripheral in peripherals.values where peripheral.state == .connected {
            central?.cancelPeripheralConnection(peripheral)
        }
        publish("BLE scan stopped")
    }

    func inspect(_ id: UUID) {
        guard let central, let peripheral = peripherals[id] else {
            publish("BLE peripheral is no longer available")
            return
        }
        scanning = false
        central.stopScan()
        update(id) { $0.state = "connecting for GATT inspection" }
        if peripheral.state == .connected {
            peripheral.discoverServices(nil)
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    func observationData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(devices.values.sorted { $0.name < $1.name })
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            publish(status(for: central.state))
            return
        }
        if scanning { start() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        var device = devices[peripheral.identifier] ?? BLEDiscoveredDevice(
            id: peripheral.identifier,
            name: peripheral.name ?? "Unnamed BLE peripheral",
            rssi: RSSI.intValue,
            state: "discovered",
            services: []
        )
        device.name = peripheral.name ?? device.name
        device.rssi = RSSI.intValue
        devices[peripheral.identifier] = device
        peripheral.delegate = self
        publish("Found \(devices.count) BLE peripheral(s)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        update(peripheral.identifier) { $0.state = "connected; discovering services" }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        update(peripheral.identifier) { $0.state = "connection failed" }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        update(peripheral.identifier) { $0.state = "disconnected" }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            update(peripheral.identifier) { $0.state = "service discovery failed" }
            return
        }
        update(peripheral.identifier) {
            $0.state = "services discovered"
            $0.services = services.map { BLEDiscoveredService(id: $0.uuid.uuidString, characteristics: []) }
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            update(peripheral.identifier) { $0.state = "characteristic discovery failed" }
            return
        }
        let observed = BLEDiscoveredService(
            id: service.uuid.uuidString,
            characteristics: characteristics.map {
                BLEDiscoveredCharacteristic(id: $0.uuid.uuidString, properties: Self.properties($0.properties))
            }
        )
        update(peripheral.identifier) {
            $0.state = "GATT profile observed"
            if let index = $0.services.firstIndex(where: { $0.id == observed.id }) {
                $0.services[index] = observed
            } else {
                $0.services.append(observed)
            }
        }
        publish("Observed GATT profile for \(peripheral.name ?? peripheral.identifier.uuidString)")
    }

    private func update(_ id: UUID, _ change: (inout BLEDiscoveredDevice) -> Void) {
        guard var device = devices[id] else { return }
        change(&device)
        devices[id] = device
        publish("Updated BLE observation")
    }

    private func publish(_ status: String) {
        onUpdate?(devices.values.sorted { $0.name < $1.name }, status)
    }

    private func status(for state: CBManagerState?) -> String {
        guard let state else { return "Bluetooth manager not started" }
        switch state {
        case .poweredOn: return "Bluetooth ready"
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported: return "Bluetooth unsupported"
        case .resetting: return "Bluetooth resetting"
        case .unknown: return "Bluetooth state unknown"
        @unknown default: return "Bluetooth unavailable"
        }
    }

    private static func properties(_ properties: CBCharacteristicProperties) -> [String] {
        var values: [String] = []
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.writeWithoutResponse) { values.append("write_without_response") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        return values
    }
}
