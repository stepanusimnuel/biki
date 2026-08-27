import SwiftUI
import SwiftData

// Header + Weight Distribution chart + today's grading history, wired to
// real SwiftData records (via the same FruitDataSource/SyncEngine
// pipeline ContentView uses — MockFruitDataSource is a fine data source
// for this while BLE hardware isn't ready).
//
// Both the "Batch Terakhir" chart and "Riwayat Grading Hari Ini" below it
// are scoped to *today's* batches only, so they always agree — a chart
// showing yesterday's weight distribution next to an empty "no batches
// today" table read as contradictory. The full multi-day history lives on
// LaporanView instead (reached via Login's "Lihat Laporan").
struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Batch.startedAt, order: .reverse) private var allBatches: [Batch]

    @State private var searchText = ""
    @State private var perPage = 5
    @State private var currentPage = 0

    var onSortNewBatch: () -> Void = {}
    var onSignOut: () -> Void = {}

    private var todaysBatches: [Batch] {
        allBatches.filter { Calendar.current.isDateInToday($0.startedAt) }
    }

    // allBatches is already startedAt-descending, and filter preserves
    // order, so this is today's most recent batch — nil, not yesterday's
    // last batch, once today has none yet.
    private var lastBatch: Batch? { todaysBatches.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DashboardHeaderView(onSignOut: onSignOut)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Batch Terakhir")
                            .font(.largeTitle.bold())

                        weightDistributionSection

                        SortingHistorySection(
                            batches: todaysBatches,
                            searchText: $searchText,
                            perPage: $perPage,
                            currentPage: $currentPage,
                            showPagination: false,
                            onDelete: { batch in modelContext.delete(batch) }
                        )
                    }
                    .padding()
                    // Room for the floating button below so it never
                    // covers the last row of content.
                    .padding(.bottom, 72)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                startGradingButton
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
    }

    private var weightDistributionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Distribusi Berat per Grade")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let lastBatch {
                WeightDistributionChart(batch: lastBatch)
            } else {
                Text("Belum ada batch hari ini")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 190)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }

    private var startGradingButton: some View {
        Button(action: onSortNewBatch) {
            Label("Mulai Grading", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.large)
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [Batch.self, FruitRecord.self], inMemory: true)
}
