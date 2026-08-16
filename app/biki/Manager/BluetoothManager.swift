//
//  BluetoothManager.swift
//  biki
//
//  Created by Stepanus Imanuel on 09/08/26.
//

import Foundation
import CoreBluetooth
import Observation

struct SensorReading {
    var weightGrams: Double = 0

    var red: Int = 0
    var green: Int = 0
    var blue: Int = 0

    var colorCode: Int = 0
    var hxReady = false
    var colorReady = false

    var colorName: String {
        switch colorCode {
        case 1: return "Merah"
        case 2: return "Orange"
        case 3: return "Kuning"
        case 4: return "Hijau"
        case 5: return "Biru"
        case 6: return "Hitam"
        case 7: return "Putih"
        default: return "Tidak dikenal"
        }
    }
}

enum OrangeGrade: UInt8 {
    case gradeA = 1
    case gradeB = 2
    case gradeC = 3
    case edible = 4
    case reject = 5

    var name: String {
        switch self {
        case .gradeA: return "Grade A"
        case .gradeB: return "Grade B"
        case .gradeC: return "Grade C"
        case .edible: return "Edible"
        case .reject: return "Reject"
        }
    }
}

@Observable
final class BluetoothManager: NSObject {
    var reading = SensorReading()
    var status = "Menyiapkan Bluetooth…"
    var isConnected = false

    private var centralManager: CBCentralManager!
    private var sensorPeripheral: CBPeripheral?

    private let serviceUUID = CBUUID(
        string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    private let sensorCharacteristicUUID = CBUUID(
        string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    )
    
    var currentGrade: OrangeGrade?
    var isProcessingOrange = false

    private var isArmed = true

    private var lastWeight: Double?
    private var stableReadingCount = 0
    private var emptyReadingCount = 0
    
    private let minimumOrangeWeight = 50.0
    private let emptyWeightThreshold = 10.0

    private let stableWeightDifference = 2.0
    private let requiredStableReadings = 3

    private var gradeWorkItem: DispatchWorkItem?

    private let commandCharacteristicUUID = CBUUID(
        string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    )

    private var commandCharacteristic: CBCharacteristic?

    override init() {
        super.init()

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil
        )
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            status = "Bluetooth belum aktif."
            return
        }

        status = "Mencari ESP32-Sensor…"

        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: nil
        )
    }

    // Paket ESP32: 12 byte
    //
    // [0-3]   berat ×100, Int32 little-endian
    // [4-5]   RAW R, UInt16 little-endian
    // [6-7]   RAW G, UInt16 little-endian
    // [8-9]   RAW B, UInt16 little-endian
    // [10]    kode warna
    // [11]    status
    private func decodeSensorPacket(_ data: Data) {
        let bytes = [UInt8](data)

        guard bytes.count >= 12 else {
            status = "Paket sensor tidak lengkap."
            return
        }

        let rawWeight = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)

        let weightHundredths = Int32(bitPattern: rawWeight)

        let rawRed = UInt16(bytes[4])
            | (UInt16(bytes[5]) << 8)

        let rawGreen = UInt16(bytes[6])
            | (UInt16(bytes[7]) << 8)

        let rawBlue = UInt16(bytes[8])
            | (UInt16(bytes[9]) << 8)

        reading.weightGrams = Double(weightHundredths) / 100.0
        reading.red = Int(rawRed)
        reading.green = Int(rawGreen)
        reading.blue = Int(rawBlue)
        reading.colorCode = Int(bytes[10])

        let sensorStatus = bytes[11]

        reading.hxReady = (sensorStatus & 0x01) != 0
        reading.colorReady = (sensorStatus & 0x02) != 0

        checkAutomaticGrading()
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()

        case .poweredOff:
            status = "Aktifkan Bluetooth di iPhone."

        case .unauthorized:
            status = "Izin Bluetooth ditolak."

        default:
            status = "Bluetooth belum siap."
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let deviceName = peripheral.name
            ?? advertisementData[
                CBAdvertisementDataLocalNameKey
            ] as? String

        guard deviceName == "ESP32-Sensor" else {
            return
        }

        sensorPeripheral = peripheral
        sensorPeripheral?.delegate = self

        central.stopScan()

        status = "Menghubungkan ke ESP32-Sensor…"

        central.connect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        isConnected = true
        status = "Terhubung."

        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        status = "Koneksi gagal."

        startScanning()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        status = "Terputus. Mencari ulang…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.startScanning()
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services else {
            return
        }

        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics(
                [
                    sensorCharacteristicUUID,
                    commandCharacteristicUUID
                ],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else {
            return
        }

        for characteristic in characteristics {
            if characteristic.uuid == sensorCharacteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                status = "Menerima data sensor."
            }

            if characteristic.uuid == commandCharacteristicUUID {
                commandCharacteristic = characteristic
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == sensorCharacteristicUUID,
              let data = characteristic.value else {
            return
        }

        decodeSensorPacket(data)
    }
    
    private func sendGradeToESP32(_ grade: OrangeGrade) {
        guard let peripheral = sensorPeripheral,
              let commandCharacteristic else {
            status = "Command servo belum siap."
            isProcessingOrange = false
            return
        }

        peripheral.writeValue(
            Data([grade.rawValue]),
            for: commandCharacteristic,
            type: .withResponse
        )

        status = "\(grade.name) dikirim ke ESP32."
    }
    
    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == commandCharacteristicUUID else {
            return
        }

        if let error {
            isProcessingOrange = false
            currentGrade = nil
            status = "Gagal mengirim grade: \(error.localizedDescription)"
        }
    }
    
    func calculateGrade(from reading: SensorReading) -> OrangeGrade {
        guard reading.hxReady,
              reading.colorReady else {
            return .reject
        }

        let weight = reading.weightGrams
        let isOrange = reading.colorCode == 2
        let isYellow = reading.colorCode == 3

        // Reject jika sensor mendeteksi warna selain
        // orange atau kuning.
        guard isOrange || isYellow else {
            return .reject
        }

        // Reject jika terlalu kecil atau terlalu besar.
        guard weight >= 50, weight <= 180 else {
            return .reject
        }

        // Grade A dan B harus benar-benar orange.
        if isOrange && weight >= 100 && weight <= 130 {
            return .gradeA
        }

        if isOrange &&
            ((weight >= 80 && weight < 100) ||
             (weight > 130 && weight <= 145)) {
            return .gradeB
        }

        if (isOrange || isYellow) &&
            ((weight >= 65 && weight < 80) ||
             (weight > 145 && weight <= 160)) {
            return .gradeC
        }

        return .edible
    }
    
    private func checkAutomaticGrading() {
        let weight = reading.weightGrams

        // Ketika sistem sedang tidak siap, tunggu load cell kosong
        // sebelum menerima jeruk baru.
        if !isArmed {
            if weight <= emptyWeightThreshold {
                emptyReadingCount += 1

                if emptyReadingCount >= requiredStableReadings {
                    isArmed = true
                    isProcessingOrange = false
                    emptyReadingCount = 0
                    stableReadingCount = 0
                    lastWeight = nil

                    status = "Siap. Letakkan jeruk berikutnya."
                }
            } else {
                emptyReadingCount = 0
            }

            return
        }

        // Belum ada jeruk atau sensor belum siap.
        guard reading.hxReady,
              reading.colorReady,
              weight >= minimumOrangeWeight else {
            stableReadingCount = 0
            lastWeight = nil
            return
        }

        // Berat dianggap stabil apabila perubahan maksimal 2 gram.
        if let lastWeight,
           abs(weight - lastWeight) <= stableWeightDifference {
            stableReadingCount += 1
        } else {
            stableReadingCount = 1
        }

        self.lastWeight = weight

        guard stableReadingCount >= requiredStableReadings,
              !isProcessingOrange else {
            status = "Menunggu berat jeruk stabil…"
            return
        }

        let grade = calculateGrade(from: reading)

        // Kunci sistem supaya satu jeruk hanya diproses satu kali.
        isArmed = false
        isProcessingOrange = true
        currentGrade = grade

        status = "Data stabil. \(grade.name) terdeteksi."

        // Tunggu 500 ms setelah grade didapat.
        gradeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.sendGradeToESP32(grade)
        }

        gradeWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.5,
            execute: workItem
        )
    }
}
