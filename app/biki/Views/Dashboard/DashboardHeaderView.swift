import SwiftUI

// No accounts/auth exist in this app (single iPad, local-only — see
// Data_Architecture.md), so there's nothing real to log "in"/"out" of.
// "Workers" is just a locally-stored roster of names typed in on this
// iPad — tap the avatar to switch between them or add a new one. "Sign
// out" clears the current selection and returns to the Login/worker-picker
// screen, standing in for handing the device to the next person on shift,
// not real authentication.
struct DashboardHeaderView: View {
    @AppStorage("operatorName") private var operatorName = ""
    @AppStorage("workerRoster") private var workerRosterRaw = ""
    @State private var isAddingWorker = false
    @State private var draftName = ""
    @State private var isShowingSettings = false

    let onSignOut: () -> Void

    private var roster: [String] {
        workerRosterRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    private var initial: String {
        operatorName.first.map(String.init)?.uppercased() ?? "?"
    }

    var body: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(roster, id: \.self) { name in
                    Button {
                        operatorName = name
                    } label: {
                        if name == operatorName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                if !roster.isEmpty {
                    Divider()
                }
                Button {
                    draftName = ""
                    isAddingWorker = true
                } label: {
                    Label("Tambah pekerja baru", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.primary)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Text(initial)
                                .font(.headline)
                                .foregroundStyle(.background)
                        )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(operatorName.isEmpty ? "Atur nama" : operatorName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Kontrol Kualitas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuOrder(.fixed)

            Spacer()

            Button {
                operatorName = ""
                onSignOut()
            } label: {
                Label("Keluar", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.bordered)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
        }
        .padding()
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
        .alert("Tambah Pekerja", isPresented: $isAddingWorker) {
            TextField("Nama", text: $draftName)
            Button("Simpan") { addWorker(draftName) }
            Button("Batal", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private func addWorker(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = roster
        if !current.contains(trimmed) {
            current.append(trimmed)
            workerRosterRaw = current.joined(separator: "|")
        }
        operatorName = trimmed
    }
}
