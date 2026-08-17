import SwiftUI
import SwiftData

// Homepage (Dashboard) is shown with no active batch; once startBatch()
// inserts an active Batch, this view's own @Query picks it up and
// switches to GradingView automatically — no separate "confirm start" tap
// needed. Login (see HaloBikiApp.RootView) is the real app entry point;
// this view only owns the Homepage <-> Grading toggle and the sync engine.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Batch.startedAt, order: .reverse) private var batches: [Batch]
    @State private var syncEngine: SyncEngine?
    // Real ESP32 BLE hardware isn't ready yet — this lets testing continue
    // via MockFruitDataSource in the meantime. All three are configured
    // via SettingsView (gear icon on Homepage).
    @AppStorage("useMockDataSource") private var useMockDataSource = true
    @AppStorage("idSource") private var idSourceRaw = DataFieldSource.esp32.rawValue
    @AppStorage("timestampSource") private var timestampSourceRaw = DataFieldSource.esp32.rawValue
    @AppStorage("operatorName") private var operatorName = ""
    @State private var isStarting = false

    let onSignOut: () -> Void

    private var activeBatch: Batch? {
        batches.first { $0.status == .active }
    }

    private var connectionErrorMessage: String? {
        if case .error(let message) = syncEngine?.connectionStatus { return message }
        return nil
    }

    var body: some View {
        Group {
            if let batch = activeBatch {
                NavigationStack {
                    GradingView(
                        batch: batch,
                        missedRecordsWarning: syncEngine?.missedRecordsWarning,
                        timestampMismatchWarning: syncEngine?.timestampMismatchWarning,
                        rejectedCount: syncEngine?.rejectedCount,
                        connectionError: connectionErrorMessage,
                        onComplete: { completeBatch(batch) }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                }
            } else {
                DashboardView(onSortNewBatch: startBatch, onSignOut: onSignOut)
            }
        }
        .onChange(of: useMockDataSource) { _, _ in
            // Switching any of the 3 settings mid-session rebuilds the
            // engine fresh — simplest to reason about, at the cost of
            // losing in-flight connection state, which is acceptable since
            // this is a rare, deliberate developer/tester action, not
            // something ops does.
            makeSyncEngine()
        }
        .onChange(of: idSourceRaw) { _, _ in makeSyncEngine() }
        .onChange(of: timestampSourceRaw) { _, _ in makeSyncEngine() }
        .task {
            guard syncEngine == nil else { return }
            makeSyncEngine()
            syncEngine?.reconcileOnResume(localActiveBatch: activeBatch)
        }
    }

    private func makeSyncEngine() {
        let dataSource: FruitDataSource = useMockDataSource ? MockFruitDataSource() : BLEFruitDataSource()
        syncEngine = SyncEngine(
            modelContext: modelContext,
            dataSource: dataSource,
            idSource: DataFieldSource(rawValue: idSourceRaw) ?? .esp32,
            timestampSource: DataFieldSource(rawValue: timestampSourceRaw) ?? .esp32
        )
    }

    // MARK: - Actions

    private func startBatch() {
        guard !isStarting else { return }
        isStarting = true
        let batch = Batch(batchLabel: nextBatchLabel(), qcStaff: operatorName)
        modelContext.insert(batch)

        // No wire-level "start" command — the ESP32 has no batch concept,
        // it's always streaming. Beginning to observe is purely local.
        syncEngine?.beginObserving(activeBatch: batch)
        isStarting = false
    }

    // Sequential per-day counter, e.g. "B2026-08-17-01", "-02", ... — uses
    // the existing highest sequence for today rather than a plain count,
    // so a deleted batch never causes the next one to collide with a
    // label that's still in use.
    private func nextBatchLabel() -> String {
        let datePrefix = "B\(Date.now.formatted(.iso8601.year().month().day()))"
        let existingSequences = batches.compactMap { batch -> Int? in
            guard batch.batchLabel.hasPrefix(datePrefix + "-") else { return nil }
            return Int(batch.batchLabel.dropFirst(datePrefix.count + 1))
        }
        let nextSequence = (existingSequences.max() ?? 0) + 1
        return "\(datePrefix)-\(String(format: "%02d", nextSequence))"
    }

    private func completeBatch(_ batch: Batch) {
        Task {
            // Grace window for a near-simultaneous BLE notification to
            // land *before* stopping — the batch is still `.active` during
            // this await, so a late-arriving event still attaches to it
            // correctly. See SyncEngine.finalDrain.
            await syncEngine?.finalDrain()
            syncEngine?.stopObserving()
            batch.status = .completed
            batch.endedAt = .now
        }
    }
}

#Preview {
    ContentView(onSignOut: {})
        .modelContainer(for: [Batch.self, FruitRecord.self], inMemory: true)
}
