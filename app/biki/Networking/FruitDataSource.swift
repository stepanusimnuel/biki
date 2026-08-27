import Foundation

enum ConnectionStatus: Equatable {
    case idle
    case connected
    // Auto-retry in progress after an unexpected drop — see
    // BLEFruitDataSource.attemptReconnect. Distinct from `.error` so the
    // UI can show a quiet "retrying" state instead of alarming the
    // operator (and offering a manual retry button) before the automatic
    // attempts are even exhausted.
    case reconnecting(attempt: Int, maxAttempts: Int)
    case error(String)
}

// Abstraction over "how we get fruit events + send grade commands" — lets
// SyncEngine stay identical whether the real transport is BLE hardware
// (BLEFruitDataSource) or an in-process generator (MockFruitDataSource).
//
// CoreBluetooth cannot run in the iOS Simulator at all — not "harder to
// test", the API simply doesn't function there — so this seam is what
// makes Simulator testing possible before real ESP32 BLE hardware exists.
// Delivery is push-based (BLE notify), not polled: `onEvent` fires
// whenever the data source has a new fruit event, on its own schedule.
//
// The real ESP32 has no batch concept at all — no start/complete/status
// commands, that lifecycle is tracked entirely app-side (see `Batch`).
// `sendGrade` is the only outbound command the firmware understands: once
// the app grades a fruit, it writes the grade back so the physical sorter
// routes it to the right lane.
@MainActor
protocol FruitDataSource: AnyObject {
    var onEvent: ((FruitEventDTO) -> Void)? { get set }
    var onStatusChange: ((ConnectionStatus) -> Void)? { get set }

    func connect()
    func disconnect()
    func sendGrade(_ grade: FruitGrade) async throws
}
