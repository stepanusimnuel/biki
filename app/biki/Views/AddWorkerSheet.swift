import SwiftUI

// Shared by LoginView and DashboardHeaderView — both let you add a worker
// to the roster. A plain .alert() can't host a role Picker, so this
// replaced the old inline TextField-in-alert on both screens.
struct AddWorkerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Worker) -> Void

    @State private var name = ""
    @State private var role: WorkerRole = .qc

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nama", text: $name)
                Picker("Peran", selection: $role) {
                    ForEach(WorkerRole.allCases) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
            }
            .navigationTitle("Tambah Pekerja")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(Worker(name: trimmed, role: role))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
