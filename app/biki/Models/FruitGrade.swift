import Foundation

enum FruitGrade: String, Codable, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"

    var id: String { rawValue }

    // Wire value for the ESP32 command characteristic, written back after
    // grading so the physical sorter routes the fruit — must match
    // esp/ble.ino's CMD_GRADE_* constants (1=A, 2=B, 3=C, 4=Edible, 5=Reject).
    var commandByte: UInt8 {
        switch self {
        case .a: return 1
        case .b: return 2
        case .c: return 3
        case .d: return 4
        case .e: return 5
        }
    }
}
