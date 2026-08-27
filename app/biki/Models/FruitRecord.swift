import Foundation
import SwiftData

@Model
final class FruitRecord {
    // receivedAt is what every FruitRecord @Query sorts and range-filters
    // by (see LaporanView).
    #Index<FruitRecord>([\.receivedAt])

    var id: UUID
    var batch: Batch?

    // Per-fruit sequence number — either the ESP32's own monotonic counter
    // or an app-generated fallback, depending on the active DataFieldSource
    // config. Dedup/gap detection only works when this is ESP32-sourced;
    // see SyncEngine.process.
    var fruitSeq: Int

    // iPad's own clock — still the authoritative timestamp for ordering
    // and display, independent of where `deviceTimestamp` comes from.
    var receivedAt: Date

    // Either the ESP32's own measurement-time clock or a copy of
    // `receivedAt`, depending on the active DataFieldSource config — see
    // SyncEngine.process.
    var deviceTimestamp: Date

    var weightG: Double

    // Raw TCS3200 color sensor reading from the ESP32 — NOT 0-255 RGB,
    // these are the sensor's raw pulse-period counts (see esp/ble.ino),
    // kept for diagnostics. `colorCode` is the ESP32's own nearest-
    // reference-color classification of that raw reading (0=unknown,
    // 1=red...7=white); `colorName`/`grade` below are computed from it
    // by FruitGrader at ingestion time.
    var rawR: Int16
    var rawG: Int16
    var rawB: Int16
    var colorCode: Int16

    // Computed by FruitGrader, stored for display/query convenience
    // rather than recomputed every read.
    var colorName: String

    // Stored as raw String for SwiftData compatibility; use `grade` for the
    // typed accessor.
    var gradeRaw: String

    var grade: FruitGrade {
        get { FruitGrade(rawValue: gradeRaw) ?? .e }
        set { gradeRaw = newValue.rawValue }
    }

    init(
        batch: Batch?,
        fruitSeq: Int,
        deviceTimestamp: Date,
        weightG: Double,
        rawR: Int16,
        rawG: Int16,
        rawB: Int16,
        colorCode: Int16,
        colorName: String,
        grade: FruitGrade
    ) {
        self.id = UUID()
        self.batch = batch
        self.fruitSeq = fruitSeq
        self.receivedAt = .now
        self.deviceTimestamp = deviceTimestamp
        self.weightG = weightG
        self.rawR = rawR
        self.rawG = rawG
        self.rawB = rawB
        self.colorCode = colorCode
        self.colorName = colorName
        self.gradeRaw = grade.rawValue
    }
}
