import Foundation
import SwiftUI
import Charts
import SQLite3
import HealthKit
import UserNotifications

#if canImport(PolarBleSdk) && !targetEnvironment(simulator)
import CoreBluetooth
import PolarBleSdk
#endif

@main
struct LoopbackApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.lowBatteryAlerts: true,
            SettingsKey.tempUnitFahrenheit: false,
            SettingsKey.imperialBodyUnits: false
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-arm seamless BLE reconnection whenever we return to the foreground.
            if phase == .active { model.onForeground() }
        }
    }
}

enum SettingsKey {
    static let lowBatteryAlerts = "settings.lowBatteryAlerts"
    static let tempUnitFahrenheit = "settings.tempUnitF"
    /// Profile height/weight input units. false = metric (cm/kg), true = imperial (ft·in / lb).
    /// Storage stays metric; this only affects how the profile fields are shown and entered.
    static let imperialBodyUnits = "settings.imperialBody"
}

/// Temperature unit preference + conversion. Absolute temps get the full °C→°F conversion; a
/// *delta* (deviation) gets only the 9/5 scale, no +32 offset.
enum TempUnit {
    static var isFahrenheit: Bool { UserDefaults.standard.bool(forKey: SettingsKey.tempUnitFahrenheit) }
    static var label: String { isFahrenheit ? "°F" : "°C" }
    static func convert(_ celsius: Double, isDelta: Bool) -> Double {
        guard isFahrenheit else { return celsius }
        return isDelta ? celsius * 9 / 5 : celsius * 9 / 5 + 32
    }
}

/// Local notifications — currently low-battery alerts for the Loop. No remote/push server; these
/// fire on-device from BLE battery events (which keep arriving under the bluetooth-central
/// background mode), so all data stays local.
enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func sendLowBattery(level: Int, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Polar Loop battery low"
        content.body = threshold <= 5
            ? "Battery is at \(level)%. Charge your Loop now to avoid losing tracking."
            : "Battery is at \(level)%. Charge your Loop soon."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "lowBattery-\(threshold)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct WearableDevice: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let rssi: Int
    let isConnectable: Bool
}

/// One contiguous sleep phase within a night, measured in minutes from sleep onset. Persisted
/// per day so the Today screen can draw a real hypnogram instead of an invented stage split.
struct SleepSpan: Codable, Equatable {
    enum Stage: String, Codable, CaseIterable { case deep, light, rem, awake }
    var startMin: Int
    var durationMin: Int
    var stage: Stage
}

extension SleepSpan {
    /// Build a plausible ordered hypnogram for a night of `totalMinutes` with `wakeCount` brief
    /// awakenings — deep sleep front-loaded, REM weighted toward morning, like real sleep. Used
    /// for sample data and as a fallback for days that have a duration but no staged sleep.
    static func synthesize(totalMinutes: Int, wakeCount: Int) -> [SleepSpan] {
        guard totalMinutes > 30 else { return [] }
        var spans: [SleepSpan] = []
        var cursor = 0
        var cycle = 0
        while cursor < totalMinutes && cycle < 12 {
            let early = cursor < totalMinutes / 2
            let pattern: [(SleepSpan.Stage, Int)] = [
                (.light, 18),
                (.deep, early ? 28 : 12),
                (.light, 14),
                (.rem, early ? 16 : 30)
            ]
            for (stage, dur) in pattern where cursor < totalMinutes {
                let d = min(dur, totalMinutes - cursor)
                spans.append(SleepSpan(startMin: cursor, durationMin: d, stage: stage))
                cursor += d
            }
            cycle += 1
        }
        // Convert a few of the lighter spans into brief awakenings.
        if wakeCount > 0 && spans.count > 2 {
            let step = max(1, spans.count / (wakeCount + 1))
            var idx = step, inserted = 0
            while inserted < wakeCount && idx < spans.count {
                spans[idx].stage = .awake
                spans[idx].durationMin = min(spans[idx].durationMin, 6)
                idx += step
                inserted += 1
            }
        }
        return spans
    }
}

struct DailySummary: Identifiable, Codable, Equatable {
    var id: String { dayKey }
    var dayKey: String
    var date: Date
    var recoveryScore: Int
    var sleepScore: Int
    var strainScore: Int
    var sleepMinutes: Int
    var activeMinutes: Int
    var restingHeartRate: Double
    var hrvMs: Double
    /// Skin-temperature deviation from the wearer's baseline, in °C. `nil` when the device hasn't
    /// established a baseline yet (Polar reports a -1000 sentinel until it has enough sleep history).
    var skinTempDeltaC: Double?
    /// Absolute overnight skin temperature in °C, available from the device immediately (before any
    /// deviation baseline exists). Lets us track temperature changes and derive our own deviation.
    var skinTempC: Double? = nil
    var calories: Int
    var steps: Int
    /// Ordered sleep phases for the night attributed to this day. Empty for days with no
    /// staged sleep (older rows, or activity-only days) — callers fall back gracefully.
    var sleepStages: [SleepSpan] = []
}

struct HeartRateSample: Identifiable, Codable, Equatable {
    var id = UUID()
    var timestamp: Date
    var bpm: Int
    var rrMs: [Int]
}

struct JournalEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var tag: String
    var note: String
}

/// The wearer's physical profile. A Polar Loop only computes steps/calories/sleep once a
/// profile like this is written to the device (the SDK's "first time use"); without it the
/// device returns empty daily slots. Stored locally on the phone (never uploaded) and the
/// relevant subset is pushed to the Loop via doFirstTimeUse.
struct UserProfile: Codable, Equatable {
    enum Sex: String, Codable, CaseIterable, Identifiable {
        case male, female
        var id: String { rawValue }
        var label: String { self == .male ? "Male" : "Female" }
    }
    enum TypicalDay: Int, Codable, CaseIterable, Identifiable {
        case sitting = 1, standing = 2, moving = 3
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .sitting: return "Mostly sitting"
            case .standing: return "Mostly standing"
            case .moving: return "Mostly moving"
            }
        }
    }

    var sex: Sex = .male
    var birthDate: Date = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    var heightCm: Double = 175
    var weightKg: Double = 75
    var restingHr: Int = 60
    var typicalDay: TypicalDay = .sitting
    // SDK-required extras with sensible defaults; users rarely need to touch these.
    var vo2Max: Int = 40
    var sleepGoalMinutes: Int = 480

    var age: Int { Calendar.current.dateComponents([.year], from: birthDate, to: .now).year ?? 30 }
    /// Age-predicted max HR, clamped to the SDK's accepted 100–240 range.
    var maxHr: Int { min(240, max(100, 220 - age)) }
}

struct SyncPayload: Codable, Equatable {
    var dailySummaries: [DailySummary]
    var heartRateSamples: [HeartRateSample]
    var journalEntries: [JournalEntry] = []
    /// Human-readable per-fetch breakdown for on-device debugging (persisted to sync_log
    /// so it can be pulled off the device — NSLog isn't visible on a real phone).
    var diagnostics: String = ""
}

enum PolarClientEvent {
    case status(String)
    case discovered(WearableDevice)
    case connecting(WearableDevice)
    case connected(WearableDevice)
    case disconnected(String)
    case battery(Int)
    case heartRate(HeartRateSample)
    /// The device's historical-data service is ready — safe to sync now.
    case readyToSync
}

protocol PolarClient: AnyObject {
    var events: AsyncStream<PolarClientEvent> { get }
    func startScan() async throws
    func stopScan() async
    func connect(_ device: WearableDevice) async throws
    /// Seamless reconnect to a previously paired device id without a user-initiated scan. Arms a
    /// direct-then-scan fallback that keeps retrying until connected or `disconnect()` is called.
    func reconnect(toDeviceId id: String) async
    func disconnect() async
    func startLiveHeartRate() async throws
    func stopLiveHeartRate() async
    func syncLatest() async throws -> SyncPayload
    /// Whether the connected device already has a user profile written (Polar "first time use").
    func isFirstTimeUseDone() async throws -> Bool
    /// Write the wearer's profile to the device so it starts computing activity, and set its clock.
    func runFirstTimeUse(profile: UserProfile) async throws
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [WearableDevice] = []
    @Published var selectedDevice: WearableDevice?
    @Published var connectionState = "Not connected"
    @Published var statusLine: String?
    @Published var batteryLevel: Int?
    @Published var liveHeartRate: Int?
    @Published var summaries: [DailySummary] = []
    @Published var journalEntries: [JournalEntry] = []
    @Published var isScanning = false
    @Published var isSyncing = false
    @Published var lastSyncText = "Never"
    @Published var showingSampleData = true
    @Published var awaitingFirstSync = false
    /// Per-source comparison days, keyed by source name. One entry per selected Health source so the
    /// Loop can be cross-checked against several wearables at once (and averaged across them).
    @Published var comparisonBySource: [String: [ComparisonDay]] = [:]
    @Published var healthSources: [HealthSource] = []
    @Published var selectedSourceIds: Set<String> = []
    @Published var isDiscoveringSources = false
    @Published var healthConnected = false
    @Published var isReadingHealth = false
    @Published var isWritingHealth = false
    @Published var healthWriteStatus: String?
    @Published var profile = UserProfile()
    @Published var hasProfile = false
    /// nil = unknown/not checked, true/false = device's first-time-use state.
    @Published var ftuDone: Bool?
    @Published var isSettingUpDevice = false
    @Published var setupStatus: String?
    @Published var alertText: String?
    @Published var exportURL: URL?

    let localOnlyCopy = "All data stays on this iPhone in SQLite. No Polar Flow, AccessLink, backend, or analytics are required."

    private let client: any PolarClient
    private let store: LocalStore
    private let health = HealthKitReader()
    private var eventTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    /// Battery thresholds (%) already alerted this discharge cycle; cleared as the battery rises
    /// back above each, so a single drain fires at most one alert per threshold.
    private var alertedBatteryThresholds: Set<Int> = []
    private let batteryAlertThresholds = [20, 10, 5]

    init(store: LocalStore? = nil, client: (any PolarClient)? = nil) {
        do {
            let resolvedStore = try store ?? LocalStore()
            self.store = resolvedStore
            self.client = client ?? AppModel.makeClient()
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.client.events {
                    self.apply(event)
                }
            }
            Task {
                await loadInitialData()
            }
            if UserDefaults.standard.bool(forKey: SettingsKey.lowBatteryAlerts) {
                NotificationManager.requestAuthorization()
            }
        } catch {
            fatalError("Unable to open local SQLite store: \(error)")
        }
    }

    /// Fire a local notification when the battery crosses below an alert threshold (once per
    /// threshold per discharge). Re-arms a threshold when the battery climbs back above it.
    private func handleBatteryLevel(_ level: Int) {
        batteryLevel = level
        guard UserDefaults.standard.bool(forKey: SettingsKey.lowBatteryAlerts) else { return }
        for threshold in batteryAlertThresholds where level > threshold {
            alertedBatteryThresholds.remove(threshold)
        }
        // Alert on the lowest crossed threshold not yet alerted (most urgent message wins).
        if let threshold = batteryAlertThresholds.sorted(by: <).first(where: { level <= $0 && !alertedBatteryThresholds.contains($0) }) {
            alertedBatteryThresholds.insert(threshold)
            NotificationManager.sendLowBattery(level: level, threshold: threshold)
            try? store.insertSyncLog(message: "Low-battery alert fired at \(level)% (threshold \(threshold)%)")
        }
    }

    deinit {
        eventTask?.cancel()
    }

    private static func makeClient() -> any PolarClient {
        #if canImport(PolarBleSdk) && !targetEnvironment(simulator)
        RealPolarBleClient()
        #else
        MockPolarClient()
        #endif
    }

    var today: DailySummary? {
        summaries.first
    }

    var coachSummary: String {
        CoachEngine.dailySummary(today: today, history: summaries)
    }

    /// Heart-rate samples recorded on a given local day, for the Today screen's daily HR curve.
    func heartRateSamples(onDay dayKey: String) -> [HeartRateSample] {
        (try? store.fetchHeartRateSamples(onDay: dayKey)) ?? []
    }

    func startScan() {
        isScanning = true
        alertText = nil
        Task {
            do {
                try await client.startScan()
            } catch {
                alertText = "Scan failed: \(error.localizedDescription)"
                isScanning = false
            }
        }
    }

    func stopScan() {
        isScanning = false
        Task {
            await client.stopScan()
        }
    }

    func connect(_ device: WearableDevice) {
        selectedDevice = device
        userInitiatedDisconnect = false
        Task {
            do {
                try await client.connect(device)
            } catch {
                alertText = "Connection failed: \(error.localizedDescription)"
                connectionState = "Connection failed"
            }
        }
    }

    func disconnect() {
        // Manual disconnect: stop auto-reconnecting and forget the saved device.
        userInitiatedDisconnect = true
        try? store.setMeta("last_device_id", value: "")
        connectionState = "Not connected"
        Task {
            await client.disconnect()
        }
    }

    /// On launch / foreground / after a reboot, reconnect to the last device by id with no scan.
    /// The client arms a direct-then-scan fallback loop that retries until the Loop is in range.
    /// Idempotent — safe to call repeatedly. Only a user disconnect (which clears last_device_id)
    /// or an app reinstall (which wipes the store) stops it.
    func autoReconnectIfPossible() {
        let lastId = (try? store.getMeta("last_device_id")).flatMap { $0 }
        guard let id = lastId, !id.isEmpty else { return }
        let name = ((try? store.getMeta("last_device_name")).flatMap { $0 }) ?? "Polar Loop"
        selectedDevice = WearableDevice(id: id, name: name, rssi: 0, isConnectable: true)
        if !connectionState.contains("Connected") {
            connectionState = "Reconnecting to \(name)"
        }
        userInitiatedDisconnect = false
        logEvent("autoReconnect armed id=\(id) name=\(name)")
        Task { await client.reconnect(toDeviceId: id) }
    }

    /// Re-arm reconnection when the app returns to the foreground.
    func onForeground() {
        autoReconnectIfPossible()
    }

    func toggleLiveHeartRate() {
        Task {
            do {
                if liveHeartRate == nil {
                    try await client.startLiveHeartRate()
                } else {
                    await client.stopLiveHeartRate()
                    liveHeartRate = nil
                }
            } catch {
                alertText = "Live HR failed: \(error.localizedDescription)"
            }
        }
    }

    func syncNow(auto: Bool = false) {
        isSyncing = true
        Task {
            do {
                let payload = try await client.syncLatest()
                guard !payload.dailySummaries.isEmpty || !payload.heartRateSamples.isEmpty else {
                    // Connected fine, but the Loop returned no stored activity/sleep for the
                    // window. Usually means it hasn't been worn (especially overnight) and
                    // synced enough yet. Keep the existing data rather than wiping it. Stay
                    // quiet for automatic syncs so reconnects don't pop alerts. Always record
                    // the per-fetch breakdown so an empty sync is debuggable from the DB.
                    try? store.insertSyncLog(message: "Empty sync — \(payload.diagnostics)")
                    if !auto {
                        alertText = "No activity or sleep history was found on the Loop for the last couple of weeks. Wear it (especially overnight), then sync again. Connection and live heart rate are working."
                    }
                    isSyncing = false
                    return
                }
                try store.save(payload.dailySummaries)
                try store.save(payload.heartRateSamples)
                try store.save(payload.journalEntries)
                try? store.pruneHeartRate(olderThanDays: 30)
                try store.setMeta("data_source", value: "real")
                try store.insertSyncLog(message: "Synced \(payload.dailySummaries.count) days, \(payload.heartRateSamples.count) HR — \(payload.diagnostics)")
                summaries = try store.fetchDailySummaries(limit: 90)
                journalEntries = try store.fetchJournalEntries(limit: 100)
                showingSampleData = false
                awaitingFirstSync = false
                lastSyncText = Date.now.shortDateTime
            } catch {
                alertText = "Sync failed: \(error.localizedDescription)"
            }
            isSyncing = false
        }
    }

    func addJournal(tag: String, note: String, date: Date = .now) {
        let entry = JournalEntry(date: date, tag: tag, note: note)
        do {
            try store.save([entry])
            journalEntries = try store.fetchJournalEntries(limit: 100)
        } catch {
            alertText = "Journal save failed: \(error.localizedDescription)"
        }
    }

    func exportJSON() {
        do {
            exportURL = try ExportService(store: store).writeJSONExport()
        } catch {
            alertText = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportCSV() {
        do {
            exportURL = try ExportService(store: store).writeDailyCSVExport()
        } catch {
            alertText = "Export failed: \(error.localizedDescription)"
        }
    }

    /// The sources the Loop is currently being compared against (in stable display order).
    var selectedSources: [HealthSource] {
        healthSources.filter { selectedSourceIds.contains($0.id) }
    }

    func connectAppleHealth() {
        guard HealthKitReader.isAvailable else {
            alertText = "Apple Health isn't available on this device."
            return
        }
        Task {
            do {
                try await health.requestAuthorization()
                healthConnected = true
                try? store.setMeta("health_connected", value: "yes")
                await discoverHealthSources()
                await refreshComparison()
            } catch {
                alertText = "Apple Health permission failed: \(error.localizedDescription)"
            }
        }
    }

    /// Enumerate every app/device writing to Health, persist the list for diagnostics, and pick a
    /// sensible default source (a ring/Ultrahuman-named one) the first time if none is chosen.
    func discoverHealthSources() async {
        guard HealthKitReader.isAvailable else { return }
        isDiscoveringSources = true
        let sources = await health.discoverSources()
        healthSources = sources
        try? store.insertSyncLog(message: "Health sources: " + sources.map { "\($0.name)(\($0.feedCount)f)={\($0.metrics.joined(separator: "/"))}" }.joined(separator: " | "))
        // Drop any selected ids that no longer exist; default-pick a ring-like source the first time.
        selectedSourceIds = selectedSourceIds.filter { id in sources.contains { $0.id == id } }
        if selectedSourceIds.isEmpty, let preferred = sources.first(where: { $0.name.localizedCaseInsensitiveContains("ultrahuman") }) ?? sources.first {
            selectedSourceIds = [preferred.id]
        }
        persistSelectedSources()
        isDiscoveringSources = false
    }

    /// Add or remove a source from the comparison set (multi-select).
    func toggleSource(_ id: String) {
        if selectedSourceIds.contains(id) {
            selectedSourceIds.remove(id)
            comparisonBySource[id] = nil
        } else {
            selectedSourceIds.insert(id)
        }
        persistSelectedSources()
        Task { await refreshComparison() }
    }

    private func persistSelectedSources() {
        // Stored as a newline-joined list (source names can contain commas/spaces).
        try? store.setMeta("compare_source_ids", value: selectedSourceIds.joined(separator: "\n"))
    }

    func refreshComparison() async {
        guard HealthKitReader.isAvailable, !selectedSourceIds.isEmpty else { comparisonBySource = [:]; return }
        isReadingHealth = true
        var result: [String: [ComparisonDay]] = [:]
        for id in selectedSourceIds {
            result[id] = await health.comparisonDays(sourceId: id, daysBack: 30)
        }
        comparisonBySource = result
        isReadingHealth = false
    }

    /// Push the Loop's real synced days into Apple Health (steps, active energy, resting HR,
    /// HRV). Requests write permission on first use. No-op until there's real data to write.
    func writeToAppleHealth() {
        guard HealthKitReader.isAvailable else {
            alertText = "Apple Health isn't available on this device."
            return
        }
        let days = summaries.filter { $0.steps > 0 || $0.restingHeartRate > 0 || $0.hrvMs > 0 || $0.calories > 0 }
        guard !days.isEmpty else {
            alertText = "No Loop data to write yet. Sync your Loop first, then push it to Apple Health."
            return
        }
        isWritingHealth = true
        healthWriteStatus = nil
        Task {
            do {
                if !healthConnected {
                    try await health.requestAuthorization()
                    healthConnected = true
                    try? store.setMeta("health_connected", value: "yes")
                }
                let count = try await health.writeSummaries(days)
                healthWriteStatus = count > 0
                    ? "Wrote \(count) sample(s) across \(days.count) day(s) to Apple Health."
                    : "Nothing to write — grant write access to these categories in Health, then try again."
            } catch {
                alertText = "Writing to Apple Health failed: \(error.localizedDescription)"
            }
            isWritingHealth = false
        }
    }

    // MARK: - User profile & device setup

    func saveProfile(_ newProfile: UserProfile) {
        profile = newProfile
        hasProfile = true
        do {
            let data = try JSONEncoder().encode(newProfile)
            try store.setMeta("user_profile", value: String(decoding: data, as: UTF8.self))
        } catch {
            alertText = "Could not save profile: \(error.localizedDescription)"
        }
    }

    private func loadProfile() {
        guard let json = (try? store.getMeta("user_profile")) ?? nil,
              let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode(UserProfile.self, from: data) else { return }
        profile = saved
        hasProfile = true
    }

    /// Ask the device whether it already has a user profile (first-time-use). Updates `ftuDone`.
    func refreshDeviceSetupState() {
        guard connectionState.contains("Connected") else { ftuDone = nil; return }
        Task {
            do { ftuDone = try await client.isFirstTimeUseDone() }
            catch { ftuDone = nil }
        }
    }

    /// Write the saved profile to the Loop so it starts computing activity, then re-check
    /// state and pull a fresh sync. Requires a connection and a saved profile.
    func setUpDevice() {
        guard connectionState.contains("Connected") else {
            alertText = "Connect your Loop before setting it up."
            return
        }
        guard hasProfile else {
            alertText = "Fill in and save your profile first."
            return
        }
        isSettingUpDevice = true
        setupStatus = "Writing your profile to the Loop…"
        Task {
            do {
                try await client.runFirstTimeUse(profile: profile)
                ftuDone = try await client.isFirstTimeUseDone()
                setupStatus = ftuDone == true
                    ? "Done. Wear the Loop and it will start recording — data syncs in automatically."
                    : "Profile written, but the device still reports setup incomplete. Try again."
                try? store.insertSyncLog(message: "FTU runFirstTimeUse done, ftuDone=\(String(describing: ftuDone))")
            } catch {
                setupStatus = nil
                alertText = "Device setup failed: \(error.localizedDescription)"
                try? store.insertSyncLog(message: "FTU FAILED: \(error)")
            }
            isSettingUpDevice = false
        }
    }

    private func loadInitialData() async {
        do {
            try store.seedIfNeeded()
            summaries = try store.fetchDailySummaries(limit: 90)
            journalEntries = try store.fetchJournalEntries(limit: 100)
            let source = (try store.getMeta("data_source")) ?? "sample"
            showingSampleData = (source == "sample")
            awaitingFirstSync = (source == "awaiting")
            healthConnected = (try store.getMeta("health_connected")) == "yes"
            // New multi-select key; fall back to the legacy single-source key for older installs.
            if let list = (try store.getMeta("compare_source_ids")), !list.isEmpty {
                selectedSourceIds = Set(list.split(separator: "\n").map(String.init))
            } else if let legacy = (try store.getMeta("compare_source_id")), !legacy.isEmpty {
                selectedSourceIds = [legacy]
            }
            loadProfile()
        } catch {
            alertText = "Startup load failed: \(error.localizedDescription)"
        }
        autoReconnectIfPossible()
        if healthConnected {
            Task {
                await discoverHealthSources()
                await refreshComparison()
            }
        }
    }

    /// Purge seeded demo data the moment a device connects so the dashboard never shows a
    /// mix of example and real numbers. Real synced days are preserved; if none remain, the
    /// UI shows a "waiting for data" state instead of dummy graphics. Idempotent.
    private func purgeSampleData() {
        do {
            try store.clearSampleData()
            summaries = try store.fetchDailySummaries(limit: 90)
            journalEntries = try store.fetchJournalEntries(limit: 100)
            showingSampleData = false
            awaitingFirstSync = summaries.isEmpty
            try store.setMeta("data_source", value: summaries.isEmpty ? "awaiting" : "real")
        } catch {
            alertText = "Could not clear sample data: \(error.localizedDescription)"
        }
    }

    /// Persist a BLE/connection lifecycle line to sync_log so the connection layer is
    /// debuggable off-device (NSLog isn't visible on a real phone). HR/battery spam excluded.
    private func logEvent(_ message: String) {
        try? store.insertSyncLog(message: "EVT \(message)")
    }

    private func apply(_ event: PolarClientEvent) {
        switch event {
        case .status(let text):
            // Diagnostic/scan/device-info messages go to a separate line so they
            // never clobber the connection status shown across the app.
            statusLine = text
            logEvent("status: \(text)")
        case .discovered(let device):
            if !devices.contains(device) {
                devices.append(device)
            }
            logEvent("discovered \(device.name) [\(device.id)]")
        case .connecting(let device):
            selectedDevice = device
            connectionState = "Connecting to \(device.name)"
            logEvent("connecting \(device.name)")
        case .connected(let device):
            selectedDevice = device
            connectionState = "Connected to \(device.name)"
            isScanning = false
            userInitiatedDisconnect = false
            try? store.setMeta("last_device_id", value: device.id)
            try? store.setMeta("last_device_name", value: device.name)
            logEvent("connected \(device.name)")
            // A real device is now the source of truth — drop any lingering sample rows
            // (preserving real synced days). The actual sync waits for .readyToSync.
            purgeSampleData()
            // Surface whether the device has a user profile, so the UI can prompt setup.
            refreshDeviceSetupState()
        case .readyToSync:
            logEvent("readyToSync")
            // Fired once the device's data service is ready. Auto-pull so data refreshes
            // on its own when the Loop reconnects (e.g. after a walk).
            if !isSyncing {
                syncNow(auto: true)
            }
        case .disconnected(let reason):
            liveHeartRate = nil
            ftuDone = nil
            statusLine = "Disconnected: \(reason)"
            logEvent("disconnected: \(reason)")
            // automaticReconnection keeps retrying unless the user disconnected on purpose.
            connectionState = userInitiatedDisconnect
                ? "Not connected"
                : "Reconnecting to \(selectedDevice?.name ?? "Polar Loop")"
        case .battery(let level):
            handleBatteryLevel(level)
        case .heartRate(let sample):
            liveHeartRate = sample.bpm
            do {
                try store.save([sample])
            } catch {
                alertText = "HR sample save failed: \(error.localizedDescription)"
            }
        }
    }
}

final class MockPolarClient: PolarClient {
    private let stream: AsyncStream<PolarClientEvent>
    private let continuation: AsyncStream<PolarClientEvent>.Continuation
    private var scanTask: Task<Void, Never>?
    private var hrTask: Task<Void, Never>?
    private var connectedDevice: WearableDevice?
    private var mockFtuDone = false

    var events: AsyncStream<PolarClientEvent> { stream }

    init() {
        var localContinuation: AsyncStream<PolarClientEvent>.Continuation!
        stream = AsyncStream { continuation in
            localContinuation = continuation
        }
        continuation = localContinuation
    }

    func startScan() async throws {
        scanTask?.cancel()
        continuation.yield(.status("Scanning for Polar Loop"))
        scanTask = Task { [continuation] in
            let devices = [
                WearableDevice(id: "MOCK-LOOP-001", name: "Polar Loop Mock", rssi: -42, isConnectable: true),
                WearableDevice(id: "MOCK-H10-002", name: "Polar H10 Nearby", rssi: -65, isConnectable: true)
            ]
            for device in devices {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                continuation.yield(.discovered(device))
            }
            continuation.yield(.status("Mock scan complete"))
        }
    }

    func stopScan() async {
        scanTask?.cancel()
        continuation.yield(.status("Scan stopped"))
    }

    func connect(_ device: WearableDevice) async throws {
        continuation.yield(.connecting(device))
        try await Task.sleep(nanoseconds: 500_000_000)
        connectedDevice = device
        continuation.yield(.connected(device))
        continuation.yield(.battery(82))
        continuation.yield(.readyToSync)
    }

    func reconnect(toDeviceId id: String) async {
        // Mock: simulate a seamless reconnect to the remembered device.
        let device = WearableDevice(id: id, name: "Polar Loop Mock", rssi: -45, isConnectable: true)
        continuation.yield(.connecting(device))
        try? await Task.sleep(nanoseconds: 400_000_000)
        connectedDevice = device
        continuation.yield(.connected(device))
        continuation.yield(.battery(82))
        continuation.yield(.readyToSync)
    }

    func disconnect() async {
        connectedDevice = nil
        hrTask?.cancel()
        continuation.yield(.disconnected("Manual disconnect"))
    }

    func startLiveHeartRate() async throws {
        guard connectedDevice != nil else {
            throw AppError.message("Connect a device before starting live HR")
        }
        hrTask?.cancel()
        hrTask = Task { [continuation] in
            var bpm = 63
            while !Task.isCancelled {
                bpm += Int.random(in: -2...3)
                bpm = min(max(bpm, 54), 96)
                continuation.yield(.heartRate(HeartRateSample(timestamp: .now, bpm: bpm, rrMs: [920, 945, 908])))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopLiveHeartRate() async {
        hrTask?.cancel()
    }

    func syncLatest() async throws -> SyncPayload {
        try await Task.sleep(nanoseconds: 750_000_000)
        return MockDataFactory.payload()
    }

    func isFirstTimeUseDone() async throws -> Bool { mockFtuDone }

    func runFirstTimeUse(profile: UserProfile) async throws {
        continuation.yield(.status("Mock: writing user profile…"))
        try await Task.sleep(nanoseconds: 600_000_000)
        mockFtuDone = true
        continuation.yield(.status("Mock: device profile written"))
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

struct RecoveryContributor: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let inRange: Bool
}

/// The taggable life-context labels shared by the log sheet and the history timeline.
/// (Replaces the per-view list that used to live inside the old Journal tab.)
enum JournalTags {
    static let all = ["caffeine", "alcohol", "late meal", "travel", "illness", "stress", "soreness", "screen time", "hard training"]

    static func color(_ tag: String) -> Color {
        let palette: [Color] = [Theme.hrv, Theme.recoveryRed, Theme.temp, Theme.strain, Theme.recoveryYellow, Theme.strainHi, Theme.activity, Theme.sleep, Theme.recoveryGreen]
        return palette[abs(tag.hashValue) % palette.count]
    }
}

/// A drill-down metric. Each Today card maps to one of these; tapping pushes a `MetricDetailView`
/// that renders this metric's history, range bars, and explanation — the Ultrahuman pattern of a
/// scrollable card feed where every card opens a full detail screen.
enum MetricKind: String, CaseIterable, Identifiable {
    case recharge, sleep, exertion, hrv, restingHr, skinTemp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recharge: return Copy.recharge
        case .sleep: return "Sleep Score"
        case .exertion: return Copy.exertion
        case .hrv: return "HRV"
        case .restingHr: return "Resting HR"
        case .skinTemp: return "Skin Temperature"
        }
    }

    var icon: String {
        switch self {
        case .recharge: return "bolt.heart.fill"
        case .sleep: return "moon.zzz.fill"
        case .exertion: return "flame.fill"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.fill"
        case .skinTemp: return "thermometer.medium"
        }
    }

    /// Fixed accent. Recharge is zone-colored at the call site (depends on the value).
    var accent: Color {
        switch self {
        case .recharge: return Theme.recoveryGreen
        case .sleep: return Theme.sleep
        case .exertion: return Theme.strain
        case .hrv: return Theme.hrv
        case .restingHr: return Theme.rhr
        case .skinTemp: return Theme.temp
        }
    }

    var unit: String {
        switch self {
        case .recharge, .sleep: return "%"
        case .exertion: return "/ 21"
        case .hrv: return "ms"
        case .restingHr: return "bpm"
        case .skinTemp: return TempUnit.label
        }
    }

    /// Decimals for value/axis display.
    var decimals: Int { self == .skinTemp ? 1 : 0 }

    /// Direction that counts as an improvement, for delta coloring. `nil` = neutral (temp).
    var higherIsBetter: Bool? {
        switch self {
        case .recharge, .sleep, .hrv: return true
        case .exertion, .restingHr: return false   // lower resting HR is better; exertion is neutral-ish but lower reads "easier"
        case .skinTemp: return nil
        }
    }

    /// The plotted value for a day, or nil when the day lacks that signal.
    func value(_ s: DailySummary) -> Double? {
        switch self {
        case .recharge: return Double(s.recoveryScore)
        case .sleep: return Double(s.sleepScore)
        case .exertion: return Double(s.strainScore) / 100 * 21
        case .hrv: return s.hrvMs > 0 ? s.hrvMs : nil
        case .restingHr: return s.restingHeartRate > 0 ? s.restingHeartRate : nil
        case .skinTemp:
            // Absolute overnight temperature (the device exposes this before any deviation baseline).
            return s.skinTempC.map { TempUnit.convert($0, isDelta: false) }
        }
    }

    /// Plain-language, wellness-only explanation shown on the detail screen.
    var about: String {
        switch self {
        case .recharge:
            return "Recharge estimates how recovered your body is, blending overnight HRV, resting heart rate, skin temperature, and sleep against your own recent baseline. Higher means your body is more ready for load."
        case .sleep:
            return "Sleep Score rates last night against an ~8h target using total time asleep, consistency, and how broken the night was. It rewards long, unbroken, regular sleep."
        case .exertion:
            return "Exertion is a 0–21 daily load estimate built from active minutes and how hard your heart worked, weighting vigorous effort more. Use it to balance hard and easy days."
        case .hrv:
            return "Heart-rate variability is the beat-to-beat variation measured overnight. Trending up usually reflects good recovery; a sharp drop can signal stress, illness, or under-recovery."
        case .restingHr:
            return "Resting heart rate is your lowest overnight pulse. Lower trends generally track improving fitness and recovery; a rise can flag fatigue or illness."
        case .skinTemp:
            return "Overnight skin temperature, tracked against your baseline. Sustained deviations can accompany illness, alcohol, or cycle changes. Informational only."
        }
    }

    var navTitle: String { title }
}

final class MetricsEngine {
    static func recoveryScore(today: DailySummary, history: [DailySummary]) -> Int {
        // History is accumulated oldest-first, so the trailing 21 days (suffix) are the most
        // recent baseline — prefix would anchor to the oldest days and never move forward.
        let baseline = history.filter { $0.dayKey != today.dayKey }.suffix(21)
        guard baseline.count >= 5 else {
            return clamp(Int(55 + Double(today.sleepScore - 70) * 0.25 + Double(70 - today.strainScore) * 0.15))
        }
        let avgHRV = baseline.map(\.hrvMs).average
        let avgRHR = baseline.map(\.restingHeartRate).average
        let hrvSignal = ((today.hrvMs - avgHRV) / max(avgHRV, 1)) * 35
        let rhrSignal = ((avgRHR - today.restingHeartRate) / max(avgRHR, 1)) * 45
        // Skin-temp only contributes once a deviation actually exists (Polar's own, or one we
        // derive from accumulated absolute temps) — a missing value never penalizes recovery.
        let tempSignal = effectiveTempDeviation(today: today, baseline: Array(baseline)).map { -abs($0) * 12 } ?? 0
        let sleepSignal = Double(today.sleepScore - 70) * 0.25
        let strainSignal = Double(55 - today.strainScore) * 0.12
        return clamp(Int(68 + hrvSignal + rhrSignal + tempSignal + sleepSignal + strainSignal))
    }

    /// Per-signal contributors behind the recovery score, each flagged in/out of its usual range,
    /// for the "X/N in range" breakdown chips. Ranges are vs. the trailing baseline when there's
    /// enough history, else simple physiological defaults.
    static func recoveryContributors(today: DailySummary, history: [DailySummary]) -> [RecoveryContributor] {
        let baseline = history.filter { $0.dayKey != today.dayKey }.suffix(21)
        let hasBaseline = baseline.count >= 5
        let avgHRV = baseline.map(\.hrvMs).average
        let avgRHR = baseline.map(\.restingHeartRate).average

        let hrvIn = hasBaseline ? today.hrvMs >= avgHRV * 0.9 : today.hrvMs >= 45
        let rhrIn = hasBaseline ? today.restingHeartRate <= avgRHR * 1.06 : today.restingHeartRate <= 65
        let sleepIn = today.sleepScore >= 70

        var result = [
            RecoveryContributor(label: "HRV", value: "\(Int(today.hrvMs)) ms", inRange: hrvIn),
            RecoveryContributor(label: "RHR", value: "\(Int(today.restingHeartRate)) bpm", inRange: rhrIn)
        ]
        // Include Temp only when a deviation exists (Polar's own, or one derived from our absolute
        // temps). A bare absolute reading with no baseline yet isn't shown as in/out of range.
        if let dev = effectiveTempDeviation(today: today, baseline: Array(baseline)) {
            let tempIn = abs(dev) <= 0.4   // range check stays in °C
            let shown = TempUnit.convert(dev, isDelta: true)
            let tempStr = shown.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
            result.append(RecoveryContributor(label: "Temp", value: "\(tempStr)\(TempUnit.label)", inRange: tempIn))
        }
        result.append(RecoveryContributor(label: "Sleep", value: "\(today.sleepScore)%", inRange: sleepIn))
        return result
    }

    /// Skin-temperature deviation in °C: the device's own once it has a baseline, otherwise one we
    /// derive from accumulated absolute overnight temps vs the trailing baseline — so temperature
    /// tracking works weeks before Polar finishes building its own baseline. `nil` until usable.
    static func effectiveTempDeviation(today: DailySummary, baseline: [DailySummary]) -> Double? {
        if let dev = today.skinTempDeltaC { return dev }
        let absTemps = baseline.compactMap(\.skinTempC)
        guard let todayAbs = today.skinTempC, absTemps.count >= 5 else { return nil }
        return todayAbs - absTemps.average
    }

    static func sleepScore(durationMinutes: Int, consistencyDeltaMinutes: Int, interruptions: Int) -> Int {
        let duration = min(Double(durationMinutes) / 480.0, 1.15) * 72
        let consistency = max(0, 18 - Double(abs(consistencyDeltaMinutes)) * 0.25)
        let continuity = max(0, 10 - Double(interruptions) * 1.8)
        return clamp(Int(duration + consistency + continuity))
    }

    static func strainScore(samples: [HeartRateSample], restingHeartRate: Double) -> Int {
        guard !samples.isEmpty else { return 0 }
        let load = samples.reduce(0.0) { partial, sample in
            let effort = max(0, Double(sample.bpm) - restingHeartRate)
            return partial + pow(effort / 40.0, 1.7)
        }
        return clamp(Int(load / Double(samples.count) * 70))
    }

    static func journalImpact(tag: String, summaries: [DailySummary], entries: [JournalEntry]) -> Double? {
        let taggedDays = Set(entries.filter { $0.tag == tag }.map { $0.date.dayKey })
        let tagged = summaries.filter { taggedDays.contains($0.dayKey) }
        let untagged = summaries.filter { !taggedDays.contains($0.dayKey) }
        guard tagged.count >= 2, untagged.count >= 2 else { return nil }
        return tagged.map(\.recoveryScore).average - untagged.map(\.recoveryScore).average
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}

final class CoachEngine {
    static func dailySummary(today: DailySummary?, history: [DailySummary]) -> String {
        guard let today else {
            return "Connect or sync your Loop to generate today's local summary."
        }
        var reasons: [String] = []
        if today.recoveryScore >= 75 {
            reasons.append("recharge is strong at \(today.recoveryScore)")
        } else if today.recoveryScore < 45 {
            reasons.append("recharge is suppressed at \(today.recoveryScore)")
        } else {
            reasons.append("recharge is moderate at \(today.recoveryScore)")
        }
        reasons.append("sleep was \(today.sleepMinutes / 60)h \(today.sleepMinutes % 60)m")
        reasons.append("HRV is \(Int(today.hrvMs)) ms")
        reasons.append("RHR is \(Int(today.restingHeartRate)) bpm")
        if let temp = today.skinTempDeltaC, abs(temp) >= 0.5 {
            reasons.append("skin temperature is \(temp.formatted(.number.precision(.fractionLength(1)))) C from baseline")
        }
        let action: String
        if today.recoveryScore >= 75 && today.strainScore < 70 {
            action = "A harder session is reasonable if you feel good."
        } else if today.recoveryScore < 45 {
            action = "Bias toward easy movement, hydration, and an earlier night."
        } else {
            action = "Keep training controlled and watch late-day strain."
        }
        return "\(reasons.joined(separator: ", ")). \(action) Wellness guidance only."
    }
}

final class ExportService {
    private let store: LocalStore

    init(store: LocalStore) {
        self.store = store
    }

    func writeJSONExport() throws -> URL {
        let payload = try SyncPayload(
            dailySummaries: store.fetchDailySummaries(limit: 365),
            heartRateSamples: store.fetchHeartRateSamples(limit: 5_000),
            journalEntries: store.fetchJournalEntries(limit: 1_000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func writeDailyCSVExport() throws -> URL {
        let rows = try store.fetchDailySummaries(limit: 365)
        var csv = "day,recovery,sleep,strain,sleep_minutes,active_minutes,rhr,hrv_ms,temp_delta_c,calories,steps\n"
        for row in rows.reversed() {
            let temp = row.skinTempDeltaC.map { "\($0)" } ?? ""
            csv += "\(row.dayKey),\(row.recoveryScore),\(row.sleepScore),\(row.strainScore),\(row.sleepMinutes),\(row.activeMinutes),\(row.restingHeartRate),\(row.hrvMs),\(temp),\(row.calories),\(row.steps)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-daily.csv")
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}

final class LocalStore {
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The `skin_temp_delta_c` column is NOT NULL, so a missing deviation is stored as this
    /// sentinel and mapped back to `nil` on read. Matches Polar's own -1000 "not calculated" marker.
    private static let tempUnavailableSentinel = -1000.0

    init(url: URL? = nil) throws {
        let resolvedURL: URL
        if let url {
            resolvedURL = url
        } else {
            resolvedURL = try Self.defaultURL()
        }
        if sqlite3_open(resolvedURL.path, &db) != SQLITE_OK {
            throw AppError.message("Could not open SQLite database")
        }
        try execute(Self.schema)
        try migrate()
    }

    /// Lightweight, idempotent migrations for databases created before a column existed.
    /// Existing rows predate the sample/real distinction, so they are treated as sample
    /// and get purged the next time a real device connects.
    private func migrate() throws {
        // ALTER fails if the column already exists; that's expected and harmless.
        try? execute("ALTER TABLE daily_summaries ADD COLUMN source TEXT NOT NULL DEFAULT 'sample';")
        try? execute("ALTER TABLE heart_rate_samples ADD COLUMN source TEXT NOT NULL DEFAULT 'sample';")
        try? execute("ALTER TABLE daily_summaries ADD COLUMN sleep_stages_json TEXT NOT NULL DEFAULT '[]';")
        try? execute("ALTER TABLE daily_summaries ADD COLUMN skin_temp_c REAL NOT NULL DEFAULT -1000;")
    }

    deinit {
        sqlite3_close(db)
    }

    static func temporary() throws -> LocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopback-\(UUID().uuidString).sqlite")
        return try LocalStore(url: url)
    }

    func seedIfNeeded() throws {
        guard try fetchDailySummaries(limit: 1).isEmpty else { return }
        let payload = MockDataFactory.payload()
        try save(payload.dailySummaries, source: "sample")
        try save(payload.heartRateSamples, source: "sample")
        try save([
            JournalEntry(date: Date.now.addingTimeInterval(-86_400 * 2), tag: "late meal", note: "Mock context"),
            JournalEntry(date: Date.now.addingTimeInterval(-86_400 * 5), tag: "travel", note: "Mock context")
        ])
        // Tag this database as containing sample data until a real device sync replaces it.
        try setMeta("data_source", value: "sample")
    }

    func setMeta(_ key: String, value: String) throws {
        let sql = "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);"
        try withStatement(sql) { statement in
            bind(key, to: statement, index: 1)
            bind(value, to: statement, index: 2)
            try step(statement)
        }
    }

    func getMeta(_ key: String) throws -> String? {
        let sql = "SELECT value FROM meta WHERE key = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(key, to: statement, index: 1)
            if sqlite3_step(statement) == SQLITE_ROW {
                return columnString(statement, 0)
            }
            return nil
        }
    }

    /// Remove seeded sample/demo content so the dashboard never mixes example data with
    /// real data. Real synced days and real journal entries the user typed are preserved.
    func clearSampleData() throws {
        try execute("DELETE FROM daily_summaries WHERE source = 'sample';")
        try execute("DELETE FROM heart_rate_samples WHERE source = 'sample';")
        try execute("DELETE FROM journal_entries WHERE note = 'Mock context';")
    }

    func save(_ summaries: [DailySummary], source: String = "real") throws {
        let sql = """
        INSERT OR REPLACE INTO daily_summaries
        (day_key, date_ts, recovery_score, sleep_score, strain_score, sleep_minutes, active_minutes, resting_hr, hrv_ms, skin_temp_delta_c, calories, steps, source, sleep_stages_json, skin_temp_c)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let encoder = JSONEncoder()
        try transaction {
            for summary in summaries {
                let stagesData = try encoder.encode(summary.sleepStages)
                let stagesJSON = String(data: stagesData, encoding: .utf8) ?? "[]"
                try withStatement(sql) { statement in
                    bind(summary.dayKey, to: statement, index: 1)
                    sqlite3_bind_double(statement, 2, summary.date.timeIntervalSince1970)
                    sqlite3_bind_int(statement, 3, Int32(summary.recoveryScore))
                    sqlite3_bind_int(statement, 4, Int32(summary.sleepScore))
                    sqlite3_bind_int(statement, 5, Int32(summary.strainScore))
                    sqlite3_bind_int(statement, 6, Int32(summary.sleepMinutes))
                    sqlite3_bind_int(statement, 7, Int32(summary.activeMinutes))
                    sqlite3_bind_double(statement, 8, summary.restingHeartRate)
                    sqlite3_bind_double(statement, 9, summary.hrvMs)
                    sqlite3_bind_double(statement, 10, summary.skinTempDeltaC ?? Self.tempUnavailableSentinel)
                    sqlite3_bind_int(statement, 11, Int32(summary.calories))
                    sqlite3_bind_int(statement, 12, Int32(summary.steps))
                    bind(source, to: statement, index: 13)
                    bind(stagesJSON, to: statement, index: 14)
                    sqlite3_bind_double(statement, 15, summary.skinTempC ?? Self.tempUnavailableSentinel)
                    try step(statement)
                }
            }
        }
    }

    func save(_ samples: [HeartRateSample], source: String = "real") throws {
        let sql = "INSERT OR REPLACE INTO heart_rate_samples (id, timestamp_ts, bpm, rr_json, source) VALUES (?, ?, ?, ?, ?);"
        let encoder = JSONEncoder()
        try transaction {
            for sample in samples {
                let rrData = try encoder.encode(sample.rrMs)
                let rrJSON = String(data: rrData, encoding: .utf8) ?? "[]"
                try withStatement(sql) { statement in
                    bind(sample.id.uuidString, to: statement, index: 1)
                    sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
                    sqlite3_bind_int(statement, 3, Int32(sample.bpm))
                    bind(rrJSON, to: statement, index: 4)
                    bind(source, to: statement, index: 5)
                    try step(statement)
                }
            }
        }
    }

    func save(_ entries: [JournalEntry]) throws {
        let sql = "INSERT OR REPLACE INTO journal_entries (id, date_ts, tag, note) VALUES (?, ?, ?, ?);"
        try transaction {
            for entry in entries {
                try withStatement(sql) { statement in
                    bind(entry.id.uuidString, to: statement, index: 1)
                    sqlite3_bind_double(statement, 2, entry.date.timeIntervalSince1970)
                    bind(entry.tag, to: statement, index: 3)
                    bind(entry.note, to: statement, index: 4)
                    try step(statement)
                }
            }
        }
    }

    func insertSyncLog(message: String) throws {
        let sql = "INSERT INTO sync_log (timestamp_ts, message) VALUES (?, ?);"
        try withStatement(sql) { statement in
            sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970)
            bind(message, to: statement, index: 2)
            try step(statement)
        }
    }

    func fetchDailySummaries(limit: Int) throws -> [DailySummary] {
        let sql = """
        SELECT day_key, date_ts, recovery_score, sleep_score, strain_score, sleep_minutes, active_minutes, resting_hr, hrv_ms, skin_temp_delta_c, calories, steps, sleep_stages_json, skin_temp_c
        FROM daily_summaries ORDER BY day_key DESC LIMIT ?;
        """
        let decoder = JSONDecoder()
        return try query(sql, limit: limit) { statement in
            let stagesJSON = columnString(statement, 12)
            let stages = (try? decoder.decode([SleepSpan].self, from: Data(stagesJSON.utf8))) ?? []
            let rawAbsTemp = sqlite3_column_double(statement, 13)
            return DailySummary(
                dayKey: columnString(statement, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                recoveryScore: Int(sqlite3_column_int(statement, 2)),
                sleepScore: Int(sqlite3_column_int(statement, 3)),
                strainScore: Int(sqlite3_column_int(statement, 4)),
                sleepMinutes: Int(sqlite3_column_int(statement, 5)),
                activeMinutes: Int(sqlite3_column_int(statement, 6)),
                restingHeartRate: sqlite3_column_double(statement, 7),
                hrvMs: sqlite3_column_double(statement, 8),
                skinTempDeltaC: { let t = sqlite3_column_double(statement, 9); return t <= -100 ? nil : t }(),
                skinTempC: rawAbsTemp <= -100 ? nil : rawAbsTemp,
                calories: Int(sqlite3_column_int(statement, 10)),
                steps: Int(sqlite3_column_int(statement, 11)),
                sleepStages: stages
            )
        }
    }

    func fetchHeartRateSamples(limit: Int) throws -> [HeartRateSample] {
        let sql = "SELECT id, timestamp_ts, bpm, rr_json FROM heart_rate_samples ORDER BY timestamp_ts DESC LIMIT ?;"
        let decoder = JSONDecoder()
        return try query(sql, limit: limit) { statement in
            let rrJSON = columnString(statement, 3)
            let rrData = Data(rrJSON.utf8)
            let rr = (try? decoder.decode([Int].self, from: rrData)) ?? []
            return HeartRateSample(
                id: UUID(uuidString: columnString(statement, 0)) ?? UUID(),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                bpm: Int(sqlite3_column_int(statement, 2)),
                rrMs: rr
            )
        }
    }

    /// Heart-rate samples that fall on a given local calendar day, oldest-first, for drawing a
    /// daily HR curve. Bounded so a long history can't return an unbounded set.
    func fetchHeartRateSamples(onDay dayKey: String, limit: Int = 600) throws -> [HeartRateSample] {
        let sql = """
        SELECT id, timestamp_ts, bpm, rr_json FROM heart_rate_samples
        WHERE id IN (SELECT id FROM heart_rate_samples ORDER BY timestamp_ts DESC LIMIT 20000)
        ORDER BY timestamp_ts ASC;
        """
        let decoder = JSONDecoder()
        let all = try withStatement(sql) { statement -> [HeartRateSample] in
            var rows: [HeartRateSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let rrJSON = columnString(statement, 3)
                let rr = (try? decoder.decode([Int].self, from: Data(rrJSON.utf8))) ?? []
                rows.append(HeartRateSample(
                    id: UUID(uuidString: columnString(statement, 0)) ?? UUID(),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    bpm: Int(sqlite3_column_int(statement, 2)),
                    rrMs: rr
                ))
            }
            return rows
        }
        return all.filter { $0.timestamp.dayKey == dayKey }.suffix(limit).map { $0 }
    }

    /// Drop heart-rate samples older than `days` so live streaming can't grow the table forever.
    func pruneHeartRate(olderThanDays days: Int) throws {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try withStatement("DELETE FROM heart_rate_samples WHERE timestamp_ts < ?;") { statement in
            sqlite3_bind_double(statement, 1, cutoff)
            try step(statement)
        }
    }

    func fetchJournalEntries(limit: Int) throws -> [JournalEntry] {
        let sql = "SELECT id, date_ts, tag, note FROM journal_entries ORDER BY date_ts DESC LIMIT ?;"
        return try query(sql, limit: limit) { statement in
            JournalEntry(
                id: UUID(uuidString: columnString(statement, 0)) ?? UUID(),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                tag: columnString(statement, 2),
                note: columnString(statement, 3)
            )
        }
    }

    private static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Loopback", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("loopback.sqlite")
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw AppError.message(message)
        }
    }

    /// Wrap a batch of writes in one transaction so a bulk insert costs a single fsync instead
    /// of one per row — in WAL mode every standalone statement otherwise commits (and syncs).
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer?) throws -> T) throws -> T {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw AppError.message(lastError)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw AppError.message(lastError)
        }
    }

    private func query<T>(_ sql: String, limit: Int, map: (OpaquePointer?) throws -> T) throws -> [T] {
        try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try map(statement))
            }
            return rows
        }
    }

    private func bind(_ string: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private var lastError: String {
        if let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS daily_summaries (
        day_key TEXT PRIMARY KEY,
        date_ts REAL NOT NULL,
        recovery_score INTEGER NOT NULL,
        sleep_score INTEGER NOT NULL,
        strain_score INTEGER NOT NULL,
        sleep_minutes INTEGER NOT NULL,
        active_minutes INTEGER NOT NULL,
        resting_hr REAL NOT NULL,
        hrv_ms REAL NOT NULL,
        skin_temp_delta_c REAL NOT NULL,
        calories INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'sample',
        sleep_stages_json TEXT NOT NULL DEFAULT '[]',
        skin_temp_c REAL NOT NULL DEFAULT -1000
    );
    CREATE TABLE IF NOT EXISTS heart_rate_samples (
        id TEXT PRIMARY KEY,
        timestamp_ts REAL NOT NULL,
        bpm INTEGER NOT NULL,
        rr_json TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'sample'
    );
    CREATE INDEX IF NOT EXISTS idx_heart_rate_timestamp ON heart_rate_samples(timestamp_ts);
    CREATE TABLE IF NOT EXISTS journal_entries (
        id TEXT PRIMARY KEY,
        date_ts REAL NOT NULL,
        tag TEXT NOT NULL,
        note TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_journal_date ON journal_entries(date_ts);
    CREATE TABLE IF NOT EXISTS sync_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp_ts REAL NOT NULL,
        message TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
}

enum MockDataFactory {
    static func payload(days: Int = 35) -> SyncPayload {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var summaries: [DailySummary] = []
        var hrSamples: [HeartRateSample] = []
        for offset in 0..<days {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let wave = sin(Double(offset) / 3.0)
            let sleepMinutes = 410 + Int(wave * 38) + Int.random(in: -12...12)
            let sleepScore = MetricsEngine.sleepScore(durationMinutes: sleepMinutes, consistencyDeltaMinutes: Int(wave * 35), interruptions: max(0, Int.random(in: 0...4)))
            let strain = 38 + Int((1 - wave) * 18) + Int.random(in: -7...9)
            let rhr = 56.0 - wave * 2.5 + Double.random(in: -1.5...1.5)
            let hrv = 62.0 + wave * 9.0 + Double.random(in: -4.0...4.0)
            let temp = wave * 0.25 + Double.random(in: -0.15...0.15)
            var summary = DailySummary(
                dayKey: date.dayKey,
                date: date,
                recoveryScore: 0,
                sleepScore: sleepScore,
                strainScore: min(max(strain, 0), 100),
                sleepMinutes: sleepMinutes,
                activeMinutes: 42 + Int((1 - wave) * 18),
                restingHeartRate: rhr,
                hrvMs: hrv,
                skinTempDeltaC: temp,
                skinTempC: 34.6 + wave * 0.4,
                calories: 2_100 + Int((1 - wave) * 210),
                steps: 7_500 + Int((1 - wave) * 2_300)
            )
            summary.recoveryScore = MetricsEngine.recoveryScore(today: summary, history: summaries)
            summary.sleepStages = SleepSpan.synthesize(totalMinutes: sleepMinutes, wakeCount: max(0, Int(2 - wave) + Int.random(in: 0...1)))
            summaries.append(summary)
            for minute in stride(from: 0, to: 90, by: 5) {
                let timestamp = date.addingTimeInterval(Double(7 * 3_600 + minute * 60))
                let bpm = Int(rhr + 8 + Double.random(in: -3...18))
                hrSamples.append(HeartRateSample(timestamp: timestamp, bpm: bpm, rrMs: [880, 910, 935]))
            }
        }
        return SyncPayload(dailySummaries: summaries, heartRateSamples: hrSamples)
    }
}

#if canImport(PolarBleSdk) && !targetEnvironment(simulator)

/// Accumulates the various Polar data streams for a single calendar day before
/// they are combined into one `DailySummary`.
private struct PartialDay {
    let dayKey: String
    var date: Date?
    var steps: Int = 0
    var calories: Int = 0
    var activeMinutes: Int = 0
    var vigorousMinutes: Int = 0
    var sleepMinutes: Int = 0
    var interruptions: Int = 0
    var hrvMs: Double = 0
    var restingHr: Double = 0
    var minDayHr: Double = 0
    var skinTempDeltaC: Double? = nil
    var skinTempC: Double? = nil
    var sleepStages: [SleepSpan] = []

    var hasRealSignal: Bool {
        steps > 0 || calories > 0 || activeMinutes > 0 || sleepMinutes > 0 || hrvMs > 0
    }
}

final class RealPolarBleClient: NSObject, PolarClient, PolarBleApiObserver, PolarBleApiDeviceInfoObserver, PolarBleApiPowerStateObserver, PolarBleApiDeviceFeaturesObserver, PolarBleApiLogger {
    private var api: PolarBleApi
    private let stream: AsyncStream<PolarClientEvent>
    private let continuation: AsyncStream<PolarClientEvent>.Continuation
    private var scanTask: Task<Void, Never>?
    private var hrTask: Task<Void, Never>?
    private var connectedDeviceId: String?
    /// The device we want to stay connected to. Set on connect(), cleared only on an explicit
    /// user disconnect. Used to (re)connect the moment Bluetooth is ready — the SDK's
    /// automaticReconnection only covers drops *after* a first successful connect, not a cold
    /// launch where connect() is attempted before CoreBluetooth has powered on.
    private var desiredDeviceId: String?
    private var blePoweredOn = false
    /// Seamless-reconnect state. All accessed on the SDK's main-queue callbacks and the reconnect
    /// Task (also main-hopping), matching the file's existing lock-free convention.
    private var userInitiatedDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var connectWatchdog: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// Per-fetch counts/errors for the in-progress sync, surfaced in SyncPayload.diagnostics.
    private var syncDiagnostics: [String] = []

    var events: AsyncStream<PolarClientEvent> { stream }

    override init() {
        var localContinuation: AsyncStream<PolarClientEvent>.Continuation!
        stream = AsyncStream { continuation in
            localContinuation = continuation
        }
        continuation = localContinuation
        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_hr,
                .feature_device_info,
                .feature_battery_info,
                .feature_polar_online_streaming,
                .feature_polar_offline_recording,
                .feature_polar_h10_exercise_recording,
                .feature_polar_sdk_mode,
                .feature_polar_activity_data,
                .feature_polar_sleep_data,
                .feature_polar_temperature_data,
                .feature_polar_device_control
            ],
            restoreIdentifier: "com.example.loopback.ble"
        )
        super.init()
        api.observer = self
        api.deviceInfoObserver = self
        api.powerStateObserver = self
        api.logger = self
        api.automaticReconnection = true
        api.deviceFeaturesObserver = self
    }

    // PolarBleApiLogger — surface Polar SDK internal logs to the device console (idevicesyslog).
    func message(_ str: String) {
        NSLog("[PolarSDK] %@", str)
    }

    // PolarBleApiDeviceFeaturesObserver — fired when each requested feature's service is ready.
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        NSLog("[PLL] feature ready: %@", "\(feature)")
        if feature == .feature_polar_activity_data {
            continuation.yield(.readyToSync)
        }
    }

    func startScan() async throws {
        scanTask?.cancel()
        continuation.yield(.status("Scanning for Polar devices"))
        NSLog("[PLL] startScan")
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await info in self.api.searchForDevice(withNameContaining: "Polar") {
                    if Task.isCancelled { break }
                    NSLog("[PLL] discovered id=%@ name=%@ rssi=%d connectable=%d", info.deviceId, info.name, info.rssi, info.connectable ? 1 : 0)
                    self.continuation.yield(.discovered(
                        WearableDevice(
                            id: info.deviceId,
                            name: info.name.isEmpty ? "Polar \(info.deviceId)" : info.name,
                            rssi: info.rssi,
                            isConnectable: info.connectable
                        )
                    ))
                }
            } catch {
                NSLog("[PLL] scan FAILED: %@", "\(error)")
                self.continuation.yield(.status("Scan failed: \(error.localizedDescription)"))
            }
        }
    }

    func stopScan() async {
        scanTask?.cancel()
        continuation.yield(.status("Scan stopped"))
    }

    func connect(_ device: WearableDevice) async throws {
        // User picked a device from a fresh scan (a session exists, so the direct connect is
        // reliable). Arm the watchdog so a stalled connect self-heals into the reconnect loop.
        userInitiatedDisconnect = false
        desiredDeviceId = device.id
        reconnectAttempt = 0
        continuation.yield(.connecting(device))
        attemptConnect()
        armConnectWatchdog(for: device.id)
    }

    func reconnect(toDeviceId id: String) async {
        // Idempotent re-arm (foreground / launch / restoration land here repeatedly).
        userInitiatedDisconnect = false
        desiredDeviceId = id
        if connectedDeviceId == id || reconnectTask != nil { return }
        reconnectAttempt = 0
        startReconnectLoop(for: id)
    }

    /// Try a direct connect once Bluetooth is powered on. Does NOT set `connectedDeviceId` — that
    /// is set only by `deviceConnected`, so the watchdog/loop can tell a real connection apart.
    private func attemptConnect() {
        guard let id = desiredDeviceId, blePoweredOn else {
            NSLog("[PLL] connect deferred — BLE not powered on yet")
            return
        }
        do {
            NSLog("[PLL] connectToDevice %@", id)
            continuation.yield(.status("Connecting to \(id)…"))
            try api.connectToDevice(id)
        } catch {
            NSLog("[PLL] connectToDevice FAILED: %@", "\(error)")
            continuation.yield(.status("Connect error: \(error.localizedDescription)"))
        }
    }

    func disconnect() async {
        // Explicit user disconnect — stop wanting this device and cancel all reconnect work.
        userInitiatedDisconnect = true
        desiredDeviceId = nil
        cancelReconnect()
        if let connectedDeviceId {
            do {
                try api.disconnectFromDevice(connectedDeviceId)
            } catch {
                continuation.yield(.status("Disconnect failed: \(error.localizedDescription)"))
            }
        }
        self.connectedDeviceId = nil
        hrTask?.cancel()
    }

    // MARK: - Seamless reconnect engine

    /// Drives reconnection until the desired device connects or the user disconnects. Each pass:
    /// wait for BLE power-on, try a direct connect, and if `deviceConnected` doesn't fire within
    /// the watchdog window, fall back to a name-scan filtered to the desired id (the path proven
    /// to work on this firmware) and connect on match — then back off and retry.
    private func startReconnectLoop(for id: String) {
        cancelReconnect()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.userInitiatedDisconnect || self.desiredDeviceId != id { return }
                if self.connectedDeviceId == id { return }
                guard self.blePoweredOn else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                self.reconnectAttempt += 1
                let attempt = self.reconnectAttempt
                NSLog("[PLL] reconnect attempt %d for %@", attempt, id)
                self.continuation.yield(.status("Reconnecting to \(id) (attempt \(attempt))"))
                do { try self.api.connectToDevice(id) }
                catch { NSLog("[PLL] direct connectToDevice threw: %@", "\(error)") }
                if await self.waitForConnection(id: id, timeoutSeconds: 7) { return }
                if Task.isCancelled || self.userInitiatedDisconnect || self.desiredDeviceId != id { return }
                NSLog("[PLL] direct reconnect stalled; scanning for %@", id)
                self.continuation.yield(.status("Scanning to reconnect \(id)"))
                if await self.scanThenConnect(id: id, scanSeconds: 10) { return }
                if Task.isCancelled || self.userInitiatedDisconnect || self.desiredDeviceId != id { return }
                let backoff = min(UInt64(attempt) * 2_000_000_000, 30_000_000_000)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    /// Polls `connectedDeviceId` until it matches `id` or the timeout elapses.
    private func waitForConnection(id: String, timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled || userInitiatedDisconnect || desiredDeviceId != id { return false }
            if connectedDeviceId == id { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return connectedDeviceId == id
    }

    /// Runs the name-based scan (the working "Scan" path) filtered to `id`, requests a connect on
    /// a match, and waits for the link to establish.
    private func scanThenConnect(id: String, scanSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(scanSeconds)
        var requested = false
        do {
            for try await info in api.searchForDevice(withNameContaining: "Polar") {
                if Task.isCancelled || userInitiatedDisconnect || desiredDeviceId != id { break }
                if info.deviceId == id {
                    NSLog("[PLL] discovered desired %@ via scan; connecting", id)
                    try? api.connectToDevice(id)
                    requested = true
                    break
                }
                if Date() > deadline { break }
            }
        } catch {
            NSLog("[PLL] scanThenConnect search failed: %@", "\(error)")
        }
        guard requested else { return false }
        return await waitForConnection(id: id, timeoutSeconds: 7)
    }

    /// One-shot watchdog after a user-initiated connect(): if the connect doesn't land, escalate
    /// into the full reconnect loop (scan fallback + retries).
    private func armConnectWatchdog(for id: String) {
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            guard let self else { return }
            if await self.waitForConnection(id: id, timeoutSeconds: 8) { return }
            if Task.isCancelled || self.userInitiatedDisconnect || self.desiredDeviceId != id { return }
            if self.reconnectTask == nil {
                NSLog("[PLL] initial connect stalled; escalating to reconnect loop for %@", id)
                self.startReconnectLoop(for: id)
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        connectWatchdog?.cancel(); connectWatchdog = nil
        scanTask?.cancel()
    }

    func startLiveHeartRate() async throws {
        guard let connectedDeviceId else {
            throw AppError.message("Connect a Polar Loop before starting live HR")
        }
        hrTask?.cancel()
        hrTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await data in self.api.startHrStreaming(connectedDeviceId) {
                    if Task.isCancelled { break }
                    for sample in data {
                        self.continuation.yield(.heartRate(
                            HeartRateSample(timestamp: .now, bpm: Int(sample.hr), rrMs: sample.rrsMs.map { Int($0) })
                        ))
                    }
                }
            } catch {
                self.continuation.yield(.status("Live HR failed: \(error.localizedDescription)"))
            }
        }
    }

    func stopLiveHeartRate() async {
        hrTask?.cancel()
    }

    func syncLatest() async throws -> SyncPayload {
        guard let id = connectedDeviceId else {
            throw AppError.message("Connect your Polar Loop before syncing")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let fromDate = calendar.date(byAdding: .day, value: -SyncWindow.days, to: today) ?? today
        // Run the window to the end of today so the current (incomplete) day — e.g. a walk
        // taken this afternoon — is included rather than cut off at midnight.
        let toDate = (calendar.date(byAdding: .day, value: 1, to: today) ?? .now).addingTimeInterval(-1)
        syncDiagnostics = []
        continuation.yield(.status("Reading the last \(SyncWindow.days) days from the Loop…"))
        NSLog("[PLL] syncLatest start id=%@ from=%@ to=%@", id, "\(fromDate)", "\(toDate)")

        // Pull each data type defensively — the Loop may not have every type recorded,
        // and an unsupported/empty type should not abort the whole sync. Each result/error
        // is logged so a failed type is visible in the device console.
        let steps = await fetch("getSteps") { try await self.api.getSteps(identifier: id, fromDate: fromDate, toDate: toDate) }
        let calories = await fetch("getCalories") { try await self.api.getCalories(identifier: id, fromDate: fromDate, toDate: toDate, caloriesType: .activity) }
        let activeTimes = await fetch("getActiveTime") { try await self.api.getActiveTime(identifier: id, fromDate: fromDate, toDate: toDate) }
        let recharges = await fetch("getNightlyRecharge") { try await self.api.getNightlyRecharge(identifier: id, fromDate: fromDate, toDate: toDate) }
        let sleeps = await fetch("getSleep") { try await self.api.getSleep(identifier: id, fromDate: fromDate, toDate: toDate) }
        let hr247 = await fetch("get247HrSamples") { try await self.api.get247HrSamples(identifier: id, fromDate: fromDate, toDate: toDate) }
        // Raw absolute skin temperature — available even before the device has a deviation baseline.
        let skinTemps = await fetch("getSkinTemperature") { try await self.api.getSkinTemperature(identifier: id, fromDate: fromDate, toDate: toDate) }

        // Audit pull: every other date-ranged data type the Loop can return. We don't use these
        // yet, but logging their counts (via `fetch`) records exactly what the device exposes so a
        // future feature can light them up. Unsupported types fail safely and log as ERR.
        _ = await fetch("get247PPiSamples") { try await self.api.get247PPiSamples(identifier: id, fromDate: fromDate, toDate: toDate) }
        _ = await fetch("getDistance") { try await self.api.getDistance(identifier: id, fromDate: fromDate, toDate: toDate) }
        _ = await fetch("getDailySummaryData") { try await self.api.getDailySummaryData(identifier: id, fromDate: fromDate, toDate: toDate) }
        _ = await fetch("getActivitySampleData") { try await self.api.getActivitySampleData(identifier: id, fromDate: fromDate, toDate: toDate) }
        _ = await fetch("getSpo2TestData") { try await self.api.getSpo2TestData(identifier: id, fromDate: fromDate, toDate: toDate) }

        // Assemble partial per-day records keyed by yyyy-MM-dd.
        var byDay: [String: PartialDay] = [:]
        func upsert(_ key: String, _ mutate: (inout PartialDay) -> Void) {
            var record = byDay[key] ?? PartialDay(dayKey: key)
            mutate(&record)
            byDay[key] = record
        }

        for s in steps {
            upsert(s.date.dayKey) { $0.date = $0.date ?? s.date; $0.steps = s.steps }
        }
        for c in calories {
            upsert(c.date.dayKey) { $0.date = $0.date ?? c.date; $0.calories = c.calories }
        }
        for a in activeTimes {
            let moderate = Self.minutes(a.timeContinuousModerateActivity) + Self.minutes(a.timeIntermittentModerateActivity)
            let vigorous = Self.minutes(a.timeContinuousVigorousActivity) + Self.minutes(a.timeIntermittentVigorousActivity)
            upsert(a.date.dayKey) {
                $0.date = $0.date ?? a.date
                $0.activeMinutes = moderate + vigorous
                $0.vigorousMinutes = vigorous
            }
        }
        for r in recharges {
            upsert(r.createdTimestamp.dayKey) {
                $0.date = $0.date ?? r.createdTimestamp
                if let rmssd = r.meanNightlyRecoveryRMSSD { $0.hrvMs = Double(rmssd) }
                if let rri = r.meanNightlyRecoveryRRI, rri > 0 { $0.restingHr = 60_000.0 / Double(rri) }
            }
        }
        for sleep in sleeps {
            guard let end = sleep.sleepEndTime else { continue }
            let (asleepMinutes, wakeCount) = Self.sleepMinutes(sleep)
            upsert(end.dayKey) {
                $0.date = $0.date ?? calendar.startOfDay(for: end)
                $0.sleepMinutes = asleepMinutes
                $0.interruptions = wakeCount
                $0.sleepStages = Self.sleepSpans(sleep)
                // Polar reports -1000.0 until it has a sleep-temperature baseline; reject that
                // sentinel and any physiologically impossible value so it stays "unavailable".
                if let temp = sleep.sleepSkinTemperatureResult?.deviationFromBaseLine, temp > -100, abs(temp) < 20 {
                    $0.skinTempDeltaC = Double(temp)
                }
                // Absolute overnight skin temperature is available even before a deviation baseline.
                if let absC = sleep.sleepSkinTemperatureResult?.sleepSkinTemperatureCelsius, absC > 20, absC < 45 {
                    $0.skinTempC = Double(absC)
                }
            }
        }
        // 24/7 HR: use the daily minimum as a resting-HR fallback when nightly recharge is absent.
        for daySamples in hr247 {
            guard let dayDate = calendar.date(from: daySamples.date) else { continue }
            let all = daySamples.samples.flatMap { $0.hrSamples }.filter { $0 > 0 }
            guard let minHr = all.min() else { continue }
            upsert(dayDate.dayKey) {
                $0.date = $0.date ?? dayDate
                $0.minDayHr = Double(minHr)
            }
        }

        // Build DailySummary list ascending, computing derived scores against accumulated history.
        var summaries: [DailySummary] = []
        for key in byDay.keys.sorted() {
            guard let p = byDay[key], p.hasRealSignal else { continue }
            let resting = p.restingHr > 0 ? p.restingHr : p.minDayHr
            let sleepScore = p.sleepMinutes > 0
                ? MetricsEngine.sleepScore(durationMinutes: p.sleepMinutes, consistencyDeltaMinutes: 0, interruptions: p.interruptions)
                : 0
            // Strain scales with active minutes, weighting vigorous activity double — it loads
            // the body more than moderate. activeMinutes already counts vigorous once, so adding
            // vigorousMinutes again gives the intended moderate + 2×vigorous, not an accidental dup.
            let intensityWeightedMinutes = p.activeMinutes + p.vigorousMinutes
            let strain = min(100, Int(Double(intensityWeightedMinutes) * 0.8))
            var summary = DailySummary(
                dayKey: key,
                date: p.date ?? today,
                recoveryScore: 0,
                sleepScore: sleepScore,
                strainScore: strain,
                sleepMinutes: p.sleepMinutes,
                activeMinutes: p.activeMinutes,
                restingHeartRate: resting,
                hrvMs: p.hrvMs,
                skinTempDeltaC: p.skinTempDeltaC,
                skinTempC: p.skinTempC,
                calories: p.calories,
                steps: p.steps
            )
            summary.recoveryScore = (p.hrvMs > 0 || resting > 0)
                ? MetricsEngine.recoveryScore(today: summary, history: summaries)
                : max(sleepScore - 5, 0)
            // Prefer the device's real hypnogram; synthesize only when a night has a duration but
            // no staged phases, so the Today screen never shows a blank sleep graph for real sleep.
            summary.sleepStages = !p.sleepStages.isEmpty
                ? p.sleepStages
                : (p.sleepMinutes > 0 ? SleepSpan.synthesize(totalMinutes: p.sleepMinutes, wakeCount: p.interruptions) : [])
            summaries.append(summary)
        }

        NSLog("[PLL] syncLatest built %d summary day(s) from %d partial day(s)", summaries.count, byDay.count)
        // Surface actual values (not just counts) so an empty build is diagnosable: are the
        // records present but zero, or genuinely populated? Show the most recent few days.
        let stepsSum = steps.reduce(0) { $0 + $1.steps }
        let calSum = calories.reduce(0) { $0 + $1.calories }
        let recentSteps = steps.sorted { $0.date < $1.date }.suffix(4)
            .map { "\($0.date.dayKey)=\($0.steps)" }.joined(separator: ",")
        let recentCal = calories.sorted { $0.date < $1.date }.suffix(4)
            .map { "\($0.date.dayKey)=\($0.calories)" }.joined(separator: ",")
        // Sleep-staging + skin-temp visibility: are phases/cycles actually coming from the device,
        // and what temperature data exists (sleep deviation = -1000 until a baseline is built;
        // absolute skin temperature is available independently via getSkinTemperature).
        let phaseCounts = sleeps.map { "\($0.sleepWakePhases?.count ?? 0)" }.joined(separator: ",")
        let cycleCounts = sleeps.map { "\($0.sleepCycles?.count ?? 0)" }.joined(separator: ",")
        let tempDev = sleeps.compactMap { $0.sleepSkinTemperatureResult?.deviationFromBaseLine }
            .map { "\($0)" }.joined(separator: ",")
        let tempAbs = sleeps.compactMap { $0.sleepSkinTemperatureResult?.sleepSkinTemperatureCelsius }
            .map { String(format: "%.2f", Double($0)) }.joined(separator: ",")
        // Raw skin-temperature time-series: how many results, total samples, and the value range.
        let skinSamples = skinTemps.flatMap { ($0.skinTemperatureList ?? []).map { Double($0.temperature) } }
        let skinStat = skinSamples.isEmpty ? "none"
            : String(format: "n=%d min=%.2f avg=%.2f max=%.2f", skinSamples.count,
                     skinSamples.min() ?? 0, skinSamples.reduce(0, +) / Double(skinSamples.count), skinSamples.max() ?? 0)
        let diagnostics = "window=\(SyncWindow.days)d \(syncDiagnostics.joined(separator: " ")) "
            + "stepsSum=\(stepsSum) calSum=\(calSum) days=\(byDay.count) built=\(summaries.count) "
            + "sleepPhases[\(phaseCounts)] sleepCycles[\(cycleCounts)] "
            + "tempDev[\(tempDev)] tempAbs[\(tempAbs)] skinTempRaw{\(skinStat)} "
            + "steps[\(recentSteps)] cal[\(recentCal)]"
        continuation.yield(.status("Synced \(summaries.count) day(s): \(steps.count) steps, \(sleeps.count) sleep, \(recharges.count) recharge"))
        // Newest-first to match the rest of the app.
        return SyncPayload(dailySummaries: summaries.reversed(), heartRateSamples: [], diagnostics: diagnostics)
    }

    /// Runs one Polar data fetch, logging the count or error so failures are visible in the device console.
    private func fetch<T>(_ label: String, _ op: () async throws -> [T]) async -> [T] {
        do {
            let result = try await op()
            NSLog("[PLL] %@ -> %d item(s)", label, result.count)
            syncDiagnostics.append("\(label)=\(result.count)")
            return result
        } catch {
            NSLog("[PLL] %@ FAILED: %@", label, "\(error)")
            syncDiagnostics.append("\(label)=ERR(\(error))")
            return []
        }
    }

    private enum SyncWindow { static let days = 14 }

    private static func minutes(_ time: PolarActiveTime) -> Int {
        time.hours * 60 + time.minutes + (time.seconds >= 30 ? 1 : 0)
    }

    /// Total asleep minutes (non-wake phases) and the number of wake interruptions.
    private static func sleepMinutes(_ result: PolarSleepData.PolarSleepAnalysisResult) -> (asleep: Int, wakeCount: Int) {
        guard let phases = result.sleepWakePhases, !phases.isEmpty,
              let start = result.sleepStartTime, let end = result.sleepEndTime else {
            return (0, 0)
        }
        let totalSeconds = Int(end.timeIntervalSince(start))
        var asleep = 0
        var wakeCount = 0
        for (index, phase) in phases.enumerated() {
            let phaseStart = Int(phase.secondsFromSleepStart)
            let phaseEnd = index + 1 < phases.count ? Int(phases[index + 1].secondsFromSleepStart) : totalSeconds
            let duration = max(0, phaseEnd - phaseStart)
            guard let state = phase.state else { continue }
            switch state {
            case .WAKE:
                wakeCount += 1
            case .REM, .NONREM12, .NONREM3:
                asleep += duration
            case .UNKNOWN:
                break
            }
        }
        return (asleep / 60, wakeCount)
    }

    /// Ordered hypnogram spans (in minutes from sleep onset) mapped from the device's sleep/wake
    /// phases, for drawing a real stage graph. Zero-length and UNKNOWN phases are dropped.
    private static func sleepSpans(_ result: PolarSleepData.PolarSleepAnalysisResult) -> [SleepSpan] {
        guard let phases = result.sleepWakePhases, !phases.isEmpty,
              let start = result.sleepStartTime, let end = result.sleepEndTime else {
            return []
        }
        let totalSeconds = Int(end.timeIntervalSince(start))
        var spans: [SleepSpan] = []
        for (index, phase) in phases.enumerated() {
            let phaseStart = Int(phase.secondsFromSleepStart)
            let phaseEnd = index + 1 < phases.count ? Int(phases[index + 1].secondsFromSleepStart) : totalSeconds
            let durationMin = max(0, phaseEnd - phaseStart) / 60
            guard durationMin > 0, let state = phase.state else { continue }
            let stage: SleepSpan.Stage
            switch state {
            case .NONREM3: stage = .deep
            case .NONREM12: stage = .light
            case .REM: stage = .rem
            case .WAKE: stage = .awake
            case .UNKNOWN: continue
            }
            spans.append(SleepSpan(startMin: phaseStart / 60, durationMin: durationMin, stage: stage))
        }
        return spans
    }

    func isFirstTimeUseDone() async throws -> Bool {
        guard let id = connectedDeviceId else {
            throw AppError.message("Connect your Polar Loop first")
        }
        let done = try await api.isFtuDone(id)
        NSLog("[PLL] isFtuDone -> %d", done ? 1 : 0)
        return done
    }

    func runFirstTimeUse(profile: UserProfile) async throws {
        guard let id = connectedDeviceId else {
            throw AppError.message("Connect your Polar Loop first")
        }
        // Clamp every value into the SDK's accepted ranges — PolarFirstTimeUseConfig's init
        // asserts on out-of-range input, which would trap in a debug build.
        let height = Float(min(240, max(90, profile.heightCm)))
        let weight = Float(min(300, max(15, profile.weightKg)))
        let maxHr = min(240, max(100, profile.maxHr))
        let restingHr = min(120, max(20, profile.restingHr))
        let vo2 = min(95, max(10, profile.vo2Max))
        let sleepGoal = min(660, max(300, profile.sleepGoalMinutes))
        let typicalDay = PolarFirstTimeUseConfig.TypicalDay(rawValue: profile.typicalDay.rawValue) ?? .mostlySitting

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let config = PolarFirstTimeUseConfig(
            gender: profile.sex == .male ? .male : .female,
            birthDate: profile.birthDate,
            height: height,
            weight: weight,
            maxHeartRate: maxHr,
            vo2Max: vo2,
            restingHeartRate: restingHr,
            trainingBackground: .regular,
            deviceTime: iso.string(from: Date()),
            typicalDay: typicalDay,
            sleepGoalMinutes: sleepGoal
        )
        continuation.yield(.status("Setting device clock…"))
        NSLog("[PLL] setLocalTime + doFirstTimeUse for %@", id)
        try await api.setLocalTime(id, time: Date(), zone: TimeZone.current)
        continuation.yield(.status("Writing user profile to device…"))
        try await api.doFirstTimeUse(id, ftuConfig: config)
        continuation.yield(.status("Device profile written"))
    }

    func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
        continuation.yield(.status("Connecting to \(polarDeviceInfo.name)"))
    }

    func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
        connectedDeviceId = polarDeviceInfo.deviceId
        desiredDeviceId = polarDeviceInfo.deviceId
        reconnectAttempt = 0
        cancelReconnect()   // connected — tear down any in-flight reconnect/scan/watchdog work
        NSLog("[PLL] deviceConnected %@", polarDeviceInfo.deviceId)
        continuation.yield(.connected(
            WearableDevice(
                id: polarDeviceInfo.deviceId,
                name: polarDeviceInfo.name,
                rssi: polarDeviceInfo.rssi,
                isConnectable: true
            )
        ))
    }

    func deviceDisconnected(_ polarDeviceInfo: PolarDeviceInfo, pairingError: Bool) {
        let reason = pairingError ? "Pairing error" : "Device disconnected"
        NSLog("[PLL] deviceDisconnected %@ (%@)", polarDeviceInfo.deviceId, reason)
        continuation.yield(.disconnected(reason))
        connectedDeviceId = nil
        hrTask?.cancel()
        // Re-arm unless the user disconnected on purpose. The SDK's automaticReconnection covers
        // fast transient drops; our loop is the safety net for the ones it gives up on.
        if !userInitiatedDisconnect, !pairingError, let id = desiredDeviceId, reconnectTask == nil {
            NSLog("[PLL] arming reconnect after drop for %@", id)
            startReconnectLoop(for: id)
        }
    }

    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        continuation.yield(.battery(Int(batteryLevel)))
    }

    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        continuation.yield(.status("Battery charging status: \(chargingStatus)"))
    }

    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        continuation.yield(.status("Device info \(uuid.uuidString): \(value)"))
    }

    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        continuation.yield(.status("Device info \(key): \(value)"))
    }

    func blePowerOn() {
        blePoweredOn = true
        continuation.yield(.status("Bluetooth powered on"))
        // BLE became available (launch, CoreBluetooth state restoration, or radio toggled back on).
        // If we still want a device and aren't connected, (re)arm the reconnect loop.
        if !userInitiatedDisconnect, let id = desiredDeviceId, connectedDeviceId != id, reconnectTask == nil {
            NSLog("[PLL] blePowerOn: arming reconnect for %@", id)
            startReconnectLoop(for: id)
        }
    }

    func blePowerOff() {
        blePoweredOn = false
        continuation.yield(.status("Bluetooth powered off"))
    }
}
#endif

// MARK: - Apple Health (Ultrahuman comparison)

/// One day of metrics read from Apple Health, written there by the Ultrahuman app.
/// One app/device writing to Apple Health, with the metric labels it provides — surfaced so the
/// user can browse what's syncing and pick which source to audit the Loop against. Keyed by source
/// *name*: Apple's own data (Watch/iPhone) fragments into many per-revision bundle ids under one
/// name, so name is the correct isolation unit; third-party apps collapse to a single feed anyway.
struct HealthSource: Identifiable, Equatable {
    var id: String        // source name (the isolation key)
    var name: String { id }
    var metrics: [String]
    var feedCount: Int    // number of underlying HKSource revisions sharing this name
}

/// One day of metrics read from a chosen Apple Health source (an Ultrahuman ring, an Apple Watch,
/// etc.), for side-by-side comparison against the Loop.
struct ComparisonDay: Identifiable, Equatable {
    var id: String { dayKey }
    let dayKey: String
    var hrvMs: Double?
    var restingHr: Double?
    var sleepMinutes: Int?
    var steps: Int?
    var activeEnergy: Double?
}

/// Reads metrics out of Apple Health, isolated to one source by bundle identifier so the Loop is
/// compared against exactly one ring/watch/app with no cross-source mixing. Read-only.
final class HealthKitReader {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private enum Reduce { case average, sum }
    private enum DayKeyField { case start, end }

    private static let perMinute = HKUnit.count().unitDivided(by: .minute())

    /// Quantity metrics we read and discover sources for. The Loop is compared on the subset it
    /// also tracks (HRV/RHR/Steps/Active Energy); the rest enrich the per-source audit list.
    private struct QuantityMetric {
        let label: String
        let id: HKQuantityTypeIdentifier
        let unit: HKUnit
        let reduce: Reduce
    }
    private static let quantityCatalog: [QuantityMetric] = [
        QuantityMetric(label: "HRV", id: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), reduce: .average),
        QuantityMetric(label: "Resting HR", id: .restingHeartRate, unit: perMinute, reduce: .average),
        QuantityMetric(label: "Steps", id: .stepCount, unit: .count(), reduce: .sum),
        QuantityMetric(label: "Active Energy", id: .activeEnergyBurned, unit: .kilocalorie(), reduce: .sum),
        QuantityMetric(label: "Heart Rate", id: .heartRate, unit: perMinute, reduce: .average),
        QuantityMetric(label: "Respiratory Rate", id: .respiratoryRate, unit: perMinute, reduce: .average),
        QuantityMetric(label: "VO₂ Max", id: .vo2Max, unit: HKUnit(from: "ml/kg*min"), reduce: .average),
        QuantityMetric(label: "Blood Oxygen", id: .oxygenSaturation, unit: .percent(), reduce: .average),
        QuantityMetric(label: "Walking HR", id: .walkingHeartRateAverage, unit: perMinute, reduce: .average)
    ]

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for metric in Self.quantityCatalog {
            if let t = HKObjectType.quantityType(forIdentifier: metric.id) { types.insert(t) }
        }
        if let s = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(s) }
        return types
    }

    /// Metrics we write back into Apple Health from the Loop. Keyed to the same identifiers
    /// we read, so the Loop's numbers sit alongside the Ultrahuman/Watch numbers in Health.
    private static let writeIdentifiers: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .restingHeartRate, .heartRateVariabilitySDNN
    ]

    private var shareTypes: Set<HKSampleType> {
        Set(Self.writeIdentifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// Writes the Loop's daily metrics into Apple Health (steps, active energy, resting HR,
    /// HRV). Idempotent: first deletes any samples this app previously wrote in the covered
    /// date range, then re-saves — so re-pushing the same days replaces rather than
    /// duplicates. Only this app's own samples are deleted; Ultrahuman/Watch data is never
    /// touched. Zero-valued metrics are skipped. Returns the number of samples written.
    func writeSummaries(_ summaries: [DailySummary]) async throws -> Int {
        let calendar = Calendar.current
        guard let earliest = summaries.map({ calendar.startOfDay(for: $0.date) }).min(),
              let latestDay = summaries.map({ calendar.startOfDay(for: $0.date) }).max() else { return 0 }
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: latestDay) ?? latestDay

        // Remove our previously-written samples in range so the push is idempotent.
        let mine = HKQuery.predicateForObjects(from: HKSource.default())
        let inRange = HKQuery.predicateForSamples(withStart: earliest, end: rangeEnd, options: [])
        let scoped = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, inRange])
        for id in Self.writeIdentifiers {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
            _ = try? await store.deleteObjects(of: type, predicate: scoped)
        }

        var samples: [HKSample] = []
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        for day in summaries {
            let start = calendar.startOfDay(for: day.date)
            let dayEnd = (calendar.date(byAdding: .day, value: 1, to: start) ?? start).addingTimeInterval(-1)
            let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? day.date
            func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, start s: Date, end e: Date) {
                guard value > 0, let type = HKObjectType.quantityType(forIdentifier: id) else { return }
                samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: s, end: e))
            }
            // Steps and active energy are cumulative over the day → span the whole day.
            add(.stepCount, .count(), Double(day.steps), start: start, end: dayEnd)
            add(.activeEnergyBurned, .kilocalorie(), Double(day.calories), start: start, end: dayEnd)
            // Resting HR and HRV are point-in-time daily values → stamp at midday.
            add(.restingHeartRate, perMinute, day.restingHeartRate, start: noon, end: noon)
            add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), day.hrvMs, start: noon, end: noon)
        }
        guard !samples.isEmpty else { return 0 }
        try await store.save(samples)
        return samples.count
    }

    // MARK: - Source discovery

    /// Every app/device currently writing the metrics we track, with the labels each provides.
    /// Lets the user browse what's syncing to Health and pick which source to audit the Loop against.
    func discoverSources() async -> [HealthSource] {
        var byName: [String: (metrics: [String], feeds: Set<String>)] = [:]
        func record(_ type: HKSampleType, label: String) async {
            for src in await sources(for: type) {
                var entry = byName[src.name] ?? ([], [])
                if !entry.metrics.contains(label) { entry.metrics.append(label) }
                entry.feeds.insert(src.bundleIdentifier)
                byName[src.name] = entry
            }
        }
        for metric in Self.quantityCatalog {
            if let t = HKObjectType.quantityType(forIdentifier: metric.id) { await record(t, label: metric.label) }
        }
        if let s = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { await record(s, label: "Sleep") }
        return byName.map { HealthSource(id: $0.key, metrics: $0.value.metrics, feedCount: $0.value.feeds.count) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private func sources(for type: HKSampleType) async -> Set<HKSource> {
        await withCheckedContinuation { continuation in
            let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, _ in
                continuation.resume(returning: sources ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - Per-source comparison read

    /// Days of metrics from exactly one Health source (by bundle id), newest first.
    func comparisonDays(sourceId: String, daysBack days: Int) async -> [ComparisonDay] {
        let hrvMap = await quantityByDay(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: days, key: .start, reduce: .average, sourceId: sourceId)
        let rhrMap = await quantityByDay(.restingHeartRate, unit: Self.perMinute, days: days, key: .start, reduce: .average, sourceId: sourceId)
        let stepMap = await quantityByDay(.stepCount, unit: .count(), days: days, key: .start, reduce: .sum, sourceId: sourceId)
        let energyMap = await quantityByDay(.activeEnergyBurned, unit: .kilocalorie(), days: days, key: .start, reduce: .sum, sourceId: sourceId)
        let sleepMap = await sleepMinutesByDay(days: days, sourceId: sourceId)
        let keys = Set(hrvMap.keys).union(rhrMap.keys).union(stepMap.keys).union(energyMap.keys).union(sleepMap.keys)
        return keys.sorted(by: >).map { key in
            ComparisonDay(
                dayKey: key,
                hrvMs: hrvMap[key],
                restingHr: rhrMap[key],
                sleepMinutes: sleepMap[key].map { Int($0) },
                steps: stepMap[key].map { Int($0) },
                activeEnergy: energyMap[key]
            )
        }
    }

    private func quantityByDay(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int, key: DayKeyField, reduce: Reduce, sourceId: String) async -> [String: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return [:] }
        let samples = await samples(type, days: days, sourceId: sourceId).compactMap { $0 as? HKQuantitySample }
        var buckets: [String: [Double]] = [:]
        for sample in samples {
            let date = key == .start ? sample.startDate : sample.endDate
            buckets[date.dayKey, default: []].append(sample.quantity.doubleValue(for: unit))
        }
        return buckets.mapValues { values in
            switch reduce {
            case .sum: return values.reduce(0, +)
            case .average: return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
        }
    }

    private func sleepMinutesByDay(days: Int, sourceId: String) async -> [String: Double] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        let samples = await samples(type, days: days, sourceId: sourceId).compactMap { $0 as? HKCategorySample }
        var minutesByDay: [String: Double] = [:]
        for sample in samples where asleep.contains(sample.value) {
            // Attribute the night to the wake-up morning.
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            minutesByDay[sample.endDate.dayKey, default: 0] += minutes
        }
        return minutesByDay
    }

    private func samples(_ type: HKSampleType, days: Int, sourceId: String) async -> [HKSample] {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: end)) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, result, _ in
                // Strict isolation by source name (covers all of an Apple device's feed revisions).
                let filtered = (result ?? []).filter { $0.sourceRevision.source.name == sourceId }
                continuation.resume(returning: filtered)
            }
            store.execute(query)
        }
    }
}

// MARK: - Design System

enum Theme {
    // Backgrounds
    static let bg = Color(hex: 0x0B0B0F)
    static let bgTop = Color(hex: 0x14141C)
    static let surface = Color(hex: 0x16161D)
    static let surfaceHi = Color(hex: 0x1F1F29)
    static let hairline = Color.white.opacity(0.07)

    // Text
    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0x9A9AA6)
    static let textTertiary = Color(hex: 0x66667A)

    // Metric accents
    static let recoveryGreen = Color(hex: 0x12E29A)
    static let recoveryYellow = Color(hex: 0xFFC93C)
    static let recoveryRed = Color(hex: 0xFF4D5E)
    static let strain = Color(hex: 0x3FA9FF)
    static let strainHi = Color(hex: 0x7C5CFF)
    static let sleep = Color(hex: 0x8A7CFF)
    static let hrv = Color(hex: 0x2FE6C8)
    static let rhr = Color(hex: 0xFF7A66)
    static let temp = Color(hex: 0xFFB13C)
    static let activity = Color(hex: 0xB4FF4D)

    static func recoveryColor(_ score: Int) -> Color {
        if score >= 67 { return recoveryGreen }
        if score >= 34 { return recoveryYellow }
        return recoveryRed
    }

    static func recoveryWord(_ score: Int) -> String {
        if score >= 67 { return "Charged" }
        if score >= 34 { return "Steady" }
        return "Low"
    }

    static let sleepDeep = Color(hex: 0x4A5BCF)
    static func sleepStageColor(_ stage: SleepSpan.Stage) -> Color {
        switch stage {
        case .deep: return strainHi
        case .rem: return sleep
        case .light: return sleepDeep
        case .awake: return textTertiary
        }
    }

    // App background gradient
    static var background: some View {
        LinearGradient(
            colors: [bgTop, bg],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
        .overlay(Theme.bg.opacity(0.0))
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// Centralized user-facing vocabulary. The app's metrics keep their original code names
/// (recoveryScore / strainScore / DB columns) but are presented under OSS-neutral labels so
/// nothing borrows a competitor's signature term. Change a word here, it changes everywhere.
enum Copy {
    static let appName = "Loopback"
    static let recharge = "Recharge"      // was "Recovery"
    static let exertion = "Exertion"      // was "Strain"
    static let sleep = "Sleep"
    static let insights = "Insights"      // was "Coach"
    static let vitals = "Vitals"          // was "Individual Markers"
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// Standard elevated card chrome used across the app.
    func cardSurface(_ radius: CGFloat = 20, fill: Color = Theme.surface) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Reusable components

struct SectionHeader: View {
    let title: String
    var accessory: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if let accessory {
                Text(accessory)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// WHOOP-style ring with a zone-colored progress arc and centered hero value.
struct RingGauge: View {
    let progress: Double          // 0...1
    let value: String
    let unit: String
    let label: String
    let color: Color
    var gradientEnd: Color? = nil
    var lineWidth: CGFloat = 12
    var valueFont: CGFloat = 30

    private var stroke: AnyShapeStyle {
        if let gradientEnd {
            return AnyShapeStyle(
                AngularGradient(
                    colors: [color, gradientEnd, color],
                    center: .center,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(270)
                )
            )
        }
        return AnyShapeStyle(color)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.5), radius: 6)
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: valueFont, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Compact metric tile with an icon chip, hero value, and caption.
struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let caption: String
    let accent: Color
    var live: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if live {
                    LivePulse(color: accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(18)
    }
}

struct LivePulse: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: on ? 5 : 1)
            .opacity(on ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = Theme.hrv

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

struct PillButton: View {
    let title: String
    let systemImage: String
    var filled: Bool = false
    var tint: Color = Theme.hrv
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(filled ? .black : tint)
                } else {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .bold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(filled ? Color.black : tint)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(filled
                          ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(tint.opacity(0.12)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0 : 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Gradient area sparkline via Swift Charts.
struct AreaSparkline: View {
    let values: [Double]
    let color: Color
    var showLine: Bool = true

    var body: some View {
        let pts = Array(values.enumerated())
        let minV = (values.min() ?? 0)
        let maxV = (values.max() ?? 1)
        let pad = max((maxV - minV) * 0.15, 0.5)
        Chart {
            ForEach(pts, id: \.offset) { idx, v in
                AreaMark(
                    x: .value("i", idx),
                    yStart: .value("min", minV - pad),
                    yEnd: .value("v", v)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                )
                if showLine {
                    LineMark(x: .value("i", idx), y: .value("v", v))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(color)
                }
            }
        }
        .chartYScale(domain: (minV - pad)...(maxV + pad))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.bg)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        // Hide scroll indicators app-wide for a cleaner, more premium feel.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
    }

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "bolt.heart.fill") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
            DeviceView()
                .tabItem { Label("Device", systemImage: "dot.radiowaves.left.and.right") }
            ProfileHubView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
        }
        .tint(Theme.recoveryGreen)
        .alert(Copy.appName, isPresented: Binding(
            get: { model.alertText != nil },
            set: { if !$0 { model.alertText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertText ?? "")
        }
    }
}

// MARK: - Today

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dayIndex = 0
    @State private var dayHR: [HeartRateSample] = []
    @State private var showingSettings = false
    @State private var showingLog = false
    @State private var logNoteMode = false
    // Observed so temperature tiles/markers re-render when the unit preference changes.
    @AppStorage(SettingsKey.tempUnitFahrenheit) private var tempF = false

    /// Summaries are newest-first, so index 0 is the most recent synced day.
    private var selected: DailySummary? {
        guard !model.summaries.isEmpty else { return nil }
        return model.summaries[min(dayIndex, model.summaries.count - 1)]
    }

    /// Days strictly older than `day`, ascending — the baseline window for that day's signals.
    private func history(before day: DailySummary) -> [DailySummary] {
        model.summaries.filter { $0.dayKey < day.dayKey }.sorted { $0.dayKey < $1.dayKey }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TodayHeader()
                        if model.showingSampleData {
                            SampleDataBanner()
                        }
                        if let day = selected {
                            DayNavigator(date: day.date, index: dayIndex, count: model.summaries.count) { delta in
                                dayIndex = max(0, min(model.summaries.count - 1, dayIndex + delta))
                            }
                            HeroRings(summary: day, contributors: MetricsEngine.recoveryContributors(today: day, history: history(before: day)))
                            SleepBreakdownCard(summary: day)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                NavigationLink(value: MetricKind.hrv) {
                                    StatTile(icon: "waveform.path.ecg", title: "HRV", value: "\(Int(day.hrvMs))", unit: "ms", caption: "Nightly average", accent: Theme.hrv)
                                }.buttonStyle(.plain)
                                NavigationLink(value: MetricKind.restingHr) {
                                    StatTile(icon: "heart.fill", title: "Resting HR", value: "\(Int(day.restingHeartRate))", unit: "bpm", caption: "Overnight low", accent: Theme.rhr)
                                }.buttonStyle(.plain)
                                NavigationLink(value: MetricKind.skinTemp) {
                                    StatTile(icon: "thermometer.medium", title: "Skin Temp", value: tempTile(day).value, unit: tempTile(day).unit, caption: tempTile(day).caption, accent: Theme.temp)
                                }.buttonStyle(.plain)
                                StatTile(icon: "figure.walk", title: "Activity", value: "\(day.activeMinutes)", unit: "min", caption: "\(day.steps.formatted()) steps", accent: Theme.activity)
                            }
                            DailyHRCard(samples: dayHR)
                            MarkersCard(day: day, history: history(before: day))
                            LiveHRCard()
                            InsightCard(text: CoachEngine.dailySummary(today: day, history: model.summaries))
                        } else {
                            AwaitingDataCard(connected: model.connectionState.contains("Connected"))
                            LiveHRCard()
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 96)
                }
                .navigationDestination(for: MetricKind.self) { kind in
                    MetricDetailView(kind: kind, summaries: model.summaries)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                AddFAB { noteMode in
                    logNoteMode = noteMode
                    showingLog = true
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingLog) { LogSheet(noteMode: logNoteMode) }
        }
        .onAppear(perform: refreshDayHR)
        .onChange(of: dayIndex) { _, _ in refreshDayHR() }
        .onChange(of: model.summaries.count) { _, _ in
            dayIndex = 0
            refreshDayHR()
        }
    }

    private func refreshDayHR() {
        guard let day = selected else { dayHR = []; return }
        dayHR = model.heartRateSamples(onDay: day.dayKey)
    }

    private func tempString(_ value: Double?) -> String {
        // No baseline yet → show "—" rather than a fabricated number.
        guard let value else { return "—" }
        // Round to one decimal first, then clamp -0.0 (and 0.0) to a clean non-signed 0.0.
        let rounded = (value * 10).rounded() / 10
        let clamped = rounded == 0 ? 0 : rounded
        return clamped.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    }

    /// Skin-temp tile: prefer Polar's signed deviation when it exists; otherwise show the absolute
    /// overnight temperature we capture from raw data; else "—".
    private func tempTile(_ day: DailySummary) -> (value: String, unit: String, caption: String) {
        if let dev = day.skinTempDeltaC {
            return (tempString(TempUnit.convert(dev, isDelta: true)), TempUnit.label, "From baseline")
        }
        if let absC = day.skinTempC {
            return (TempUnit.convert(absC, isDelta: false).formatted(.number.precision(.fractionLength(1))), TempUnit.label, "Overnight")
        }
        return ("—", "", "No data yet")
    }
}

struct TodayHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.recoveryGreen)
                    .padding(10)
                    .background(Theme.recoveryGreen.opacity(0.12), in: Circle())
            }
            HStack(spacing: 8) {
                StatusPill(text: model.connectionState, systemImage: "antenna.radiowaves.left.and.right", tint: model.connectionState.contains("Connected") ? Theme.recoveryGreen : Theme.hrv)
                if model.showingSampleData {
                    StatusPill(text: "Sample data", systemImage: "wand.and.stars", tint: Theme.recoveryYellow)
                }
                if let battery = model.batteryLevel {
                    StatusPill(text: "\(battery)%", systemImage: "battery.75percent", tint: Theme.activity)
                }
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }
}

struct HeroRings: View {
    let summary: DailySummary
    var contributors: [RecoveryContributor] = []

    private var inRangeCount: Int { contributors.filter(\.inRange).count }

    var body: some View {
        VStack(spacing: 18) {
            // Recharge as the central hero
            NavigationLink(value: MetricKind.recharge) {
                RingGauge(
                    progress: Double(summary.recoveryScore) / 100,
                    value: "\(summary.recoveryScore)",
                    unit: "%",
                    label: Copy.recharge,
                    color: Theme.recoveryColor(summary.recoveryScore),
                    lineWidth: 16,
                    valueFont: 52
                )
                .frame(width: 168, height: 168)
                .overlay(alignment: .bottom) {
                    Text(Theme.recoveryWord(summary.recoveryScore).uppercased())
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(Theme.recoveryColor(summary.recoveryScore))
                        .offset(y: 26)
                }
                .padding(.bottom, 14)
            }
            .buttonStyle(.plain)

            if !contributors.isEmpty {
                VStack(spacing: 8) {
                    Text("\(inRangeCount)/\(contributors.count) SIGNALS IN RANGE")
                        .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 6) {
                        ForEach(contributors) { ContributorChip(contributor: $0) }
                    }
                }
            }

            HStack(spacing: 12) {
                NavigationLink(value: MetricKind.sleep) {
                    RingGauge(
                        progress: Double(summary.sleepScore) / 100,
                        value: "\(summary.sleepScore)",
                        unit: "%",
                        label: "Sleep",
                        color: Theme.sleep,
                        gradientEnd: Theme.strainHi,
                        lineWidth: 11,
                        valueFont: 26
                    )
                    .frame(height: 104)
                }.buttonStyle(.plain)
                NavigationLink(value: MetricKind.exertion) {
                    RingGauge(
                        progress: Double(summary.strainScore) / 100,
                        value: strain21,
                        unit: "/ 21",
                        label: Copy.exertion,
                        color: Theme.strain,
                        gradientEnd: Theme.strainHi,
                        lineWidth: 11,
                        valueFont: 26
                    )
                    .frame(height: 104)
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .cardSurface(24)
    }

    private var strain21: String {
        let v = Double(summary.strainScore) / 100 * 21
        return v.formatted(.number.precision(.fractionLength(1)))
    }
}

/// Real hypnogram drawn from the night's persisted sleep phases. Falls back to a synthesized
/// shape (clearly captioned "estimated") only when a day has a duration but no staged phases.
struct SleepBreakdownCard: View {
    let summary: DailySummary

    private var spans: [SleepSpan] {
        if !summary.sleepStages.isEmpty { return summary.sleepStages }
        return SleepSpan.synthesize(totalMinutes: summary.sleepMinutes, wakeCount: 0)
    }
    private var isEstimated: Bool { summary.sleepStages.isEmpty && summary.sleepMinutes > 0 }
    private var totalMin: Int { max(1, spans.map { $0.startMin + $0.durationMin }.max() ?? summary.sleepMinutes) }

    /// Minutes per stage, in display order (Awake, REM, Light, Deep).
    private var totals: [(SleepSpan.Stage, Int)] {
        SleepSpan.Stage.allCases.reversed().map { stage in
            (stage, spans.filter { $0.stage == stage }.reduce(0) { $0 + $1.durationMin })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Sleep", accessory: isEstimated ? "estimated" : nil)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(summary.sleepMinutes / 60)")
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("h").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text("\(summary.sleepMinutes % 60)")
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("m").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(summary.sleepScore)% performance")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sleep)
            }
            .foregroundStyle(Theme.textPrimary)

            if spans.isEmpty {
                Text("No staged sleep recorded for this night.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else {
                Hypnogram(spans: spans, totalMin: totalMin)
                    .frame(height: 92)
                HStack(spacing: 0) {
                    ForEach(totals, id: \.0) { stage, minutes in
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.sleepStageColor(stage)).frame(width: 6, height: 6)
                                Text(stage.rawValue.capitalized)
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                            Text("\(minutes / 60)h \(minutes % 60)m")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .cardSurface(20)
    }
}

/// Stepped sleep-stage graph: time on x, stage depth on y (Awake top → Deep bottom).
struct Hypnogram: View {
    let spans: [SleepSpan]
    let totalMin: Int

    private func level(_ stage: SleepSpan.Stage) -> Int {
        switch stage {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let rowH = size.height / 4
            let total = CGFloat(max(1, totalMin))
            for span in spans {
                let x = CGFloat(span.startMin) / total * size.width
                let w = max(1.5, CGFloat(span.durationMin) / total * size.width)
                let y = CGFloat(level(span.stage)) * rowH
                let rect = CGRect(x: x, y: y + 1.5, width: w, height: rowH - 3)
                let path = Path(roundedRect: rect, cornerRadius: 2.5)
                ctx.fill(path, with: .color(Theme.sleepStageColor(span.stage)))
            }
        }
    }
}

struct ContributorChip: View {
    let contributor: RecoveryContributor
    private var tint: Color { contributor.inRange ? Theme.recoveryGreen : Theme.recoveryYellow }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: contributor.inRange ? "checkmark" : "exclamationmark")
                    .font(.system(size: 8, weight: .bold))
                Text(contributor.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.5)
            }
            .foregroundStyle(tint)
            Text(contributor.value)
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Date pager over synced days — shows the data's own date (not the device clock), so an older
/// day is never mislabeled as today. Chevrons step through history within bounds.
struct DayNavigator: View {
    let date: Date
    let index: Int
    let count: Int
    let move: (Int) -> Void   // +1 = older, -1 = newer

    private var isToday: Bool { date.dayKey == Date.now.dayKey }

    var body: some View {
        HStack {
            chevron("chevron.left", enabled: index < count - 1) { move(1) }
            Spacer()
            VStack(spacing: 1) {
                Text(isToday ? "TODAY" : date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(1.2).foregroundStyle(Theme.textTertiary)
                Text(date.formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            chevron("chevron.right", enabled: index > 0) { move(-1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .cardSurface(16)
    }

    private func chevron(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary.opacity(0.4))
                .frame(width: 40, height: 32)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Daily heart-rate curve for the selected day, drawn from persisted samples (sample data + live
/// HR sessions). Shows min/avg/max with a gradient area sparkline.
struct DailyHRCard: View {
    let samples: [HeartRateSample]

    private var bpms: [Double] { samples.map { Double($0.bpm) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.rhr)
                SectionHeader(title: "Heart Rate", accessory: samples.isEmpty ? nil : "\(samples.count) samples")
            }
            if bpms.count < 2 {
                Text("No heart-rate samples for this day. Start Live HR while wearing the Loop to record some.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 18) {
                    hrStat("MIN", Int(bpms.min() ?? 0))
                    hrStat("AVG", Int(bpms.reduce(0, +) / Double(bpms.count)))
                    hrStat("MAX", Int(bpms.max() ?? 0))
                }
                AreaSparkline(values: bpms, color: Theme.rhr)
                    .frame(height: 70)
            }
        }
        .padding(16)
        .cardSurface(20)
    }

    private func hrStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text("bpm").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Individual markers (Ultrahuman-style): each key signal with its value and 7-day baseline delta.
struct MarkersCard: View {
    let day: DailySummary
    let history: [DailySummary]   // ascending, older than `day`

    private var baseline: [DailySummary] { Array(history.suffix(7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Copy.vitals)
            markerRow("waveform.path.ecg", "HRV", Theme.hrv, value: day.hrvMs, unit: "ms", baseline: baseline.map(\.hrvMs), higherIsBetter: true, decimals: 0)
            divider
            markerRow("heart.fill", "Resting HR", Theme.rhr, value: day.restingHeartRate, unit: "bpm", baseline: baseline.map(\.restingHeartRate), higherIsBetter: false, decimals: 0)
            divider
            markerRow("thermometer.medium", "Skin Temp", Theme.temp,
                      value: day.skinTempC.map { TempUnit.convert($0, isDelta: false) },
                      unit: TempUnit.label,
                      baseline: baseline.compactMap { $0.skinTempC.map { TempUnit.convert($0, isDelta: false) } },
                      higherIsBetter: nil, decimals: 1)
        }
        .padding(16)
        .cardSurface(20)
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    @ViewBuilder
    private func markerRow(_ icon: String, _ label: String, _ accent: Color, value: Double?, unit: String, baseline: [Double], higherIsBetter: Bool?, decimals: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if let value {
                let avg = baseline.isEmpty ? nil : baseline.reduce(0, +) / Double(baseline.count)
                let delta = avg.map { value - $0 }
                // Normalize -0.0 (from rounding a tiny negative) to a clean 0 before display.
                let scale = pow(10.0, Double(decimals))
                let rounded = (value * scale).rounded() / scale
                let shownValue = rounded == 0 ? 0 : rounded
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if let avg {
                        Text("7-day avg \(avg.formatted(.number.precision(.fractionLength(decimals))))\(unit)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("building baseline").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(shownValue.formatted(.number.precision(.fractionLength(decimals))))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    if let delta, abs(delta) >= (decimals == 0 ? 1 : 0.1) {
                        Text(deltaText(delta, decimals: decimals))
                            .font(.system(size: 11, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(deltaColor(delta, higherIsBetter: higherIsBetter))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("no baseline yet").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text("—").font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func deltaText(_ delta: Double, decimals: Int) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(delta.formatted(.number.precision(.fractionLength(decimals))))"
    }

    private func deltaColor(_ delta: Double, higherIsBetter: Bool?) -> Color {
        guard let higherIsBetter else { return Theme.textSecondary }   // temp: neither direction is "good"
        let good = higherIsBetter ? delta >= 0 : delta <= 0
        return good ? Theme.recoveryGreen : Theme.recoveryYellow
    }
}

struct LiveHRCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.rhr.opacity(0.14)).frame(width: 46, height: 46)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.rhr)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("LIVE HEART RATE")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Text(model.connectionState)
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(model.liveHeartRate.map { "\($0)" } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                if model.liveHeartRate != nil {
                    Text("bpm").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            if model.liveHeartRate != nil { LivePulse(color: Theme.rhr) }
        }
        .padding(16)
        .cardSurface(18)
    }
}

struct InsightCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.recoveryGreen)
                Text(Copy.insights.uppercased())
                    .font(.system(size: 12, weight: .heavy)).tracking(1.4)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Theme.recoveryGreen.opacity(0.5), Theme.hrv.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Metric detail (drill-down)

/// Full-screen detail for one metric, pushed when a Today card is tapped. Mirrors the Ultrahuman
/// pattern: hero value, a 7-day range strip, a Daily/Weekly/Monthly history chart, contributors
/// (for Recharge), and a plain-language explanation. Reads the same in-memory summaries the feed uses.
struct MetricDetailView: View {
    let kind: MetricKind
    let summaries: [DailySummary]   // newest-first

    @State private var scope: Scope = .daily

    enum Scope: String, CaseIterable, Identifiable {
        case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
        var id: String { rawValue }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let value: Double
    }

    private var ascending: [DailySummary] { summaries.reversed() }
    private var latest: DailySummary? { summaries.first }
    private var currentValue: Double? { latest.flatMap { kind.value($0) } }
    private var color: Color { kind == .recharge ? Theme.recoveryColor(latest?.recoveryScore ?? 0) : kind.accent }
    private var isScore: Bool { kind == .recharge || kind == .sleep || kind == .exertion }

    /// Baseline = the 7 most recent days before the latest, for the delta readout.
    private var baselineAvg: Double? {
        let vals = ascending.dropLast().suffix(7).compactMap { kind.value($0) }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                weekStrip
                Picker("Range", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                historyChart
                if kind == .recharge, let day = latest {
                    contributorsCard(for: day)
                }
                aboutCard
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(kind.navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currentValue.map { fmt($0) } ?? "—")
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                Text(kind.unit)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            if kind == .recharge, let s = latest {
                Text(Theme.recoveryWord(s.recoveryScore).uppercased())
                    .font(.system(size: 13, weight: .heavy)).tracking(1.4).foregroundStyle(color)
            } else if let avg = baselineAvg, let cur = currentValue {
                let delta = cur - avg
                HStack(spacing: 6) {
                    Text("7-day avg \(fmt(avg))\(kind.unit)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    if abs(delta) >= (kind.decimals == 0 ? 1 : 0.1) {
                        Text("\(delta >= 0 ? "+" : "")\(fmt(delta))")
                            .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(deltaColor(delta))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(22)
    }

    // MARK: 7-day strip

    private var weekStrip: some View {
        let days = ascending.suffix(7)
        let vals = days.compactMap { kind.value($0) }
        let maxV = max(vals.max() ?? 1, 0.001)
        let minV = min(vals.min() ?? 0, maxV)
        let span = max(maxV - minV, 0.001)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, s in
                let v = kind.value(s)
                let isLatest = s.dayKey == latest?.dayKey
                VStack(spacing: 6) {
                    Text(v.map { fmt($0) } ?? "—")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(isLatest ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isLatest ? barColor(s) : barColor(s).opacity(0.45))
                        .frame(height: 14 + CGFloat(((v ?? minV) - minV) / span) * 66)
                    Text(s.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 112)
        .padding(16)
        .cardSurface(20)
    }

    // MARK: History chart

    private var points: [Point] {
        switch scope {
        case .daily:
            return ascending.suffix(14).compactMap { s in
                kind.value(s).map { Point(date: s.date, label: s.date.formatted(.dateTime.month().day()), value: $0) }
            }
        case .weekly:
            return grouped(by: .weekOfYear, take: 8)
        case .monthly:
            return grouped(by: .month, take: 6)
        }
    }

    private func grouped(by comp: Calendar.Component, take: Int) -> [Point] {
        let cal = Calendar.current
        var buckets: [Date: [Double]] = [:]
        for s in ascending {
            guard let v = kind.value(s) else { continue }
            let key = cal.dateInterval(of: comp, for: s.date)?.start ?? s.date
            buckets[key, default: []].append(v)
        }
        return buckets.keys.sorted().suffix(take).map { key in
            let vals = buckets[key]!
            let avg = vals.reduce(0, +) / Double(vals.count)
            let fmtStr: Date.FormatStyle = comp == .month ? .dateTime.month(.abbreviated) : .dateTime.month().day()
            return Point(date: key, label: key.formatted(fmtStr), value: avg)
        }
    }

    @ViewBuilder private var historyChart: some View {
        let pts = points
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "History", accessory: scope.rawValue)
            if pts.count < 2 {
                Text("Not enough history yet. More days will fill this in as your Loop syncs.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(pts) { p in
                    if isScore {
                        BarMark(x: .value("When", p.label), y: .value(kind.title, p.value), width: .fixed(barWidth(pts.count)))
                            .clipShape(Capsule())
                            .foregroundStyle(kind == .recharge ? Theme.recoveryColor(Int(p.value)) : color)
                    } else {
                        AreaMark(x: .value("When", p.label), y: .value(kind.title, p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("When", p.label), y: .value(kind.title, p.value))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .foregroundStyle(color)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().foregroundStyle(Theme.textTertiary).font(.system(size: 10))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel().foregroundStyle(Theme.textTertiary).font(.system(size: 9))
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(16)
        .cardSurface(20)
    }

    private func contributorsCard(for day: DailySummary) -> some View {
        let history = summaries.filter { $0.dayKey < day.dayKey }.sorted { $0.dayKey < $1.dayKey }
        let contributors = MetricsEngine.recoveryContributors(today: day, history: history)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Contributors", accessory: "\(contributors.filter(\.inRange).count)/\(contributors.count) in range")
            ForEach(contributors) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.inRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(c.inRange ? Theme.recoveryGreen : Theme.recoveryYellow)
                    Text(c.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(c.value).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                    Text(c.inRange ? "Within range" : "Out of range")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.inRange ? Theme.recoveryGreen : Theme.recoveryYellow)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((c.inRange ? Theme.recoveryGreen : Theme.recoveryYellow).opacity(0.14), in: Capsule())
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .cardSurface(20)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "About \(kind.title)")
            Text(kind.about)
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            Text("Wellness guidance only — not a medical device.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .cardSurface(20)
    }

    // MARK: helpers

    private func fmt(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(kind.decimals)))
    }

    private func barColor(_ s: DailySummary) -> Color {
        kind == .recharge ? Theme.recoveryColor(s.recoveryScore) : kind.accent
    }

    private func barWidth(_ count: Int) -> CGFloat { count > 10 ? 10 : 18 }

    private func deltaColor(_ delta: Double) -> Color {
        guard let higher = kind.higherIsBetter else { return Theme.textSecondary }
        let good = higher ? delta >= 0 : delta <= 0
        return good ? Theme.recoveryGreen : Theme.recoveryYellow
    }
}

// MARK: - Add log (FAB + sheet)

/// Floating action button that expands to logging actions, mirroring the Ultrahuman "+" feed FAB.
/// Both actions open the same `LogSheet`; "Tag" preselects a context chip, "Note" focuses the note.
struct AddFAB: View {
    @State private var expanded = false
    let onSelect: (Bool) -> Void   // true = note mode, false = tag mode

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if expanded {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.3)) { expanded = false } }
            }
            VStack(alignment: .trailing, spacing: 12) {
                if expanded {
                    miniAction("Note", "square.and.pencil", Theme.sleep) { fire(true) }
                    miniAction("Tag", "tag.fill", Theme.activity) { fire(false) }
                }
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "xmark" : "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 58, height: 58)
                        .background(
                            LinearGradient(colors: [Theme.recoveryGreen, Theme.hrv], startPoint: .top, endPoint: .bottom),
                            in: Circle()
                        )
                        .shadow(color: Theme.recoveryGreen.opacity(0.4), radius: 10, y: 4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
    }

    private func fire(_ noteMode: Bool) {
        withAnimation(.spring(response: 0.3)) { expanded = false }
        onSelect(noteMode)
    }

    private func miniAction(_ title: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.surfaceHi, in: Capsule())
                Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 46, height: 46).background(tint, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// Full-screen logging sheet (Ultrahuman add-tag style): context chips, a time, an optional note,
/// then a confirmation. Writes a `JournalEntry` via the model.
struct LogSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteMode: Bool

    @State private var selectedTag = JournalTags.all.first ?? "caffeine"
    @State private var note = ""
    @State private var when = Date.now
    @State private var saved = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if saved {
                    confirmation
                } else {
                    form
                }
            }
            .navigationTitle(noteMode ? "Add Note" : "Add Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.tint(Theme.textSecondary) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { noteFocused = noteMode }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Context")
                    let cols = [GridItem(.adaptive(minimum: 96), spacing: 8)]
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(JournalTags.all, id: \.self) { tag in
                            let on = tag == selectedTag
                            Text(tag)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? .black : Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(on ? JournalTags.color(tag) : Theme.surfaceHi, in: Capsule())
                                .onTapGesture { selectedTag = tag }
                        }
                    }
                }
                .padding(16).cardSurface(20)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "When")
                    DatePicker("", selection: $when, in: ...Date.now)
                        .labelsHidden().colorScheme(.dark)
                }
                .padding(16).cardSurface(20)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Note")
                    TextField("", text: $note, prompt: Text("Optional note…").foregroundColor(Theme.textTertiary), axis: .vertical)
                        .lineLimit(2...5)
                        .font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                        .focused($noteFocused)
                        .padding(14)
                        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16).cardSurface(20)

                PillButton(title: "Save", systemImage: "checkmark.circle.fill", filled: true, tint: JournalTags.color(selectedTag)) {
                    model.addJournal(tag: selectedTag, note: note, date: when)
                    withAnimation(.spring(response: 0.35)) { saved = true }
                }
            }
            .padding(16).padding(.bottom, 24)
        }
    }

    private var confirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Theme.recoveryGreen)
            Text("Tagged \(selectedTag.capitalized)")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text("Saved locally. You'll see how tagged days line up with your metrics in Trends.")
                .font(.system(size: 14)).multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            PillButton(title: "Done", systemImage: "checkmark", tint: Theme.hrv) { dismiss() }
                .frame(maxWidth: 200)
        }
        .padding(28)
    }
}

// MARK: - Trends

struct TrendsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range = 30

    private var ranged: [DailySummary] {
        Array(model.summaries.prefix(range).reversed())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.showingSampleData {
                            SampleDataBanner()
                        }
                        ComparisonCard()
                        AppleHealthSyncCard()
                        Picker("Range", selection: $range) {
                            Text("7 Days").tag(7)
                            Text("30 Days").tag(30)
                        }
                        .pickerStyle(.segmented)

                        if ranged.count >= 2 {
                            TrendChartCard(title: Copy.recharge, unit: "%", data: ranged.map { ($0.date, Double($0.recoveryScore)) }, color: Theme.recoveryColor(model.today?.recoveryScore ?? 60), style: .bar, zoned: true)
                            TrendChartCard(title: "Sleep Score", unit: "%", data: ranged.map { ($0.date, Double($0.sleepScore)) }, color: Theme.sleep, style: .bar)
                            TrendChartCard(title: Copy.exertion, unit: "/21", data: ranged.map { ($0.date, Double($0.strainScore) / 100 * 21) }, color: Theme.strain, style: .area)
                            TrendChartCard(title: "HRV", unit: "ms", data: ranged.map { ($0.date, $0.hrvMs) }, color: Theme.hrv, style: .area)
                            TrendChartCard(title: "Resting HR", unit: "bpm", data: ranged.map { ($0.date, $0.restingHeartRate) }, color: Theme.rhr, style: .area)
                            if let impact = MetricsEngine.journalImpact(tag: "late meal", summaries: model.summaries, entries: model.journalEntries) {
                                CorrelationCard(tag: "Late Meal", delta: impact)
                            }
                        } else if model.awaitingFirstSync {
                            AwaitingDataCard(connected: model.connectionState.contains("Connected"))
                        } else {
                            EmptyState(title: "Not enough history", subtitle: "Sync more days from your Loop to populate trend charts.")
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Trends")
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct TrendChartCard: View {
    enum Style { case bar, area }
    let title: String
    let unit: String
    let data: [(Date, Double)]
    let color: Color
    let style: Style
    var zoned: Bool = false

    private var points: [TrendPoint] { data.map { TrendPoint(date: $0.0, value: $0.1) } }
    private var current: Double { data.last?.1 ?? 0 }
    private var avg: Double { data.isEmpty ? 0 : data.map(\.1).reduce(0,+) / Double(data.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title, accessory: "avg \(avg.formatted(.number.precision(.fractionLength(0))))\(unit)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(current.formatted(.number.precision(.fractionLength(unit == "ms" || unit == "bpm" ? 0 : (unit == "/21" ? 1 : 0)))))
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            chart
                .frame(height: 120)
        }
        .padding(16)
        .cardSurface(20)
    }

    @ViewBuilder private var chart: some View {
        Chart {
            ForEach(points) { p in
                if style == .bar {
                    BarMark(
                        x: .value("Day", p.date, unit: .day),
                        y: .value(title, p.value),
                        width: .fixed(barWidth)
                    )
                    .clipShape(Capsule())
                    .foregroundStyle(zoned ? Theme.recoveryColor(Int(p.value)) : color)
                } else {
                    AreaMark(x: .value("Day", p.date), y: .value(title, p.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", p.date), y: .value(title, p.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(color)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textTertiary).font(.system(size: 10))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                    .foregroundStyle(Theme.textTertiary).font(.system(size: 10))
            }
        }
    }

    private var barWidth: CGFloat { points.count > 14 ? 6 : 12 }
}

struct CorrelationCard: View {
    let tag: String
    let delta: Double

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(delta >= 0 ? Theme.recoveryGreen : Theme.recoveryRed)
                .frame(width: 40, height: 40)
                .background((delta >= 0 ? Theme.recoveryGreen : Theme.recoveryRed).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tag) signal").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Recovery \(delta >= 0 ? "+" : "")\(delta.formatted(.number.precision(.fractionLength(1)))) on tagged days · correlation only")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .cardSurface(18)
    }
}

// MARK: - Device

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ConnectionHero()
                        VStack(spacing: 10) {
                            PillButton(title: model.isScanning ? "Scanning…" : "Scan for Polar Loop", systemImage: "dot.radiowaves.left.and.right", filled: true, tint: Theme.recoveryGreen, busy: model.isScanning) { model.startScan() }
                            HStack(spacing: 10) {
                                PillButton(title: model.isSyncing ? "Syncing…" : "Sync Data", systemImage: "arrow.triangle.2.circlepath", tint: Theme.hrv, busy: model.isSyncing) { model.syncNow() }
                                PillButton(title: model.liveHeartRate == nil ? "Live HR" : "Stop HR", systemImage: "waveform.path.ecg", tint: Theme.rhr) { model.toggleLiveHeartRate() }
                            }
                        }

                        // Scan results appear immediately under the button — no scrolling.
                        if model.isScanning || !model.devices.isEmpty {
                            DiscoveredDevicesCard()
                        }

                        DeviceSetupCard { showingProfile = true }

                        if let status = model.statusLine, !status.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(status)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 4)
                        }

                        DeviceInfoCard()

                        HealthDevicesCard()

                        ChecklistCard(title: "Hardware Checklist", items: [
                            "Install on iPhone with Bluetooth enabled",
                            "Grant Bluetooth permission",
                            "Scan and confirm Polar Loop appears",
                            "Connect and verify battery/device info",
                            "Start live HR while wearing the Loop",
                            "If pairing fails, close Polar Flow and consider factory reset"
                        ])
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Device")
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
    }
}

/// Nearby Polar devices from the live scan — shown directly under the Scan button so results never
/// require scrolling. Tap one to connect.
struct DiscoveredDevicesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Discovered Devices",
                          accessory: model.isScanning ? "scanning…" : (model.devices.isEmpty ? nil : "\(model.devices.count) found"))
            if model.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.recoveryGreen)
                    Text("Searching for nearby Polar hardware…")
                        .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).cardSurface(16)
            } else {
                ForEach(model.devices) { device in
                    Button { model.connect(device) } label: { DeviceRow(device: device) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Other wearables/apps writing to Apple Health (Ultrahuman, Apple Watch, Sleep Cycle, …), listed
/// under Device so the user can see everything feeding the hub and pick one to cross-check the Loop
/// against. Reuses the same source discovery the Trends comparison uses.
struct HealthDevicesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.strainHi)
                SectionHeader(title: "Apple Health Devices",
                              accessory: (model.healthConnected && !model.healthSources.isEmpty) ? "\(model.healthSources.count)" : nil)
                if model.isDiscoveringSources { ProgressView().controlSize(.small).tint(Theme.strainHi) }
            }

            if !HealthKitReader.isAvailable {
                Text("Apple Health isn't available on this device.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else if !model.healthConnected {
                Text("Connect Apple Health to see other wearables syncing here — Ultrahuman, Apple Watch, Sleep Cycle — and pick one to cross-check the Loop against.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                PillButton(title: "Connect Apple Health", systemImage: "heart.text.square.fill", filled: true, tint: Theme.strainHi) {
                    model.connectAppleHealth()
                }
            } else if model.healthSources.isEmpty {
                Text("No other sources are writing to Apple Health yet. Open a wearable's app, enable its Apple Health sync, then rediscover.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                Button { Task { await model.discoverHealthSources() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                        Text("Rediscover").font(.system(size: 12, weight: .semibold))
                    }.foregroundStyle(Theme.strainHi)
                }
            } else {
                ForEach(model.healthSources) { source in
                    Button { model.toggleSource(source.id) } label: {
                        HealthSourceRow(source: source, selected: model.selectedSourceIds.contains(source.id))
                    }
                    .buttonStyle(.plain)
                }
                Text("Tap one to set it as the comparison source used in Trends.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .task {
            if model.healthConnected && model.healthSources.isEmpty {
                await model.discoverHealthSources()
            }
        }
    }
}

/// Shows whether the connected Loop has a user profile written, and opens the profile sheet.
struct DeviceSetupCard: View {
    @EnvironmentObject private var model: AppModel
    let openProfile: () -> Void

    private var connected: Bool { model.connectionState.contains("Connected") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.activity)
                SectionHeader(title: "Device Setup")
            }

            // Status line reflecting the device's first-time-use state.
            Group {
                if !connected {
                    statusRow(icon: "bolt.horizontal.circle", tint: Theme.textTertiary,
                              text: "Connect your Loop to check whether it's set up. You can edit your profile anytime.")
                } else if model.ftuDone == false {
                    statusRow(icon: "exclamationmark.triangle.fill", tint: Theme.recoveryYellow,
                              text: "Your Loop has no user profile yet, so it isn't recording steps or sleep. Add your profile and set it up.")
                } else if model.ftuDone == true {
                    statusRow(icon: "checkmark.seal.fill", tint: Theme.recoveryGreen,
                              text: "Your Loop is set up and recording. Wear it and data syncs in automatically.")
                } else {
                    statusRow(icon: "hourglass", tint: Theme.textTertiary, text: "Checking device setup…")
                }
            }

            if let s = model.setupStatus {
                Text(s).font(.system(size: 12)).foregroundStyle(Theme.recoveryGreen)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PillButton(title: model.hasProfile ? "Profile & Loop Setup" : "Add Your Profile",
                       systemImage: "slider.horizontal.3",
                       filled: model.ftuDone == false,
                       tint: Theme.activity) {
                openProfile()
            }
        }
        .padding(16)
        .cardSurface(20)
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
        }
    }
}

/// Editable physical profile + the "Set up my Loop" action. Stored locally; the relevant
/// subset is written to the device. Birthday/height/weight/etc. drive the Loop's step,
/// calorie, and sleep math (the same data Whoop/Ultrahuman collect at onboarding).
struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = UserProfile()
    @State private var savedTick = false
    @AppStorage(SettingsKey.imperialBodyUnits) private var imperial = false

    private var connected: Bool { model.connectionState.contains("Connected") }

    // Height/weight are always stored metric in `draft`; these bindings convert to/from imperial
    // for display so the underlying profile (and the Loop's first-time-use config) stay in cm/kg.
    private static let lbPerKg = 2.2046226218
    private var totalInches: Int { Int((draft.heightCm / 2.54).rounded()) }
    private var heightFeet: Binding<Int> {
        Binding(get: { totalInches / 12 },
                set: { draft.heightCm = Double($0 * 12 + (totalInches % 12)) * 2.54 })
    }
    private var heightInches: Binding<Int> {
        Binding(get: { totalInches % 12 },
                set: { draft.heightCm = Double((totalInches / 12) * 12 + min(max($0, 0), 11)) * 2.54 })
    }
    private var weightLb: Binding<Double> {
        Binding(get: { (draft.weightKg * Self.lbPerKg).rounded() },
                set: { draft.weightKg = $0 / Self.lbPerKg })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Stored only on this iPhone — never uploaded. Your Loop needs this to compute steps, calories, and sleep.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(1)

                        VStack(spacing: 0) {
                            row("Sex") {
                                Picker("", selection: $draft.sex) {
                                    ForEach(UserProfile.Sex.allCases) { Text($0.label).tag($0) }
                                }.pickerStyle(.menu).tint(Theme.textPrimary)
                            }
                            divider
                            row("Birthday") {
                                DatePicker("", selection: $draft.birthDate, in: ...Date.now, displayedComponents: .date)
                                    .labelsHidden().colorScheme(.dark)
                            }
                            divider
                            row("Units") {
                                Picker("", selection: $imperial) {
                                    Text("cm·kg").tag(false)
                                    Text("ft·lb").tag(true)
                                }.pickerStyle(.segmented).frame(width: 132)
                            }
                            divider
                            if imperial {
                                row("Height") {
                                    HStack(spacing: 6) {
                                        unitIntField(heightFeet, width: 38); unitSuffix("ft")
                                        unitIntField(heightInches, width: 38); unitSuffix("in")
                                    }
                                }
                                divider
                                row("Weight (lb)") { numberField(weightLb) }
                            } else {
                                row("Height (cm)") { numberField($draft.heightCm) }
                                divider
                                row("Weight (kg)") { numberField($draft.weightKg) }
                            }
                            divider
                            row("Resting HR (bpm)") { intField($draft.restingHr) }
                            divider
                            row("Typical day") {
                                Picker("", selection: $draft.typicalDay) {
                                    ForEach(UserProfile.TypicalDay.allCases) { Text($0.label).tag($0) }
                                }.pickerStyle(.menu).tint(Theme.textPrimary)
                            }
                        }
                        .cardSurface(18)

                        PillButton(title: savedTick ? "Saved ✓" : "Save Profile", systemImage: "checkmark.circle", tint: Theme.hrv) {
                            model.saveProfile(draft)
                            savedTick = true
                        }

                        // Device setup
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Set up your Loop")
                            Text(connected
                                 ? "Writes your profile to the Loop and sets its clock. After this, wear it and it starts recording."
                                 : "Connect your Loop on the Device screen first, then come back here to set it up.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            PillButton(title: model.isSettingUpDevice ? "Setting up…" : "Set up my Loop",
                                       systemImage: "checkmark.seal",
                                       filled: true, tint: Theme.activity, busy: model.isSettingUpDevice) {
                                model.saveProfile(draft)
                                savedTick = true
                                model.setUpDevice()
                            }
                            .disabled(!connected || model.isSettingUpDevice)
                            .opacity(connected ? 1 : 0.5)
                            if let s = model.setupStatus {
                                Text(s).font(.system(size: 12)).foregroundStyle(Theme.recoveryGreen)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16).cardSurface(18)
                    }
                    .padding(16).padding(.bottom, 24)
                }
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Theme.hrv)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { draft = model.profile }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func numberField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .frame(width: 90)
    }

    private func intField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .frame(width: 90)
    }

    /// Compact integer field for the feet/inches inputs.
    private func unitIntField(_ value: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: value, format: .number)
            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .frame(width: width)
    }

    private func unitSuffix(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textTertiary)
    }
}

struct ConnectionHero: View {
    @EnvironmentObject private var model: AppModel
    private var connected: Bool { model.connectionState.contains("Connected") }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 130, height: 130)
                Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 96, height: 96)
                Circle()
                    .fill((connected ? Theme.recoveryGreen : Theme.hrv).opacity(0.16))
                    .frame(width: 70, height: 70)
                Image(systemName: connected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(connected ? Theme.recoveryGreen : Theme.hrv)
            }
            .padding(.top, 6)
            VStack(spacing: 4) {
                Text(model.connectionState)
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(model.selectedDevice?.name ?? "No device selected")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            if let battery = model.batteryLevel {
                BatteryGauge(level: battery)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .cardSurface(24)
    }
}

struct BatteryGauge: View {
    let level: Int
    private var color: Color { level > 50 ? Theme.recoveryGreen : (level > 20 ? Theme.temp : Theme.recoveryRed) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Battery", systemImage: "battery.100percent").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(level)%").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * Double(level) / 100))
                }
            }
            .frame(height: 10)
        }
        .padding(.horizontal, 4)
    }
}

struct DeviceInfoCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            StatRow(label: "State", value: model.connectionState)
            Divider().overlay(Theme.hairline)
            StatRow(label: "Device", value: model.selectedDevice?.name ?? "None")
            Divider().overlay(Theme.hairline)
            StatRow(label: "Battery", value: model.batteryLevel.map { "\($0)%" } ?? "—")
            Divider().overlay(Theme.hairline)
            StatRow(label: "Last sync", value: model.lastSyncText)
        }
        .padding(.vertical, 4)
        .cardSurface(18)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct DeviceRow: View {
    let device: WearableDevice
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.hrv)
                .frame(width: 40, height: 40)
                .background(Theme.hrv.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(device.id).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: "wifi", variableValue: signalStrength).font(.system(size: 14)).foregroundStyle(Theme.recoveryGreen)
                Text("\(device.rssi) dBm").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .cardSurface(16)
    }
    private var signalStrength: Double { min(1, max(0.2, Double(device.rssi + 100) / 60)) }
}

struct ChecklistCard: View {
    let title: String
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.recoveryGreen)
                        Text(item).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .cardSurface(18)
        }
    }
}

// MARK: - Profile hub

/// The Profile tab: an Ultrahuman-style hub linking out to profile/device setup, the tag history,
/// data export, and settings, plus the privacy/scope statement. Replaces the old Journal and
/// Export tabs (logging now happens via the Today "+" FAB).
struct ProfileHubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable { case profile, history, export, settings; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 26)).foregroundStyle(Theme.recoveryGreen)
                                .frame(width: 64, height: 64)
                                .background(Theme.recoveryGreen.opacity(0.12), in: Circle())
                            Text(Copy.appName).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            Text("Local-first companion for your Polar Loop")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(20).cardSurface(22)

                        VStack(spacing: 0) {
                            hubRow("person.text.rectangle.fill", "Your Profile & Loop Setup", Theme.activity) { sheet = .profile }
                            divider
                            hubRow("tag.fill", "Tag History", Theme.sleep, badge: "\(model.journalEntries.count)") { sheet = .history }
                            divider
                            hubRow("square.and.arrow.up", "Export Data", Theme.hrv) { sheet = .export }
                            divider
                            hubRow("gearshape.fill", "Settings", Theme.textSecondary) { sheet = .settings }
                        }
                        .cardSurface(18)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.recoveryGreen)
                                SectionHeader(title: "Privacy & Scope")
                            }
                            Text(model.localOnlyCopy)
                                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                        }
                        .padding(16).cardSurface(20)

                        ChecklistCard(title: "Scope", items: [
                            "SQLite is the source of truth",
                            "No backend or cloud account",
                            "HealthKit is optional, behind permissions",
                            "BP, ECG, AFib, and SpO2 are intentionally excluded"
                        ])
                    }
                    .padding(16).padding(.bottom, 24)
                }
            }
            .navigationTitle("Profile")
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $sheet) { which in
                switch which {
                case .profile: ProfileView()
                case .history: JournalHistoryView()
                case .export: ExportView()
                case .settings: SettingsView()
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    private func hubRow(_ icon: String, _ title: String, _ tint: Color, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let badge { Text(badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Journal history

/// Read-only timeline of logged tags/notes, opened from the Profile hub. Adding happens via the
/// Today "+" FAB and `LogSheet`.
struct JournalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Timeline", accessory: "\(model.journalEntries.count) entries")
                        if model.journalEntries.isEmpty {
                            EmptyState(title: "No entries yet", subtitle: "Tap + on Today to tag context like caffeine, travel, or illness. Tagged days line up against your metrics in Trends.")
                        } else {
                            ForEach(model.journalEntries) { entry in
                                JournalRow(entry: entry, color: JournalTags.color(entry.tag))
                            }
                        }
                    }
                    .padding(16).padding(.bottom, 24)
                }
            }
            .navigationTitle("Tag History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(Theme.hrv) } }
        }
        .preferredColorScheme(.dark)
    }
}

struct JournalRow: View {
    let entry: JournalEntry
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.tag.capitalized).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(entry.date.shortDateTime).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .cardSurface(16)
    }
}

// MARK: - Export

struct ExportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Export Data")
                            VStack(spacing: 10) {
                                PillButton(title: "Create JSON Export", systemImage: "curlybraces", filled: true, tint: Theme.hrv) { model.exportJSON() }
                                PillButton(title: "Create Daily CSV", systemImage: "tablecells", tint: Theme.activity) { model.exportCSV() }
                                if let exportURL = model.exportURL {
                                    ShareLink(item: exportURL) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .bold))
                                            Text("Share \(exportURL.lastPathComponent)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                                        .foregroundStyle(Theme.recoveryGreen)
                                        .background(Theme.recoveryGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .cardSurface(20)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.recoveryGreen)
                                SectionHeader(title: "Privacy & Scope")
                            }
                            Text(model.localOnlyCopy)
                                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface(16, fill: Theme.surface)
                        }

                        ChecklistCard(title: "Scope", items: [
                            "SQLite is the source of truth",
                            "No backend or cloud account",
                            "HealthKit can be added behind optional permissions",
                            "BP, ECG, AFib, and SpO2 are intentionally excluded"
                        ])
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(Theme.hrv) } }
        }
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.lowBatteryAlerts) private var lowBatteryAlerts = true
    @AppStorage(SettingsKey.tempUnitFahrenheit) private var tempF = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Notifications")
                            Toggle(isOn: $lowBatteryAlerts) {
                                settingLabel("Low battery alerts", "Get notified when the Loop drops below 20%, 10%, and 5%.")
                            }
                            .tint(Theme.recoveryGreen)
                            .onChange(of: lowBatteryAlerts) { _, on in
                                if on { NotificationManager.requestAuthorization() }
                            }
                        }
                        .padding(16).cardSurface(18)

                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Units")
                            HStack {
                                settingLabel("Temperature", "Skin temperature scale.")
                                Spacer()
                            }
                            Picker("Temperature", selection: $tempF) {
                                Text("°C").tag(false)
                                Text("°F").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(16).cardSurface(18)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 12)).foregroundStyle(Theme.recoveryGreen)
                            Text("Battery alerts are generated on this iPhone from the Loop's Bluetooth readings — nothing is sent to any server.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(16).padding(.bottom, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(Theme.hrv) } }
        }
        .preferredColorScheme(.dark)
    }

    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.hrv)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.system(size: 14)).multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .cardSurface(20)
    }
}

/// Prominent banner shown whenever the dashboard is populated with seeded sample
/// data instead of real numbers synced from a Polar Loop.
struct SampleDataBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.recoveryYellow)
                .frame(width: 38, height: 38)
                .background(Theme.recoveryYellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("SAMPLE DATA")
                    .font(.system(size: 12, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(Theme.recoveryYellow)
                Text("These are example numbers, not your Loop. Connect on the Device tab and tap Sync to replace them with your real data.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.recoveryYellow.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.recoveryYellow.opacity(0.32), lineWidth: 1)
        )
    }
}

/// Shown after a device is connected and the demo data has been cleared, but before the
/// first real sync. A skeleton hint that real graphics will appear once data is synced.
struct AwaitingDataCard: View {
    let connected: Bool

    var body: some View {
        VStack(spacing: 18) {
            // Skeleton ring placeholder.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 16))
                    .frame(width: 150, height: 150)
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(Theme.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 150, height: 150)
                Image(systemName: connected ? "arrow.triangle.2.circlepath" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Two skeleton metric tiles.
            HStack(spacing: 12) {
                SkeletonTile()
                SkeletonTile()
            }
            VStack(spacing: 8) {
                Text(connected ? "Waiting for your first sync" : "No data yet")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(connected
                     ? "Your Loop is connected. Tap Sync Data on the Device tab — once it has activity and sleep recorded, your rings and charts will appear here."
                     : "Connect your Polar Loop on the Device tab, then tap Sync Data. Your real metrics will appear here.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardSurface(24)
    }
}

private struct SkeletonTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)).frame(width: 64, height: 12)
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)).frame(width: 90, height: 26)
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)).frame(width: 76, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(18)
    }
}

/// Side-by-side comparison of the Polar Loop (our SQLite data) against the Ultrahuman ring
/// (read from Apple Health), for the most recent day Ultrahuman has data.
/// Cross-checks the Loop against one OR MORE Apple Health sources at once. Columns: Loop, then each
/// selected source, then an average across the selected sources (when ≥2). Horizontally scrollable
/// so any number of sources fit on a phone.
struct ComparisonCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSources = false

    private let labelW: CGFloat = 116
    private let colW: CGFloat = 66

    private var loopByDay: [String: DailySummary] {
        Dictionary(model.summaries.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// One metric: how to pull it from the Loop and from a Health source, plus display precision.
    private struct Metric {
        let label: String
        let decimals: Int
        let loop: (DailySummary) -> Double?
        let src: (ComparisonDay) -> Double?
    }
    private let metrics: [Metric] = [
        Metric(label: "HRV (ms)", decimals: 0, loop: { $0.hrvMs > 0 ? $0.hrvMs : nil }, src: { $0.hrvMs }),
        Metric(label: "Resting HR", decimals: 0, loop: { $0.restingHeartRate > 0 ? $0.restingHeartRate : nil }, src: { $0.restingHr }),
        Metric(label: "Sleep (h)", decimals: 1, loop: { $0.sleepMinutes > 0 ? Double($0.sleepMinutes) / 60 : nil }, src: { $0.sleepMinutes.map { Double($0) / 60 } }),
        Metric(label: "Steps", decimals: 0, loop: { $0.steps > 0 ? Double($0.steps) : nil }, src: { $0.steps.map(Double.init) }),
        Metric(label: "Energy (kcal)", decimals: 0, loop: { $0.calories > 0 ? Double($0.calories) : nil }, src: { $0.activeEnergy })
    ]

    /// Most recent day any selected source has data for.
    private var latestDay: String? {
        model.selectedSourceIds
            .flatMap { (model.comparisonBySource[$0] ?? []).map(\.dayKey) }
            .max()
    }

    private func sourceDay(_ id: String, _ day: String) -> ComparisonDay? {
        model.comparisonBySource[id]?.first { $0.dayKey == day }
    }

    private func abbrev(_ name: String) -> String {
        let word = name.split(separator: " ").first.map(String.init) ?? name
        return String(word.prefix(6)).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.strainHi)
                SectionHeader(title: "Cross-check")
                if model.isReadingHealth || model.isDiscoveringSources { ProgressView().controlSize(.small).tint(Theme.strainHi) }
            }

            if !HealthKitReader.isAvailable {
                Text("Apple Health isn't available on this device.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else if !model.healthConnected {
                Text("Read other wearables' metrics from Apple Health — an Ultrahuman ring, your Apple Watch, Sleep Cycle, anything syncing — and audit the Loop against them, side by side.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                PillButton(title: "Connect Apple Health", systemImage: "heart.text.square.fill", filled: true, tint: Theme.strainHi) {
                    model.connectAppleHealth()
                }
            } else {
                Button { showingSources = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .bold))
                        Text(model.selectedSources.isEmpty ? "Choose Health sources" : model.selectedSources.map(\.name).joined(separator: ", "))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("\(model.selectedSources.count)/\(model.healthSources.count)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                if let day = latestDay, !model.selectedSources.isEmpty {
                    comparisonTable(day: day)
                } else if !model.selectedSources.isEmpty {
                    Text("No data from the selected source(s) in the last 30 days. Make sure each one's Apple Health sync is on, then refresh.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                } else {
                    Text("Pick one or more Health sources above to cross-check the Loop against them.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                }

                Button { Task { await model.discoverHealthSources(); await model.refreshComparison() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                        Text("Rediscover & refresh").font(.system(size: 12, weight: .semibold))
                    }.foregroundStyle(Theme.strainHi)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .cardSurface(20)
        .sheet(isPresented: $showingSources) { HealthSourcesView() }
    }

    @ViewBuilder
    private func comparisonTable(day: String) -> some View {
        let sources = model.selectedSources
        let loop = loopByDay[day]
        let showAvg = sources.count >= 2
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row.
                HStack(spacing: 0) {
                    Text(day).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: labelW, alignment: .leading)
                    headerCell("LOOP", Theme.recoveryGreen)
                    ForEach(sources) { headerCell(abbrev($0.name), Theme.strainHi) }
                    if showAvg { headerCell("AVG", Theme.hrv) }
                }
                .padding(.bottom, 6)

                ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                    let loopVal = loop.flatMap { m.loop($0) }
                    let srcVals = sources.map { s in sourceDay(s.id, day).flatMap { m.src($0) } }
                    let present = srcVals.compactMap { $0 }
                    let avg = present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
                    HStack(spacing: 0) {
                        Text(m.label).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            .frame(width: labelW, alignment: .leading)
                        valueCell(loopVal, m.decimals)
                        ForEach(Array(srcVals.enumerated()), id: \.offset) { _, v in valueCell(v, m.decimals) }
                        if showAvg { valueCell(avg, m.decimals, accent: Theme.hrv) }
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }
        }
    }

    private func headerCell(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(color)
            .frame(width: colW, alignment: .trailing)
    }

    private func valueCell(_ value: Double?, _ decimals: Int, accent: Color = Theme.textPrimary) -> some View {
        Text(value.map { $0.formatted(.number.precision(.fractionLength(decimals))) } ?? "—")
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .foregroundStyle(accent)
            .frame(width: colW, alignment: .trailing)
    }
}

/// Self-service browser of every app/device syncing to Apple Health, so the user can audit what's
/// flowing in and pick one OR MORE sources to cross-check the Loop against (each source's samples
/// stay isolated; the comparison shows them as separate columns plus an average).
struct HealthSourcesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("These apps and devices are writing to Apple Health on this iPhone. Tap any number of them to cross-check the Loop against — each source stays isolated, shown as its own column plus an average.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(1)

                        if model.isDiscoveringSources {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Discovering sources…").font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
                        } else if model.healthSources.isEmpty {
                            EmptyState(title: "No sources found", subtitle: "Nothing is writing these metrics to Apple Health yet, or read access was denied.")
                        } else {
                            ForEach(model.healthSources) { source in
                                Button { model.toggleSource(source.id) } label: {
                                    HealthSourceRow(source: source, selected: model.selectedSourceIds.contains(source.id))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        PillButton(title: "Rediscover", systemImage: "arrow.clockwise", tint: Theme.strainHi) {
                            Task { await model.discoverHealthSources() }
                        }
                    }
                    .padding(16).padding(.bottom, 24)
                }
            }
            .navigationTitle("Health Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(Theme.hrv) } }
        }
        .preferredColorScheme(.dark)
        .onAppear { if model.healthSources.isEmpty { Task { await model.discoverHealthSources() } } }
    }
}

struct HealthSourceRow: View {
    let source: HealthSource
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(selected ? Theme.recoveryGreen : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(source.metrics.count) metric\(source.metrics.count == 1 ? "" : "s")\(source.feedCount > 1 ? " · \(source.feedCount) feeds" : "")")
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(source.metrics, id: \.self) { metric in
                        Text(metric)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.surfaceHi, in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .cardSurface(16, fill: selected ? Theme.surfaceHi : Theme.surface)
    }
}

/// Push the Loop's synced days into Apple Health. Read access (for the Ultrahuman
/// comparison above) and write access are granted together by "Connect Apple Health".
struct AppleHealthSyncCard: View {
    @EnvironmentObject private var model: AppModel

    private var hasLoopData: Bool {
        model.summaries.contains { $0.steps > 0 || $0.restingHeartRate > 0 || $0.hrvMs > 0 || $0.calories > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.rhr)
                SectionHeader(title: "Apple Health")
                if model.isWritingHealth { ProgressView().controlSize(.small).tint(Theme.rhr) }
            }

            if !HealthKitReader.isAvailable {
                Text("Apple Health isn't available on this device.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else {
                Text("Write your Loop's days into Apple Health — steps, active energy, resting heart rate, and HRV — so the Loop's numbers live alongside everything else in Health.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                PillButton(
                    title: hasLoopData ? "Write Loop Data to Apple Health" : "Sync your Loop first",
                    systemImage: "square.and.arrow.up",
                    filled: hasLoopData,
                    tint: Theme.rhr,
                    busy: model.isWritingHealth
                ) {
                    model.writeToAppleHealth()
                }
                .disabled(!hasLoopData || model.isWritingHealth)
                .opacity(hasLoopData ? 1 : 0.5)
                if let status = model.healthWriteStatus {
                    Text(status)
                        .font(.system(size: 12)).foregroundStyle(Theme.recoveryGreen)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Re-writing the same days replaces those samples rather than duplicating them, and only ever touches data this app wrote.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .cardSurface(20)
    }
}

extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

extension Array where Element == Int {
    var average: Double {
        guard !isEmpty else { return 0 }
        return Double(reduce(0, +)) / Double(count)
    }
}

extension Date {
    var dayKey: String {
        Self.dayFormatter.string(from: self)
    }

    var shortDateTime: String {
        Self.shortFormatter.string(from: self)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
