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
//
// The sensor characteristic streams continuously while a fruit settles on
// the load cell, not one packet per fruit — see processDecodedPacket for
// the settle-detection debounce that turns that raw stream into one
// onEvent call per physical fruit. SyncEngine assumes every onEvent is a
// distinct fruit, so this is not optional.
@MainActor
final class BLEFruitDataSource: NSObject, FruitDataSource {
    enum GATT {
        static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let sensorCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let commandCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        // Matches the companion app's BluetoothManager — scanning
        // withServices: [serviceUUID] already filters at the radio level,
        // but this is an extra explicit check against the advertised name
        // in case another device ever advertises the same service UUID.
        static let expectedDeviceName = "ESP32-Sensor"
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

    // Settle-detection debounce, ported from the companion app's
    // BluetoothManager.checkAutomaticGrading. The ESP32 streams raw
    // weight/color continuously while a fruit sits on the load cell and
    // settles — it is NOT one clean packet per fruit. Without this,
    // SyncEngine (which treats every onEvent call as one distinct fruit)
    // would grade and persist a FruitRecord for every single notification,
    // wildly over-counting one physical fruit as many. A fruit only
    // counts once weight has held steady (within stableWeightDifferenceG)
    // for requiredStableReadings consecutive packets; after that, further
    // packets are ignored until the platform drops back near-empty for
    // requiredStableReadings consecutive packets, confirming the fruit
    // has actually left before the next one can be detected.
    private static let minimumFruitWeightG = 50.0
    private static let emptyWeightThresholdG = 10.0
    private static let stableWeightDifferenceG = 2.0
    private static let requiredStableReadings = 3

    private var isArmed = true
    private var lastStableCheckWeight: Double?
    private var stableReadingCount = 0
    private var emptyReadingCount = 0

    // Auto-reconnect: an unexpected drop mid-batch retries silently up to
    // maxAutoReconnectAttempts times (short delay between each) before
    // giving up and surfacing a terminal `.error` with a manual retry
    // path — see GradingView's "Coba Lagi" button, wired through
    // SyncEngine.retryConnection() to connect() below. isIntentionalStop
    // distinguishes that from a *deliberate* disconnect() call (batch
    // completed, engine torn down), which must never trigger a retry.
    private static let maxAutoReconnectAttempts = 3
    private static let reconnectDelaySeconds: UInt64 = 2
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var isIntentionalStop = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // Entry point for both the initial connection and a manual retry
    // after auto-reconnect has given up — either way, start counting a
    // fresh set of auto-reconnect attempts.
    func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isIntentionalStop = false
        resetSettleState()
        guard let centralManager, centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [GATT.serviceUUID])
    }

    func disconnect() {
        isIntentionalStop = true
        reconnectTask?.cancel()
        reconnectTask = nil
        centralManager?.stopScan()
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    // Called on an unexpected drop (didDisconnectPeripheral) or a failed
    // reconnect attempt (didFailToConnect) — never on a deliberate
    // disconnect(). Retries connecting to the *same* already-discovered
    // peripheral (no need to re-scan) after a short delay, up to the
    // attempt limit, then surfaces a terminal error for the operator to
    // retry manually.
    private func attemptReconnect() {
        guard !isIntentionalStop else { return }
        guard let peripheral, let centralManager else {
            onStatusChange?(.error("Koneksi ke ESP32 terputus"))
            return
        }
        guard reconnectAttempt < Self.maxAutoReconnectAttempts else {
            onStatusChange?(.error("Koneksi ke ESP32 terputus setelah \(Self.maxAutoReconnectAttempts)x percobaan otomatis"))
            return
        }
        reconnectAttempt += 1
        onStatusChange?(.reconnecting(attempt: reconnectAttempt, maxAttempts: Self.maxAutoReconnectAttempts))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.reconnectDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            centralManager.connect(peripheral)
        }
    }

    private func resetSettleState() {
        isArmed = true
        lastStableCheckWeight = nil
        stableReadingCount = 0
        emptyReadingCount = 0
    }

    // Runs every decoded packet through the settle state machine and
    // forwards to onEvent at most once per physical fruit — see the
    // property comment above for why this exists.
    private func processDecodedPacket(_ event: FruitEventDTO) {
        let weight = event.weightG

        guard isArmed else {
            // Waiting for the previous fruit to clear the platform.
            if weight <= Self.emptyWeightThresholdG {
                emptyReadingCount += 1
                if emptyReadingCount >= Self.requiredStableReadings {
                    resetSettleState()
                }
            } else {
                emptyReadingCount = 0
            }
            return
        }

        guard event.hxReady, event.colorReady, weight >= Self.minimumFruitWeightG else {
            stableReadingCount = 0
            lastStableCheckWeight = nil
            return
        }

        if let lastStableCheckWeight, abs(weight - lastStableCheckWeight) <= Self.stableWeightDifferenceG {
            stableReadingCount += 1
        } else {
            stableReadingCount = 1
        }
        lastStableCheckWeight = weight

        guard stableReadingCount >= Self.requiredStableReadings else { return }

        // Weight has held steady long enough — this is one settled fruit.
        // Lock out further detections until the platform reads empty
        // again, then surface it.
        isArmed = false
        onEvent?(event)
    }

    func sendGrade(_ grade: FruitGrade) async throws {
        guard let peripheral, let commandCharacteristic else {
            print("BLEFruitDataSource: cannot send grade \(grade.rawValue) — no peripheral/commandCharacteristic (not connected, or characteristic discovery hasn't completed yet)")
            throw BLEError.notConnected
        }
        print("BLEFruitDataSource: writing grade \(grade.rawValue) (byte \(grade.commandByte)) to command characteristic")
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
        let deviceName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard deviceName == GATT.expectedDeviceName else { return }
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Connected again (whether this was the first attempt or an
            // auto/manual reconnect) — reset the attempt count so a
            // *future* drop gets its own fresh set of retries.
            reconnectAttempt = 0
        }
        peripheral.discoverServices([GATT.serviceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            attemptReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            attemptReconnect()
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
            processDecodedPacket(event)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == GATT.commandCharacteristicUUID else { return }
            if let error {
                print("BLEFruitDataSource: command write was NOT acknowledged by ESP32 — \(error)")
                commandContinuation?.resume(throwing: error)
            } else {
                print("BLEFruitDataSource: command write acknowledged by ESP32")
                commandContinuation?.resume(returning: ())
            }
            commandContinuation = nil
        }
    }
}
