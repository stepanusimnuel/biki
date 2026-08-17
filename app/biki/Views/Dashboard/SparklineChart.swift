import SwiftUI
import Charts

// Last-7-days daily totals for one grade, as a line + area trend. Color is
// passed in rather than derived here, so the card's headline label and
// this chart always agree on the same red/yellow/green threshold — see
// GradeStatCardView.trendColor.
struct SparklineChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Day", index), y: .value("Weight", value))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.25), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                LineMark(x: .value("Day", index), y: .value("Weight", value))
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
    }
}
