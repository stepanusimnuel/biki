import Foundation
import CoreBluetooth

// Real ESP32 connection over Bluetooth Low Energy — chosen over WiFi/HTTP
// since each transmission is just one small per-fruit reading, not worth
// a WiFi/HTTP round trip for. Cannot be exercised in the iOS Simulator at
// all (CoreBluetooth doesn't run there); use MockFruitDataSource for that.
//
// UUIDs and wire format below are confirmed against the real firmware —
// see ../../esp/ble.ino, the source of truth this file must stay in sync
// with. The sensor characteristic carries a fixed
// 12-byte binary packet (see DTOs.swift for the layout), and the command
// characteristic takes a single grade byte — neither is JSON. There is no
// batch-status characteristic: the firmware has no batch concept at all.
@MainActor
final class BLEFruitDataSource: NSObject, FruitDataSource {
    enum GATT {
        static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let sensorCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let commandCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    }

    enum BLEError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected: "Belum terhubung ke perangkat ESP32"
            }
        }
    }

    var onEvent: ((FruitEventDTO) -> Void)?
    var onStatusChange: ((ConnectionStatus) -> Void)?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var sensorCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?

    private var commandContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [GATT.serviceUUID])
    }

    func disconnect() {
        centralManager?.stopScan()
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    func sendGrade(_ grade: FruitGrade) async throws {
        guard let peripheral, let commandCharacteristic else {
            throw BLEError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandContinuation = continuation
            peripheral.writeValue(Data([grade.commandByte]), for: commandCharacteristic, type: .withResponse)
        }
    }
}

extension BLEFruitDataSource: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                connect()
            } else {
                onStatusChange?(.error("Bluetooth tidak aktif"))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([GATT.serviceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            onStatusChange?(.error(error?.localizedDescription ?? "Gagal terhubung ke ESP32"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            onStatusChange?(.error("Koneksi ke ESP32 terputus"))
        }
    }
}

extension BLEFruitDataSource: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == GATT.serviceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [GATT.sensorCharacteristicUUID, GATT.commandCharacteristicUUID],
            for: service
        )
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case GATT.sensorCharacteristicUUID:
                    sensorCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case GATT.commandCharacteristicUUID:
                    commandCharacteristic = characteristic
                default:
                    break
                }
            }
            onStatusChange?(.connected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == GATT.sensorCharacteristicUUID,
                  error == nil,
                  let data = characteristic.value,
                  let event = FruitEventDTO.decode(data) else { return }
            onEvent?(event)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == GATT.commandCharacteristicUUID else { return }
            if let error {
                commandContinuation?.resume(throwing: error)
            } else {
                commandContinuation?.resume(returning: ())
            }
            commandContinuation = nil
        }
    }
}
