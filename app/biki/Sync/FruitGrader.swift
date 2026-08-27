import Foundation

// Weight + color -> shipping grade, and color code -> human-readable name.
// The ESP32 only reports raw weight + its own nearest-reference color
// classification (see DTOs.swift) — it does NOT grade fruit itself.
// Ported directly from the working companion app's
// BluetoothManager.calculateGrade (formerly at app/biki/Manager/
// BluetoothManager.swift), which has always run this combination
// app-side against real hardware; `colorName` mirrors esp/ble.ino's own
// colorName() so the label matches what the firmware already classified.
// Pure, stateless computation with no main-actor dependency — marked
// nonisolated (overriding the project's default MainActor isolation) so
// it can be called from any context, including DebugSeeder's background
// @ModelActor.
nonisolated enum FruitGrader {
    static func grade(weightG: Double, colorCode: Int, hxReady: Bool, colorReady: Bool) -> FruitGrade {
        guard hxReady, colorReady else { return .e }

        let isOrange = colorCode == 2
        let isYellow = colorCode == 3
        let isRed = colorCode == 1

        // Reject anything that isn't orange or yellow.
        guard isOrange || isYellow else { return .e }

        // Reject if too small or too large.
        guard weightG >= 50, weightG <= 180 else { return .e }

        // Grade A and B must be genuinely orange.
        if isRed || isOrange, weightG >= 100, weightG <= 130 {
            return .a
        }

        if isOrange || isRed,
           (weightG >= 80 && weightG < 100) || (weightG > 130 && weightG <= 145) {
            return .b
        }

        if (isOrange || isYellow),
           (weightG >= 65 && weightG < 80) || (weightG > 145 && weightG <= 160) {
            return .c
        }

        return .d
    }

    static func colorName(colorCode: Int) -> String {
        switch colorCode {
        case 1: return "Merah"
        case 2: return "Orange"
        case 3: return "Kuning"
        case 4: return "Hijau"
        case 5: return "Biru"
        case 6: return "Hitam"
        case 7: return "Putih"
        default: return "Tidak diketahui"
        }
    }
}
