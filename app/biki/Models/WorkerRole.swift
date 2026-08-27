import Foundation

enum WorkerRole: String, Codable, CaseIterable, Identifiable {
    case qc = "Petugas QC"
    case manager = "Manajer"

    var id: String { rawValue }
}
