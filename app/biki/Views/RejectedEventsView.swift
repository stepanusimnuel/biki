import SwiftUI

// Read-only diagnostic list for one batch's RejectedEvents — what
// SyncEngine.process dropped and why, so a short-looking batch count can
// actually be investigated. Reached from BatchDetailView.
struct RejectedEventsView: View {
    let batch: Batch

    private var sortedEvents: [RejectedEvent] {
        batch.rejectedEvents.sorted { $0.receivedAt > $1.receivedAt }
    }

    var body: some View {
        List(sortedEvents, id: \.id) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(event.receivedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.subheadline.weight(.semibold))
                Text(event.reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Text(String(
                    format: "Berat: %.0f gram · RGB mentah: %d,%d,%d · Kode warna: %d",
                    event.weightG, event.rawR, event.rawG, event.rawB, event.colorCode
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Log Diagnostik")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if sortedEvents.isEmpty {
                Text("Tidak ada data yang ditolak")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
