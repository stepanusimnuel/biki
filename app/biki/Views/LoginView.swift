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
    @AppStorage("workerRoster") private var workerRosterRaw = ""
    @State private var selectedWorker: String?
    @State private var isAddingWorker = false
    @State private var draftName = ""
    @State private var showingLaporan = false

    let onContinue: () -> Void

    private var roster: [String] {
        workerRosterRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 8) {
                    (Text("Halo, ") + Text("BIKI").foregroundStyle(.orange) + Text(" Staff"))
                        .font(.largeTitle.bold())
                    Text("Silahkan masuk terlebih dahulu")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 28) {
                    ForEach(roster, id: \.self) { name in
                        profileTile(name)
                    }
                    addWorkerTile
                }

                VStack(spacing: 12) {
                    Button("Masuk") {
                        if let selectedWorker {
                            operatorName = selectedWorker
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
            .alert("Tambah Pekerja", isPresented: $isAddingWorker) {
                TextField("Nama", text: $draftName)
                Button("Simpan") { addWorker(draftName) }
                Button("Batal", role: .cancel) {}
            }
            .navigationDestination(isPresented: $showingLaporan) {
                LaporanView()
            }
        }
    }

    private func profileTile(_ name: String) -> some View {
        let isSelected = selectedWorker == name
        return Button {
            selectedWorker = name
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isSelected ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                Text(name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var addWorkerTile: some View {
        Button {
            draftName = ""
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

    private func addWorker(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = roster
        if !current.contains(trimmed) {
            current.append(trimmed)
            workerRosterRaw = current.joined(separator: "|")
        }
        selectedWorker = trimmed
    }
}
