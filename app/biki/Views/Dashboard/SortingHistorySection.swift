import SwiftUI

struct SortingHistorySection: View {
    let batches: [Batch]
    @Binding var searchText: String
    @Binding var perPage: Int
    @Binding var currentPage: Int

    // Homepage shows today-only batches (never more than a handful), so it
    // passes showPagination: false to drop the Per halaman/Selanjutnya
    // footer entirely rather than paginating a list that's already short.
    var showPagination: Bool = true
    // Only Homepage wires this up — lets ops remove a batch they started
    // and immediately stopped by accident. Deleting is real and permanent,
    // so a confirmation alert sits in front of it either way — per Apple
    // HIG, destructive actions should confirm upfront rather than rely on
    // undo-after-the-fact.
    var onDelete: ((Batch) -> Void)?

    @State private var batchPendingDeletion: Batch?

    // Always latest-first, regardless of the order `batches` arrives in.
    private var sortedBatches: [Batch] {
        batches.sorted { $0.startedAt > $1.startedAt }
    }

    // One search box matches date, batch label, grade, and QC staff — the
    // Figma design's separate concept of per-column filters isn't built,
    // but this covers the same ground with a single field.
    private var filteredBatches: [Batch] {
        guard !searchText.isEmpty else { return sortedBatches }
        return sortedBatches.filter { batch in
            batch.batchLabel.localizedCaseInsensitiveContains(searchText)
                || batch.startedAt.formatted(date: .abbreviated, time: .omitted)
                    .localizedCaseInsensitiveContains(searchText)
                || batch.qcStaff.localizedCaseInsensitiveContains(searchText)
                || (batch.topGrade?.displayName.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filteredBatches.count) / Double(perPage))))
    }

    private var pagedBatches: [Batch] {
        guard showPagination else { return filteredBatches }
        let start = currentPage * perPage
        guard start < filteredBatches.count else { return [] }
        return Array(filteredBatches[start..<min(start + perPage, filteredBatches.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // iPhone: title + up-to-280pt search field side by side left
            // almost no room for either on a ~350-400pt-wide screen —
            // stack them instead. iPad keeps the original HStack, since
            // its width was what searchField's 280pt cap was sized for.
            if isPhoneIdiom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Riwayat Grading Hari Ini")
                        .font(.title3.bold())
                    searchField
                }
            } else {
                HStack {
                    Text("Riwayat Grading Hari Ini")
                        .font(.title3.bold())
                    Spacer()
                    searchField
                }
            }

            // iPhone: the fixed-column `table` below needs Column.minTotal
            // (sized for iPad) of width and falls back to horizontal
            // scroll on anything narrower — on iPhone that meant "Lihat
            // Detail" and the delete button were only reachable by
            // scrolling right, every time. `tablePhone` is a genuinely
            // different layout (stacked rows, no fixed column widths) that
            // needs no scrolling at all. iPad keeps the exact original
            // `table` + ScrollView(.horizontal), untouched.
            if isPhoneIdiom {
                tablePhone
            } else {
                // `containerRelativeFrame` reads the ScrollView's own
                // available width directly and synchronously — unlike a
                // GeometryReader + PreferenceKey pair, which read that
                // width one layout pass late via a preference round-trip
                // and got stuck reporting 0. `max(length, Column.minTotal)`
                // keeps a floor: stretch to fill on wide layouts, fall
                // back to horizontal scroll when the container is
                // narrower than the columns comfortably need.
                //
                // Each column below has `maxWidth: .infinity`, so once
                // `table` has a real resolved width, all five columns
                // share the leftover space evenly — a single trailing
                // spacer after "View Detail" left all of it as one dead
                // gap instead.
                ScrollView(.horizontal, showsIndicators: false) {
                    table
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            max(length, Column.minTotal)
                        }
                }
            }

            if showPagination {
                HStack {
                    perPagePicker
                    Spacer()
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
                    onDelete?(batch)
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
            ForEach([5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .frame(width: 130)
        .onChange(of: perPage) { _, _ in currentPage = 0 }
    }

    private func headerLabel(_ text: String, chevron: String, minWidth: CGFloat, maxWidth: CGFloat?) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: chevron)
                .font(.caption2)
        }
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
    }

    // Only Date/Batch grows unbounded — it's the "headline" column, so
    // extra width should visually anchor there. The rest (numbers, staff
    // name, grade badge, button) get a modest cap instead of `.infinity`,
    // so they stay compact and legible rather than stretching into empty
    // space just because the row got wider.
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

    // iPhone-only: each batch as a compact 3-line stacked row instead of
    // fixed-width columns, so nothing needs Column.minTotal of horizontal
    // room — "Lihat Detail" and delete are always on-screen, no scrolling.
    // 44pt-tall tap targets on both per Apple's minimum tappable size.
    private var tablePhone: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pagedBatches.isEmpty {
                Text("Tidak ada batch ditemukan")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ForEach(pagedBatches) { batch in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(batch.batchLabel)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let top = batch.topGrade {
                                GradeBadge(grade: top)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        Text("\(batch.qcStaff.isEmpty ? "—" : batch.qcStaff) · \(String(format: "%.1f kg / %d buah", batch.totalWeightG / 1000, batch.totalCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            NavigationLink("Lihat Detail") {
                                BatchDetailView(batch: batch, onDelete: onDelete)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            Spacer()
                            if onDelete != nil {
                                Button {
                                    batchPendingDeletion = batch
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Column.spacing) {
                headerLabel("Batch", chevron: "chevron.down", minWidth: Column.dateMin, maxWidth: .infinity)
                headerLabel("Total Diproses", chevron: "chevron.up", minWidth: Column.processedMin, maxWidth: Column.processedMax)
                headerLabel("Petugas QC", chevron: "chevron.up", minWidth: Column.staffMin, maxWidth: Column.staffMax)
                headerLabel("Grade Terbanyak", chevron: "chevron.down", minWidth: Column.gradeMin, maxWidth: Column.gradeMax)
                Text("")
                    .frame(minWidth: Column.detailMin, maxWidth: Column.detailMax, alignment: .leading)
                if onDelete != nil {
                    Text("").frame(width: Column.deleteWidth)
                }
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
                ForEach(pagedBatches) { batch in
                    HStack(spacing: Column.spacing) {
                        Text(batch.batchLabel)
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
                            BatchDetailView(batch: batch, onDelete: onDelete)
                        }
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                        .frame(minWidth: Column.detailMin, maxWidth: Column.detailMax, alignment: .leading)
                        if onDelete != nil {
                            Button {
                                batchPendingDeletion = batch
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .frame(width: Column.deleteWidth)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }
}
