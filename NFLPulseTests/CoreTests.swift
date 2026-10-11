import XCTest
@testable import NFLPulseCore

final class CoreTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    var player: Player { Player(id: "p1", name: "Jugador de prueba", team: "CHI", position: "RB", status: "ACT") }

    func fixture() -> Snapshot {
        var games: [Game] = [], stats: [StatLine] = []
        for i in 0..<12 {
            let id = "game-\(i)"
            games.append(Game(id: id, season: 2025, week: i + 1, kind: "REG", kickoff: start.addingTimeInterval(Double(i) * 7 * 86400), home: "CHI", away: "GB", stadium: "Test", roof: "outdoors", location: "Home", completed: true))
            stats.append(StatLine(playerID: "p1", gameID: id, season: 2025, week: i + 1, team: "CHI", opponent: "GB", position: "RB", passing: 0, rushing: Double(20 + i * 5), receiving: Double(10 + i), receptions: Double(i % 5), attempts: 0, carries: 12, targets: 5))
        }
        let now = start.addingTimeInterval(12 * 7 * 86400)
        games.append(Game(id: "next", season: 2025, week: 13, kind: "REG", kickoff: now.addingTimeInterval(86400), home: "CHI", away: "GB", stadium: "Test", roof: "outdoors", location: "Home", completed: false))
        return Snapshot(fetchedAt: now, season: 2025, players: [player], games: games, stats: stats, injuries: [], sources: [], warnings: [])
    }

    func testCSVQuotedCommaNewlineAndBOM() throws {
        let rows = try CSV.parse("\u{FEFF}id,name,note\r\n1,\"Doe, John\",\"line one\nline \"\"two\"\"\"\r\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"], "Doe, John")
        XCTAssertEqual(rows[0]["note"], "line one\nline \"two\"")
        XCTAssertThrowsError(try CSV.parse("id,name\n1,\"unfinished"))
        XCTAssertThrowsError(try CSV.parse("id,name\n1,Joe,extra"))
    }

    func testWeightedMeanAndZeros() {
        let engine = ProjectionEngine(snapshot: fixture())
        XCTAssertEqual(engine.weightedMean([0, 10]), 10 / 1.85, accuracy: 1e-10)
        XCTAssertEqual(engine.weightedMean([0, 0]), 0)
    }

    func testNoFutureLeakage() {
        let original = fixture()
        let cutoff = original.games[8].kickoff
        let a = ProjectionEngine(snapshot: original)
        var changed = original
        for i in 8..<12 { changed.stats[i].rushing = 99999 }
        let b = ProjectionEngine(snapshot: changed)
        let ha = a.history(player: player.id, team: player.team, cutoff: cutoff)
        let hb = b.history(player: player.id, team: player.team, cutoff: cutoff)
        XCTAssertEqual(ha.count, 8)
        XCTAssertEqual(a.point(ha, metric: .rushing, opponent: "GB", cutoff: cutoff),
                       b.point(hb, metric: .rushing, opponent: "GB", cutoff: cutoff), accuracy: 1e-10)
    }

    func testProjectionAndZeroPreservation() throws {
        let data = fixture()
        let p = try ProjectionEngine(snapshot: data).make(player: player, metric: .receptions, now: data.fetchedAt)
        XCTAssertEqual(p.sample, 12)
        XCTAssertTrue(p.recent.contains(0))
        XCTAssertNotNil(p.low)
        XCTAssertGreaterThanOrEqual(p.low!, 0)
        XCTAssertGreaterThanOrEqual(p.high!, p.low!)
        XCTAssertEqual(p.game.id, "next")
    }

    func testStaleDownloadAndOutBlock() {
        var data = fixture()
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: player, metric: .rushing, now: data.fetchedAt.addingTimeInterval(86401)))
        data.injuries = [Injury(playerID: player.id, team: player.team, week: 13, season: 2025, kind: "REG", status: "Out", practice: "DNP", detail: "Ankle")]
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: player, metric: .rushing, now: data.fetchedAt))
    }

    func testPreviousWeeksInjuryDoesNotBlock() throws {
        var data = fixture()
        data.injuries = [Injury(playerID: player.id, team: player.team, week: 10, season: 2025, kind: "REG", status: "Out", practice: "DNP", detail: "Ankle")]
        XCTAssertNoThrow(try ProjectionEngine(snapshot: data).make(player: player, metric: .rushing, now: data.fetchedAt))
    }

    func testInsufficientHistoryAndUnsupportedMetric() {
        var data = fixture(); data.stats = Array(data.stats.suffix(3))
        XCTAssertThrowsError(try ProjectionEngine(snapshot: data).make(player: player, metric: .rushing, now: data.fetchedAt))
        XCTAssertThrowsError(try ProjectionEngine(snapshot: fixture()).make(player: player, metric: .passing, now: fixture().fetchedAt))
    }

    func testKickoffUsesEasternDaylightSaving() throws {
        let row = ["game_id": "test", "season": "2026", "week": "4", "game_type": "REG", "gameday": "2026-10-04", "gametime": "13:00", "home_team": "CHI", "away_team": "GB"]
        let game = try XCTUnwrap(DataService.game(row))
        XCTAssertEqual(ISO8601DateFormatter().string(from: game.kickoff), "2026-10-04T17:00:00Z")
    }

    func testNeutralVenueHasNoAssumedHomeWeather() async {
        var game = fixture().games.last!; game.location = "Neutral"
        let weather = await WeatherService.fetch(game: game, now: fixture().fetchedAt)
        XCTAssertEqual(weather.title, "Ubicación por confirmar")
        XCTAssertNil(weather.checkedAt)
    }

    func testJSONRoundTrip() throws {
        let data = fixture()
        let recovered = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(recovered.stats.count, 12)
        XCTAssertEqual(recovered.players.first?.id, player.id)
    }
}
