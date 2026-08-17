import SwiftUI
import SwiftData

// Reached from Login's "Lihat Laporan" — a read-only report browse that
// doesn't set an active worker (unlike "Masuk"). Recreates the pre-revamp
// Dashboard layout (5 grade cards with week-over-week trend + sparkline)
// as its header, then a full, searchable/sortable/paginated batch history
// below — Homepage only shows today's batches now, so this is where the
// rest of the history lives.
struct LaporanView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FruitRecord.receivedAt, order: .reverse) private var allRecords: [FruitRecord]
    @Query(sort: \Batch.startedAt, order: .reverse) private var allBatches: [Batch]

    @State private var searchText = ""
    @State private var perPage = 10
    @State private var currentPage = 0
    @State private var sortColumn: SortColumn = .date
    @State private var sortAscending = false
    @State private var batchPendingDeletion: Batch?
    #if DEBUG
    @State private var pendingSeedAction: DebugSeedAction?
    #endif

    private enum SortColumn {
        case date, processed, staff, grade
    }

    #if DEBUG
    private enum DebugSeedAction {
        case fill, remove
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Grading Hari Ini")
                    .font(.largeTitle.bold())

                VStack(spacing: 16) {
                    cardRow(Array(gradeStats.prefix(2)))
                    cardRow(Array(gradeStats.suffix(3)))
                }

                historySection
            }
            .padding()
        }
        .navigationTitle("Laporan")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Isi Data Contoh") { pendingSeedAction = .fill }
                    Button("Hapus Data Contoh", role: .destructive) { pendingSeedAction = .remove }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
            }
        }
        .confirmationDialog(
            pendingSeedAction == .fill ? "Isi Data Contoh?" : "Hapus Data Contoh?",
            isPresented: Binding(
                get: { pendingSeedAction != nil },
                set: { if !$0 { pendingSeedAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingSeedAction == .fill ? "Isi Data" : "Hapus Data", role: .destructive) {
                switch pendingSeedAction {
                case .fill: DebugSeeder.seedHistoricalTrendData(modelContext: modelContext)
                case .remove: DebugSeeder.removeDemoData(modelContext: modelContext)
                case nil: break
                }
                pendingSeedAction = nil
            }
            Button("Batal", role: .cancel) { pendingSeedAction = nil }
        } message: {
            Text(pendingSeedAction == .fill
                 ? "8 hari data contoh (beberapa batch per hari, jumlah acak) akan ditambahkan. Data asli tidak akan terhapus."
                 : "Semua data contoh yang pernah ditambahkan akan dihapus. Data asli tidak akan terpengaruh.")
        }
        #endif
    }

    private func cardRow(_ stats: [GradeStat]) -> some View {
        HStack(spacing: 16) {
            ForEach(stats) { stat in
                GradeStatCardView(stat: stat)
            }
        }
    }

    // Real per-grade stats: today's totals, a week-over-week trend (today
    // vs the same weekday one week ago), and a 7-day sparkline — all
    // derived from persisted FruitRecords, nothing fabricated.
    private var gradeStats: [GradeStat] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        return FruitGrade.allCases.map { grade in
            let gradeRecords = allRecords.filter { $0.grade == grade }
            let todayRecords = gradeRecords.filter { calendar.isDate($0.receivedAt, inSameDayAs: today) }
            let totalWeight = todayRecords.reduce(0) { $0 + $1.weightG }

            let sparkline: [Double] = (0..<7).reversed().map { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 0 }
                return gradeRecords
                    .filter { calendar.isDate($0.receivedAt, inSameDayAs: day) }
                    .reduce(0) { $0 + $1.weightG }
            }

            let trend: Double? = {
                guard let lastWeekDay = calendar.date(byAdding: .day, value: -7, to: today) else { return nil }
                let lastWeekTotal = gradeRecords
                    .filter { calendar.isDate($0.receivedAt, inSameDayAs: lastWeekDay) }
                    .reduce(0) { $0 + $1.weightG }
                guard lastWeekTotal > 0 else { return nil }
                return ((totalWeight - lastWeekTotal) / lastWeekTotal) * 100
            }()

            return GradeStat(
                grade: grade,
                totalWeightG: totalWeight,
                totalCount: todayRecords.count,
                trendPercent: trend,
                sparklineValues: sparkline
            )
        }
    }

    // MARK: - History: search, sort, paginate

    private var filteredBatches: [Batch] {
        guard !searchText.isEmpty else { return allBatches }
        return allBatches.filter { batch in
            batch.batchLabel.localizedCaseInsensitiveContains(searchText)
                || batch.startedAt.formatted(date: .abbreviated, time: .omitted)
                    .localizedCaseInsensitiveContains(searchText)
                || batch.qcStaff.localizedCaseInsensitiveContains(searchText)
                || (batch.topGrade?.displayName.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var sortedBatches: [Batch] {
        let ascending = sortAscending
        switch sortColumn {
        case .date:
            return filteredBatches.sorted { ascending ? $0.startedAt < $1.startedAt : $0.startedAt > $1.startedAt }
        case .processed:
            return filteredBatches.sorted { ascending ? $0.totalWeightG < $1.totalWeightG : $0.totalWeightG > $1.totalWeightG }
        case .staff:
            return filteredBatches.sorted { ascending ? $0.qcStaff < $1.qcStaff : $0.qcStaff > $1.qcStaff }
        case .grade:
            return filteredBatches.sorted {
                let lhs = $0.topGrade?.rawValue ?? ""
                let rhs = $1.topGrade?.rawValue ?? ""
                return ascending ? lhs < rhs : lhs > rhs
            }
        }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(sortedBatches.count) / Double(perPage))))
    }

    private var pagedBatches: [Batch] {
        let start = currentPage * perPage
        guard start < sortedBatches.count else { return [] }
        return Array(sortedBatches[start..<min(start + perPage, sortedBatches.count)])
    }

    // Date separators only make sense when the list is actually ordered
    // by date — sorting by weight/staff/grade would scatter same-day
    // batches apart, so a header would just be confusing there.
    private func showsDateHeader(before index: Int) -> Bool {
        guard sortColumn == .date, index < pagedBatches.count else { return false }
        guard index > 0 else { return true }
        let calendar = Calendar.current
        return !calendar.isDate(pagedBatches[index].startedAt, inSameDayAs: pagedBatches[index - 1].startedAt)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Riwayat Grading")
                    .font(.title3.bold())
                Spacer()
                searchField
            }

            ScrollView(.horizontal, showsIndicators: false) {
                table
                    .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                        max(length, Column.minTotal)
                    }
            }

            HStack {
                perPagePicker
                Spacer()
                Button("Sebelumnya") { currentPage = max(0, currentPage - 1) }
                    .buttonStyle(.bordered)
                    .disabled(currentPage == 0)
                Text("Halaman \(currentPage + 1) dari \(pageCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Selanjutnya") { currentPage = min(pageCount - 1, currentPage + 1) }
                    .buttonStyle(.bordered)
                    .disabled(currentPage >= pageCount - 1)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .alert("Hapus batch ini?", isPresented: Binding(
            get: { batchPendingDeletion != nil },
            set: { if !$0 { batchPendingDeletion = nil } }
        )) {
            Button("Hapus", role: .destructive) {
                if let batch = batchPendingDeletion {
                    modelContext.delete(batch)
                }
                batchPendingDeletion = nil
            }
            Button("Batal", role: .cancel) { batchPendingDeletion = nil }
        } message: {
            if let batch = batchPendingDeletion {
                Text("\(batch.batchLabel) akan dihapus permanen, termasuk semua data buah di dalamnya.")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Cari", text: $searchText)
                .textFieldStyle(.plain)
                .onChange(of: searchText) { _, _ in currentPage = 0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 280)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
    }

    private var perPagePicker: some View {
        Picker("Per halaman", selection: $perPage) {
            ForEach([5, 10, 20, 50], id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .frame(width: 130)
        .onChange(of: perPage) { _, _ in currentPage = 0 }
    }

    private func sortableHeader(_ title: String, column: SortColumn, minWidth: CGFloat, maxWidth: CGFloat?) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = false
            }
            currentPage = 0
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: sortColumn == column ? (sortAscending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(sortColumn == column ? .primary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
    }

    private enum Column {
        static let dateMin: CGFloat = 220
        static let processedMin: CGFloat = 150
        static let processedMax: CGFloat = 220
        static let staffMin: CGFloat = 110
        static let staffMax: CGFloat = 170
        static let gradeMin: CGFloat = 120
        static let gradeMax: CGFloat = 170
        static let detailMin: CGFloat = 90
        static let detailMax: CGFloat = 110
        static let deleteWidth: CGFloat = 32
        static let spacing: CGFloat = 20
        // 6 columns (date/processed/staff/grade/detail/delete) means 5 gaps
        // between them, not 4 — and deleteWidth was missing entirely. Both
        // omissions understated the row's real minimum width, so narrower
        // containers (portrait, smaller iPads) sized the table too small
        // and clipped the trailing "Lihat Detail" link and delete icon
        // instead of properly triggering horizontal scroll.
        static let minTotal: CGFloat = dateMin + processedMin + staffMin + gradeMin + detailMin + deleteWidth + spacing * 5
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Column.spacing) {
                sortableHeader("Tanggal / Batch", column: .date, minWidth: Column.dateMin, maxWidth: .infinity)
                sortableHeader("Total Diproses", column: .processed, minWidth: Column.processedMin, maxWidth: Column.processedMax)
                sortableHeader("Petugas QC", column: .staff, minWidth: Column.staffMin, maxWidth: Column.staffMax)
                sortableHeader("Grade Terbanyak", column: .grade, minWidth: Column.gradeMin, maxWidth: Column.gradeMax)
                Text("").frame(minWidth: Column.detailMin, maxWidth: Column.detailMax, alignment: .leading)
                Text("").frame(width: Column.deleteWidth)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))

            Divider()

            if pagedBatches.isEmpty {
                Text("Tidak ada batch ditemukan")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(pagedBatches.enumerated()), id: \.element.id) { index, batch in
                    if showsDateHeader(before: index) {
                        Text(batch.startedAt.formatted(date: .complete, time: .omitted))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, index == 0 ? 10 : 16)
                            .padding(.bottom, 4)
                    }
                    HStack(spacing: Column.spacing) {
                        Text("\(batch.startedAt.formatted(date: .abbreviated, time: .omitted)) / \(batch.batchLabel)")
                            .frame(minWidth: Column.dateMin, maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f kg / %d buah", batch.totalWeightG / 1000, batch.totalCount))
                            .frame(minWidth: Column.processedMin, maxWidth: Column.processedMax, alignment: .leading)
                        Text(batch.qcStaff.isEmpty ? "—" : batch.qcStaff)
                            .foregroundStyle(batch.qcStaff.isEmpty ? .secondary : .primary)
                            .frame(minWidth: Column.staffMin, maxWidth: Column.staffMax, alignment: .leading)
                        Group {
                            if let top = batch.topGrade {
                                GradeBadge(grade: top)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: Column.gradeMin, maxWidth: Column.gradeMax, alignment: .leading)
                        NavigationLink("Lihat Detail") {
                            BatchDetailView(batch: batch)
                        }
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                        .frame(minWidth: Column.detailMin, maxWidth: Column.detailMax, alignment: .leading)
                        Button {
                            batchPendingDeletion = batch
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .frame(width: Column.deleteWidth)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LaporanView()
    }
    .modelContainer(for: [Batch.self, FruitRecord.self], inMemory: true)
}
