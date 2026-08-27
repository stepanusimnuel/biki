import Foundation

// The worker roster persists as a single JSON-encoded string in
// @AppStorage("workerRoster") — there's no SwiftData model for it since
// it's just locally-typed names/roles, not graded-fruit data. This is the
// one place that (de)serializes it, so LoginView and DashboardHeaderView
// (both of which read/write the roster) can't drift apart on format.
enum WorkerRoster {
    static func decode(_ raw: String) -> [Worker] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Worker].self, from: data)) ?? []
    }

    static func encode(_ workers: [Worker]) -> String {
        guard let data = try? JSONEncoder().encode(workers) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
