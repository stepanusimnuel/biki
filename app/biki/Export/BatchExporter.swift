import Foundation
import UIKit

// CSV/PDF generation for a single Batch — writes to a temp file and
// returns the URL, which BatchDetailView hands to ShareSheet (the system
// share sheet, which includes AirDrop to another Apple device like a
// manager's iPhone automatically for any file URL).
enum BatchExporter {
    static func writeCSV(for batch: Batch) -> URL? {
        var csv = "Urutan,Waktu,Berat (gram),Grade,Warna,Raw R,Raw G,Raw B,Kode Warna\n"
        let records = batch.fruitRecords.sorted { $0.fruitSeq < $1.fruitSeq }
        for record in records {
            csv += "\(record.fruitSeq),\(record.receivedAt.ISO8601Format()),\(record.weightG),\(record.grade.rawValue),\(record.colorName),\(record.rawR),\(record.rawG),\(record.rawB),\(record.colorCode)\n"
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(batch.batchLabel).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func writePDF(for batch: Batch) -> URL? {
        let pageWidth: CGFloat = 612   // US Letter at 72dpi
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(batch.batchLabel).pdf")

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                var y: CGFloat = margin

                func draw(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 4) {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
                    y += font.lineHeight + spacingAfter
                }

                draw("Laporan Grading — \(batch.batchLabel)", font: .boldSystemFont(ofSize: 20), spacingAfter: 12)
                draw("Petugas QC: \(batch.qcStaff.isEmpty ? "—" : batch.qcStaff)", font: .systemFont(ofSize: 12))
                draw("Tanggal: \(batch.startedAt.formatted(date: .long, time: .shortened))", font: .systemFont(ofSize: 12))
                draw(
                    String(format: "Total: %.2f kg · %d buah", batch.totalWeightG / 1000, batch.totalCount),
                    font: .systemFont(ofSize: 12),
                    spacingAfter: 16
                )

                draw("Ringkasan per Grade", font: .boldSystemFont(ofSize: 14), spacingAfter: 8)
                for grade in FruitGrade.allCases {
                    let count = batch.count(for: grade)
                    let weight = batch.weight(for: grade)
                    draw(
                        String(format: "%@: %d buah — %.2f kg", grade.displayName, count, weight / 1000),
                        font: .systemFont(ofSize: 11)
                    )
                }
                y += 12

                if !batch.rejectedEvents.isEmpty {
                    draw("Data Ditolak Sensor: \(batch.rejectedEvents.count)", font: .boldSystemFont(ofSize: 14), color: .systemOrange)
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
