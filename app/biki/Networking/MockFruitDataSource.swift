import Foundation

// In-process stand-in for BLEFruitDataSource — since CoreBluetooth cannot
// run in the iOS Simulator at all, this is what makes Simulator testing
// possible until real ESP32 BLE hardware is ready. Delivered through the
// same FruitDataSource interface the real BLE client uses — SyncEngine
// can't tell the difference. Switch between this and BLEFruitDataSource
// via the "Sumber Data" setting in the header.
@MainActor
final class MockFruitDataSource: FruitDataSource {
    var onEvent: ((FruitEventDTO) -> Void)?
    var onStatusChange: ((ConnectionStatus) -> Void)?

    private var timer: Timer?
    private var seq = 0

    // Raw R/G/B + color code drawn from the same calibrated reference
    // table as esp/ble.ino's `references[]`, with weight ranges tuned to
    // land inside each of FruitGrader's real thresholds — not because
    // this needs to match FruitGrader's internals, just so the app's
    // tally looks plausible across all 5 grades in the Simulator. Always
    // emits seq + timestamp regardless of the app's configured
    // DataFieldSource, so switching that setting between ESP32/App
    // exercises both code paths against the same mock — SyncEngine
    // decides whether to use or ignore them. The real firmware never
    // sends either field, so this is Simulator-only behavior.
    private static let profiles: [(grade: String, baseWeight: Double, colorCode: Int, r: Int, g: Int, b: Int)] = [
        ("A", 115, 2, 83, 178, 181),   // Orange, weight in Grade A range
        ("B", 90, 2, 83, 178, 181),    // Orange, weight in Grade B range
        ("C", 72, 2, 83, 178, 181),    // Orange, weight in Grade C range
        ("D", 55, 3, 74, 104, 145),    // Kuning, lands in the edible bucket
        ("E", 100, 1, 117, 295, 234),  // Merah — wrong color, rejected
    ]

    func connect() {
        onStatusChange?(.connected)
        seq = 0
        scheduleNextEvent()
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
    }

    func sendGrade(_ grade: FruitGrade) async throws {
        // No physical sorter to actuate in the Simulator — accepted as a no-op.
    }

    private func scheduleNextEvent() {
        let interval = Double.random(in: 1.5...3.0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.emitEvent()
                self?.scheduleNextEvent()
            }
        }
    }

    private func emitEvent() {
        seq += 1
        let profile = Self.profiles.randomElement()!
        let weight = ((profile.baseWeight + Double.random(in: -3...3)) * 10).rounded() / 10
        let jitter = { Int.random(in: -5...5) }
        let event = FruitEventDTO(
            weightG: weight,
            rawR: max(0, profile.r + jitter()),
            rawG: max(0, profile.g + jitter()),
            rawB: max(0, profile.b + jitter()),
            colorCode: profile.colorCode,
            hxReady: true,
            colorReady: true,
            seq: seq,
            timestamp: .now
        )
        onEvent?(event)
    }
}
