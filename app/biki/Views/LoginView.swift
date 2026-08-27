import SwiftUI

// App's new landing screen — a worker picker, not real authentication.
// There's still no accounts/auth system (single iPad, local-only — see
// Data_Architecture.md); this just makes the existing worker-roster
// concept (previously a header menu on Dashboard) the first thing you see.
// "Masuk" sets the active worker and goes to Homepage. "Lihat Laporan"
// pushes the read-only LaporanView instead, without setting anyone as
// active — you're just browsing the report, not starting a shift.
struct LoginView: View {
    @AppStorage("operatorName") private var operatorName = ""
    @AppStorage("operatorRole") private var operatorRole = WorkerRole.qc.rawValue
    @AppStorage("workerRoster") private var workerRosterRaw = ""
    @State private var selectedWorker: Worker?
    @State private var isAddingWorker = false
    @State private var showingLaporan = false

    let onContinue: () -> Void

    private var roster: [Worker] {
        WorkerRoster.decode(workerRosterRaw)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 8) {
                    (Text("Halo, ") + Text("Oren").foregroundStyle(.orange) + Text(" Staff"))
                        .font(.largeTitle.bold())
                    Text("Silahkan masuk terlebih dahulu")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 28) {
                    ForEach(roster) { worker in
                        profileTile(worker)
                    }
                    addWorkerTile
                }

                VStack(spacing: 12) {
                    Button("Masuk") {
                        if let selectedWorker {
                            operatorName = selectedWorker.name
                            operatorRole = selectedWorker.role.rawValue
                        }
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selectedWorker == nil)

                    Button("Lihat Laporan") {
                        showingLaporan = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedWorker == nil)
                }
                .controlSize(.large)
                .frame(maxWidth: 280)

                Spacer()
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $isAddingWorker) {
                AddWorkerSheet { worker in
                    addWorker(worker)
                }
            }
            .navigationDestination(isPresented: $showingLaporan) {
                LaporanView()
            }
        }
    }

    private func profileTile(_ worker: Worker) -> some View {
        let isSelected = selectedWorker == worker
        return Button {
            // Tapping the already-selected tile deselects it — there was
            // previously no way to back out of a selection short of
            // picking someone else.
            selectedWorker = isSelected ? nil : worker
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isSelected ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                VStack(spacing: 2) {
                    Text(worker.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(worker.role.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var addWorkerTile: some View {
        Button {
            isAddingWorker = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Tambah")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func addWorker(_ worker: Worker) {
        var current = roster
        if !current.contains(where: { $0.name == worker.name }) {
            current.append(worker)
            workerRosterRaw = WorkerRoster.encode(current)
        }
        selectedWorker = worker
    }
}
