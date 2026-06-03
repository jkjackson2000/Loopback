import XCTest
@testable import Loopback

final class MetricsEngineTests: XCTestCase {
    func testSleepScoreRewardsEnoughSleep() {
        let good = MetricsEngine.sleepScore(durationMinutes: 480, consistencyDeltaMinutes: 10, interruptions: 1)
        let short = MetricsEngine.sleepScore(durationMinutes: 300, consistencyDeltaMinutes: 60, interruptions: 5)
        XCTAssertGreaterThan(good, 85)
        XCTAssertLessThan(short, good)
    }

    func testRecoveryScoreMovesWithHRVAndRHR() {
        var history: [DailySummary] = []
        for offset in 1...14 {
            history.append(summary(dayOffset: offset, recovery: 70, sleep: 78, strain: 45, rhr: 58, hrv: 60, temp: 0.0))
        }
        let strong = summary(dayOffset: 0, recovery: 0, sleep: 86, strain: 35, rhr: 54, hrv: 74, temp: 0.0)
        let weak = summary(dayOffset: 0, recovery: 0, sleep: 62, strain: 78, rhr: 64, hrv: 44, temp: 0.7)
        XCTAssertGreaterThan(MetricsEngine.recoveryScore(today: strong, history: history), MetricsEngine.recoveryScore(today: weak, history: history))
    }

    func testStrainScoreUsesHeartRateLoad() {
        let easy = (0..<20).map { _ in HeartRateSample(timestamp: .now, bpm: 70, rrMs: []) }
        let hard = (0..<20).map { _ in HeartRateSample(timestamp: .now, bpm: 142, rrMs: []) }
        XCTAssertGreaterThan(MetricsEngine.strainScore(samples: hard, restingHeartRate: 55), MetricsEngine.strainScore(samples: easy, restingHeartRate: 55))
    }
}

final class LocalStoreTests: XCTestCase {
    func testSQLiteRoundTrip() throws {
        let store = try LocalStore.temporary()
        let daily = summary(dayOffset: 0, recovery: 81, sleep: 88, strain: 42, rhr: 55, hrv: 72, temp: 0.1)
        let hr = HeartRateSample(timestamp: .now, bpm: 64, rrMs: [900, 920])
        let journal = JournalEntry(date: .now, tag: "caffeine", note: "Morning")

        try store.save([daily])
        try store.save([hr])
        try store.save([journal])

        XCTAssertEqual(try store.fetchDailySummaries(limit: 10), [daily])
        XCTAssertEqual(try store.fetchHeartRateSamples(limit: 10).first?.bpm, 64)
        XCTAssertEqual(try store.fetchJournalEntries(limit: 10).first?.tag, "caffeine")
    }

    func testExportWritesFiles() throws {
        let store = try LocalStore.temporary()
        try store.save(MockDataFactory.payload(days: 3).dailySummaries)
        let service = ExportService(store: store)

        let json = try service.writeJSONExport()
        let csv = try service.writeDailyCSVExport()

        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        XCTAssertTrue(try String(contentsOf: csv).contains("recovery"))
    }
}

final class MockPolarClientTests: XCTestCase {
    func testMockClientScansConnectsAndSyncs() async throws {
        let client = MockPolarClient()
        try await client.startScan()

        let device = try await firstDiscoveredDevice(from: client.events)
        try await client.connect(device)
        let payload = try await client.syncLatest()

        XCTAssertEqual(device.name, "Polar Loop Mock")
        XCTAssertGreaterThan(payload.dailySummaries.count, 20)
        XCTAssertFalse(payload.heartRateSamples.isEmpty)
    }

    private func firstDiscoveredDevice(from stream: AsyncStream<PolarClientEvent>) async throws -> WearableDevice {
        for await event in stream {
            if case .discovered(let device) = event {
                return device
            }
        }
        throw AppError.message("No discovered device")
    }
}

private func summary(
    dayOffset: Int,
    recovery: Int,
    sleep: Int,
    strain: Int,
    rhr: Double,
    hrv: Double,
    temp: Double
) -> DailySummary {
    let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Calendar.current.startOfDay(for: .now)) ?? .now
    return DailySummary(
        dayKey: date.dayKey,
        date: date,
        recoveryScore: recovery,
        sleepScore: sleep,
        strainScore: strain,
        sleepMinutes: 430,
        activeMinutes: 55,
        restingHeartRate: rhr,
        hrvMs: hrv,
        skinTempDeltaC: temp,
        calories: 2_200,
        steps: 8_400
    )
}
