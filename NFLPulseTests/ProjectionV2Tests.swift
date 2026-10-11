import XCTest
@testable import NFLPulseCore

final class ProjectionV2Tests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    var runner: Player { Player(id: "p1", name: "Same Name", team: "CHI", position: "RB", status: "ACT", espnID: "123") }

    func fixture(position: String = "RB", count: Int = 16) -> Snapshot {
        let player = Player(id: runner.id, name: runner.name, team: runner.team, position: position, status: "ACT", espnID: runner.espnID)
        var games: [Game] = [], stats: [StatLine] = []
        for i in 0..<count {
            let id = "g\(i)"
            games.append(Game(id: id, season: 2025, week: i + 1, kind: "REG", kickoff: start.addingTimeInterval(Double(i) * 7 * 86400), home: "CHI", away: "GB", stadium: "Test", roof: "outdoors", location: "Home", completed: true))
            stats.append(StatLine(playerID: player.id, gameID: id, season: 2025, week: i + 1, team: "CHI", opponent: "GB", position: position, passing: 225, rushing: 60, receiving: 35, receptions: 4, attempts: 30, carries: 12, targets: 6, completions: 20, fieldGoals: i % 2 == 0 ? 0 : 2, fieldGoalAttempts: 2, extraPoints: 3))
        }
        let now = start.addingTimeInterval(Double(count) * 7 * 86400)
        games.append(Game(id: "next", season: 2025, week: count + 1, kind: "REG", kickoff: now.addingTimeInterval(86400), home: "CHI", away: "GB", stadium: "Test", roof: "outdoors", location: "Home", completed: false))
        return Snapshot(fetchedAt: now, season: 2025, players: [player], games: games, stats: stats, injuries: [], sources: [], warnings: [])
    }

    func context(_ data: Snapshot, status: AvailabilityStatus = .out, playerID: String? = "p1", espnID: String? = nil,
                 gameID: String? = "next", age: TimeInterval = 0, reportedAt: Date? = nil) -> LiveContext {
        let report = AvailabilityReport(id: "report", playerID: playerID, espnID: espnID, name: runner.name, team: "CHI", status: status,
            detail: "Official game notice", reportedAt: reportedAt ?? data.fetchedAt.addingTimeInterval(-3600), checkedAt: data.fetchedAt.addingTimeInterval(-age),
            gameID: gameID, source: "ESPN summary", sourceURL: "https://example.test/summary")
        return LiveContext(fetchedAt: data.fetchedAt, reports: [report], news: [], sources: [], warnings: [])
    }

    func testNewCountMetricsByPositionAndRecordedZeros() throws {
        for (position, metrics) in [("RB", [Metric.carries, .targets]), ("QB", [.passAttempts, .completions]), ("K", [.fieldGoals, .fieldGoalAttempts, .extraPoints])] {
            let data = fixture(position: position)
            let player = data.players[0]
            for metric in metrics {
                let projection = try ProjectionEngine(snapshot: data).make(player: player, metric: metric, now: data.fetchedAt)
                XCTAssertTrue(projection.estimate.isFinite)
                XCTAssertGreaterThanOrEqual(projection.estimate, 0)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(projection.low), 0)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(projection.high), try XCTUnwrap(projection.low))
                XCTAssertNotNil(projection.baselineEstimate)
            }
            if position == "K" {
                let projection = try ProjectionEngine(snapshot: data).make(player: player, metric: .fieldGoals, now: data.fetchedAt)
                XCTAssertTrue(projection.recent.contains(0))
                XCTAssertFalse(Metric.carries.supports("K"))
            }
        }
    }

    func testMissingFieldGoalsNeverBecomeZeroAndReduceSample() throws {
        var data = fixture(position: "K")
        for i in 0..<12 { data.stats[i].fieldGoals = nil }
        let projection = try ProjectionEngine(snapshot: data).make(player: data.players[0], metric: .fieldGoals, now: data.fetchedAt)
        XCTAssertEqual(projection.sample, 4)
        XCTAssertEqual(projection.recent.count, 4)
        XCTAssertTrue(projection.recent.contains(0))
        XCTAssertTrue(projection.warnings.contains { $0.contains("se excluyeron") })
        data.stats[12].fieldGoals = nil
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: data.players[0], metric: .fieldGoals, now: data.fetchedAt))
        XCTAssertNil(data.stats[12].observed(.fieldGoals))
        XCTAssertTrue(data.stats[12].value(.fieldGoals).isNaN)
    }

    func testMissingAttemptsCannotInventKickingOpportunities() {
        var data = fixture(position: "K")
        for i in data.stats.indices { data.stats[i].fieldGoalAttempts = nil }
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: data.players[0], metric: .fieldGoals, now: data.fetchedAt))
    }

    func testConstantHistoryUsesReferenceRatherThanClaimingImprovement() throws {
        let data = fixture()
        let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt)
        XCTAssertEqual(projection.estimate, 60, accuracy: 1e-10)
        XCTAssertEqual(projection.estimate, try XCTUnwrap(projection.baselineEstimate), accuracy: 1e-10)
        XCTAssertEqual(projection.defenseFactor, 1)
        XCTAssertTrue(projection.model.contains("referencia"))
        let validation = ProjectionEngine(snapshot: data).validate(metric: .rushing, now: data.fetchedAt)
        XCTAssertEqual(validation.count, 12)
        XCTAssertEqual(validation.mae, 0)
        XCTAssertEqual(validation.bias, 0)
    }

    func testSelectionAndValidationIgnoreAllFutureResults() {
        let original = fixture()
        let cutoff = original.games[12].kickoff
        var modified = original
        for i in 12..<modified.stats.count {
            modified.stats[i].rushing = 1_000_000
            modified.stats[i].carries = 1_000
            modified.games[i].windKmh = 150
            modified.games[i].temperatureC = -50
        }
        let a = ProjectionEngine(snapshot: original), b = ProjectionEngine(snapshot: modified)
        let beforeA = a.history(player: runner.id, team: runner.team, cutoff: cutoff)
        let beforeB = b.history(player: runner.id, team: runner.team, cutoff: cutoff)
        XCTAssertEqual(a.point(beforeA, metric: .rushing, opponent: "GB", cutoff: cutoff), b.point(beforeB, metric: .rushing, opponent: "GB", cutoff: cutoff))
        let va = a.validate(metric: .rushing, now: cutoff), vb = b.validate(metric: .rushing, now: cutoff)
        XCTAssertEqual(va.count, vb.count)
        XCTAssertEqual(va.mae, vb.mae)
        XCTAssertEqual(va.bias, vb.bias)
    }

    func testVolumeEfficiencyIsSelectedOnlyAfterPriorImprovement() throws {
        var data = fixture()
        for i in data.stats.indices { data.stats[i].rushing = i % 2 == 0 ? 40 : 80 }
        let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt)
        XCTAssertTrue(projection.model.contains("volumen"))
        XCTAssertNotEqual(projection.estimate, projection.baselineEstimate)
        data.stats = Array(data.stats.prefix(8))
        // Forecasting the ninth observation has only four prior error comparisons.
        let engine = ProjectionEngine(snapshot: data)
        let cutoff = data.games[8].kickoff
        XCTAssertEqual(engine.point(engine.history(player: runner.id, team: runner.team, cutoff: cutoff), metric: .rushing, opponent: "GB", cutoff: cutoff), 64)
    }

    func testNameOnlyAndWrongGameReportsCannotBlockOrConfirm() throws {
        let data = fixture()
        let engine = ProjectionEngine(snapshot: data)
        let game = data.games.last!
        for reportContext in [context(data, playerID: nil), context(data, playerID: "other"), context(data, gameID: "previous"), context(data, status: .active, gameID: nil)] {
            let assessment = engine.availability(player: runner, game: game, now: data.fetchedAt, context: reportContext)
            XCTAssertEqual(assessment.status, .unknown)
            XCTAssertNoThrow(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: reportContext))
        }
    }

    func testESPNIdentityAndCurrentInjuredReserveBlock() {
        let data = fixture()
        let engine = ProjectionEngine(snapshot: data)
        XCTAssertThrowsError(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: context(data, playerID: nil, espnID: runner.espnID)))
        XCTAssertThrowsError(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: context(data, status: .injuredReserve, gameID: nil)))
        let otherTeam = Player(id: runner.id, name: runner.name, team: "GB", position: "RB", status: "ACT", espnID: runner.espnID)
        XCTAssertEqual(engine.availability(player: otherTeam, game: data.games.last!, now: data.fetchedAt, context: context(data)).status, .unknown)
    }

    func testAllExplicitBlockingStatusesAndSourceDates() {
        let data = fixture()
        for status in [AvailabilityStatus.out, .doubtful, .inactive, .injuredReserve] {
            XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, context: context(data, status: status)))
        }
        let assessment = ProjectionEngine(snapshot: data).availability(player: runner, game: data.games.last!, now: data.fetchedAt, context: context(data))
        XCTAssertEqual(assessment.checkedAt, data.fetchedAt)
        XCTAssertEqual(assessment.reports.count, 1)
        XCTAssertTrue(assessment.warnings.contains { $0.contains("Revisado") })
    }

    func testOldFutureUndatedAndWrongIDReportsAreIgnored() throws {
        let data = fixture()
        let engine = ProjectionEngine(snapshot: data)
        var undated = context(data); undated.reports[0].reportedAt = nil
        var futureContext = context(data); futureContext.fetchedAt = data.fetchedAt.addingTimeInterval(1)
        for reportContext in [context(data, age: 6 * 3600 + 1), context(data, age: -1), context(data, reportedAt: data.fetchedAt.addingTimeInterval(1)), undated, futureContext] {
            XCTAssertEqual(engine.availability(player: runner, game: data.games.last!, now: data.fetchedAt, context: reportContext).status, .unknown)
            XCTAssertNoThrow(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: reportContext))
        }
    }

    func testNearKickoffFreshnessAndOptionalStrictMode() throws {
        var data = fixture(); data.games[data.games.count - 1].kickoff = data.fetchedAt.addingTimeInterval(60 * 60)
        let engine = ProjectionEngine(snapshot: data)
        XCTAssertEqual(engine.availability(player: runner, game: data.games.last!, now: data.fetchedAt, context: context(data, age: 901)).status, .unknown)
        let conditional = try engine.make(player: runner, metric: .rushing, now: data.fetchedAt)
        XCTAssertEqual(conditional.availability?.status, .unknown)
        XCTAssertTrue(conditional.warnings.contains { $0.contains("PARTICIPACIÓN SIN CONFIRMAR") })
        XCTAssertThrowsError(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, requireConfirmedAvailability: true))
        XCTAssertThrowsError(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: context(data, status: .questionable), requireConfirmedAvailability: true))
        XCTAssertNoThrow(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: context(data, status: .active), requireConfirmedAvailability: true))
        let now = data.fetchedAt
        data.fetchedAt = now.addingTimeInterval(-6 * 3600 - 1)
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: now))
    }

    func testWeeklyReportRequiresCurrentWeekKindAndFreshSource() throws {
        var data = fixture()
        data.injuries = [Injury(playerID: runner.id, team: runner.team, week: 17, season: 2025, kind: "REG", status: "Out", practice: "DNP", detail: "Ankle")]
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt))
        data.injuries[0].week = 16
        XCTAssertNoThrow(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt))
        data.injuries[0].week = 17; data.injuries[0].kind = "POST"
        XCTAssertNoThrow(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt))
        data.injuries[0].kind = "REG"
        data.sources = [SourceStamp(name: "Lesiones", url: "https://example.test", checkedAt: data.fetchedAt.addingTimeInterval(-24 * 3600 - 1), rows: 1)]
        XCTAssertNoThrow(try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt))
    }

    func testOldDatedOrUnknownLiveReportCannotSuppressCurrentWeeklyOut() {
        var data = fixture()
        data.injuries = [Injury(playerID: runner.id, team: runner.team, week: 17, season: 2025, kind: "REG", status: "Out", practice: "DNP", detail: "Ankle")]
        for live in [context(data, status: .active, reportedAt: data.fetchedAt.addingTimeInterval(-30 * 86400)), context(data, status: .unknown)] {
            let engine = ProjectionEngine(snapshot: data)
            XCTAssertEqual(engine.availability(player: runner, game: data.games.last!, now: data.fetchedAt, context: live).status, .out)
            XCTAssertThrowsError(try engine.make(player: runner, metric: .rushing, now: data.fetchedAt, context: live))
        }
    }

    func weather(_ data: Snapshot) -> WeatherContext {
        WeatherContext(title: "Pronóstico", detail: "20 °C, viento 35 km/h", checkedAt: data.fetchedAt, temperatureC: 20, windKmh: 35, precipitationProbability: 70, indoor: false,
                       sourceURL: "https://example.test/weather", validAt: data.games.last!.kickoff)
    }

    func testWeatherMissingStaleWrongTimeAndIndoorNeverInventCoefficients() throws {
        var data = fixture()
        let reference = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt)
        var stale = weather(data); stale.checkedAt = data.fetchedAt.addingTimeInterval(-6 * 3600 - 1)
        var future = weather(data); future.checkedAt = data.fetchedAt.addingTimeInterval(1)
        var wrongTime = weather(data); wrongTime.validAt = data.games.last!.kickoff.addingTimeInterval(4 * 3600)
        for forecast in [weather(data), stale, future, wrongTime] {
            let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, weather: forecast)
            XCTAssertEqual(projection.estimate, reference.estimate)
            XCTAssertFalse(projection.adjustments?.contains { $0.name == "Clima" } ?? true)
        }
        data.games[data.games.count - 1].roof = "closed"
        let indoor = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, weather: weather(data))
        XCTAssertEqual(indoor.estimate, reference.estimate)
        XCTAssertTrue(indoor.warnings.contains { $0.contains("Estadio cerrado") })
    }

    func testUnknownRoofAndUnknownIndoorStatusPreserveReference() throws {
        var data = fixture(count: 60)
        for i in data.stats.indices {
            data.games[i].temperatureC = 15; data.games[i].windKmh = i % 2 == 0 ? 0 : 40
            data.stats[i].rushing = i % 2 == 0 ? 100 : 50
        }
        data.games[data.games.count - 1].roof = "unknown"
        var forecast = weather(data); forecast.indoor = nil
        let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, weather: forecast)
        XCTAssertFalse(projection.adjustments?.contains { $0.name == "Clima" } ?? true)
        XCTAssertTrue(projection.warnings.contains { $0.contains("Techo sin confirmar") })
        for i in data.games.indices { data.games[i].roof = "unknown" }
        forecast.indoor = false
        let noTraining = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, weather: forecast)
        XCTAssertFalse(noTraining.adjustments?.contains { $0.name == "Clima" } ?? true)
    }

    func testNewsProvidesEvidenceWithoutConvertingHeadlinesIntoStatus() throws {
        let data = fixture()
        var live = LiveContext(fetchedAt: data.fetchedAt, reports: [], news: [], sources: [], warnings: [])
        live.news = [NewsItem(id: "injury", title: "Same Name ruled out?", summary: "Rumor", url: "https://example.test/news", publishedAt: data.fetchedAt, source: "Test", playerIDs: [runner.id], teams: [runner.team]),
                     NewsItem(id: "future", title: "Future news", summary: "", url: "https://example.test/future", publishedAt: data.fetchedAt.addingTimeInterval(1), source: "Test", playerIDs: [runner.id], teams: [runner.team])]
        let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, context: live)
        XCTAssertEqual(projection.estimate, 60)
        XCTAssertEqual(projection.availability?.status, .unknown)
        XCTAssertEqual(projection.context?.news.map(\.id), ["injury"])
        XCTAssertTrue(projection.warnings.contains { $0.contains("titulares no confirman") })
        XCTAssertEqual(projection.scenarios?.first { $0.name == "No participa" }?.estimate, 0)
    }

    func testLearnedClimateNeedsTemporalEvidenceAndCapsExtrapolation() throws {
        var data = fixture(count: 60)
        for i in data.stats.indices {
            data.games[i].temperatureC = 15
            data.games[i].windKmh = i % 2 == 0 ? 0 : 40
            data.stats[i].rushing = i % 2 == 0 ? 100 : 50
        }
        var forecast = weather(data); forecast.temperatureC = 15; forecast.windKmh = 40
        let projection = try ProjectionEngine(snapshot: data).make(player: runner, metric: .rushing, now: data.fetchedAt, weather: forecast)
        let adjustment = try XCTUnwrap(projection.adjustments?.first { $0.name == "Clima" })
        XCTAssertGreaterThanOrEqual(adjustment.evidenceCount, 12)
        XCTAssertLessThan(adjustment.factor, 1)
        XCTAssertGreaterThanOrEqual(adjustment.factor, 0.85)
        XCTAssertLessThanOrEqual(adjustment.factor, 1.15)
        XCTAssertTrue(projection.warnings.contains { $0.contains("no están calibrados") })
        XCTAssertTrue(projection.warnings.contains { $0.contains("Su cobertura publicada no valida") })
    }
}
