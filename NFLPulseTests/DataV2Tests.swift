import XCTest
@testable import NFLPulseCore

/// Synthetic fixtures, shaped after the audited nflverse/ESPN/Open-Meteo schemas.
/// These tests do not claim that these fictional athletes/news represent live data.
final class DataV2Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_800_000)
    var player: Player { Player(id: "synthetic-gsis", name: "Synthetic Runner", team: "CHI", position: "RB", status: "ACT", espnID: "12345") }
    var game: Game { Game(id: "synthetic-game", season: 2026, week: 5, kind: "REG", kickoff: now.addingTimeInterval(7200), home: "CHI", away: "GB", stadium: "Synthetic Stadium", roof: "outdoors", location: "Home", completed: false) }
    var statRow: [String: String] {
        ["player_id": "synthetic-kicker", "game_id": "synthetic-game", "season": "2026", "week": "5", "position": "K", "team": "CHI", "opponent_team": "GB",
         "passing_yards": "0", "rushing_yards": "0", "receiving_yards": "0", "receptions": "0", "attempts": "0", "carries": "0", "targets": "0", "fg_made": "0", "fg_att": "1", "pat_made": "3", "completions": "0"]
    }
    func event(_ game: Game? = nil) -> [String: Any] {
        let game = game ?? self.game
        return ["id": "999999", "date": ISO8601DateFormatter().string(from: game.kickoff), "season": ["year": game.season], "week": ["number": game.week],
                "competitions": [["competitors": [["team": ["abbreviation": game.home]], ["team": ["abbreviation": game.away]]]]]]
    }
    func injuries(status: String = "Out", date: Date? = nil) -> [String: Any] {
        ["season": ["year": game.season], "timestamp": ISO8601DateFormatter().string(from: now),
         "injuries": [["id": "3", "displayName": "Synthetic Team", "injuries": [["id": "report-id", "status": status,
             "date": ISO8601DateFormatter().string(from: date ?? now.addingTimeInterval(-1800)),
             "athlete": ["displayName": player.name, "links": [["href": "https://www.espn.com/nfl/player/_/id/12345/synthetic-runner"]], "team": ["id": "3"], "status": ["name": "Active"]]]]]]]
    }

    func testKickersAndZeroAreObservedButMissingNewMetricsStayUnknown() throws {
        let row = try XCTUnwrap(DataService.stat(statRow))
        XCTAssertEqual(row.observed(.fieldGoals), 0)
        XCTAssertEqual(row.observed(.fieldGoalAttempts), 1)
        XCTAssertEqual(row.observed(.extraPoints), 3)
        var missing = statRow; missing["fg_made"] = ""; missing["completions"] = nil
        let absent = try XCTUnwrap(DataService.stat(missing))
        XCTAssertNil(absent.observed(.fieldGoals)); XCTAssertNil(absent.observed(.completions))
        XCTAssertTrue(absent.value(.fieldGoals).isNaN)
        missing["fg_made"] = "Infinity"
        XCTAssertNil(DataService.stat(missing)?.observed(.fieldGoals))
        missing["fg_made"] = "-1"
        XCTAssertNil(DataService.stat(missing)?.observed(.fieldGoals))
        missing["fg_made"] = "1.5"
        XCTAssertNil(DataService.stat(missing)?.observed(.fieldGoals))
    }
    func testRosterCrosswalkIncludesKickersAndDoesNotGuessIDs() throws {
        let row = ["gsis_id": "synthetic", "full_name": "Synthetic Kicker", "position": "PK", "team": "CHI", "status": "ACT", "espn_id": "12345.0"]
        XCTAssertEqual(try XCTUnwrap(DataService.player(row)).espnID, "12345")
        var bad = row; bad["espn_id"] = "NaN"
        XCTAssertNil(DataService.player(bad)?.espnID)
        bad["gsis_id"] = ""; XCTAssertNil(DataService.player(bad))
    }
    func testHistoricalScheduleUnitsAreConvertedWithFiniteChecks() throws {
        var row = ["game_id": "synthetic", "season": "2026", "week": "5", "game_type": "REG", "gameday": "2026-10-11", "gametime": "13:00", "home_team": "CHI", "away_team": "GB", "temp": "50", "wind": "10", "home_score": "0", "away_score": "3"]
        let parsed = try XCTUnwrap(DataService.game(row))
        XCTAssertEqual(try XCTUnwrap(parsed.temperatureC), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(parsed.windKmh), 16.09344, accuracy: 0.0001)
        XCTAssertTrue(parsed.completed)
        row["temp"] = "NaN"; row["wind"] = "-1"; row["home_score"] = "pending"
        let unavailable = try XCTUnwrap(DataService.game(row))
        XCTAssertNil(unavailable.temperatureC); XCTAssertNil(unavailable.windKmh); XCTAssertFalse(unavailable.completed)
    }
    func testSchemaFailuresAreExplicit() throws {
        XCTAssertThrowsError(try CSV.require([["player_id": "synthetic"]], ["fg_att"], source: "synthetic stats"))
        XCTAssertThrowsError(try LiveContextService.matchEvent(["events": "changed"], game: game))
        XCTAssertThrowsError(try LiveContextService.parseInjuries(["injuries": []], player: player, game: game, checkedAt: now, now: now))
        XCTAssertThrowsError(try LiveContextService.parseNews(["articles": "changed"], player: player, now: now))
    }
    func testESPNMatchRequiresBothTeamsTimeSeasonAndWeek() throws {
        let valid = event()
        XCTAssertEqual(try LiveContextService.matchEvent(["events": [valid]], game: game), "999999")
        for mutation in ["season", "week", "date", "teams"] {
            var changed = valid
            switch mutation {
            case "season": changed["season"] = ["year": 2025]
            case "week": changed["week"] = ["number": 4]
            case "date": changed["date"] = ISO8601DateFormatter().string(from: game.kickoff.addingTimeInterval(301))
            default: changed["competitions"] = [["competitors": [["team": ["abbreviation": "CHI"]], ["team": ["abbreviation": "NYG"]]]]]
            }
            XCTAssertThrowsError(try LiveContextService.matchEvent(["events": [changed]], game: game), mutation)
        }
        XCTAssertThrowsError(try LiveContextService.matchEvent(["events": [valid, valid]], game: game))
    }
    func testLeagueLiveSchemaResolvesIDOnlyFromOfficialLinkAndInjuryStatus() throws {
        let reports = try LiveContextService.parseInjuries(injuries(), player: player, game: game, checkedAt: now, now: now)
        XCTAssertEqual(reports.count, 1); XCTAssertEqual(reports.first?.espnID, player.espnID)
        XCTAssertEqual(reports.first?.status, .out) // athlete.status=Active is a general roster classification.
        XCTAssertEqual(reports.first?.gameID, game.id)
        XCTAssertNil(LiveContextService.athleteID(["links": [["href": "https://evil.example/nfl/player/_/id/12345/test"]]]))
        XCTAssertNil(LiveContextService.athleteID(["links": [["href": "https://www.espn.com/nfl/player/fake/id/12345/test"]]]))
        XCTAssertNil(LiveContextService.athleteID(["links": [["href": "https://www.espn.com/nfl/player/_/id/12345/test"], ["href": "https://www.espn.com/nfl/player/_/id/67890/test"]]]))
        XCTAssertNil(LiveContextService.athleteID(["displayName": player.name]))
    }
    func testHistoricalOrUndatedInjuryCannotBeAssignedToUpcomingGame() throws {
        XCTAssertTrue(try LiveContextService.parseInjuries(injuries(date: now.addingTimeInterval(-180 * 86400)), player: player, game: game, checkedAt: now, now: now).isEmpty)
        var payload = injuries()
        var groups = try XCTUnwrap(payload["injuries"] as? [[String: Any]])
        var entries = try XCTUnwrap(groups[0]["injuries"] as? [[String: Any]])
        entries[0]["date"] = nil; groups[0]["injuries"] = entries; payload["injuries"] = groups
        XCTAssertTrue(try LiveContextService.parseInjuries(payload, player: player, game: game, checkedAt: now, now: now).isEmpty)
        let ir = try LiveContextService.parseInjuries(injuries(status: "Injured Reserve"), player: player, game: game, checkedAt: now, now: now)
        XCTAssertEqual(ir.first?.status, .injuredReserve); XCTAssertNil(ir.first?.gameID)
    }
    func testNoInjuryNeverProvesHealthyAndSourceClockIsPreserved() throws {
        var payload = injuries(); payload["injuries"] = [["id": "3", "injuries": []]]
        XCTAssertTrue(try LiveContextService.parseInjuries(payload, player: player, game: game, checkedAt: now, now: now).isEmpty)
        payload["timestamp"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-901))
        XCTAssertThrowsError(try LiveContextService.parseInjuries(payload, player: player, game: game, checkedAt: now, now: now))
        XCTAssertFalse(LiveContextService.fresh(now.addingTimeInterval(-901), now: now, game: game))
        XCTAssertFalse(LiveContextService.fresh(now.addingTimeInterval(61), now: now, game: game))
        let upstream = now.addingTimeInterval(-600)
        var fresh = injuries(); fresh["timestamp"] = ISO8601DateFormatter().string(from: upstream)
        XCTAssertEqual(try LiveContextService.parseInjuries(fresh, player: player, game: game, checkedAt: now, now: now).first?.checkedAt, upstream)
    }
    func testSummaryRequiresExactGameAndExplicitGameRosterStatus() throws {
        var header = event(); header["week"] = game.week
        let roster: [String: Any] = ["team": ["abbreviation": "CHI"], "roster": [["athlete": ["id": "12345", "status": ["name": "Active"]]]]]
        var payload: [String: Any] = ["header": header, "rosters": [roster]]
        XCTAssertTrue(try LiveContextService.parseSummary(payload, eventID: "999999", player: player, game: game, checkedAt: now, now: now).isEmpty)
        payload["rosters"] = [["team": ["abbreviation": "CHI"], "roster": [["athlete": ["id": "12345"], "active": true]]]]
        XCTAssertEqual(try LiveContextService.parseSummary(payload, eventID: "999999", player: player, game: game, checkedAt: now, now: now).first?.status, .active)
        XCTAssertThrowsError(try LiveContextService.parseSummary(payload, eventID: "wrong-game", player: player, game: game, checkedAt: now, now: now))
    }
    func testNewsUsesEntityIDsNotHeadlineOrTaxonomyID() throws {
        let article: [String: Any] = ["id": 1, "headline": "Synthetic Runner ruled OUT", "description": "Fictional fixture only",
            "published": ISO8601DateFormatter().string(from: now), "links": ["web": ["href": "https://www.espn.com/nfl/story/_/id/1/test"]],
            "categories": [["id": 9999, "type": "athlete", "athleteId": 12345, "athlete": ["id": 12345]]]]
        let news = try LiveContextService.parseNews(["articles": [article]], player: player, now: now)
        XCTAssertEqual(news.count, 1); XCTAssertEqual(news.first?.playerIDs, [player.id])
        var unrelated = article; unrelated["categories"] = [["id": 12345, "type": "athlete", "athlete": ["id": 99999]]]
        XCTAssertTrue(try LiveContextService.parseNews(["articles": [unrelated]], player: player, now: now).isEmpty)
        XCTAssertEqual(LiveContextService.availability("Synthetic Runner ruled OUT"), .unknown)
    }
    func testISO8601WireContractSupportsFractionalAndMinuteDates() throws {
        XCTAssertNotNil(LiveContextService.parseDate("2026-10-11T13:30Z"))
        let fixture = Data("""
        {"fetchedAt":"2026-10-11T06:00:00.123Z","reports":[],"news":[],"sources":[],"warnings":["Synthetic fixture"]}
        """.utf8)
        let context = try LiveContextService.decodeContext(fixture)
        XCTAssertEqual(context.warnings, ["Synthetic fixture"])
        XCTAssertEqual(context.fetchedAt, try XCTUnwrap(LiveContextService.parseDate("2026-10-11T06:00:00.123Z")))
    }
    func testHTTPServerConfigurationFailsExplicitlyWithoutInventingStatus() async {
        let result = await LiveContextService.fetch(player: player, game: game, now: now, serverURL: URL(string: "http://example.com"))
        XCTAssertTrue(result.reports.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("HTTPS") })
        XCTAssertTrue(result.warnings.contains { $0.contains("sin confirmar") })
    }
    func weatherData(time: Double? = nil, wind: Double = 25, rain: Double = 60, unit: String = "km/h") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hourly_units": ["temperature_2m": "°C", "wind_speed_10m": unit, "precipitation_probability": "%"],
            "hourly": ["time": [time ?? game.kickoff.timeIntervalSince1970], "temperature_2m": [8], "wind_speed_10m": [wind], "precipitation_probability": [rain]]])
    }
    func testWeatherCarriesMeasurementsValidTimeAndRejectsChangedUnitsOrInvalidValues() throws {
        let data = try weatherData()
        let context = try WeatherService.parse(data: data, game: game, now: now, sourceURL: "https://api.open-meteo.com/v1/forecast", location: "Synthetic")
        XCTAssertEqual(context.temperatureC, 8); XCTAssertEqual(context.windKmh, 25)
        XCTAssertEqual(context.precipitationProbability, 60); XCTAssertEqual(context.validAt, game.kickoff); XCTAssertEqual(context.indoor, false)
        XCTAssertThrowsError(try WeatherService.parse(data: weatherData(unit: "mph"), game: game, now: now, sourceURL: "synthetic", location: "Synthetic"))
        XCTAssertThrowsError(try WeatherService.parse(data: weatherData(rain: 101), game: game, now: now, sourceURL: "synthetic", location: "Synthetic"))
        XCTAssertThrowsError(try WeatherService.parse(data: weatherData(time: game.kickoff.timeIntervalSince1970 + 3601), game: game, now: now, sourceURL: "synthetic", location: "Synthetic"))
    }
    func testClosedRoofAndNeutralLocationsNeverAssumeHomeCityWeather() async {
        var closed = game; closed.roof = "closed"
        let indoor = await WeatherService.fetch(game: closed, now: now)
        XCTAssertEqual(indoor.indoor, true); XCTAssertNil(indoor.windKmh)
        var neutral = game; neutral.location = "Neutral"
        XCTAssertNil(WeatherService.venue(game: neutral))
        neutral.stadium = "Tottenham Hotspur Stadium"
        XCTAssertEqual(WeatherService.venue(game: neutral)?.0, "Tottenham, Londres")
        neutral.location = "Home"; neutral.home = "JAX"
        XCTAssertEqual(WeatherService.venue(game: neutral)?.0, "Tottenham, Londres") // real nflverse shape: international Home designation
        var home = game; home.stadium = "Soldier Field"
        XCTAssertEqual(WeatherService.venue(game: home)?.0, "Chicago")
    }
}
