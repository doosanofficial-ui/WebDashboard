import CoreBluetooth
import Foundation
import TelemetryCore

enum BLETransportError: Error, Equatable {
    case bluetoothUnavailable
    case peripheralNotSelected
    case characteristicsNotConfigured
    case notConnected
    case connectionFailed
}

/// Core Bluetooth adapter with explicit, observed characteristic configuration.
/// No ELM327 UUID is inferred from the product name or from another adapter.
@MainActor
final class BLETransport: NSObject, CANTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let targetPeripheralID: UUID?
    private let serviceUUID: CBUUID?
    private let writeUUID: CBUUID?
    private let notifyUUID: CBUUID?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var closed = false

    init(targetPeripheralID: UUID?, serviceUUID: CBUUID?, writeUUID: CBUUID?, notifyUUID: CBUUID?) {
        self.targetPeripheralID = targetPeripheralID
        self.serviceUUID = serviceUUID
        self.writeUUID = writeUUID
        self.notifyUUID = notifyUUID
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func incoming() async -> AsyncThrowingStream<Data, Error> { stream }

    func scan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() { central.stopScan() }

    func select(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    func connect() async throws {
        guard central.state == .poweredOn else { throw BLETransportError.bluetoothUnavailable }
        guard let peripheral else { throw BLETransportError.peripheralNotSelected }
        guard serviceUUID != nil, writeUUID != nil, notifyUUID != nil else {
            throw BLETransportError.characteristicsNotConfigured
        }
        closed = false
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            central.connect(peripheral, options: nil)
        }
    }

    func write(_ data: Data) async throws {
        guard let peripheral, peripheral.state == .connected,
              let characteristic = writeCharacteristic else {
            throw BLETransportError.notConnected
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    func close() async {
        closed = true
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        connectContinuation?.resume(throwing: BLETransportError.connectionFailed)
        connectContinuation = nil
        continuation.finish()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            fail(BLETransportError.bluetoothUnavailable)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if let targetPeripheralID, peripheral.identifier != targetPeripheralID { return }
        self.peripheral = peripheral
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(serviceUUID.map { [$0] })
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        fail(BLETransportError.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if !closed { fail(BLETransportError.connectionFailed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            fail(BLETransportError.connectionFailed)
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            fail(BLETransportError.connectionFailed)
            return
        }
        for characteristic in characteristics {
            if let writeUUID, characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if let notifyUUID, characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
        }
        guard let notifyCharacteristic, writeCharacteristic != nil else { return }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { continuation.finish(throwing: error); return }
        if let value = characteristic.value { continuation.yield(value) }
    }

    private func fail(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        continuation.finish(throwing: error)
    }
}
