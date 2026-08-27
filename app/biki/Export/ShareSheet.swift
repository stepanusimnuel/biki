import SwiftUI
import UIKit

// Thin wrapper around UIActivityViewController — SwiftUI's own ShareLink
// is meant to be tapped directly, but here the file needs to be generated
// on demand first (CSV vs PDF choice), so a .sheet(item:) presenting this
// is simpler than routing through ShareLink's Transferable machinery.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
