import Foundation
import SwiftData

// DEBUG-only historical data generator for exercising LaporanView's
// week-over-week trend/sparkline coloring without waiting on real
// multi-day ESP32 usage. Lives in the app itself (triggered from
// LaporanView/SettingsView) rather than an external script run against a
// specific simulator container — that approach breaks every time the
// sandboxed container rotates on rebuild/reinstall, which happens often
// during active development. This works from any install, Simulator or
// device.
//
// Demo batches are tagged via a "-DEMO" label suffix rather than wiping
// the whole store: `seedHistoricalTrendData` only clears previously
// generated demo batches before inserting a fresh set, and
// `removeDemoData` only deletes batches carrying that tag. Real data
// (or whatever's active) is never touched by either action, so filling
// and clearing demo data is fully reversible.
#if DEBUG
enum DebugSeeder {
    private static let demoLabelSuffix = "-DEMO"
    private static let demoStaffNames = ["Mamat", "Siti", "Budi", "Ani"]

    private struct GradeProfile {
        let weight: Double
        let colorCode: Int16
        let startCount: Int  // roughly how many 7 days ago
        let endCount: Int    // roughly how many today
    }

    // startCount/endCount set the overall week-over-week trend direction
    // (and therefore trend color) for each grade: A/D increasing (green),
    // B/E decreasing (red), C roughly flat (yellow). Per-day counts are
    // randomized around the line between these two rather than following
    // it exactly, so the sparkline visibly zigzags day to day instead of
    // moving in a straight line.
    private static let profiles: [GradeProfile] = [
        GradeProfile(weight: 115, colorCode: 2, startCount: 1, endCount: 6),  // A
        GradeProfile(weight: 90, colorCode: 2, startCount: 6, endCount: 1),   // B
        GradeProfile(weight: 72, colorCode: 2, startCount: 3, endCount: 4),   // C
        GradeProfile(weight: 55, colorCode: 3, startCount: 1, endCount: 5),   // D
        GradeProfile(weight: 100, colorCode: 1, startCount: 5, endCount: 1),  // E / Ditolak
    ]

    static func seedHistoricalTrendData(modelContext: ModelContext) {
        removeDemoData(modelContext: modelContext, save: false)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var seq = Int.random(in: 5000...9000)

        for dayOffset in stride(from: 7, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let progress = Double(7 - dayOffset) / 7.0

            // Multiple grading sessions (batches) per day, at varied times
            // — a real QC shift runs several batches, not one.
            let sessionCount = Int.random(in: 2...4)
            let sessionHours = (0..<sessionCount).map { _ in Int.random(in: 7...17) }.sorted()

            var dayBatches: [Batch] = []
            for (index, hour) in sessionHours.enumerated() {
                let start = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...59), second: 0, of: day) ?? day
                let batch = Batch(
                    batchLabel: "B\(day.formatted(.iso8601.year().month().day()))\(demoLabelSuffix)-\(index + 1)",
                    qcStaff: demoStaffNames.randomElement()!
                )
                batch.startedAt = start
                batch.status = .completed
                batch.endedAt = calendar.date(byAdding: .minute, value: Int.random(in: 20...90), to: start)
                modelContext.insert(batch)
                dayBatches.append(batch)
            }

            for profile in profiles {
                let base = Double(profile.startCount) + (Double(profile.endCount) - Double(profile.startCount)) * progress
                // Floored at 1, not 0 — every profile has some baseline
                // activity every day, so a same-weekday-last-week
                // comparison point always exists and every card gets a
                // real trend color instead of occasionally landing on
                // "no data yet" by pure noise.
                let noisyCount = max(1, Int((base + Double.random(in: -2...2)).rounded()))

                for _ in 0..<noisyCount {
                    seq += 1
                    let batch = dayBatches.randomElement()!
                    let weight = profile.weight + Double.random(in: -5...5)
                    let recordTime = calendar.date(byAdding: .minute, value: Int.random(in: 0...60), to: batch.startedAt) ?? batch.startedAt
                    let grade = FruitGrader.grade(weightG: weight, colorCode: Int(profile.colorCode), hxReady: true, colorReady: true)
                    let colorName = FruitGrader.colorName(colorCode: Int(profile.colorCode))
                    let record = FruitRecord(
                        batch: batch,
                        fruitSeq: seq,
                        deviceTimestamp: recordTime,
                        weightG: weight,
                        rawR: 80, rawG: 150, rawB: 150,
                        colorCode: profile.colorCode,
                        colorName: colorName,
                        grade: grade
                    )
                    record.receivedAt = recordTime
                    modelContext.insert(record)
                }
            }
        }

        try? modelContext.save()
    }

    static func removeDemoData(modelContext: ModelContext, save: Bool = true) {
        let all = (try? modelContext.fetch(FetchDescriptor<Batch>())) ?? []
        for batch in all where batch.batchLabel.contains(demoLabelSuffix) {
            modelContext.delete(batch)
        }
        if save {
            try? modelContext.save()
        }
    }
}
#endif
