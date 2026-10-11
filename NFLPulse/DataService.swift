import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor DataService {
    private let base = "https://github.com/nflverse/nflverse-data/releases/download/"
    private let scheduleURL = "https://raw.githubusercontent.com/nflverse/nfldata/master/data/games.csv"

    func fetchCSV(_ url: String, name: String) async throws -> ([[String: String]], SourceStamp) {
        guard let url = URL(string: url) else { throw PulseError.message("URL inválida.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw PulseError.message("No se pudo consultar \(name). Reintenta con conexión a internet.")
        }
        let rows = try CSV.parse(text)
        return (rows, SourceStamp(name: name, url: url.absoluteString, checkedAt: Date(),
            modified: response.value(forHTTPHeaderField: "Last-Modified"), rows: rows.count))
    }

    func refresh(now: Date = Date()) async throws -> Snapshot {
        let (scheduleRows, scheduleStamp) = try await fetchCSV(scheduleURL, name: "Calendario · nflverse")
        try CSV.require(scheduleRows, ["game_id", "season", "week", "gameday", "gametime", "home_team", "away_team"], source: "Calendario")
        let games = scheduleRows.compactMap(Self.game)
        // Use published schedule, not an assumed September boundary.
        guard let activeGame = games.filter({ $0.kickoff <= now.addingTimeInterval(45 * 86400) })
            .max(by: { $0.kickoff < $1.kickoff }) else {
            throw PulseError.message("No hay calendario válido disponible.")
        }
        let season = activeGame.season
        var stamps = [scheduleStamp], warnings: [String] = [], allStats: [StatLine] = []
        let eligibleSchedule = scheduleRows.filter { ["REG", "WC", "DIV", "CON", "SB"].contains($0["game_type"] ?? "") }
        if games.count < eligibleSchedule.count {
            warnings.append("Calendario: se rechazaron \(eligibleSchedule.count - games.count) filas incompletas o inválidas; esos partidos no se usan.")
        }
        for year in [season - 1, season] {
            do {
                let (rows, stamp) = try await fetchCSV(base + "stats_player/stats_player_week_\(year).csv", name: "Estadísticas \(year) · nflverse")
                try CSV.require(rows, ["player_id", "game_id", "season", "week", "position", "team", "opponent_team", "passing_yards", "rushing_yards", "receiving_yards", "receptions", "attempts", "carries", "targets"], source: "Estadísticas")
                let eligible = rows.filter { Self.positions.contains($0["position"] ?? "") }
                let parsed = eligible.compactMap(Self.stat)
                guard !parsed.isEmpty else { throw PulseError.message("Estadísticas \(year): ninguna fila válida; no se reemplazó la última descarga válida.") }
                allStats += parsed
                if parsed.count < eligible.count {
                    warnings.append("Estadísticas \(year): se rechazaron \(eligible.count - parsed.count) filas de jugadores con valores o identidad inválidos.")
                }
                let newColumns = ["completions", "fg_made", "fg_att", "pat_made"]
                let missingColumns = newColumns.filter { rows.first?[$0] == nil }
                if !missingColumns.isEmpty {
                    warnings.append("Estadísticas \(year): faltan columnas \(missingColumns.joined(separator: ", ")); esas observaciones quedan desconocidas, sin sustituirlas por cero.")
                }
                let malformed = eligible.reduce(0) { count, row in
                    count + newColumns.filter { column in
                        guard let value = row[column], !value.missing else { return false }
                        return Self.countNumber(value) == nil
                    }.count
                }
                if malformed > 0 { warnings.append("Estadísticas \(year): \(malformed) valores opcionales inválidos se descartaron.") }
                stamps.append(stamp)
            } catch {
                // Current-season stats must exist once games have been completed.
                if year == season && games.contains(where: { $0.season == season && $0.completed && $0.kickoff < now.addingTimeInterval(-86400) }) { throw error }
                warnings.append("Estadísticas \(year) no disponibles. \(error.localizedDescription)")
            }
        }
        guard !allStats.isEmpty else { throw PulseError.message("Aún no hay estadísticas suficientes para proyectar.") }
        let (rosterRows, rosterStamp) = try await fetchCSV(base + "rosters/roster_\(season).csv", name: "Plantilla \(season) · nflverse")
        try CSV.require(rosterRows, ["gsis_id", "full_name", "team", "position", "status"], source: "Plantilla")
        stamps.append(rosterStamp)
        var playersByID: [String: Player] = [:]
        var rejectedRoster = 0
        for r in rosterRows.sorted(by: { (Int($0["week"] ?? "") ?? 0) < (Int($1["week"] ?? "") ?? 0) }) {
            guard Self.positions.contains(r["position"] ?? "") else { continue }
            guard let player = Self.player(r) else { rejectedRoster += 1; continue }
            playersByID[player.id] = player
        }
        guard !playersByID.isEmpty else { throw PulseError.message("No se identificaron jugadores en la plantilla.") }
        if rejectedRoster > 0 { warnings.append("Plantilla: se rechazaron \(rejectedRoster) filas sin identidad válida.") }
        let unmapped = playersByID.values.filter { $0.espnID == nil }.count
        if unmapped > 0 { warnings.append("Plantilla: \(unmapped) jugadores sin identificador ESPN; su contexto automático requiere una fuente con identidad verificable.") }
        var injuries: [Injury] = []
        do {
            let (rows, stamp) = try await fetchCSV(base + "injuries/injuries_\(season).csv", name: "Lesiones \(season) · nflverse")
            try CSV.require(rows, ["gsis_id", "week", "team", "report_status", "practice_status"], source: "Lesiones")
            injuries = rows.compactMap(Self.injury)
            if injuries.count < rows.count { warnings.append("Lesiones: se rechazaron \(rows.count - injuries.count) filas con identidad inválida.") }
            stamps.append(stamp)
        } catch { warnings.append("Lesiones no disponibles. La ausencia de un reporte no confirma que el jugador esté sano.") }
        let keys = Set(allStats.map(\.id))
        guard keys.count == allStats.count else { throw PulseError.message("Estadísticas duplicadas; actualización cancelada.") }
        return Snapshot(fetchedAt: now, season: season,
            players: playersByID.values.sorted { $0.name < $1.name }, games: games,
            stats: allStats, injuries: injuries, sources: stamps, warnings: warnings)
    }

    static func game(_ r: [String: String]) -> Game? {
        guard let id = r["game_id"], !id.missing, let season = Int(r["season"] ?? ""),
              let week = Int(r["week"] ?? ""), ["REG", "WC", "DIV", "CON", "SB"].contains(r["game_type"] ?? ""),
              let day = r["gameday"], let time = r["gametime"], !time.missing,
              let home = r["home_team"], !home.missing, let away = r["away_team"], !away.missing, home != away else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = format.date(from: "\(day) \(time)") else { return nil }
        return Game(id: id, season: season, week: week, kind: r["game_type"] ?? "REG", kickoff: date,
            home: home, away: away, stadium: r["stadium"] ?? "Estadio pendiente",
            roof: r["roof"] ?? "", location: r["location"] ?? "",
            completed: number(r["home_score"]) != nil && number(r["away_score"]) != nil,
            temperatureC: number(r["temp"]).flatMap {
                let converted = ($0 - 32) / 9 * 5
                return converted.isFinite && (-100...70).contains(converted) ? converted : nil
            },
            windKmh: number(r["wind"]).flatMap {
                let converted = $0 * 1.609344
                return converted.isFinite && (0...500).contains(converted) ? converted : nil
            })
    }

    static let positions = ["QB", "RB", "FB", "WR", "TE", "K", "PK"]

    static func number(_ raw: String?) -> Double? {
        guard let raw, !raw.missing, let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    static func countNumber(_ raw: String?) -> Double? {
        guard let value = number(raw), value >= 0, value.rounded() == value else { return nil }
        return value
    }

    static func player(_ r: [String: String]) -> Player? {
        guard let id = r["gsis_id"], !id.missing, let name = r["full_name"], !name.missing,
              let team = r["team"], !team.missing, let position = r["position"], positions.contains(position) else { return nil }
        // nflverse's ESPN ID is a crosswalk, never guessed from an athlete's name.
        let espn = r["espn_id"].flatMap { raw -> String? in
            guard !raw.missing, let value = Double(raw), value.isFinite, value > 0,
                  value.rounded() == value, value <= 9_999_999_999 else { return nil }
            return String(Int64(value))
        }
        return Player(id: id, name: name, team: team, position: position,
                      status: r["status"].flatMap { $0.missing ? nil : $0 } ?? "Desconocido", espnID: espn)
    }

    static func stat(_ r: [String: String]) -> StatLine? {
        guard let id = r["player_id"], !id.missing, let game = r["game_id"], !game.missing,
              let year = Int(r["season"] ?? ""), let week = Int(r["week"] ?? ""),
              let position = r["position"], positions.contains(position),
              let team = r["team"], !team.missing, let opp = r["opponent_team"], !opp.missing,
              let passing = Double(r["passing_yards"] ?? ""),
              let rushing = Double(r["rushing_yards"] ?? ""),
              let receiving = Double(r["receiving_yards"] ?? ""),
              let receptions = Double(r["receptions"] ?? ""),
              let attempts = Double(r["attempts"] ?? ""),
              let carries = Double(r["carries"] ?? ""), let targets = Double(r["targets"] ?? ""),
              [passing, rushing, receiving, receptions, attempts, carries, targets].allSatisfy(\.isFinite),
              [receptions, attempts, carries, targets].allSatisfy({ $0 >= 0 && $0.rounded() == $0 })
        else { return nil }
        return StatLine(playerID: id, gameID: game, season: year, week: week, team: team,
            opponent: opp, position: position, passing: passing, rushing: rushing,
            receiving: receiving, receptions: receptions, attempts: attempts, carries: carries, targets: targets,
            completions: countNumber(r["completions"]), fieldGoals: countNumber(r["fg_made"]),
            fieldGoalAttempts: countNumber(r["fg_att"]), extraPoints: countNumber(r["pat_made"]))
    }

    static func injury(_ r: [String: String]) -> Injury? {
        guard let id = r["gsis_id"], !id.missing, let team = r["team"], !team.missing,
              let year = Int(r["season"] ?? ""), let week = Int(r["week"] ?? "") else { return nil }
        let detail = [r["report_primary_injury"], r["practice_primary_injury"]]
            .compactMap { $0 }.filter { !$0.missing }.joined(separator: " · ")
        return Injury(playerID: id, team: team, week: week, season: year,
            kind: r["game_type"] ?? r["season_type"] ?? "REG", status: r["report_status"] ?? "",
            practice: r["practice_status"] ?? "", detail: detail)
    }
}
