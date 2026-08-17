import Foundation
import SwiftData

enum BatchStatus: String, Codable {
    case active
    case completed
}

@Model
final class Batch {
    var id: UUID
    var batchLabel: String
    var startedAt: Date
    var endedAt: Date?
    var statusRaw: String

    // Whoever was selected in the header's worker roster when this batch
    // was started — see DashboardHeaderView. Empty when nobody was set.
    var qcStaff: String = ""

    @Relationship(deleteRule: .cascade, inverse: \FruitRecord.batch)
    var fruitRecords: [FruitRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \RejectedEvent.batch)
    var rejectedEvents: [RejectedEvent] = []

    var status: BatchStatus {
        get { BatchStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(batchLabel: String, qcStaff: String = "") {
        self.id = UUID()
        self.batchLabel = batchLabel
        self.startedAt = .now
        self.endedAt = nil
        self.statusRaw = BatchStatus.active.rawValue
        self.qcStaff = qcStaff
    }

    // Aggregates are computed from fruitRecords, never stored — see
    // Data_Architecture.md § "Why aggregates are computed, not stored".
    // These are convenience accessors, not persisted fields.
    var totalCount: Int { fruitRecords.count }
    var totalWeightG: Double { fruitRecords.reduce(0) { $0 + $1.weightG } }

    func count(for grade: FruitGrade) -> Int {
        fruitRecords.filter { $0.grade == grade }.count
    }

    func weight(for grade: FruitGrade) -> Double {
        fruitRecords.filter { $0.grade == grade }.reduce(0) { $0 + $1.weightG }
    }

    // Most recently graded fruit in this batch — nil once it has zero records.
    var lastRecord: FruitRecord? {
        fruitRecords.max(by: { $0.fruitSeq < $1.fruitSeq })
    }

    // Highest-count grade in this batch — nil once it has zero records.
    var topGrade: FruitGrade? {
        let counts = FruitGrade.allCases.map { ($0, count(for: $0)) }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}
