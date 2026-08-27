# Oren iPad App — Data Architecture

Scope: single iPad, single rig, local persistence only. "Sync" here means
ESP32 → iPad data flow, not multi-device or cloud sync. If that
assumption changes (e.g. a supervisor dashboard watching multiple rigs
at once), most of this needs rethinking.

## Why a database at all, and why SwiftData

This is a data-logging/QA app by nature (batch history, per-fruit
records, export). **SwiftData** (SQLite-backed) is the right tool:
native, integrates with SwiftUI via `@Query`/`@Model`, works fully
offline, needs no server. Nothing here justifies anything heavier (Core
Data + custom stack, Realm, Firebase) under the local-only assumption.

**No Postgres/MySQL, and no separate backend service, either** — both
solve problems this architecture doesn't have: multiple untrusted
clients needing a shared source of truth, remote/networked access,
centralized multi-user transactions. There's one iPad and one rig,
connected directly over Bluetooth Low Energy — chosen over WiFi/HTTP
because each transmission is a single small per-fruit reading, not worth
a request/response round trip for. The ESP32 exposes a GATT service
(fruit-event notify, command write) — a peripheral in the BLE sense, but
not a backend service in the infrastructure sense: no database of its
own, and no batch concept either (see "Batch lifecycle" below). SwiftData
on the iPad is the only durable store in the system.

## Schema

**`Batch`** (`Models/Batch.swift`)
| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `batchLabel` | String | Sequential per-day, e.g. `B2026-08-17-01`, `-02` — derived from the highest existing sequence for today, not a plain count, so a deleted batch never collides with a label still in use (`ContentView.nextBatchLabel`) |
| `startedAt` / `endedAt` | Date | `endedAt` nil while active |
| `statusRaw` / `status` | String / `BatchStatus` | `active` / `completed`, exposed as a typed computed property |
| `qcStaff` | String | Whoever was selected on `LoginView` when the batch started; empty if nobody was set |
| `fruitRecords` | `[FruitRecord]` | Cascade-delete relationship |
| `rejectedEvents` | `[RejectedEvent]` | Cascade-delete relationship |

Deliberately **no stored count/total fields** — see "Why aggregates are
computed, not stored" below.

**`FruitRecord`** (`Models/FruitRecord.swift`) — one successfully graded fruit
| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `batch` | `Batch?` | |
| `fruitSeq` | Int | Either the ESP32's own counter or an app-generated fallback, depending on `idSource` — see "Configurable ID/timestamp sourcing" |
| `receivedAt` | Date | iPad's own clock — always the authoritative timestamp for ordering/display, regardless of `deviceTimestamp`'s source |
| `deviceTimestamp` | Date | Either the ESP32's measurement-time clock or a copy of `receivedAt`, depending on `timestampSource` |
| `weightG` | Double | Raw sensor reading, grams |
| `rawR` / `rawG` / `rawB` | Int16 | Raw TCS3200 color-sensor pulse-period counts from the ESP32 — **not** 0–255 RGB, kept for diagnostics (see `esp/ble.ino`) |
| `colorCode` | Int16 | The ESP32's own nearest-reference-color classification of that raw reading (0=unknown … 7=white) |
| `colorName` | String | Computed app-side from `colorCode` by `FruitGrader` (placeholder logic — see "App-side grading") |
| `gradeRaw` / `grade` | String / `FruitGrade` | `A`–`E`, also computed app-side by `FruitGrader`, same caveat |

**`RejectedEvent`** (`Models/RejectedEvent.swift`) — one event that failed
validation before it could become a `FruitRecord`
| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `batch` | `Batch?` | |
| `receivedAt` | Date | |
| `weightG`, `rawR`/`rawG`/`rawB`, `colorCode` | Double / Int16 | Same raw fields as `FruitRecord`, whatever was on the wire when it was rejected |
| `hxReady` / `colorReady` | Bool | Sensor-readiness bits from the status byte — see `SyncEngine.process` |
| `reason` | String | Human-readable (Indonesian), e.g. "Berat di luar rentang wajar (2400 gram)" |

Exists so validation failures are visible and queryable
(`RejectedEventsView`, reachable from a batch's detail page) instead of
silently vanishing — see `SyncEngine.process`.

## Why aggregates are computed, not stored

First draft stored running totals on `Batch`, incrementally updated per
fruit. Rejected: if a crash or partial write happens between saving a
`FruitRecord` and updating the paired counter, the two silently drift
apart with no signal that it happened. Computing `totalCount`, per-grade
counts, and `totalWeightG` as live computed properties over the actual
`fruitRecords` array (see `Batch.swift`) costs nothing measurable at this
data volume (dozens to low hundreds of records per batch) and makes
drift structurally impossible — the numbers are always derived from the
source-of-truth rows.

## Sync pipeline (ESP32 → iPad)

BLE, push-based (GATT notify) — not HTTP polling. Implemented in
`Sync/SyncEngine.swift`, the only class allowed to talk to
`FruitDataSource`.

1. The ESP32 is a raw sensor: it notifies a BLE characteristic with a
   fixed 12-byte packet (`weight`, raw R/G/B, `colorCode`, status
   bitmask) — see `Networking/DTOs.swift` for the exact layout. No
   `seq`/`timestamp` on the real wire (see below). This is a *continuous*
   stream while a fruit sits on the load cell settling, not one clean
   packet per fruit — `BLEFruitDataSource.processDecodedPacket` runs a
   settle-detection debounce (ported from the companion app's
   `BluetoothManager.checkAutomaticGrading`) that only forwards a
   notification to `onEvent` once weight has held steady for 3
   consecutive packets, then requires the platform to read back
   near-empty for 3 consecutive packets before the next fruit can be
   detected. Without this, one physical fruit would be graded and
   persisted as many separate `FruitRecord`s. `MockFruitDataSource`
   doesn't need this — it already emits one discrete event per simulated
   fruit.
2. `ContentView` builds a `FruitDataSource` (`BLEFruitDataSource` or
   `MockFruitDataSource`, per the "Sumber Data" setting) and hands it to
   `SyncEngine`. The iPad subscribes once a batch is active
   (`SyncEngine.beginObserving`) and receives events via `onEvent` — each
   call is assumed to be exactly one distinct fruit.
3. `FruitGrader` (app-side, placeholder — see "App-side grading" below)
   classifies each event's weight + RGB into a `grade` and `colorName`.
4. Each event is validated before persisting: `hxReady`/`colorReady`
   sensor-ready bits must both be true, and `weightG` must be in
   `0..<2000`g. Failures become a `RejectedEvent` with a human-readable
   `reason` instead of silently being dropped or counted toward the
   batch.
5. **Gap/duplicate detection** uses `seq`, only when `idSource ==
   .esp32`: if a received `seq` jumps by more than expected,
   `missedRecordsWarning` accumulates and surfaces in `GradingView`
   rather than continuing silently. When `idSource == .app`, gap
   detection is switched off entirely — an app-generated counter can
   only count what it *receives*, with no way to know a notification was
   dropped in transit.
6. **Timestamp validation**, when `timestampSource == .esp32`, is
   separate: the ESP32's `timestamp` is compared against the iPad's own
   receipt time (`receivedAt`), and a drift beyond 10 seconds
   (`SyncEngine.maxPlausibleTimestampDriftSeconds`) increments
   `timestampMismatchWarning`. This does **not** replace `receivedAt` as
   the authoritative timestamp. When `timestampSource == .app`, this
   check is skipped.
7. App resume: `ContentView.task` calls
   `SyncEngine.reconcileOnResume(localActiveBatch:)` on launch — if a
   `Batch` was left `active` locally, observing resumes automatically.
   The ESP32 has no batch state of its own to reconcile against (it's
   stateless), so this is purely a local decision.
8. Start/Complete are **local-only actions**, not wire commands — see
   "Batch lifecycle" below. The only outbound wire command is the graded
   result, written back once per event (`sendGrade`, `commandByte` 1–5)
   so the physical sorter routes the fruit into the right lane.

## App-side grading (placeholder)

The ESP32 only reports raw weight + RGB; it does not classify fruit
itself. `Sync/FruitGrader.swift` owns that classification, but **the
real algorithm hasn't been handed over yet** — what's there is a rough
stand-in (weight-banded grading, nearest-named-color RGB matching)
clearly marked as provisional in code. Swap it out wholesale once real
thresholds are confirmed; `FruitGrader` is the only place that logic
lives, so nothing else in the pipeline should need to change.

## Configurable ID/timestamp sourcing

Because the ESP32 does not send `seq` or `timestamp` on the real wire
today, each is independently either ESP32-sourced or app-generated,
chosen via a `DataFieldSource` (`.esp32` / `.app`) setting in
`SettingsView` — not a fixed architectural decision, since which side
ends up providing these is still open pending firmware changes.

**`idSource`**
- `.esp32`: uses the ESP32's `seq` when present (falls back to a local
  counter for that one event if momentarily missing). Gap detection is
  active.
- `.app`: always uses a local per-batch counter, ignoring any `seq` on
  the wire. Gap detection cannot run in this mode — structural, not a
  bug to fix later.

**`timestampSource`**
- `.esp32`: uses the ESP32's `timestamp` when present, cross-validated
  against `receivedAt`.
- `.app`: `deviceTimestamp` is just set to `receivedAt` — no independent
  clock to validate against.

`MockFruitDataSource` always emits both `seq` and `timestamp` regardless
of these settings, so switching between `.esp32`/`.app` in Settings
exercises both code paths against the same mock — `SyncEngine` decides
whether to trust or ignore what's on the wire, not the data source.

**This is live, not batch-released.** Every fruit is validated and
written to SwiftData individually, within roughly BLE notification
latency of being graded — not withheld until Complete is pressed.
Because aggregates are live computed properties (see above), the UI
reflects each new record immediately with no separate "finalize" step.
Pressing **Complete** only flips `status` and stamps `endedAt`. Because
delivery is push-based rather than polled, there's no "one more poll"
step before completing — instead, a 1-second grace window
(`SyncEngine.finalDrain`) gives a near-simultaneous notification a
moment to land before the app stops observing.

## Batch lifecycle (confirmed)

A `Batch` is strictly bounded by two explicit user actions in the app:
tapping **Mulai Grading** opens it (`status = .active`, a `Batch` row
inserted locally), tapping **Selesai** closes it (`status = .completed`,
`endedAt` set). There's no implicit "always counting" state. Neither
action is a wire command — the ESP32 has no batch concept at all, it
streams continuously regardless; `beginObserving`/`stopObserving` just
start/stop *listening* and connect/disconnect BLE around local state.

Fruit events that arrive with no active `Batch` are ignored outright
(`SyncEngine.process` returns early when `activeBatch == nil`) — never
auto-attached to a phantom batch or folded into the most recent one.

## Deferred, not rejected

- **Real grading algorithm** — `FruitGrader`'s weight-band grading and
  nearest-named-color matching are placeholders, not calibrated against
  real sensor data. Pending handoff of the actual classification logic
  from whoever owns that on the firmware/QC side.
- **Real hardware validation** — `BLEFruitDataSource`'s service/
  characteristic UUIDs and packet decode are confirmed against
  `esp/ble.ino` on paper, but the class has not yet been run against
  physical ESP32 hardware. `MockFruitDataSource` is what Simulator
  testing actually exercises in the meantime — see README.md.
- **Correcting a record after the fact** — out of scope: once N fruit
  are physically mixed into the sorted output, there's no way to know
  which specific record a correction should apply to.
- **Archiving/retention policy** — not needed for this PoC; CSV/PDF
  export (`Export/BatchExporter.swift`, share-sheet delivery including
  AirDrop to e.g. a manager's iPhone) covers getting data off-device.
