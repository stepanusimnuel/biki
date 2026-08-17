import SwiftUI

// Read-only detail for a past batch, matching the Figma "Last Process" +
// "Sorting Summary" design. Pushed onto the existing NavigationStack from
// Sorting History, so the system back button/title still apply — the
// avatar/name row and "Generate Report" button below are page content,
// not a replacement nav bar.
struct BatchDetailView: View {
    let batch: Batch

    @AppStorage("operatorName") private var operatorName = ""
    @State private var sortColumn: SortColumn = .grade
    @State private var sortAscending = true
    @State private var exportFile: ExportFile?

    private enum SortColumn {
        case grade, quantity, weight
    }

    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private struct GradeSummary: Identifiable {
        let grade: FruitGrade
        var id: String { grade.id }
        let count: Int
        let weightG: Double
    }

    // Always exactly 5 rows (one per FruitGrade case) — there's no
    // pagination here on purpose, see summarySection.
    private var summaries: [GradeSummary] {
        FruitGrade.allCases.map { grade in
            GradeSummary(grade: grade, count: batch.count(for: grade), weightG: batch.weight(for: grade))
        }
    }

    private var sortedSummaries: [GradeSummary] {
        let ascending = sortAscending
        switch sortColumn {
        case .grade:
            return summaries.sorted { ascending ? $0.grade.rawValue < $1.grade.rawValue : $0.grade.rawValue > $1.grade.rawValue }
        case .quantity:
            return summaries.sorted { ascending ? $0.count < $1.count : $0.count > $1.count }
        case .weight:
            return summaries.sorted { ascending ? $0.weightG < $1.weightG : $0.weightG > $1.weightG }
        }
    }

    private var initial: String {
        operatorName.first.map(String.init)?.uppercased() ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                Text("Proses Terakhir")
                    .font(.largeTitle.bold())

                lastProcessRow

                if !batch.rejectedEvents.isEmpty {
                    NavigationLink {
                        RejectedEventsView(batch: batch)
                    } label: {
                        Label("\(batch.rejectedEvents.count) data ditolak sensor", systemImage: "xmark.octagon")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                summarySection
            }
            .padding()
        }
        .navigationTitle(batch.batchLabel)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { file in
            ShareSheet(activityItems: [file.url])
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.primary)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(initial)
                            .font(.headline)
                            .foregroundStyle(.background)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(operatorName.isEmpty ? "Atur nama" : operatorName)
                        .font(.subheadline.weight(.semibold))
                    Text("Kontrol Kualitas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button("Ekspor sebagai CSV") {
                    if let url = BatchExporter.writeCSV(for: batch) {
                        exportFile = ExportFile(url: url)
                    }
                }
                Button("Ekspor sebagai PDF") {
                    if let url = BatchExporter.writePDF(for: batch) {
                        exportFile = ExportFile(url: url)
                    }
                }
            } label: {
                Label("Buat Laporan", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private var lastProcessRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Tanggal:").foregroundStyle(.secondary)
                Text(batch.startedAt.formatted(date: .abbreviated, time: .omitted))
            }
            HStack(spacing: 4) {
                Text("Waktu:").foregroundStyle(.secondary)
                Text(batch.startedAt.formatted(date: .omitted, time: .shortened))
            }

            Text("Total")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 12) {
                Text(String(format: "%.1f kg", batch.totalWeightG / 1000))
                Text("|").foregroundStyle(.tertiary)
                Text("\(batch.totalCount) buah")
            }
            .font(.largeTitle.bold())
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ringkasan Grading")
                .font(.title3.bold())

            summaryTable
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }

    private func sortableHeader(_ title: String, column: SortColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: sortColumn == column ? (sortAscending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(sortColumn == column ? .primary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sortableHeader("Grade Terbanyak", column: .grade)
                sortableHeader("Jumlah", column: .quantity)
                sortableHeader("Berat", column: .weight)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))

            Divider()

            ForEach(Array(sortedSummaries.enumerated()), id: \.element.id) { index, summary in
                HStack {
                    GradeBadge(grade: summary.grade)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(summary.count) buah")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f kg", summary.weightG / 1000))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                if index < sortedSummaries.count - 1 {
                    Divider()
                }
            }
        }
    }
}
