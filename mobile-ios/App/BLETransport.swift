import CoreBluetooth
import Foundation
import TelemetryCore

enum BLETransportError: Error, Equatable {
    case bluetoothUnavailable
    case peripheralNotSelected
    case characteristicsNotConfigured
    case notConnected
    case connectionFailed
    case unsupportedCharacteristicProperties
    case notificationFailed
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
    private var stateContinuation: CheckedContinuation<Void, Error>?
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
        try await waitForBluetoothReady()
        if peripheral == nil, let targetPeripheralID {
            peripheral = central.retrievePeripherals(withIdentifiers: [targetPeripheralID]).first
        }
        guard let peripheral else { throw BLETransportError.peripheralNotSelected }
        guard serviceUUID != nil, writeUUID != nil, notifyUUID != nil else {
            throw BLETransportError.characteristicsNotConfigured
        }
        closed = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        peripheral.delegate = self
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectContinuation = continuation
                central.connect(peripheral, options: nil)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelPendingConnection() }
        })
    }

    func write(_ data: Data) async throws {
        guard let peripheral, peripheral.state == .connected,
              let characteristic = writeCharacteristic else {
            throw BLETransportError.notConnected
        }
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            throw BLETransportError.unsupportedCharacteristicProperties
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
        stateContinuation?.resume(throwing: BLETransportError.connectionFailed)
        stateContinuation = nil
        continuation.finish()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateContinuation?.resume()
            stateContinuation = nil
        case .poweredOff, .unauthorized, .unsupported:
            let error = BLETransportError.bluetoothUnavailable
            stateContinuation?.resume(throwing: error)
            stateContinuation = nil
            fail(error)
        default:
            break
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
        guard let writeCharacteristic, let notifyCharacteristic else { return }
        guard writeCharacteristic.properties.contains(.write) || writeCharacteristic.properties.contains(.writeWithoutResponse),
              notifyCharacteristic.properties.contains(.notify) || notifyCharacteristic.properties.contains(.indicate) else {
            fail(BLETransportError.unsupportedCharacteristicProperties)
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(BLETransportError.notificationFailed)
            return
        }
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

    private func waitForBluetoothReady() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff, .unauthorized, .unsupported:
            throw BLETransportError.bluetoothUnavailable
        case .unknown, .resetting:
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if central.state == .poweredOn {
                        continuation.resume()
                    } else if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
                        continuation.resume(throwing: BLETransportError.bluetoothUnavailable)
                    } else {
                        stateContinuation = continuation
                    }
                }
            }, onCancel: { [weak self] in
                Task { @MainActor in self?.cancelStateWait() }
            })
        @unknown default:
            throw BLETransportError.bluetoothUnavailable
        }
    }

    private func cancelStateWait() {
        let pending = stateContinuation
        stateContinuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func cancelPendingConnection() {
        let pending = connectContinuation
        connectContinuation = nil
        pending?.resume(throwing: CancellationError())
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        closed = true
    }
}
