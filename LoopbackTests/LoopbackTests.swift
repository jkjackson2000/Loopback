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

    func testRecoveryScoreIgnoresMissingVitalsInBaseline() {
        var history: [DailySummary] = []
        for offset in 1...10 {
            history.append(summary(dayOffset: offset, recovery: 70, sleep: 78, strain: 45, rhr: 0, hrv: 0, temp: 0.0))
        }
        let today = summary(dayOffset: 0, recovery: 0, sleep: 82, strain: 42, rhr: 58, hrv: 64, temp: 0.0)

        XCTAssertGreaterThan(MetricsEngine.recoveryScore(today: today, history: history), 55)
    }

    func testSleepConsistencyUsesCircularBedtimeDistance() {
        var history: [DailySummary] = []
        for offset in 1...5 {
            var row = summary(dayOffset: offset, recovery: 70, sleep: 80, strain: 40, rhr: 58, hrv: 60, temp: 0.0)
            row.sleepStart = Calendar.current.startOfDay(for: row.date).addingTimeInterval(23 * 3_600 + 50 * 60)
            history.append(row)
        }
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(10 * 60)

        XCTAssertLessThan(MetricsEngine.sleepConsistencyDeltaMinutes(sleepStart: start, history: history), 30)
    }

    func testStrainScoreUsesHeartRateLoad() {
        let easy = (0..<20).map { _ in HeartRateSample(timestamp: .now, bpm: 70, rrMs: []) }
        let hard = (0..<20).map { _ in HeartRateSample(timestamp: .now, bpm: 142, rrMs: []) }
        XCTAssertGreaterThan(MetricsEngine.strainScore(samples: hard, restingHeartRate: 55), MetricsEngine.strainScore(samples: easy, restingHeartRate: 55))
    }

    func testCircadianPlanUsesRecentSleepAnchors() throws {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 10))!
        var rows: [DailySummary] = []
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: base))!
            var row = summary(dayOffset: offset, recovery: 75, sleep: 82, strain: 35, rhr: 57, hrv: 65, temp: 0.0)
            row.date = day
            row.dayKey = day.dayKey
            row.sleepStart = day.addingTimeInterval(-45 * 60)
            row.sleepEnd = day.addingTimeInterval(7 * 3_600 + 15 * 60)
            rows.append(row)
        }

        let plan = try XCTUnwrap(CircadianEngine.plan(summaries: rows, now: base))

        XCTAssertEqual(plan.phase, .daytimeAnchor)
        XCTAssertEqual(Calendar.current.component(.hour, from: plan.caffeineCutoff), 17)
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

    func testHeartRateDayQueryUsesRequestedDayAndLimit() throws {
        let store = try LocalStore.temporary()
        let start = Calendar.current.startOfDay(for: .now)
        let target = start.dayKey
        var samples: [HeartRateSample] = []
        for minute in 0..<900 {
            samples.append(HeartRateSample(timestamp: start.addingTimeInterval(Double(minute) * 60), bpm: 60 + minute % 40, rrMs: []))
        }
        samples.append(HeartRateSample(timestamp: start.addingTimeInterval(-3_600), bpm: 101, rrMs: []))
        try store.save(samples)

        let fetched = try store.fetchHeartRateSamples(onDay: target, limit: 600)

        XCTAssertEqual(fetched.count, 600)
        XCTAssertTrue(fetched.allSatisfy { $0.timestamp.dayKey == target })
        XCTAssertEqual(fetched.first?.timestamp, start.addingTimeInterval(300 * 60))
    }

    func testSeedRefreshesLegacySampleDataWithoutSleepAnchors() throws {
        let store = try LocalStore.temporary()
        let legacy = summary(dayOffset: 0, recovery: 70, sleep: 80, strain: 45, rhr: 58, hrv: 60, temp: 0.0)
        try store.save([legacy], source: "sample")

        try store.seedIfNeeded()

        let rows = try store.fetchDailySummaries(limit: 40)
        XCTAssertGreaterThan(rows.count, 20)
        XCTAssertTrue(rows.allSatisfy { $0.sleepStart != nil && $0.sleepEnd != nil })
    }

    func testSleepCorrectionAppliesWithoutMutatingRawSummary() throws {
        let store = try LocalStore.temporary()
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(-45 * 60)
        let end = start.addingTimeInterval(405 * 60)
        var daily = summary(dayOffset: 0, recovery: 70, sleep: 80, strain: 45, rhr: 58, hrv: 60, temp: 0.0)
        daily.sleepStart = start
        daily.sleepEnd = end
        daily.sleepMinutes = 405
        try store.save([daily])

        let correctedStart = start.addingTimeInterval(-30 * 60)
        let correctedEnd = end.addingTimeInterval(45 * 60)
        try store.save(SleepCorrection(dayKey: daily.dayKey, sleepStart: correctedStart, sleepEnd: correctedEnd))

        let adjusted = try XCTUnwrap(store.fetchDailySummaries(limit: 1).first)
        let raw = try XCTUnwrap(store.fetchDailySummaries(limit: 1, applyingSleepCorrections: false).first)

        XCTAssertTrue(adjusted.sleepAdjusted)
        XCTAssertEqual(adjusted.sleepMinutes, 480)
        XCTAssertEqual(adjusted.rawSleepMinutes, 405)
        XCTAssertEqual(adjusted.rawSleepStart, start)
        XCTAssertEqual(raw.sleepMinutes, 405)
        XCTAssertFalse(raw.sleepAdjusted)

        try store.deleteSleepCorrection(dayKey: daily.dayKey)
        let reset = try XCTUnwrap(store.fetchDailySummaries(limit: 1).first)
        XCTAssertFalse(reset.sleepAdjusted)
        XCTAssertEqual(reset.sleepMinutes, 405)
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
