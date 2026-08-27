import SwiftUI
import SwiftData

@main
struct HaloBikiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Batch.self, FruitRecord.self, RejectedEvent.self])
    }
}

// Login (worker picker) is the real landing screen now — every cold
// launch starts there. `isLoggedIn` is session-only state (not persisted),
// which is what makes it reset on each fresh launch; Sign Out on Homepage
// flips it back.
private struct RootView: View {
    @State private var isLoggedIn = false

    var body: some View {
        if isLoggedIn {
            ContentView(onSignOut: { isLoggedIn = false })
        } else {
            LoginView(onContinue: { isLoggedIn = true })
        }
    }
}
