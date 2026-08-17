import SwiftUI

// Revamped live/active-batch screen — replaces the old GradeTallyView +
// scrolling per-fruit list with a "Total" sidebar and a big last-scan
// card, matching the Figma "Grading Page" design. The ESP32 sends its own
// raw sensor units, not display-ready RGB (see DTOs.swift) — the swatch
// below is a fixed display color per `colorCode`, matching esp/ble.ino's
// calibrated reference palette, not a literal render of the raw reading.
// "Jeruk" (orange/citrus) in the design is also just an example fruit;
// the schema doesn't track species, so labels here stay generic ("Grade",
// not "Grade Jeruk").
struct GradingView: View {
    let batch: Batch
    let missedRecordsWarning: Int?
    let timestampMismatchWarning: Int?
    let rejectedCount: Int?
    let connectionError: String?
    let onComplete: () -> Void

    // The "Total" sidebar has its own native-style collapse control (see
    // totalSidebar's header) — collapsing it just lets lastScanCard take
    // the full width. Re-expanding happens via the same icon, which moves
    // to sit above lastScanCard while collapsed so it's never stranded.
    @State private var isSidebarVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let connectionError {
                Label(connectionError, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Batch Grading \(batch.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if let missedRecordsWarning {
                Label("\(missedRecordsWarning) data mungkin terlewat", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let timestampMismatchWarning {
                Label("\(timestampMismatchWarning) data punya selisih waktu mencurigakan dengan ESP32", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let rejectedCount {
                Label("\(rejectedCount) data ditolak sensor — lihat detail batch setelah selesai", systemImage: "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 20) {
                if isSidebarVisible {
                    totalSidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible = true }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                lastScanCard
            }
            .frame(maxHeight: .infinity)

            Button(action: onComplete) {
                Label("Selesai Grading", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
        .padding()
    }

    private var totalSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Total")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible = false }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(FruitGrade.allCases) { grade in
                HStack(spacing: 8) {
                    Circle()
                        .fill(grade.badgeColor)
                        .frame(width: 10, height: 10)
                    Text(grade.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f kg", batch.weight(for: grade) / 1000))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Berat Total").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f kg", batch.totalWeightG / 1000))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Total Buah").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(batch.totalCount) buah")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 260, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }

    @ViewBuilder
    private var lastScanCard: some View {
        if let last = batch.lastRecord {
            VStack(spacing: 12) {
                Text("Grade")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(last.grade.rawValue)
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(.white)
                Text(String(format: "Berat: %.0f gram", last.weightG))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 8) {
                    Circle()
                        .fill(swatchColor(for: last.colorCode))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    Text(last.colorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.white.opacity(0.2), in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(last.grade.badgeColor.gradient, in: RoundedRectangle(cornerRadius: 20))
        } else {
            Text("Menunggu hasil pertama…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // Fixed display color per ESP32 color code — the raw sensor reading
    // (rawR/G/B on FruitRecord) is pulse-period counts, not RGB, so it
    // can't be rendered directly; this swatch shows what the classified
    // color actually looks like instead. Matches esp/ble.ino's colorName().
    private func swatchColor(for colorCode: Int16) -> Color {
        switch colorCode {
        case 1: return Color(red: 0.85, green: 0.15, blue: 0.15)  // Merah
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.10)  // Orange
        case 3: return Color(red: 0.95, green: 0.85, blue: 0.15)  // Kuning
        case 4: return Color(red: 0.25, green: 0.65, blue: 0.25)  // Hijau
        case 5: return Color(red: 0.15, green: 0.35, blue: 0.85)  // Biru
        case 6: return Color(white: 0.1)                          // Hitam
        case 7: return Color(white: 0.95)                         // Putih
        default: return Color(white: 0.6)                         // Tidak diketahui
        }
    }
}
