import Foundation
import XCTest
@testable import NFLPulseCore

/// Explicitly opt in: these tests download REAL source files, never synthetic projections.
final class LiveSourceTests: XCTestCase {
    func testPublishedStatisticsAndChronologicalValidation() async throws {
        guard ProcessInfo.processInfo.environment["NFLPULSE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Network audit is optional; set NFLPULSE_LIVE_TESTS=1 to execute.")
        }
        let now = Date()
        let snapshot = try await DataService().refresh(now: now)
        XCTAssertFalse(snapshot.players.isEmpty)
        XCTAssertFalse(snapshot.stats.isEmpty)
        XCTAssertTrue(snapshot.players.contains { ["K", "PK"].contains($0.position) })
        XCTAssertTrue(snapshot.stats.contains { $0.observed(.fieldGoals) != nil })
        let engine = ProjectionEngine(snapshot: snapshot)
        var reports: [[String: Any]] = []
        for metric in Metric.allCases {
            let report = engine.validate(metric: metric, now: now)
            XCTAssertGreaterThan(report.count, 0, "No examples evaluated for \(metric.rawValue)")
            XCTAssertTrue(report.mae?.isFinite == true)
            XCTAssertTrue(report.baselineMAE?.isFinite == true)
            reports.append([
                "metric": metric.rawValue, "count": report.count,
                "mae": report.mae as Any? ?? NSNull(),
                "last5MAE": report.baselineMAE as Any? ?? NSNull(),
                "intervalCount": report.intervalCount,
                "observedCoverage": report.coverage as Any? ?? NSNull(),
                "bias": report.bias as Any? ?? NSNull()
            ])
        }
        var projections = 0
        for metric in Metric.allCases {
            for player in snapshot.players where metric.supports(player.position) {
                if let projection = try? engine.make(player: player, metric: metric, now: now) {
                    XCTAssertTrue(projection.estimate.isFinite)
                    XCTAssertLessThan(projection.createdAt, projection.game.kickoff)
                    if metric.isCount { XCTAssertGreaterThanOrEqual(projection.estimate, 0) }
                    projections += 1
                    break
                }
            }
        }
        XCTAssertGreaterThan(projections, 0, "No real player can be projected using published sources")
        if let output = ProcessInfo.processInfo.environment["NFLPULSE_AUDIT_OUTPUT"] {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let sourceData = try encoder.encode(snapshot.sources)
            let sources = try JSONSerialization.jsonObject(with: sourceData)
            let report: [String: Any] = [
                "version": "0.2.0", "checkedAt": ISO8601DateFormatter().string(from: now),
                "scope": "Executed Swift core, published retrospective files; conditional on observed stat rows. Does not evaluate iPhone UI, news, injuries as-of, or forecast weather accuracy.",
                "season": snapshot.season, "players": snapshot.players.count,
                "statRows": snapshot.stats.count, "projectionMetricsExercised": projections,
                "sources": sources, "warnings": snapshot.warnings,
                "validation": reports
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

extension LiveSourceTests {
    func testLiveWeatherAndContextReaders() async throws {
        guard ProcessInfo.processInfo.environment["NFLPULSE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live weather/news checks require NFLPULSE_LIVE_TESTS=1.")
        }
        let now = Date()
        let snapshot = try await DataService().refresh(now: now)
        let nextGames = snapshot.games.filter {
            !$0.completed && $0.kickoff > now && $0.kickoff.timeIntervalSince(now) < 14 * 86400
                && $0.location.lowercased() == "home" && $0.roof.lowercased() == "outdoors"
        }.sorted { $0.kickoff < $1.kickoff }
        let game = try XCTUnwrap(nextGames.first)
        let player = try XCTUnwrap(snapshot.players.first { $0.team == game.home && $0.espnID != nil })
        async let weather = WeatherService.fetch(game: game, now: now)
        async let context = LiveContextService.fetch(player: player, game: game, now: now)
        let results = await (weather, context)
        XCTAssertNotNil(results.0.checkedAt, results.0.detail)
        XCTAssertNotNil(results.0.windKmh)
        XCTAssertNotNil(results.0.temperatureC)
        XCTAssertNotNil(results.0.validAt)
        XCTAssertGreaterThanOrEqual(results.1.sources.count, 3, results.1.warnings.joined(separator: "; "))
        XCTAssertFalse(results.1.warnings.contains { $0.contains("cambió el formato") }, results.1.warnings.joined(separator: "; "))
        XCTAssertTrue(results.1.reports.allSatisfy { $0.espnID == player.espnID && ($0.gameID == game.id || $0.status == .injuredReserve) })
        if let output = ProcessInfo.processInfo.environment["NFLPULSE_CONTEXT_AUDIT_OUTPUT"] {
            struct Audit: Encodable {
                var checkedAt: Date
                var player: Player
                var game: Game
                var weather: WeatherContext
                var context: LiveContext
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Audit(checkedAt: now, player: player, game: game, weather: results.0, context: results.1))
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
