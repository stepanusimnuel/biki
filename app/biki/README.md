# Oren iPad App

QC/grading app for a fruit-sorting rig: an iPad receives per-fruit weight
+ color readings from an ESP32 over Bluetooth Low Energy, grades each
fruit app-side, tracks it against a `Batch`, and writes the grade back so
the physical sorter routes the fruit into the right lane.

Target device: **iPad Pro 11" (M5)**, iOS 26+. Single iPad, single rig,
local-only persistence — see [`Data_Architecture.md`](Data_Architecture.md)
for why there's no backend/server.

## 1. Repository layout

```
biki/
├── app/
│   └── biki/                  ← this Xcode project (biki.xcodeproj is one level up, in app/)
│       ├── HaloBikiApp.swift  ← @main entry point (WindowGroup → RootView)
│       ├── DebugSeeder.swift  ← DEBUG-only historical data generator (see §5)
│       ├── README.md          ← this file
│       ├── Data_Architecture.md
│       ├── Models/            ← SwiftData schema: Batch, FruitRecord, RejectedEvent, FruitGrade
│       ├── Networking/        ← FruitDataSource protocol + BLE/Mock implementations, wire DTOs
│       ├── Sync/               ← SyncEngine (the pipeline), FruitGrader, DataFieldSource
│       ├── Export/             ← CSV/PDF generation + share sheet
│       └── Views/              ← Login → Dashboard/Grading → Laporan, plus Settings
│           └── Dashboard/      ← Homepage subviews (charts, history table, batch detail)
└── esp/
    └── ble.ino                ← ESP32 firmware — the wire-contract source of truth
```

Nothing else in the tree is part of the shipped app: `esp/ble.ino` is
firmware you flash to the ESP32 separately: it is not built by the Xcode
project.

## 2. App architecture

- **UI**: SwiftUI throughout, `@Observable` for `SyncEngine`, `@Query`/
  `@Model` (SwiftData) for persistence-backed views. No UIKit except two
  narrow spots: `UIGraphicsPDFRenderer` for PDF export and
  `UIActivityViewController` for the native share sheet (both wrapped,
  not used directly in views).
- **Screen flow**: `LoginView` (worker picker, not real auth — see
  `Data_Architecture.md`) → `ContentView`, which toggles between
  `DashboardView` (Homepage, no active batch) and `GradingView` (an
  active batch exists), decided by a live `@Query` for `Batch.status ==
  .active`. `LoginView` can also push `LaporanView` directly ("Lihat
  Laporan") without setting an active worker.
- **Data flow abstraction**: views never talk to Bluetooth directly.
  `FruitDataSource` (protocol) is implemented by `BLEFruitDataSource`
  (real CoreBluetooth) and `MockFruitDataSource` (in-process generator).
  `SyncEngine` is the only consumer of that protocol — it grades events
  (`FruitGrader`), validates them, persists `FruitRecord`/`RejectedEvent`
  via SwiftData, and writes the graded result back over BLE.
  `ContentView.makeSyncEngine()` picks the concrete data source based on
  the "Sumber Data" setting.
- **Settings**: three independent `@AppStorage`-backed toggles exposed in
  `SettingsView` (gear icon, Homepage header) — data source (Mock/BLE),
  ID source, timestamp source. See §3 and `Data_Architecture.md` §
  "Configurable ID/timestamp sourcing".

## 3. Database structure

SwiftData (SQLite-backed), fully offline, no server. Full rationale and
field-by-field notes in `Data_Architecture.md` § "Schema" — summary:

| Model | Purpose | Key fields |
|---|---|---|
| `Batch` | One grading session | `batchLabel` (e.g. `B2026-08-17-01`), `startedAt`/`endedAt`, `status` (`active`/`completed`), `qcStaff`; `fruitRecords`/`rejectedEvents` cascade-delete relationships |
| `FruitRecord` | One graded fruit | `fruitSeq`, `receivedAt` (iPad clock, authoritative), `deviceTimestamp`, `weightG`, `rawR/G/B` + `colorCode` (raw sensor), `colorName`/`grade` (computed app-side by `FruitGrader`) |
| `RejectedEvent` | One event that failed validation (sensor not ready, implausible weight) | Same raw fields as `FruitRecord` plus `reason` (human-readable, Indonesian) |

`Batch.totalCount`/`totalWeightG`/per-grade counts are **computed
properties over `fruitRecords`, never stored** — see `Data_Architecture.md`
§ "Why aggregates are computed, not stored" for why (crash-safety: a
stored counter can drift from the rows it's supposed to summarize).

## 4. Mock setting (Simulator testing)

**CoreBluetooth cannot run in the iOS Simulator at all** — not "harder to
test", the API doesn't function there. `MockFruitDataSource` is what
makes Simulator testing possible: it generates one plausible fruit event
(spanning all 5 grades) every 1.5–3 seconds while a batch is active,
in-process, no server or network involved.

To use it:

1. On Homepage, tap the gear icon (top-right) → **Pengaturan**.
2. Under **Sumber Data**, select **"Simulasi (Mock)"** (this is the
   default — `useMockDataSource` starts `true`).
3. Done. Every other setting on the sheet works normally against the
   mock: `MockFruitDataSource` always emits both `seq` and `timestamp`,
   so switching "Sumber ID"/"Sumber Timestamp" between "Dari ESP32"/"Dari
   Aplikasi" exercises both code paths against the same mock data —
   `SyncEngine` is what decides whether to trust or ignore what's on the
   wire, not the mock.

## 5. How to use the app with Mock data

1. Build and run on the Simulator (any iPad target — iPad Pro 11" M5 is
   the deployment target, but Simulator devices don't need matching
   hardware).
2. **Login**: pick or add a worker on the first screen, tap **Masuk**.
3. **Homepage**: tap **Mulai Grading** to start a batch — this creates a
   `Batch` row and calls `SyncEngine.beginObserving`, which connects the
   configured data source (Mock, per §4).
4. The screen switches automatically to **GradingView** once the batch
   is active (driven by the live `@Query`, no separate confirmation
   step). Mock events start arriving every 1.5–3s; watch weight/grade
   populate live.
5. Tap **Selesai** to complete the batch (`status = completed`,
   `endedAt` stamped) — a 1-second grace window (`SyncEngine.finalDrain`)
   lets one more in-flight mock event land first.
6. Back on Homepage, the completed batch appears in **Riwayat Grading**.
   Tap **Lihat Detail** for the per-fruit list, rejected-event log (if
   any), and **Buat Laporan** → choose **CSV** or **PDF** → share sheet
   (AirDrop-capable — this is how a report reaches, e.g., a manager's
   iPhone with no separate transfer step).
7. **Faster historical testing**: Pengaturan → **"Isi Data Contoh
   (Debug)"** (DEBUG builds only) seeds 8 days of demo batches so
   `LaporanView`'s week-over-week trend/sparkline has something to show
   immediately, without waiting on real usage. "Hapus Data Contoh"
   removes only that demo data (tagged `-DEMO`), leaving real data
   untouched. See `DebugSeeder.swift`.

## 6. How to use the app with real IoT (ESP32 over BLE)

**Status: wire format and GATT UUIDs are confirmed against `esp/ble.ino`
(the firmware source of truth), but `BLEFruitDataSource` has not yet been
run against physical hardware — verify end-to-end before relying on it
in the field.**

1. Flash `esp/ble.ino` to the ESP32 rig (outside this project — use your
   normal Arduino/PlatformIO flow).
2. **Required Info.plist entry** (already present in this project, but
   note it if porting):
   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>Oren connects to the grading rig over Bluetooth to receive graded fruit data.</string>
   ```
   Skipping this crashes the app the instant it touches
   `CBCentralManager` — stricter than a missing network permission, which
   just fails silently.
3. Run the app on a **physical iPad**, not the Simulator (see §4 for why).
4. Gear icon → Pengaturan → **Sumber Data → "BLE (Perangkat Asli)"**.
5. Everything else (starting/completing a batch, viewing history,
   exporting) works identically to §5 — `SyncEngine` doesn't know or
   care which `FruitDataSource` implementation is behind it.

**Wire contract** (binary, not JSON — one small reading per fruit isn't
worth a request/response round trip):

- Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Sensor characteristic (notify) `6E400003-...` — fixed 12-byte
  little-endian packet: weight×100 (Int32) + raw R/G/B (UInt16 each) +
  color code (UInt8, 0=unknown…7=white) + status bitmask (bit0=load cell
  ready, bit1=color sensor ready). See `Networking/DTOs.swift` for the
  exact decode.
- Command characteristic (write) `6E400002-...` — single byte, the grade
  the app computed (`1`=A … `5`=Reject/E), so the physical sorter routes
  the fruit. Sent once per graded event, right after the record is
  persisted (`Sync/SyncEngine.process`).
- **No `seq`/`timestamp` on the wire, no batch start/complete/status
  command.** The ESP32 is a stateless raw sensor + sorter; batch
  lifecycle and ID/timestamp sourcing are handled entirely app-side —
  see `Data_Architecture.md` § "Configurable ID/timestamp sourcing".
- **Grading happens app-side**, not on the ESP32 — see
  `Sync/FruitGrader.swift`. The algorithm there is a placeholder
  (weight-banded grading, nearest-named-color matching), not yet the
  real calibrated thresholds — see `Data_Architecture.md` § "Deferred,
  not rejected".

## 7. Settings reference

All three persist via `@AppStorage`, editable from the gear icon on
Homepage (`SettingsView.swift`):

| Setting | Options | Effect |
|---|---|---|
| Sumber Data | Simulasi (Mock) / BLE (Perangkat Asli) | Which `FruitDataSource` `SyncEngine` uses |
| Sumber ID / Urutan | Dari ESP32 / Dari Aplikasi | Whether `fruitSeq` comes from the wire `seq` or a local per-batch counter. Gap detection ("N records may be missed") only runs when ESP32-sourced |
| Sumber Timestamp | Dari ESP32 / Dari Aplikasi | Whether `deviceTimestamp` comes from the wire `timestamp` or mirrors `receivedAt`. Drift validation against `receivedAt` only runs when ESP32-sourced |

Changing any of the three mid-session rebuilds `SyncEngine` from scratch
(`ContentView.onChange`) — acceptable because this is a deliberate
tester/developer action, not something ops does mid-shift.

## 8. What's deliberately deferred

- **Real grading algorithm** — `FruitGrader` is a placeholder pending
  handoff of calibrated thresholds from whoever owns that on the
  firmware/QC side; nothing else needs to change when it's swapped in.
- **Real hardware testing** — `BLEFruitDataSource` matches `esp/ble.ino`
  on paper but hasn't run against a physical ESP32 yet.
- **Correcting a record after the fact** — deliberately out of scope:
  once N fruit of unknown identity are mixed in the physical output bin,
  there's no way to know which one a correction should apply to.
- **Archiving/retention policy** — not needed for this PoC; CSV/PDF
  export (§5–6) covers getting data off the device in the meantime.
