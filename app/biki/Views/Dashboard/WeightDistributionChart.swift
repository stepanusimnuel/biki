import SwiftUI
import Charts

// Horizontal bar chart of weight per grade for one batch — replaces the
// old 5-card layout. `batch` is nil-safe so an empty/no-batch state just
// renders all-zero bars instead of crashing or needing a separate branch.
struct WeightDistributionChart: View {
    let batch: Batch?

    private var rows: [(grade: FruitGrade, weightKg: Double)] {
        FruitGrade.allCases.map { grade in
            (grade, (batch?.weight(for: grade) ?? 0) / 1000)
        }
    }

    var body: some View {
        Chart(rows, id: \.grade) { row in
            BarMark(
                x: .value("Weight", row.weightKg),
                y: .value("Grade", row.grade.displayName)
            )
            .foregroundStyle(row.grade.badgeColor.gradient)
            .cornerRadius(4)
            .annotation(position: .trailing) {
                Text(String(format: "%.1f kg", row.weightKg))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended)
        }
        .frame(height: 190)
    }
}
