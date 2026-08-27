import Foundation

// Whether `seq` (per-fruit ID) and `timestamp` are trusted from the ESP32
// or generated app-side. Configurable rather than fixed because the
// firmware side is no longer guaranteed to send either — see
// SyncEngine.process and SettingsView.
enum DataFieldSource: String, CaseIterable {
    case esp32
    case app
}
