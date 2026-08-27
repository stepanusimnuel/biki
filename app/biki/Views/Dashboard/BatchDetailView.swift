import SwiftUI

// Read-only detail for a past batch, matching the Figma "sorting-summary-page"
// design: a custom back chevron + big batch-label title, share/delete
// actions top-trailing, the QC worker's name+role, Tanggal/Pukul, and a
// grade-by-grade "Sorting Summary" table. The system nav bar is hidden so
// the title can be this page's own large heading rather than a small inline
// bar title, matching the design.
struct BatchDetailView: View {
    let batch: Batch
    var onDelete: ((Batch) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sortColumn: SortColumn?
    @State private var sortAscending = true
    @State private var exportFile: ExportFile?
    @State private var isConfirmingDelete = false

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
    // pagination here on purpose, see summarySection. Reads batch's
    // gradeBreakdown once (one pass over fruitRecords) rather than calling
    // count(for:)/weight(for:) ten times, which would each re-scan it.
    private var summaries: [GradeSummary] {
        let breakdown = batch.gradeBreakdown
        return FruitGrade.allCases.map { grade in
            let entry = breakdown[grade]
            return GradeSummary(grade: grade, count: entry?.count ?? 0, weightG: entry?.weightG ?? 0)
        }
    }

    private var sortedSummaries: [GradeSummary] {
        let ascending = sortAscending
        switch sortColumn {
        case nil:
            return summaries
        case .grade:
            return summaries.sorted { ascending ? $0.grade.rawValue < $1.grade.rawValue : $0.grade.rawValue > $1.grade.rawValue }
        case .quantity:
            return summaries.sorted { ascending ? $0.count < $1.count : $0.count > $1.count }
        case .weight:
            return summaries.sorted { ascending ? $0.weightG < $1.weightG : $0.weightG > $1.weightG }
        }
    }

    private var initial: String {
        batch.qcStaff.first.map(String.init)?.uppercased() ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleRow
                workerRow

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Tanggal:").foregroundStyle(.secondary)
                        Text(batch.startedAt.formatted(date: .long, time: .omitted))
                    }
                    HStack(spacing: 4) {
                        Text("Pukul:").foregroundStyle(.secondary)
                        Text(batch.startedAt.formatted(date: .omitted, time: .shortened))
                    }
                }

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $exportFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .alert("Hapus batch ini?", isPresented: $isConfirmingDelete) {
            Button("Hapus", role: .destructive) {
                onDelete?(batch)
                dismiss()
            }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("\(batch.batchLabel) akan dihapus permanen, termasuk semua data buah di dalamnya.")
        }
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.plain)

            Text(batch.batchLabel)
                .font(.title.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

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
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Buat Laporan")

            if onDelete != nil {
                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Hapus Batch")
            }
        }
    }

    private var workerRow: some View {
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
                Text(batch.qcStaff.isEmpty ? "—" : batch.qcStaff)
                    .font(.subheadline.weight(.semibold))
                Text(batch.qcRole.isEmpty ? WorkerRole.qc.rawValue : batch.qcRole)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                sortableHeader("Grade", column: .grade)
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

            Divider()

            HStack {
                Text("Total")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(batch.totalCount) buah")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "%.1f kg", batch.totalWeightG / 1000))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }
}
