import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public-provider context. A successful HTTP request never proves a player is healthy.
enum LiveContextService {
    static let base = "https://site.api.espn.com/apis/site/v2/sports/football/nfl"
    static let teamIDs = ["ARI": "22", "ATL": "1", "BAL": "33", "BUF": "2", "CAR": "29", "CHI": "3",
        "CIN": "4", "CLE": "5", "DAL": "6", "DEN": "7", "DET": "8", "GB": "9", "HOU": "34",
        "IND": "11", "JAX": "30", "KC": "12", "LAC": "24", "LAR": "14", "LV": "13", "MIA": "15",
        "MIN": "16", "NE": "17", "NO": "18", "NYG": "19", "NYJ": "20", "PHI": "21", "PIT": "23",
        "SEA": "26", "SF": "25", "TB": "27", "TEN": "10", "WAS": "28"]

    struct Document {
        var payload: [String: Any]
        var stamp: SourceStamp
    }

    static func fetch(player: Player, game: Game, now: Date = Date(), serverURL: URL? = nil) async -> LiveContext {
        if let serverURL { return await fetchServer(url: serverURL, player: player, game: game, now: now) }
        var context = LiveContext(fetchedAt: now, reports: [], news: [], sources: [], warnings: [])
        guard let espnID = player.espnID, !espnID.isEmpty else {
            context.warnings.append("No hay identificador ESPN verificable para este jugador. No se confirma su participación por nombre.")
            return context
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "America/New_York")
        day.dateFormat = "yyyyMMdd"
        let scoreboardURL = base + "/scoreboard?dates=\(day.string(from: game.kickoff))&limit=100"
        async let injuriesResult = attempt(url: base + "/injuries", name: "Lesiones · ESPN", now: now)
        async let newsResult = attempt(url: base + "/news?limit=50", name: "Noticias · ESPN", now: now)
        async let scoreboardResult = attempt(url: scoreboardURL, name: "Calendario del partido · ESPN", now: now)
        let results = await (injuriesResult, newsResult, scoreboardResult)
        var injuriesDocument: Document?
        var scoreboardDocument: Document?
        switch results.0 {
        case .success(let document): injuriesDocument = document; context.sources.append(document.stamp)
        case .failure(let error): context.warnings.append("Lesiones sin verificar: \(error.localizedDescription)")
        }
        switch results.1 {
        case .success(let document):
            do { context.news = try parseNews(document.payload, player: player, now: now) }
            catch { context.warnings.append("Noticias: \(error.localizedDescription)") }
            context.sources.append(document.stamp)
        case .failure(let error): context.warnings.append("Noticias no disponibles: \(error.localizedDescription)")
        }
        switch results.2 {
        case .success(let document): scoreboardDocument = document; context.sources.append(document.stamp)
        case .failure(let error): context.warnings.append("Identidad del partido sin verificar: \(error.localizedDescription)")
        }
        // Injury lists describe a team, not a game's participation. Verify the NFL matchup first.
        do {
            guard let scoreboardDocument else { throw PulseError.message("No se pudo verificar el partido en ESPN.") }
            guard fresh(scoreboardDocument.stamp.checkedAt, now: now, game: game) else {
                throw PulseError.message("El calendario de ESPN es antiguo; no se renueva su fecha de verificación.")
            }
            let eventID = try matchEvent(scoreboardDocument.payload, game: game)
            if let injuriesDocument {
                do {
                    guard fresh(injuriesDocument.stamp.checkedAt, now: now, game: game) else {
                        throw PulseError.message("El reporte de lesiones de ESPN es antiguo.")
                    }
                    context.reports += try parseInjuries(injuriesDocument.payload, player: player, game: game,
                                                         checkedAt: injuriesDocument.stamp.checkedAt, now: now)
                } catch {
                    context.warnings.append("Lesiones generales: \(error.localizedDescription)")
                }
            }
            switch await attempt(url: base + "/summary?event=\(eventID)", name: "Participación del partido · ESPN", now: now) {
            case .success(let document):
                context.sources.append(document.stamp)
                if fresh(document.stamp.checkedAt, now: now, game: game) {
                    context.reports += try parseSummary(document.payload, eventID: eventID, player: player,
                                                        game: game, checkedAt: document.stamp.checkedAt, now: now)
                } else { context.warnings.append("Resumen del partido antiguo; participación sin confirmar.") }
            case .failure(let error): context.warnings.append("Participación del partido sin verificar: \(error.localizedDescription)")
            }
        } catch { context.warnings.append(error.localizedDescription) }
        if context.reports.isEmpty {
            context.warnings.append("Participación sin confirmar: la ausencia de lesiones o de noticias no demuestra que el jugador vaya a jugar.")
        }
        return context
    }

    static func fresh(_ date: Date, now: Date, game: Game) -> Bool {
        let ttl: TimeInterval = abs(game.kickoff.timeIntervalSince(now)) <= 24 * 3600 ? 15 * 60 : 6 * 3600
        return date <= now.addingTimeInterval(60) && now.timeIntervalSince(date) <= ttl
    }

    static func fetchServer(url: URL, player: Player, game: Game, now: Date) async -> LiveContext {
        let failure = { (message: String) in
            LiveContext(fetchedAt: now, reports: [], news: [], sources: [], warnings: [message, "Participación sin confirmar."])
        }
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            return failure("El servidor de contexto debe usar una URL HTTPS sin credenciales en la dirección.")
        }
        let endpoint = url.path.hasSuffix("/v1/context") ? url : url.appendingPathComponent("v1/context")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return failure("URL de contexto inválida.") }
        components.queryItems = [
            URLQueryItem(name: "player_id", value: player.id), URLQueryItem(name: "espn_id", value: player.espnID),
            URLQueryItem(name: "name", value: player.name), URLQueryItem(name: "team", value: normalizedTeam(player.team)),
            URLQueryItem(name: "game_id", value: game.id), URLQueryItem(name: "kickoff", value: ISO8601DateFormatter().string(from: game.kickoff)),
            URLQueryItem(name: "season", value: String(game.season)), URLQueryItem(name: "week", value: String(game.week))
        ]
        guard let endpointURL = components.url else { return failure("URL de contexto inválida.") }
        do {
            var request = URLRequest(url: endpointURL)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PulseError.message("Servidor de contexto: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            var context = try decodeContext(data)
            guard context.fetchedAt <= now.addingTimeInterval(60) else { throw PulseError.message("Fecha futura inválida en el servidor de contexto.") }
            let original = context.reports.count
            context.reports = context.reports.filter { report in
                let identity = (report.playerID == player.id || (player.espnID != nil && report.espnID == player.espnID))
                    && (report.playerID == nil || report.playerID == player.id)
                    && (player.espnID == nil || report.espnID == nil || report.espnID == player.espnID)
                return identity && normalizedTeam(report.team) == normalizedTeam(player.team)
                    && (report.gameID == game.id || (report.status == .injuredReserve && report.gameID == nil))
                    && fresh(report.checkedAt, now: now, game: game)
                    && (report.reportedAt == nil || report.reportedAt! <= now.addingTimeInterval(60))
                    && URL(string: report.sourceURL)?.scheme?.lowercased() == "https"
            }
            if context.reports.count < original { context.warnings.append("Se descartaron reportes antiguos o cuya identidad/partido no coincide.") }
            if !fresh(context.fetchedAt, now: now, game: game) { context.warnings.append("El servidor devolvió una consulta antigua; se conserva su fecha original.") }
            if context.reports.isEmpty { context.warnings.append("Participación sin confirmar; no hay evidencia vigente del jugador para este partido.") }
            return context
        } catch { return failure("Contexto automático no disponible: \(error.localizedDescription)") }
    }

    static func decodeContext(_ data: Data) throws -> LiveContext {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Fecha ISO8601 inválida")
            }
            return date
        }
        return try decoder.decode(LiveContext.self, from: data)
    }

    static func attempt(url: String, name: String, now: Date) async -> Result<Document, Error> {
        do { return .success(try await download(url: url, name: name, now: now)) }
        catch { return .failure(error) }
    }

    static func download(url: String, name: String, now: Date) async throws -> Document {
        guard let endpoint = URL(string: url) else { throw PulseError.message("URL inválida.") }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PulseError.message("\(name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard data.count <= 16 * 1024 * 1024, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PulseError.message("\(name): formato JSON inválido o demasiado grande.")
        }
        // Respect a provider's snapshot clock. Old cached documents do not become fresh on download.
        let providerTime = parseDate(payload["timestamp"] as? String ?? "")
        let age = max(0, Double(http.value(forHTTPHeaderField: "Age") ?? "") ?? 0)
        let checked = min(providerTime ?? now, now.addingTimeInterval(-age))
        return Document(payload: payload, stamp: SourceStamp(name: name, url: url, checkedAt: checked,
                         modified: http.value(forHTTPHeaderField: "Last-Modified"), rows: 0))
    }

    static func matchEvent(_ payload: [String: Any], game: Game) throws -> String {
        guard let events = payload["events"] as? [[String: Any]] else { throw PulseError.message("ESPN cambió el formato del calendario (events).") }
        let matches = events.filter { matchesGame($0, fallback: payload, game: game) }
        guard matches.count == 1, let id = stringID(matches[0]["id"]), id.allSatisfy(\.isNumber) else {
            throw PulseError.message("No existe una coincidencia única de equipos, temporada, semana y hora del partido en ESPN.")
        }
        return id
    }

    static func matchesGame(_ event: [String: Any], fallback: [String: Any], game: Game) -> Bool {
        let season = event["season"] as? [String: Any] ?? fallback["season"] as? [String: Any]
        let week = (event["week"] as? [String: Any])?["number"] as? Int ?? event["week"] as? Int
            ?? (fallback["week"] as? [String: Any])?["number"] as? Int ?? fallback["week"] as? Int
        guard (season?["year"] as? Int) == game.season,
              week == espnWeek(game),
              let competitions = event["competitions"] as? [[String: Any]], let competition = competitions.first,
              let date = parseDate(event["date"] as? String ?? competition["date"] as? String ?? ""),
              abs(date.timeIntervalSince(game.kickoff)) <= 300,
              let competitors = competition["competitors"] as? [[String: Any]], competitors.count == 2 else { return false }
        let teams = competitors.compactMap { ($0["team"] as? [String: Any])?["abbreviation"] as? String }.map(normalizedTeam)
        return Set(teams) == Set([normalizedTeam(game.home), normalizedTeam(game.away)])
    }

    static func parseInjuries(_ payload: [String: Any], player: Player, game: Game, checkedAt: Date, now: Date) throws -> [AvailabilityReport] {
        guard let season = payload["season"] as? [String: Any], (season["year"] as? Int) == game.season,
              let timestamp = parseDate(payload["timestamp"] as? String ?? ""), fresh(timestamp, now: now, game: game) else {
            throw PulseError.message("El reporte ESPN no acredita una temporada y fecha de actualización vigentes.")
        }
        guard let groups = payload["injuries"] as? [[String: Any]] else { throw PulseError.message("ESPN cambió el formato de lesiones (injuries).") }
        return try parseInjuryGroups(groups, player: player, game: game, checkedAt: min(checkedAt, timestamp), now: now, sourceURL: base + "/injuries")
    }

    static func parseInjuryGroups(_ groups: [[String: Any]], player: Player, game: Game, checkedAt: Date, now: Date, sourceURL: String) throws -> [AvailabilityReport] {
        var reports: [AvailabilityReport] = []
        for group in groups {
            let groupTeam = group["team"] as? [String: Any] ?? group
            guard teamMatches(groupTeam, team: player.team) else { continue }
            guard let entries = group["injuries"] as? [[String: Any]] else { throw PulseError.message("ESPN cambió el formato de lesiones del equipo.") }
            for entry in entries {
                guard let athlete = entry["athlete"] as? [String: Any],
                      let id = athleteID(athlete), id == player.espnID else { continue }
                if let athleteTeam = athlete["team"] as? [String: Any], !teamMatches(athleteTeam, team: player.team) { continue }
                let status = availability(entry["status"])
                // Injury listings must never establish Active, even if the provider uses that label.
                guard status != .active, status != .unknown else { continue }
                let reported = parseDate(entry["date"] as? String ?? "")
                guard let reported, reported <= now.addingTimeInterval(60) else { continue }
                let currentWindow = reported >= game.kickoff.addingTimeInterval(-7 * 86400)
                    && game.kickoff >= now.addingTimeInterval(-4 * 3600)
                // An old injury article cannot declare somebody out of a different game.
                guard currentWindow || status == .injuredReserve else { continue }
                let detail = entry["details"] as? [String: Any]
                let description = [entry["shortComment"] as? String, detail?["detail"] as? String,
                    (entry["type"] as? [String: Any])?["description"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                reports.append(AvailabilityReport(id: "espn-injury-\(stringID(entry["id"]) ?? id)", playerID: player.id,
                    espnID: id, name: player.name, team: player.team, status: status,
                    detail: description.isEmpty ? "Estado explícito del reporte de lesiones." : description,
                    reportedAt: reported, checkedAt: checkedAt, gameID: status == .injuredReserve ? nil : game.id,
                    source: "ESPN · lesiones", sourceURL: sourceURL))
            }
        }
        return reports
    }

    static func parseSummary(_ payload: [String: Any], eventID: String, player: Player, game: Game, checkedAt: Date, now: Date) throws -> [AvailabilityReport] {
        guard let header = payload["header"] as? [String: Any], stringID(header["id"]) == eventID,
              matchesGame(header, fallback: payload, game: game) else { throw PulseError.message("El resumen ESPN corresponde a otro partido o tiene formato incompatible.") }
        var reports: [AvailabilityReport] = []
        if let injuries = payload["injuries"] as? [[String: Any]] {
            reports += try parseInjuryGroups(injuries, player: player, game: game, checkedAt: checkedAt, now: now,
                                            sourceURL: base + "/summary?event=\(eventID)")
        }
        guard let groups = payload["rosters"] as? [[String: Any]] else { return reports }
        for group in groups {
            guard let team = (group["team"] as? [String: Any])?["abbreviation"] as? String,
                  normalizedTeam(team) == normalizedTeam(player.team), let roster = group["roster"] as? [[String: Any]] else { continue }
            for entry in roster {
                guard let athlete = entry["athlete"] as? [String: Any], stringID(athlete["id"]) == player.espnID else { continue }
                var status = availability(entry["status"])
                if let active = entry["active"] as? Bool { status = active ? .active : .inactive }
                guard status != .unknown else { continue }
                reports.append(AvailabilityReport(id: "espn-participation-\(eventID)-\(player.espnID ?? player.id)", playerID: player.id,
                    espnID: player.espnID, name: player.name, team: player.team, status: status,
                    detail: "Estado explícito de la lista del partido; no inferido de la plantilla general ni de titulares.",
                    reportedAt: nil, checkedAt: checkedAt, gameID: game.id, source: "ESPN · lista del partido",
                    sourceURL: base + "/summary?event=\(eventID)"))
            }
        }
        return reports
    }

    static func parseNews(_ payload: [String: Any], player: Player, now: Date) throws -> [NewsItem] {
        guard let articles = payload["articles"] as? [[String: Any]] else { throw PulseError.message("ESPN cambió el formato de noticias (articles).") }
        return articles.compactMap { article in
            guard let categories = article["categories"] as? [[String: Any]] else { return nil }
            let athleteIDs = categories.compactMap { category -> String? in
                if let athlete = category["athlete"] as? [String: Any] { return stringID(athlete["id"]) }
                return (category["type"] as? String) == "athlete" ? stringID(category["athleteId"]) : nil
            }
            let teams = categories.compactMap { ($0["team"] as? [String: Any])?["abbreviation"] as? String }.map(normalizedTeam)
            guard (player.espnID.map { athleteIDs.contains($0) } ?? false) || teams.contains(normalizedTeam(player.team)),
                  let title = article["headline"] as? String, !title.isEmpty,
                  let published = parseDate(article["published"] as? String ?? ""), published <= now.addingTimeInterval(60),
                  now.timeIntervalSince(published) <= 14 * 86400,
                  let links = article["links"] as? [String: Any], let web = links["web"] as? [String: Any],
                  let url = web["href"] as? String, URL(string: url)?.scheme?.lowercased() == "https" else { return nil }
            return NewsItem(id: stringID(article["id"]) ?? url, title: title, summary: article["description"] as? String ?? "",
                url: url, publishedAt: published, source: "ESPN", playerIDs: athleteIDs.contains(player.espnID ?? "") ? [player.id] : [], teams: teams)
        }.sorted { $0.publishedAt > $1.publishedAt }
    }

    static func availability(_ raw: Any?) -> AvailabilityStatus {
        let text: String
        if let raw = raw as? String { text = raw }
        else if let raw = raw as? [String: Any] { text = raw["name"] as? String ?? raw["type"] as? String ?? "" }
        else { return .unknown }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "status_active": return .active
        case "questionable", "q": return .questionable
        case "doubtful", "d": return .doubtful
        case "out", "o": return .out
        case "inactive", "status_inactive": return .inactive
        case "injured reserve", "injured_reserve", "reserve/injured", "ir": return .injuredReserve
        default: return .unknown
        }
    }

    static func normalizedTeam(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["LA": "LAR", "WSH": "WAS", "SD": "LAC", "OAK": "LV"][value] ?? value
    }
    static func teamMatches(_ value: [String: Any], team: String) -> Bool {
        if let abbreviation = value["abbreviation"] as? String { return normalizedTeam(abbreviation) == normalizedTeam(team) }
        return stringID(value["id"]) == teamIDs[normalizedTeam(team)]
    }
    static func athleteID(_ athlete: [String: Any]) -> String? {
        if let id = stringID(athlete["id"]), id.allSatisfy(\.isNumber) { return id }
        // League injuries omit athlete.id in the live schema. Resolve only official NFL player links.
        let ids = Set((athlete["links"] as? [[String: Any]] ?? []).compactMap { link -> String? in
            guard let href = link["href"] as? String, let url = URL(string: href), url.scheme == "https",
                  ["espn.com", "www.espn.com"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
            let pieces = url.path.split(separator: "/").map(String.init)
            guard pieces.count >= 5, pieces[0] == "nfl", pieces[1] == "player", pieces[2] == "_", pieces[3] == "id",
                  !pieces[4].isEmpty, pieces[4].allSatisfy(\.isNumber) else { return nil }
            return pieces[4]
        })
        return ids.count == 1 ? ids.first : nil
    }
    static func espnWeek(_ game: Game) -> Int {
        // nflverse uses NFL weeks 19...22 for playoffs; ESPN restarts at 1.
        switch game.kind { case "WC": return 1; case "DIV": return 2; case "CON": return 3; case "SB": return 5; default: return game.week }
    }
    static func stringID(_ raw: Any?) -> String? {
        if let raw = raw as? String, !raw.isEmpty { return raw }
        if let raw = raw as? Int { return String(raw) }
        return nil
    }
    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        let minute = DateFormatter()
        minute.locale = Locale(identifier: "en_US_POSIX")
        minute.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return minute.date(from: value)
    }
}
