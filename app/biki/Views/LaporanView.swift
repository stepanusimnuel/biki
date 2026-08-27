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
    @Query(sort: \Batch.startedAt, order: .reverse) private var allBatches: [Batch]

    // Was a `@Query private var allRecords: [FruitRecord]` — a *live*
    // query, so SwiftData kept every matching row (thousands, once real
    // usage or demo data piles up) fetched and continuously observed for
    // the entire time this view existed, even though only 5 small summary
    // cards ever read from it. gradeStats is a report snapshot, not
    // something that needs per-write live updates, so it's now a one-shot
    // fetch cached in @State (see loadGradeStats) — computed on appear and
    // manually refreshed after actions that actually change the data
    // (seeding/removing demo data, deleting a batch).
    @State private var gradeStats: [GradeStat] = FruitGrade.allCases.map {
        GradeStat(grade: $0, totalWeightG: 0, totalCount: 0, trendPercent: nil, sparklineValues: Array(repeating: 0, count: 7))
    }

    // Per-batch totals/top-grade for the history table below. Batch's own
    // totalWeightG/totalCount/topGrade each scan that batch's fruitRecords
    // relationship — fine for one batch (see BatchDetailView), but the
    // table renders/sorts/searches across every batch, and once a batch
    // has thousands of records (realistic demo/production volume), that's
    // thousands of relationship-array materializations per render, per
    // page change, per sort. This is computed once (see
    // loadBatchAggregates) from a single bulk fetch instead.
    private struct BatchAggregate {
        var totalCount = 0
        var totalWeightG = 0.0
        var gradeCounts: [FruitGrade: Int] = [:]
        var topGrade: FruitGrade? { gradeCounts.max(by: { $0.value < $1.value })?.key }
    }
    // Cache, not a per-render fetch: an entry, once loaded, is reused for
    // the rest of this view's lifetime — including navigating to
    // BatchDetailView and back, since @State (and this dictionary) simply
    // isn't touched by that push/pop. Only cleared (see
    // invalidateAggregateCache) when the underlying data actually changes.
    @State private var batchAggregates: [PersistentIdentifier: BatchAggregate] = [:]
    // Bulk-loaded once per cache generation, only when something actually
    // needs every batch's aggregate at once (sorting or searching by it —
    // see ensureAllAggregatesLoaded). Everyday paging/browsing never sets
    // this; it's covered by the cheaper per-row load instead.
    @State private var hasBulkLoadedAggregates = false
    // Bumped by invalidateAggregateCache so each visible row's .task(id:)
    // re-fires and reloads — a plain cache clear wouldn't do that on its
    // own, since .task(id:) only re-runs when its id changes, not just
    // because the dictionary it reads from was mutated externally.
    @State private var cacheGeneration = 0

    @State private var searchText = ""
    @State private var perPage = 10
    @State private var currentPage = 0
    @State private var sortColumn: SortColumn = .date
    @State private var sortAscending = false
    @State private var batchPendingDeletion: Batch?
    #if DEBUG
    @State private var pendingSeedAction: DebugSeedAction?
    @State private var isSeeding = false
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

                // iPhone: stacking all 5 cards one-per-row (an earlier fix
                // for 3-per-row being too cramped) fixed readability but
                // pushed the table hundreds of points down the screen. A
                // horizontal carousel — a standard iOS pattern for stat
                // cards (Health, App Store, etc.) — keeps this section a
                // single fixed-height row while each card still gets a
                // comfortable, non-cramped width. iPad keeps the original
                // 2-then-3 grid, unchanged.
                if isPhoneIdiom {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(gradeStats) { stat in
                                GradeStatCardView(stat: stat)
                                    .frame(width: 240)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        cardRow(Array(gradeStats.prefix(2)))
                        cardRow(Array(gradeStats.suffix(3)))
                    }
                }

                historySection
            }
            .padding()
        }
        .task {
            // batchAggregates deliberately isn't loaded here — each visible
            // row loads its own on appear (see the table row's .task(id:)),
            // so opening this page only ever fetches aggregates for the
            // batches actually on screen, not the whole history.
            loadGradeStats()
        }
        .refreshable {
            invalidateAggregateCache()
            loadGradeStats()
        }
        .navigationTitle("Laporan")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isSeeding {
                    ProgressView()
                } else {
                    Menu {
                        Button("Isi Data Contoh") { pendingSeedAction = .fill }
                        Button("Hapus Data Contoh", role: .destructive) { pendingSeedAction = .remove }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
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
                let action = pendingSeedAction
                pendingSeedAction = nil
                isSeeding = true
                Task {
                    // DebugSeeder is a @ModelActor — this runs on its own
                    // background executor, not the main actor, so the UI
                    // (including the toolbar ProgressView) stays
                    // responsive for the ~1 minute this can take.
                    let seeder = DebugSeeder(modelContainer: modelContext.container)
                    switch action {
                    case .fill: await seeder.seedHistoricalTrendData()
                    case .remove: await seeder.removeDemoData()
                    case nil: break
                    }
                    // gradeStats/batchAggregates are one-shot fetches/caches
                    // now, not live @Query, so they need an explicit
                    // refresh whenever seeding/removing demo data actually
                    // changes the underlying FruitRecords.
                    invalidateAggregateCache()
                    loadGradeStats()
                    isSeeding = false
                }
            }
            Button("Batal", role: .cancel) { pendingSeedAction = nil }
        } message: {
            Text(pendingSeedAction == .fill
                 ? "8 hari data contoh (±2 ton/hari, beberapa batch per hari) akan ditambahkan — prosesnya bisa memakan waktu sekitar satu menit. Data asli tidak akan terhapus."
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
    //
    // Fetched fresh here (not via @Query — see the gradeStats property
    // comment) with two deliberate scoping choices, since this can touch
    // tens of thousands of rows once real usage or demo data piles up:
    //   1. predicate limits the fetch to the last 8 days (7-day sparkline
    //      + today) instead of every FruitRecord ever graded.
    //   2. propertiesToFetch limits each row to just the 3 fields actually
    //      used here, skipping rawR/G/B, colorCode, colorName,
    //      deviceTimestamp, fruitSeq, id, and the batch relationship that
    //      @Query would otherwise materialize for every row.
    // Then one pass over the result bucketing by (day, grade), instead of
    // 5 grades × 9 day-windows separately filtering/reducing the same
    // array (that was O(45) full scans every time this ran).
    private func loadGradeStats() {
        struct DayGrade: Hashable { let day: Date; let grade: FruitGrade }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let windowStart = calendar.date(byAdding: .day, value: -7, to: today) else { return }

        var descriptor = FetchDescriptor<FruitRecord>(
            predicate: #Predicate { $0.receivedAt >= windowStart }
        )
        descriptor.propertiesToFetch = [\.receivedAt, \.weightG, \.gradeRaw]
        guard let records = try? modelContext.fetch(descriptor) else { return }

        var weightByDayGrade: [DayGrade: Double] = [:]
        var countByDayGrade: [DayGrade: Int] = [:]
        for record in records {
            let key = DayGrade(day: calendar.startOfDay(for: record.receivedAt), grade: record.grade)
            weightByDayGrade[key, default: 0] += record.weightG
            countByDayGrade[key, default: 0] += 1
        }

        gradeStats = FruitGrade.allCases.map { grade in
            let totalWeight = weightByDayGrade[DayGrade(day: today, grade: grade)] ?? 0
            let totalCount = countByDayGrade[DayGrade(day: today, grade: grade)] ?? 0

            let sparkline: [Double] = (0..<7).reversed().map { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 0 }
                return weightByDayGrade[DayGrade(day: day, grade: grade)] ?? 0
            }

            let trend: Double? = {
                guard let lastWeekDay = calendar.date(byAdding: .day, value: -7, to: today) else { return nil }
                let lastWeekTotal = weightByDayGrade[DayGrade(day: lastWeekDay, grade: grade)] ?? 0
                guard lastWeekTotal > 0 else { return nil }
                return ((totalWeight - lastWeekTotal) / lastWeekTotal) * 100
            }()

            return GradeStat(
                grade: grade,
                totalWeightG: totalWeight,
                totalCount: totalCount,
                trendPercent: trend,
                sparklineValues: sparkline
            )
        }
    }

    // Targeted fetch for exactly one batch — this is what actually
    // populates batchAggregates during normal browsing: each visible
    // table row calls this from its own .task(id:), so only the batches
    // currently on screen are ever queried. A no-op if that batch's
    // aggregate is already cached (e.g. paging back to a page already
    // visited, or returning from BatchDetailView).
    private func loadAggregate(for batch: Batch) {
        let batchID = batch.persistentModelID
        guard batchAggregates[batchID] == nil else { return }

        var descriptor = FetchDescriptor<FruitRecord>(
            predicate: #Predicate { $0.batch?.persistentModelID == batchID }
        )
        descriptor.propertiesToFetch = [\.weightG, \.gradeRaw]
        guard let records = try? modelContext.fetch(descriptor) else { return }

        var aggregate = BatchAggregate()
        for record in records {
            aggregate.totalCount += 1
            aggregate.totalWeightG += record.weightG
            aggregate.gradeCounts[record.grade, default: 0] += 1
        }
        batchAggregates[batchID] = aggregate
    }

    // Sorting or searching by an aggregate column needs every filtered
    // batch's value up front — there's no way to know the correct global
    // order (or find every match) from just the currently-visible page.
    // Only called for those two actions (see sortableHeader/searchField),
    // never on plain open/page/date-sort, and only once per cache
    // generation — already-cached entries from per-row loads get
    // overwritten with the same values, which is harmless.
    private func ensureAllAggregatesLoaded() {
        guard !hasBulkLoadedAggregates else { return }
        loadAllBatchAggregates()
        hasBulkLoadedAggregates = true
    }

    // One bulk fetch across every FruitRecord (unlike loadGradeStats, this
    // is deliberately NOT date-scoped — the table must show correct
    // totals for batches of any age) instead of touching each batch's
    // fruitRecords relationship individually. propertiesToFetch limits
    // each row to the 2 fields actually needed; relationshipKeyPathsFor-
    // Prefetching bulk-loads the `batch` relationship up front so grouping
    // by batch below doesn't fault it in one row at a time.
    private func loadAllBatchAggregates() {
        var descriptor = FetchDescriptor<FruitRecord>()
        descriptor.propertiesToFetch = [\.weightG, \.gradeRaw]
        descriptor.relationshipKeyPathsForPrefetching = [\.batch]
        guard let records = try? modelContext.fetch(descriptor) else { return }

        var result: [PersistentIdentifier: BatchAggregate] = [:]
        for record in records {
            guard let batchID = record.batch?.persistentModelID else { continue }
            var aggregate = result[batchID] ?? BatchAggregate()
            aggregate.totalCount += 1
            aggregate.totalWeightG += record.weightG
            aggregate.gradeCounts[record.grade, default: 0] += 1
            result[batchID] = aggregate
        }
        batchAggregates = result
    }

    // Called whenever the underlying FruitRecord data actually changes
    // (seed/remove demo data, delete a batch, manual pull-to-refresh).
    // Bumping cacheGeneration is what makes already-rendered rows'
    // .task(id:) re-fire and reload — see the property's comment.
    private func invalidateAggregateCache() {
        batchAggregates = [:]
        hasBulkLoadedAggregates = false
        cacheGeneration += 1
    }

    // MARK: - History: search, sort, paginate

    private var filteredBatches: [Batch] {
        guard !searchText.isEmpty else { return allBatches }
        return allBatches.filter { batch in
            batch.batchLabel.localizedCaseInsensitiveContains(searchText)
                || batch.startedAt.formatted(date: .abbreviated, time: .omitted)
                    .localizedCaseInsensitiveContains(searchText)
                || batch.qcStaff.localizedCaseInsensitiveContains(searchText)
                || (batchAggregates[batch.persistentModelID]?.topGrade?.displayName
                    .localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var sortedBatches: [Batch] {
        let ascending = sortAscending
        switch sortColumn {
        case .date:
            return filteredBatches.sorted { ascending ? $0.startedAt < $1.startedAt : $0.startedAt > $1.startedAt }
        case .processed:
            let decorated = filteredBatches.map { ($0, batchAggregates[$0.persistentModelID]?.totalWeightG ?? 0) }
            return decorated
                .sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
                .map(\.0)
        case .staff:
            return filteredBatches.sorted { ascending ? $0.qcStaff < $1.qcStaff : $0.qcStaff > $1.qcStaff }
        case .grade:
            let decorated = filteredBatches.map { ($0, batchAggregates[$0.persistentModelID]?.topGrade?.rawValue ?? "") }
            return decorated
                .sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
                .map(\.0)
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
            // iPhone: title + up-to-280pt search field side by side left
            // almost no room for either on a ~350-400pt-wide screen —
            // stack them instead, with a sort Menu added (see tablePhone —
            // there are no tappable column headers to sort by there, so
            // this replaces that affordance). iPad keeps the original
            // HStack with sortableHeader taps doing the same job.
            if isPhoneIdiom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Riwayat Grading")
                        .font(.title3.bold())
                    HStack {
                        searchField
                        Spacer()
                        sortMenuPhone
                    }
                }
            } else {
                HStack {
                    Text("Riwayat Grading")
                        .font(.title3.bold())
                    Spacer()
                    searchField
                }
            }

            // iPhone: tablePhone is a stacked-row layout needing no fixed
            // column width, so nothing needs horizontal scrolling to
            // reach "Lihat Detail"/delete — see tablePhone. iPad keeps
            // the exact original fixed-column table, untouched.
            if isPhoneIdiom {
                tablePhone
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    table
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            max(length, Column.minTotal)
                        }
                }
            }

            // iPhone: picker + 2 buttons + page-count text all fighting
            // for one row (even a follow-up 3-way split of just the
            // buttons+text) still squeezed "Sebelumnya"/"Selanjutnya"
            // enough to wrap their labels ("Sebelum-nya"). Buttons now get
            // their own row with a single Spacer between them — their
            // full natural width, no competition — and the page-count
            // text moves to its own centered row. iPad keeps the original
            // single-row layout, untouched.
            if isPhoneIdiom {
                VStack(spacing: 8) {
                    HStack {
                        perPagePicker
                        Spacer()
                    }
                    Text("Halaman \(currentPage + 1) dari \(pageCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack {
                        Button("Sebelumnya") { currentPage = max(0, currentPage - 1) }
                            .buttonStyle(.bordered)
                            .disabled(currentPage == 0)
                            .lineLimit(1)
                        Spacer()
                        Button("Selanjutnya") { currentPage = min(pageCount - 1, currentPage + 1) }
                            .buttonStyle(.bordered)
                            .disabled(currentPage >= pageCount - 1)
                            .lineLimit(1)
                    }
                }
            } else {
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
                    // Cascade-deletes that batch's FruitRecords, which
                    // gradeStats/batchAggregates' one-shot fetches/caches
                    // won't otherwise notice.
                    invalidateAggregateCache()
                    loadGradeStats()
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
                .onChange(of: searchText) { _, newValue in
                    currentPage = 0
                    // Matching against Grade Terbanyak needs every
                    // filtered batch's aggregate, not just the visible
                    // page — same reasoning as sorting by it.
                    if !newValue.isEmpty {
                        ensureAllAggregatesLoaded()
                    }
                }
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
            // Sorting by Total Diproses/Grade Terbanyak needs every
            // filtered batch's aggregate to order correctly — not just
            // whichever page happens to be visible.
            if column == .processed || column == .grade {
                ensureAllAggregatesLoaded()
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
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
    }

    // Distinct from Batch's own `id` (used by ForEach below) — this is
    // what gates the row's aggregate-loading .task, so it re-fires when
    // either the row now shows a different batch (paging/sorting) or the
    // cache was invalidated (cacheGeneration bumped), but not on a plain
    // re-render of the same row showing the same batch.
    private struct RowTaskID: Equatable {
        let batchID: PersistentIdentifier
        let generation: Int
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

    // iPhone-only: tablePhone (below) has no tappable column headers to
    // sort by, since it isn't a fixed-column layout — this Menu replaces
    // that affordance. Deliberately a standalone copy of sortableHeader's
    // selection logic rather than a shared helper, so iPad's existing
    // sortableHeader is never touched by this iPhone-only addition.
    private var sortMenuPhone: some View {
        Menu {
            sortMenuButtonPhone(.date, title: "Batch")
            sortMenuButtonPhone(.processed, title: "Total Diproses")
            sortMenuButtonPhone(.staff, title: "Petugas QC")
            sortMenuButtonPhone(.grade, title: "Grade Terbanyak")
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    private func sortMenuButtonPhone(_ column: SortColumn, title: String) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = false
            }
            currentPage = 0
            if column == .processed || column == .grade {
                ensureAllAggregatesLoaded()
            }
        } label: {
            if sortColumn == column {
                Label(title, systemImage: sortAscending ? "chevron.up" : "chevron.down")
            } else {
                Text(title)
            }
        }
    }

    // iPhone-only: each batch as a compact 3-line stacked row instead of
    // fixed-width columns, so nothing needs Column.minTotal of horizontal
    // room — "Lihat Detail" and delete are always on-screen, no scrolling.
    // Sorting is via sortMenuPhone instead of tappable column headers, but
    // the date-group headers (showsDateHeader) are kept since they're not
    // a width concern. 44pt-tall tap targets on both per Apple's minimum
    // tappable size.
    private var tablePhone: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pagedBatches.isEmpty {
                Text("Tidak ada batch ditemukan")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(pagedBatches.enumerated()), id: \.element.id) { index, batch in
                    if showsDateHeader(before: index) {
                        Text(batch.startedAt.formatted(date: .complete, time: .omitted))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 10 : 16)
                            .padding(.bottom, 4)
                    }
                    let aggregate = batchAggregates[batch.persistentModelID]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(batch.batchLabel)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let top = aggregate?.topGrade {
                                GradeBadge(grade: top)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        Text("\(batch.qcStaff.isEmpty ? "—" : batch.qcStaff) · \(String(format: "%.1f kg / %d buah", (aggregate?.totalWeightG ?? 0) / 1000, aggregate?.totalCount ?? 0))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            NavigationLink("Lihat Detail") {
                                BatchDetailView(batch: batch, onDelete: { modelContext.delete($0) })
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            Spacer()
                            Button {
                                batchPendingDeletion = batch
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 6)
                    .task(id: RowTaskID(batchID: batch.persistentModelID, generation: cacheGeneration)) {
                        loadAggregate(for: batch)
                    }
                    Divider()
                }
            }
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Column.spacing) {
                sortableHeader("Batch", column: .date, minWidth: Column.dateMin, maxWidth: .infinity)
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
                        let aggregate = batchAggregates[batch.persistentModelID]
                        Text(batch.batchLabel)
                            .frame(minWidth: Column.dateMin, maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f kg / %d buah", (aggregate?.totalWeightG ?? 0) / 1000, aggregate?.totalCount ?? 0))
                            .frame(minWidth: Column.processedMin, maxWidth: Column.processedMax, alignment: .leading)
                        Text(batch.qcStaff.isEmpty ? "—" : batch.qcStaff)
                            .foregroundStyle(batch.qcStaff.isEmpty ? .secondary : .primary)
                            .frame(minWidth: Column.staffMin, maxWidth: Column.staffMax, alignment: .leading)
                        Group {
                            if let top = aggregate?.topGrade {
                                GradeBadge(grade: top)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: Column.gradeMin, maxWidth: Column.gradeMax, alignment: .leading)
                        NavigationLink("Lihat Detail") {
                            BatchDetailView(batch: batch, onDelete: { modelContext.delete($0) })
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
                    .task(id: RowTaskID(batchID: batch.persistentModelID, generation: cacheGeneration)) {
                        loadAggregate(for: batch)
                    }
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
