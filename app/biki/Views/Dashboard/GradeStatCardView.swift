import SwiftUI

// Today's totals for one grade, plus a week-over-week comparison derived
// from real FruitRecord history — see LaporanView.gradeStats. `trendPercent`
// is nil (not 0%) when there's no same-weekday-last-week data to compare
// against, so the UI can say "no data yet" instead of fabricating a number.
struct GradeStat: Identifiable {
    let grade: FruitGrade
    var id: String { grade.id }
    let totalWeightG: Double
    let totalCount: Int
    let trendPercent: Double?
    let sparklineValues: [Double]
}

struct GradeStatCardView: View {
    let stat: GradeStat

    // Within ±5%, week-over-week movement reads as "steady" (yellow)
    // rather than a real increase/decrease — avoids the trend line
    // flipping between green/red on noise for low-volume grades.
    private static let steadyThreshold = 5.0

    private var trendColor: Color {
        guard let trend = stat.trendPercent else { return .secondary }
        if trend > Self.steadyThreshold { return .green }
        if trend < -Self.steadyThreshold { return .red }
        return .yellow
    }

    private var trendIcon: String {
        guard let trend = stat.trendPercent else { return "minus" }
        if trend > Self.steadyThreshold { return "arrow.up.right" }
        if trend < -Self.steadyThreshold { return "arrow.down.right" }
        return "arrow.right"
    }

    private var trendLabel: String {
        guard let trend = stat.trendPercent else { return "Belum ada data pembanding" }
        if trend > Self.steadyThreshold { return String(format: "%.0f%% naik dari minggu lalu", trend) }
        if trend < -Self.steadyThreshold { return String(format: "%.0f%% turun dari minggu lalu", abs(trend)) }
        return "Stabil dari minggu lalu"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stat.grade.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(String(format: "%.1f kg • %d buah", stat.totalWeightG / 1000, stat.totalCount))
                .font(.title2.weight(.bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Label(trendLabel, systemImage: trendIcon)
                .font(.caption)
                .foregroundStyle(trendColor)

            SparklineChart(values: stat.sparklineValues, color: trendColor)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }
}
