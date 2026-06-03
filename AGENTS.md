# AGENTS.md — Loopback contributor & agent guide

This file orients both human contributors and AI coding agents. Read it before making changes.
`CLAUDE.md` intentionally points here so there is a single source of truth.

## What this is

Loopback is a **local-first SwiftUI iOS app** that reads a Polar Loop band over Bluetooth and shows
activity/sleep/recovery data, storing everything on-device in SQLite. No backend, no accounts, no
analytics. See `README.md` for the product overview and screenshots.

## Repo layout

```
Loopback.xcodeproj/                 # project + shared "Loopback" scheme
Loopback/
  LoopbackApp.swift                 # the entire app (see "Single-file layout" below)
  Info.plist                        # display name "Loopback", usage strings, BLE background mode
  Loopback.entitlements             # HealthKit
  Assets.xcassets/                  # app icon
LoopbackTests/
  LoopbackTests.swift               # unit tests for MetricsEngine
tools/make_icon.py                  # regenerates the app icon
docs/screenshots/                   # README images
```

## Build, run, test

```bash
# Build for the simulator
xcodebuild -project Loopback.xcodeproj -scheme Loopback -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run the unit tests
xcodebuild -project Loopback.xcodeproj -scheme Loopback \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The project has **no signing team and a placeholder bundle id** (`com.example.loopback`) so the
simulator build needs zero setup. For a device build, set your own team + bundle id in Xcode
(Signing & Capabilities). Do **not** commit a real team id or a personal bundle id back to the repo.

From the command line you can sign a device build by passing your team and bundle id at build time
(nothing committed):

```bash
xcodebuild -project Loopback.xcodeproj -scheme Loopback -configuration Debug \
  -destination 'platform=iOS,id=<YOUR_DEVICE_UDID>' -derivedDataPath build-device \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> PRODUCT_BUNDLE_IDENTIFIER=<your.bundle.id> \
  -allowProvisioningUpdates
xcrun devicectl device install app --device <YOUR_DEVICE_UDID> \
  build-device/Build/Products/Debug-iphoneos/Loopback.app
```

A personal, git-ignored `install-device.sh` is the convenient way to keep your own values out of the
repo.

## Single-file layout

The whole app is `Loopback/LoopbackApp.swift`, divided by `// MARK:` sections. Swift doesn't care
about declaration order at file scope, so types are grouped by concern, not dependency. Major
sections, in order:

1. **App entry & infra** — `LoopbackApp`, `SettingsKey`, `TempUnit`, `NotificationManager`.
2. **Model types** — `DailySummary` (the device-neutral daily record), `SleepSpan`, `HeartRateSample`,
   `JournalEntry`, `UserProfile`, `SyncPayload`, `HealthSource`, `ComparisonDay`.
3. **`AppModel`** — the single `@MainActor ObservableObject` the whole UI binds to. Owns connection
   state, summaries, journal, health-source selection, and all user actions.
4. **`PolarClient` protocol** + two implementations:
   - `RealPolarBleClient` — wraps the Polar BLE SDK. Compiled **only off-simulator**
     (`#if canImport(PolarBleSdk) && !targetEnvironment(simulator)`).
   - `MockPolarClient` — used on the simulator; emits fake scan results, battery, live HR, and a
     `MockDataFactory` sync payload.
5. **Engines** — `MetricsEngine` (recharge/sleep/exertion scoring + contributors), `CoachEngine`
   (the Insights blurb), `ExportService`.
6. **`LocalStore`** — hand-rolled SQLite (via `SQLite3`). Schema + migrations live here.
7. **`MockDataFactory`** — generates the 35-day sample dataset (see below).
8. **`HealthKitReader`** — optional Apple Health read/write + multi-source discovery.
9. **Design system** — `Theme` (colors/gradients), `Copy` (user-facing vocabulary), reusable views
   (`RingGauge`, `StatTile`, `PillButton`, `AreaSparkline`, …).
10. **Views** — `RootView` (TabView) → `TodayView`, `TrendsView`, `DeviceView`, `ProfileHubView`,
    plus `MetricDetailView`, `LogSheet`, sheets, and cards.

## Key concepts

- **`DailySummary` is the unit of truth for a day.** It is device-neutral on purpose: the Polar sync,
  the sample factory, and (read-through) Apple Health all reduce to this shape.
- **`MetricKind` enum** drives the drill-downs. Each Today card is a `NavigationLink(value:)` and
  `MetricDetailView` renders whatever `MetricKind` it's handed (title, unit, color, value extractor,
  history aggregation, "about" text). **To add a metric to the detail system, add a case here.**
- **`Copy` enum** holds all user-facing metric names. Internal code names (`recoveryScore`,
  `strainScore`, DB columns) are unchanged; only display strings route through `Copy`. This keeps the
  vocabulary neutral (Recharge, Exertion, Sleep Score, Vitals, Insights) — don't hardcode competitor
  terms in views.
- **Navigation:** 4 tabs (Today / Trends / Device / Profile). Logging is a floating `AddFAB` on Today
  that opens `LogSheet`. Export, Settings, and tag history live under `ProfileHubView` as sheets.
- **Multi-source cross-check:** `AppModel.selectedSourceIds: Set<String>` +
  `comparisonBySource: [name: [ComparisonDay]]`. `toggleSource` adds/removes; `ComparisonCard`
  renders Loop + each selected source + an average column. `HealthSource.metrics` lists exactly what
  each source writes to Apple Health — use it to reason about granularity.

## Sample / dummy data (for development)

On first launch `LocalStore.seedIfNeeded()` seeds `MockDataFactory.payload(days: 35)` with
`source: "sample"` so the UI is fully populated in the simulator. On the simulator, `MockPolarClient`
also returns this payload from a "sync". When a real device connects, `purgeSampleData()` deletes the
`source = 'sample'` rows so real and sample data never mix. A "Sample data" banner is shown while
sample rows are present. If you change the `DailySummary` shape, update both `MockDataFactory` and the
SQLite schema/migrations in `LocalStore`.

## Conventions

- Match the surrounding style; keep changes surgical. The file favors small value types, `@MainActor`
  on `AppModel`, and `async`/`AsyncStream` for the BLE event flow.
- Comments explain **why**, not what. Tests (`LoopbackTests`) encode intent — e.g. that recharge
  moves with HRV/RHR.
- Wellness framing only: no medical claims in copy. Keep BP/ECG/AFib/SpO₂ out of scope.
- Persisted data stays on-device. Don't add network calls, analytics, or telemetry.

## Gotchas

- The Polar SDK types are unavailable on the simulator by design — guard any SDK use with the same
  `#if canImport(PolarBleSdk) && !targetEnvironment(simulator)`.
- `skin_temp_delta_c` uses a `-1000` sentinel for "no baseline yet" (matches Polar). Read paths map
  it back to `nil`.
- The app is single-file by choice for now; if you split it, keep the `// MARK:` structure.
