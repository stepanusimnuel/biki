import SwiftUI
import SwiftData

// Replaces the old single confirmationDialog on the gear icon — now that
// there are 3 independent config dimensions (data source, ID source,
// timestamp source) instead of 1, a proper sheet reads better than
// stacking dialogs. Persisted via @AppStorage so ContentView can read the
// same values when building SyncEngine.
struct SettingsView: View {
    @AppStorage("useMockDataSource") private var useMockDataSource = true
    @AppStorage("idSource") private var idSourceRaw = DataFieldSource.esp32.rawValue
    @AppStorage("timestampSource") private var timestampSourceRaw = DataFieldSource.esp32.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    #if DEBUG
    @State private var pendingSeedAction: DebugSeedAction?
    @State private var isSeeding = false

    private enum DebugSeedAction {
        case fill, remove
    }
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sumber Data", selection: $useMockDataSource) {
                        Text("Simulasi (Mock)").tag(true)
                        Text("BLE (Perangkat Asli)").tag(false)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("Hardware ESP32 BLE belum siap — pakai Simulasi untuk testing sampai perangkat asli tersedia.")
                }

                Section {
                    Picker("Sumber ID / Urutan", selection: $idSourceRaw) {
                        Text("Dari ESP32").tag(DataFieldSource.esp32.rawValue)
                        Text("Dari Aplikasi").tag(DataFieldSource.app.rawValue)
                    }
                } footer: {
                    Text("ESP32 belum tentu selalu mengirim nomor urut. Kalau \"Dari Aplikasi\": deteksi data yang mungkin terlewat tidak akan aktif, karena aplikasi hanya bisa menghitung data yang diterima, bukan yang seharusnya dikirim.")
                }

                Section {
                    Picker("Sumber Timestamp", selection: $timestampSourceRaw) {
                        Text("Dari ESP32").tag(DataFieldSource.esp32.rawValue)
                        Text("Dari Aplikasi").tag(DataFieldSource.app.rawValue)
                    }
                } footer: {
                    Text("ESP32 belum tentu selalu mengirim waktu pengukuran. Kalau \"Dari Aplikasi\": validasi selisih waktu terhadap ESP32 tidak berlaku, karena keduanya akan selalu sama.")
                }

                #if DEBUG
                Section {
                    if isSeeding {
                        HStack {
                            ProgressView()
                            Text("Memproses data contoh…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Isi Data Contoh (Debug)") { pendingSeedAction = .fill }
                        Button("Hapus Data Contoh (Debug)", role: .destructive) { pendingSeedAction = .remove }
                    }
                } footer: {
                    Text("Isi menambahkan 8 hari data riwayat contoh (±2 ton/hari, beberapa batch per hari) tanpa menghapus data asli, supaya grafik tren di halaman Laporan bisa diuji tanpa menunggu data asli selama seminggu — prosesnya berat (puluhan ribu data buah) dan bisa memakan waktu sekitar satu menit. Hapus hanya menghapus data contoh yang ditambahkan. Hanya ada di build Debug.")
                }
                #endif
            }
            .navigationTitle("Pengaturan")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Selesai") { dismiss() }
                }
            }
            #if DEBUG
            .confirmationDialog(
                pendingSeedAction == .fill ? "Isi Data Contoh?" : "Hapus Data Contoh?",
                isPresented: Binding(
                    get: { pendingSeedAction != nil },
                    set: { if !$0 { pendingSeedAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(pendingSeedAction == .fill ? "Isi Data" : "Hapus Data", role: .destructive) {
                    let action = pendingSeedAction
                    pendingSeedAction = nil
                    isSeeding = true
                    Task {
                        // DebugSeeder is a @ModelActor — this runs on its
                        // own background executor, not the main actor, so
                        // the UI (including the ProgressView above) stays
                        // responsive for the ~1 minute this can take.
                        let seeder = DebugSeeder(modelContainer: modelContext.container)
                        switch action {
                        case .fill: await seeder.seedHistoricalTrendData()
                        case .remove: await seeder.removeDemoData()
                        case nil: break
                        }
                        isSeeding = false
                    }
                }
                Button("Batal", role: .cancel) { pendingSeedAction = nil }
            } message: {
                Text(pendingSeedAction == .fill
                     ? "8 hari data contoh (±2 ton/hari, beberapa batch per hari) akan ditambahkan. Data asli tidak akan terhapus."
                     : "Semua data contoh yang pernah ditambahkan akan dihapus. Data asli tidak akan terpengaruh.")
            }
            #endif
        }
    }
}
