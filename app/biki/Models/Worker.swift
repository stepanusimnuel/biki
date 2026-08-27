import Foundation

// A locally-stored roster entry — not an account, just a name + role typed
// in on this iPad. See LoginView/DashboardHeaderView for where the roster
// is picked from, and WorkerRoster for how it's persisted.
struct Worker: Codable, Identifiable, Equatable {
    var name: String
    var role: WorkerRole

    var id: String { name }
}
