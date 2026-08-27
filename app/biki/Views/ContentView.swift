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
    @AppStorage("operatorRole") private var operatorRole = WorkerRole.qc.rawValue
    @State private var isStarting = false

    let onSignOut: () -> Void

    private var activeBatch: Batch? {
        batches.first { $0.status == .active }
    }

    // Covers both a terminal error (auto-reconnect exhausted, or no
    // peripheral ever found) and an in-progress auto-reconnect attempt —
    // GradingView shows both as the same red banner, distinguished only
    // by whether canRetryConnection offers a manual "Coba Lagi" button.
    private var connectionErrorMessage: String? {
        switch syncEngine?.connectionStatus {
        case .error(let message): return message
        case .reconnecting(let attempt, let maxAttempts):
            return "Menyambungkan ulang ke ESP32… (percobaan \(attempt)/\(maxAttempts))"
        default: return nil
        }
    }

    // Only a terminal `.error` means BLEFruitDataSource has given up on
    // its own — offering a manual retry while `.reconnecting` is still in
    // progress would just race the automatic attempt already in flight.
    private var canRetryConnection: Bool {
        if case .error = syncEngine?.connectionStatus { return true }
        return false
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
                        canRetryConnection: canRetryConnection,
                        onRetryConnection: { syncEngine?.retryConnection() },
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
        let batch = Batch(batchLabel: nextBatchLabel(), qcStaff: operatorName, qcRole: operatorRole)
        modelContext.insert(batch)

        // No wire-level "start" command — the ESP32 has no batch concept,
        // it's always streaming. Beginning to observe is purely local.
        syncEngine?.beginObserving(activeBatch: batch)
        isStarting = false
    }

    private func nextBatchLabel() -> String {
        Batch.nextLabel(for: .now, existingLabels: batches.map(\.batchLabel))
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
