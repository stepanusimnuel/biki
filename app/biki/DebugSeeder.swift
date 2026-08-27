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
// Demo batches use the exact same label format as real ones (see
// Batch.nextLabel) — there's deliberately nothing in a batch's visible
// label, staff name, or role that marks it as demo data, so it reads
// identically to real usage. `Batch.isDemo` is the actual marker:
// `seedHistoricalTrendData` only clears previously generated demo
// batches before inserting a fresh set, and `removeDemoData` only
// deletes batches with that flag set. Real data is never touched by
// either action, so filling and clearing demo data is fully reversible.
//
// A `@ModelActor` rather than a plain enum taking the view's MainActor
// ModelContext: inserting ~20k+ FruitRecords/day (roughly 2 tons at
// realistic per-fruit weight) takes tens of seconds — running that on the
// actor's own background executor keeps the UI thread free the whole
// time, instead of freezing the app for however long the insert loop
// takes. Callers construct one from `modelContext.container` (Sendable)
// and `await` its methods — see SettingsView/LaporanView.
#if DEBUG
@ModelActor
actor DebugSeeder {
    private static let demoStaffNames = ["Mamat", "Siti", "Budi", "Ani"]

    private struct GradeProfile {
        let weight: Double       // representative weight within FruitGrader's real band for this grade — see Sync/FruitGrader.swift
        let colorCode: Int16
        let startFraction: Double  // share of the day's total tonnage, 7 days ago
        let endFraction: Double    // share of the day's total tonnage, today
    }

    // Weights sit mid-band per FruitGrader's actual thresholds, so seeded
    // fruit grade the way its own label claims if re-graded. Fractions of
    // daily tonnage trend the same way the old count-based version did —
    // A/D increasing (green), B/E decreasing (red), C flat (yellow) — just
    // weight-based now so the totals mean something. Each day's fractions
    // sum to ~1.0 at both endpoints (and everywhere in between, since it's
    // a linear blend of two distributions that each sum to 1).
    private static let profiles: [GradeProfile] = [
        GradeProfile(weight: 115, colorCode: 2, startFraction: 0.12, endFraction: 0.25),  // A
        GradeProfile(weight: 90, colorCode: 2, startFraction: 0.32, endFraction: 0.18),   // B
        GradeProfile(weight: 72, colorCode: 2, startFraction: 0.25, endFraction: 0.25),   // C
        GradeProfile(weight: 57, colorCode: 3, startFraction: 0.11, endFraction: 0.20),   // D
        GradeProfile(weight: 100, colorCode: 1, startFraction: 0.20, endFraction: 0.12),  // E / Ditolak
    ]

    // Roughly 2 metric tons processed per day, ±10% so the total isn't
    // suspiciously identical every day.
    private static let dailyTargetWeightG: ClosedRange<Double> = 1_800_000...2_200_000

    func seedHistoricalTrendData() {
        removeDemoData(save: false)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var seq = Int.random(in: 5000...9000)

        // Seeded labels must not collide with same-day real batches (or
        // each other), so Batch.nextLabel needs to see every label that
        // already exists as we go.
        var knownLabels = Set((try? modelContext.fetch(FetchDescriptor<Batch>()))?.map(\.batchLabel) ?? [])

        for dayOffset in stride(from: 7, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let progress = Double(7 - dayOffset) / 7.0

            // Several grading sessions per day, at varied times — a busy
            // sorting line running ~2 tons through in a day is many
            // batches, not one or two.
            let sessionCount = Int.random(in: 4...8)
            let sessionHours = (0..<sessionCount).map { _ in Int.random(in: 6...18) }.sorted()

            var dayBatches: [Batch] = []
            for hour in sessionHours {
                let start = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...59), second: 0, of: day) ?? day
                let label = Batch.nextLabel(for: start, existingLabels: Array(knownLabels))
                knownLabels.insert(label)
                let batch = Batch(batchLabel: label, qcStaff: Self.demoStaffNames.randomElement()!, qcRole: WorkerRole.qc.rawValue)
                batch.isDemo = true
                batch.startedAt = start
                batch.status = .completed
                batch.endedAt = calendar.date(byAdding: .minute, value: Int.random(in: 30...180), to: start)
                modelContext.insert(batch)
                dayBatches.append(batch)
            }

            let dailyTotalG = Double.random(in: Self.dailyTargetWeightG)

            for profile in Self.profiles {
                let fraction = profile.startFraction + (profile.endFraction - profile.startFraction) * progress
                let gradeWeightG = dailyTotalG * fraction * Double.random(in: 0.9...1.1)
                let count = max(1, Int((gradeWeightG / profile.weight).rounded()))

                for _ in 0..<count {
                    seq += 1
                    let batch = dayBatches.randomElement()!
                    let weight = profile.weight + Double.random(in: -6...6)
                    let batchDuration = max(60, (batch.endedAt ?? batch.startedAt).timeIntervalSince(batch.startedAt))
                    let recordTime = batch.startedAt.addingTimeInterval(Double.random(in: 0...batchDuration))
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

            // Save per day rather than one giant end-of-run transaction —
            // ~20k+ records/day adds up fast across 8 days.
            try? modelContext.save()
        }
    }

    func removeDemoData(save: Bool = true) {
        let all = (try? modelContext.fetch(FetchDescriptor<Batch>())) ?? []
        for batch in all where batch.isDemo {
            modelContext.delete(batch)
        }
        if save {
            try? modelContext.save()
        }
    }
}
#endif
