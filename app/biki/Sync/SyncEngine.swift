import Foundation
import SwiftData
import Observation

// Implements the pipeline from Data_Architecture.md § "Sync pipeline
// (ESP32 → iPad)" — BLE notify (push), not HTTP polling: FruitDataSource
// calls back with each new event as the peripheral delivers it, so there's
// no poll loop or since-cursor here anymore. This is deliberately the only
// place that talks to FruitDataSource — views should never call it directly.
//
// The ESP32 only reports raw weight + RGB (see DTOs.swift); grading
// happens here via FruitGrader, ported from the real firmware-facing
// algorithm. After grading, the computed grade is written straight back
// to the ESP32 (see the end of `process(_:)`) — that's the command
// channel's only real job, since the physical sorter needs to know which
// lane to route the fruit into.
//
// The ESP32 has no batch concept at all — no start/complete/status
// commands — so batch lifecycle (`Batch.status`, `startedAt`/`endedAt`)
// is tracked entirely app-side; this class never talks to the device
// about it.
//
// `seq` and `timestamp` are each independently either ESP32-sourced or
// app-generated, per `idSource`/`timestampSource` — the firmware side
// isn't guaranteed to send either. Two validations only make sense when
// their respective field is actually ESP32-sourced:
//   - Gap/duplicate detection needs a `seq` that originates at the source;
//     an app-generated counter can only count what it *receives*, so gap
//     detection is structurally impossible when idSource == .app.
//   - Timestamp validation compares the ESP32's measurement-time clock
//     against the iPad's own receipt time; when timestampSource == .app
//     there's nothing independent to compare against.
@MainActor
@Observable
final class SyncEngine {
    private(set) var lastSeenSeq: Int = 0
    private(set) var connectionStatus: ConnectionStatus = .idle
    private(set) var missedRecordsWarning: Int?
    private(set) var timestampMismatchWarning: Int?
    private(set) var rejectedCount: Int?

    private let dataSource: FruitDataSource
    private let modelContext: ModelContext
    private let idSource: DataFieldSource
    private let timestampSource: DataFieldSource
    private var activeBatch: Batch?
    private var localSeqCounter = 0

    // Validation bounds — tune once real sensor/firmware ranges are known.
    private static let maxPlausibleWeightG = 2000.0
    // How far apart the ESP32's measurement timestamp and the iPad's
    // receipt time can be before it's flagged as a clock/latency problem
    // rather than normal BLE delivery jitter. Only checked when
    // timestampSource == .esp32.
    private static let maxPlausibleTimestampDriftSeconds: TimeInterval = 10

    init(
        modelContext: ModelContext,
        dataSource: FruitDataSource,
        idSource: DataFieldSource,
        timestampSource: DataFieldSource
    ) {
        self.modelContext = modelContext
        self.dataSource = dataSource
        self.idSource = idSource
        self.timestampSource = timestampSource
        dataSource.onEvent = { [weak self] event in
            self?.process(event)
        }
        dataSource.onStatusChange = { [weak self] status in
            self?.connectionStatus = status
        }
    }

    func beginObserving(activeBatch: Batch) {
        self.activeBatch = activeBatch
        localSeqCounter = 0
        dataSource.connect()
    }

    func stopObserving() {
        dataSource.disconnect()
        activeBatch = nil
    }

    /// Manual retry after BLEFruitDataSource's automatic reconnect
    /// attempts (see its attemptReconnect) are exhausted and
    /// connectionStatus has settled into a terminal `.error` — surfaced
    /// as a "Coba Lagi" button in GradingView. Just re-enters connect(),
    /// which also resets the auto-reconnect attempt counter, so the next
    /// unexpected drop gets its own fresh set of retries.
    func retryConnection() {
        dataSource.connect()
    }

    /// Call once, right before completing a batch. BLE delivery is
    /// push-based so there's no "one more poll" to do the way HTTP
    /// polling had — but a fruit graded right at the moment Complete is
    /// pressed could still be in flight. A short grace window lets it
    /// land before we stop observing.
    func finalDrain() async {
        try? await Task.sleep(for: .seconds(1))
    }

    /// Call on app launch/foreground to resume any batch left active
    /// locally. The ESP32 has no batch state of its own to reconcile
    /// against — it's a stateless sensor + sorter — so this is purely
    /// local: if a batch was active when the app last quit, resume
    /// observing it.
    func reconcileOnResume(localActiveBatch: Batch?) {
        guard let localActiveBatch else { return }
        beginObserving(activeBatch: localActiveBatch)
    }

    private func process(_ event: FruitEventDTO) {
        guard let activeBatch else { return }
        connectionStatus = .connected

        let seq: Int
        if idSource == .esp32, let espSeq = event.seq {
            seq = espSeq
        } else {
            localSeqCounter += 1
            seq = localSeqCounter
        }

        if idSource == .esp32 {
            if lastSeenSeq > 0, seq > lastSeenSeq + 1 {
                let missed = seq - lastSeenSeq - 1
                missedRecordsWarning = (missedRecordsWarning ?? 0) + missed
            }
        }
        // idSource == .app: gap detection is structurally impossible — an
        // app-generated counter only counts what it receives.

        guard event.hxReady, event.colorReady,
              event.weightG > 0, event.weightG < Self.maxPlausibleWeightG
        else {
            let reason: String
            if !event.hxReady {
                reason = "Sensor berat (load cell) belum siap"
            } else if !event.colorReady {
                reason = "Sensor warna belum siap"
            } else {
                reason = String(format: "Berat di luar rentang wajar (%.0f gram)", event.weightG)
            }
            let rejected = RejectedEvent(
                batch: activeBatch,
                weightG: event.weightG,
                rawR: Int16(event.rawR),
                rawG: Int16(event.rawG),
                rawB: Int16(event.rawB),
                colorCode: Int16(event.colorCode),
                hxReady: event.hxReady,
                colorReady: event.colorReady,
                reason: reason
            )
            modelContext.insert(rejected)
            // Explicit save (not relying on autosave — its timing isn't
            // guaranteed/immediate) so the UI reflects this right away.
            // See the identical comment below on `record` for why this
            // matters: without it, sendGrade below still fires instantly
            // (it doesn't touch the model context at all), but the
            // on-screen result can lag noticeably behind the actual
            // command reaching the ESP32.
            try? modelContext.save()
            rejectedCount = (rejectedCount ?? 0) + 1
            lastSeenSeq = max(lastSeenSeq, seq)
            return
        }

        let receivedAt = Date.now
        let deviceTimestamp: Date
        if timestampSource == .esp32, let espTimestamp = event.timestamp {
            deviceTimestamp = espTimestamp
            if abs(receivedAt.timeIntervalSince(espTimestamp)) > Self.maxPlausibleTimestampDriftSeconds {
                timestampMismatchWarning = (timestampMismatchWarning ?? 0) + 1
            }
        } else {
            // timestampSource == .app (or ESP32 didn't send one despite
            // config): nothing independent to validate against.
            deviceTimestamp = receivedAt
        }

        let grade = FruitGrader.grade(weightG: event.weightG, colorCode: event.colorCode, hxReady: event.hxReady, colorReady: event.colorReady)
        let colorName = FruitGrader.colorName(colorCode: event.colorCode)

        let record = FruitRecord(
            batch: activeBatch,
            fruitSeq: seq,
            deviceTimestamp: deviceTimestamp,
            weightG: event.weightG,
            rawR: Int16(event.rawR),
            rawG: Int16(event.rawG),
            rawB: Int16(event.rawB),
            colorCode: Int16(event.colorCode),
            colorName: colorName,
            grade: grade
        )
        record.receivedAt = receivedAt
        modelContext.insert(record)
        // Explicit save — SwiftData's autosave timing isn't guaranteed or
        // immediate (per SwiftData core guidance, prefer an explicit
        // save() when correctness/promptness matters), and GradingView's
        // lastScanCard/totalSidebar read `batch.fruitRecords`/`lastRecord`
        // straight off this relationship. Without this, sendGrade below
        // still writes to the ESP32 immediately (it's independent of the
        // model context entirely), but the on-screen result could lag
        // behind the command actually reaching the device — this is what
        // fixes that gap, not any change to the settle-detection timing.
        try? modelContext.save()
        lastSeenSeq = max(lastSeenSeq, seq)

        // Tell the ESP32 which physical lane to sort this fruit into —
        // the command channel's only real job. Fire-and-forget: a failed
        // write shouldn't block ingest, but it's logged (not silently
        // discarded via `try?`) — a write can fail for reasons that don't
        // trigger a connectionStatus change at all (e.g. a GATT error on
        // an otherwise-live connection), which would otherwise leave the
        // servo simply not moving with zero signal anywhere as to why.
        let dataSource = dataSource
        Task {
            do {
                try await dataSource.sendGrade(grade)
            } catch {
                print("SyncEngine: failed to send grade \(grade.rawValue) command to ESP32 — \(error)")
            }
        }
    }
}
