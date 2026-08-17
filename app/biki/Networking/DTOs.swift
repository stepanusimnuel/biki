import Foundation

// Wire contract with the ESP32 over BLE — see README.md and ../../esp/ble.ino
// (firmware source of truth) for the GATT service/characteristic layout.
// This is a fixed 12-byte BINARY packet,
// NOT JSON — the ESP32 is a raw sensor, not a full grader: it reports
// `weightG` plus the color sensor's raw RGB reading and its own
// nearest-reference color classification (`colorCode`). Combining weight
// + color into a shipping grade (A-E) happens app-side — see
// `Sync/FruitGrader.swift`.
//
// Packet layout (little-endian):
//   [0-3]  weight x100 (grams), Int32
//   [4-5]  raw R, UInt16
//   [6-7]  raw G, UInt16
//   [8-9]  raw B, UInt16
//   [10]   color code: 0=unknown 1=red 2=orange 3=yellow 4=green 5=blue 6=black 7=white
//   [11]   status bitmask: bit0 = load cell ready, bit1 = color sensor ready
//
// There is no seq/timestamp field in the real packet — the firmware never
// sends either, so both decode to nil against real hardware; see
// `DataFieldSource` for how the app falls back to its own counter/clock
// when that happens.
struct FruitEventDTO {
    let weightG: Double
    let rawR: Int
    let rawG: Int
    let rawB: Int
    let colorCode: Int
    let hxReady: Bool
    let colorReady: Bool
    let seq: Int?
    let timestamp: Date?

    static func decode(_ data: Data) -> FruitEventDTO? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }

        let rawWeight = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let weightHundredths = Int32(bitPattern: rawWeight)

        let r = Int(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
        let g = Int(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))
        let b = Int(UInt16(bytes[8]) | (UInt16(bytes[9]) << 8))

        let status = bytes[11]

        return FruitEventDTO(
            weightG: Double(weightHundredths) / 100.0,
            rawR: r,
            rawG: g,
            rawB: b,
            colorCode: Int(bytes[10]),
            hxReady: (status & 0x01) != 0,
            colorReady: (status & 0x02) != 0,
            seq: nil,
            timestamp: nil
        )
    }
}
