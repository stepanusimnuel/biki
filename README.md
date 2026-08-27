# Biki

QC and grading system for a fruit-sorting rig. An iPad receives per-fruit weight and colour readings from an ESP32 over Bluetooth Low Energy, grades each fruit on-device, tracks it against a batch, and writes the grade back so the sorter routes the fruit into the correct lane.

Target device: **iPad Pro 11" (M5)**, iOS 26+. Single iPad, single rig, local-only persistence — there is no backend.

## Repository layout

```
biki/
├── app/          iPadOS app — Xcode project at app/biki.xcodeproj
└── esp/          ESP32 firmware
    ├── ble.ino        the wire contract between rig and app
    └── wokwi_sim.ino  simulator build for testing without hardware
```

## Documentation

The detailed docs live with the app:

- [`app/biki/README.md`](app/biki/README.md) — architecture, database schema, mock-vs-BLE setup, settings reference, and step-by-step run instructions
- [`app/biki/Data_Architecture.md`](app/biki/Data_Architecture.md) — why there is no backend, and how ID/timestamp sourcing is configured

## Tech stack

- Swift / SwiftUI with `@Observable`
- SwiftData — local persistence
- CoreBluetooth — the link to the rig
- Swift Charts — dashboard visualisations
- ESP32 (Arduino C++) — firmware

Views never touch Bluetooth directly. `FruitDataSource` is a protocol with two implementations — `BLEFruitDataSource` for real hardware and `MockFruitDataSource` for an in-process generator — and `SyncEngine` is its only consumer, which is what makes the app runnable without the rig.

## Getting started

**Without hardware** (works in the Simulator):

1. Open `app/biki.xcodeproj` in Xcode.
2. Run, then open Settings (gear icon in the Homepage header) and set **Sumber Data** to *Mock*.
3. See §5 of the [app README](app/biki/README.md) for the walkthrough.

**With the rig:**

1. Flash `esp/ble.ino` to an ESP32.
2. Run the app on a physical iPad and set **Sumber Data** to *BLE*.
3. See §6 of the [app README](app/biki/README.md) for pairing and troubleshooting.

> The app is titled "Oren iPad App" in the docs while the repository and Xcode target are named `biki` — both refer to this project.
