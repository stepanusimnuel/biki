import Foundation
import SwiftData

// A fruit-sensor reading SyncEngine couldn't turn into a FruitRecord —
// weight out of plausible range, or the load-cell/color sensor not ready
// yet. Previously these were silently dropped (see SyncEngine.process);
// persisting them here means a batch whose count looks short can actually
// be investigated instead of just noticed.
@Model
final class RejectedEvent {
    var id: UUID
    var batch: Batch?
    var receivedAt: Date
    var weightG: Double
    var rawR: Int16
    var rawG: Int16
    var rawB: Int16
    var colorCode: Int16
    var hxReady: Bool
    var colorReady: Bool
    var reason: String

    init(
        batch: Batch?,
        weightG: Double,
        rawR: Int16,
        rawG: Int16,
        rawB: Int16,
        colorCode: Int16,
        hxReady: Bool,
        colorReady: Bool,
        reason: String
    ) {
        self.id = UUID()
        self.batch = batch
        self.receivedAt = .now
        self.weightG = weightG
        self.rawR = rawR
        self.rawG = rawG
        self.rawB = rawB
        self.colorCode = colorCode
        self.hxReady = hxReady
        self.colorReady = colorReady
        self.reason = reason
    }
}
