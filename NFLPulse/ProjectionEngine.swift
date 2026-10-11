import Foundation

struct ProjectionEngine {
    static let version = "V2 · volumen, eficiencia y selección temporal"
    let snapshot: Snapshot
    private let games: [String: Game]
    private let byPlayer: [String: [StatLine]]
    private let defense: [Metric: [String: [String: [(date: Date, value: Double)]]]]

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
        games = Dictionary(snapshot.games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byPlayer = Dictionary(grouping: snapshot.stats, by: \.playerID)
        let gameIndex = games
        var index: [Metric: [String: [String: [(date: Date, value: Double)]]]] = [:]
        for metric in Metric.allCases {
            let eligible = snapshot.stats.filter {
                guard metric.supports($0.position), let value = $0.observed(metric) else { return false }
                return !metric.isCount || value >= 0
            }
            let groups = Dictionary(grouping: eligible, by: { "\($0.gameID)|\($0.opponent)|\($0.position)" })
            for rows in groups.values {
                guard let row = rows.first, let game = gameIndex[row.gameID], game.completed else { continue }
                let total = rows.compactMap { $0.observed(metric) }.reduce(0, +)
                index[metric, default: [:]][row.position, default: [:]][row.opponent, default: []]
                    .append((game.kickoff, total))
            }
        }
        defense = index
    }

    func nextGame(for player: Player, now: Date) -> Game? {
        snapshot.games.filter { $0.contains(player.team) && $0.kickoff > now && !$0.completed }
            .min { $0.kickoff < $1.kickoff }
    }

    func history(player: String, team: String, cutoff: Date) -> [StatLine] {
        (byPlayer[player] ?? []).filter { line in
            guard let game = games[line.gameID] else { return false }
            return line.team == team && game.completed && game.kickoff.addingTimeInterval(8 * 3600) < cutoff
                && game.kickoff > cutoff.addingTimeInterval(-550 * 86400)
        }.sorted {
            let a = games[$0.gameID]?.kickoff ?? .distantPast
            let b = games[$1.gameID]?.kickoff ?? .distantPast
            return a == b ? $0.id < $1.id : a < b
        }
    }

    func weightedMean(_ values: [Double]) -> Double {
        let valid = values.filter(\.isFinite)
        guard !valid.isEmpty else { return 0 }
        var total = 0.0, weights = 0.0
        for (i, value) in valid.reversed().enumerated() {
            let w = pow(0.85, Double(i)); total += value * w; weights += w
        }
        return total / weights
    }

    private func observedRows(_ rows: [StatLine], metric: Metric) -> [StatLine] {
        rows.filter { row in
            guard let value = row.observed(metric) else { return false }
            return !metric.isCount || value >= 0
        }
    }

    private func baseline(_ rows: [StatLine], metric: Metric) -> Double {
        let values = observedRows(rows, metric: metric).suffix(5).compactMap { $0.observed(metric) }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    // Opponent totals are stratified by position. Thin samples contribute no adjustment.
    // The public overload is retained for v0.1 callers; forecasts use the position overload.
    func opponentFactor(_ opponent: String, metric: Metric, cutoff: Date) -> Double {
        let positions = defense[metric]?.keys.sorted() ?? []
        guard positions.count == 1, let position = positions.first else { return 1 }
        return opponentFactor(opponent, metric: metric, position: position, cutoff: cutoff)
    }

    func opponentFactor(_ opponent: String, metric: Metric, position: String, cutoff: Date) -> Double {
        let valid: (Date) -> Bool = { $0.addingTimeInterval(8 * 3600) < cutoff && $0 > cutoff.addingTimeInterval(-365 * 86400) }
        let teams = defense[metric]?[position] ?? [:]
        let recent = Array((teams[opponent] ?? []).filter { valid($0.date) }.sorted { $0.date < $1.date }.suffix(8))
        let league = teams.values.flatMap { $0 }.filter { valid($0.date) }
        guard recent.count >= 5, league.count >= 15 else { return 1 }
        let mean = league.reduce(0) { $0 + $1.value } / Double(league.count)
        guard mean > 0 else { return 1 }
        let opponentMean = recent.reduce(0) { $0 + $1.value } / Double(recent.count)
        let reliability = Double(recent.count) / (Double(recent.count) + 12)
        return min(1.15, max(0.85, 1 + (opponentMean / mean - 1) * reliability))
    }

    private func volume(_ row: StatLine, metric: Metric) -> Double? {
        let result: Double?
        switch metric {
        case .passing, .passAttempts, .completions: result = row.observed(.passAttempts)
        case .rushing, .carries: result = row.observed(.carries)
        case .receiving, .receptions, .targets: result = row.observed(.targets)
        case .fieldGoals, .fieldGoalAttempts: result = row.observed(.fieldGoalAttempts)
        case .extraPoints: result = row.observed(.extraPoints)
        }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
    }

    func opportunity(_ rows: [StatLine], metric: Metric) -> Double {
        weightedMean(Array(observedRows(rows, metric: metric).suffix(12)).compactMap { volume($0, metric: metric) })
    }

    private func minimumOpportunity(_ metric: Metric) -> Double {
        switch metric {
        case .passing, .passAttempts, .completions: return 5
        case .fieldGoals, .fieldGoalAttempts, .extraPoints: return 0.25
        default: return 1
        }
    }

    private func candidate(_ rows: [StatLine], metric: Metric, opponent: String, cutoff: Date) -> Double {
        let eligible = observedRows(rows, metric: metric)
        let recent = Array(eligible.suffix(12))
        let direct = weightedMean(recent.compactMap { $0.observed(metric) })
        let ratioMetrics: [Metric] = [.passing, .rushing, .receiving, .receptions, .completions, .fieldGoals]
        var value = direct
        if ratioMetrics.contains(metric) {
            let paired = recent.filter { (volume($0, metric: metric) ?? 0) > 0 }
            let historical = eligible.filter { (volume($0, metric: metric) ?? 0) > 0 }
            let priorVolume = historical.compactMap { volume($0, metric: metric) }.reduce(0, +)
            if !paired.isEmpty, priorVolume > 0 {
                let priorEfficiency = historical.compactMap { $0.observed(metric) }.reduce(0, +) / priorVolume
                var output = 0.0, attempts = 0.0
                for (i, row) in paired.reversed().enumerated() {
                    let weight = pow(0.85, Double(i))
                    output += (row.observed(metric) ?? 0) * weight
                    attempts += (volume(row, metric: metric) ?? 0) * weight
                }
                // Three typical games of the player's historical efficiency stabilize a small sample.
                let priorWeight = priorVolume / Double(historical.count) * 3
                var efficiency = (output + priorEfficiency * priorWeight) / (attempts + priorWeight)
                if [.receptions, .completions, .fieldGoals].contains(metric) { efficiency = min(1, max(0, efficiency)) }
                value = opportunity(recent, metric: metric) * efficiency
            }
        }
        let position = recent.last?.position ?? ""
        value *= opponentFactor(opponent, metric: metric, position: position, cutoff: cutoff)
        return metric.isCount ? max(0, value) : value
    }

    private struct Selection {
        var estimate: Double
        var baseline: Double
        var usesCandidate: Bool
        var checks: Int
    }

    // Every comparison uses only completed games before its own kickoff.
    // No result at or after the forecast cutoff can choose the model.
    private func selected(_ rows: [StatLine], metric: Metric, opponent: String, cutoff: Date) -> Selection {
        let eligible = observedRows(rows, metric: metric).filter {
            (games[$0.gameID]?.kickoff ?? .distantFuture).addingTimeInterval(8 * 3600) < cutoff
        }
        let simple = baseline(eligible, metric: metric)
        var candidateError = 0.0, baselineError = 0.0, count = 0
        for i in max(4, eligible.count - 12)..<max(4, eligible.count) {
            guard i < eligible.count, let game = games[eligible[i].gameID], let actual = eligible[i].observed(metric) else { continue }
            let before = Array(eligible[..<i]).filter {
                (games[$0.gameID]?.kickoff ?? .distantFuture).addingTimeInterval(8 * 3600) < game.kickoff
            }
            guard before.count >= 4, opportunity(before, metric: metric) >= minimumOpportunity(metric) else { continue }
            candidateError += abs(candidate(before, metric: metric, opponent: eligible[i].opponent, cutoff: game.kickoff) - actual)
            baselineError += abs(baseline(before, metric: metric) - actual)
            count += 1
        }
        let useCandidate = count >= 6 && candidateError < baselineError * 0.98
        return Selection(estimate: useCandidate ? candidate(eligible, metric: metric, opponent: opponent, cutoff: cutoff) : simple,
                         baseline: simple, usesCandidate: useCandidate, checks: count)
    }

    func point(_ rows: [StatLine], metric: Metric, opponent: String, cutoff: Date) -> Double {
        selected(rows, metric: metric, opponent: opponent, cutoff: cutoff).estimate
    }

    func quantile(_ sortedValues: [Double], _ p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let x = Double(sortedValues.count - 1) * min(1, max(0, p))
        let low = Int(floor(x)), high = Int(ceil(x))
        return sortedValues[low] + (sortedValues[high] - sortedValues[low]) * (x - Double(low))
    }

    func interval(rows: [StatLine], metric: Metric, estimate: Double) -> (Double, Double)? {
        let eligible = observedRows(rows, metric: metric)
        guard eligible.count >= 10 else { return nil }
        var residuals: [Double] = []
        for i in max(4, eligible.count - 16)..<eligible.count {
            guard let game = games[eligible[i].gameID], let actual = eligible[i].observed(metric) else { continue }
            let before = Array(eligible[..<i]).filter {
                (games[$0.gameID]?.kickoff ?? .distantFuture).addingTimeInterval(8 * 3600) < game.kickoff
            }
            guard before.count >= 4 else { continue }
            residuals.append(actual - point(before, metric: metric, opponent: eligible[i].opponent, cutoff: game.kickoff))
        }
        guard residuals.count >= 6 else { return nil }
        residuals.sort()
        var low = estimate + quantile(residuals, 0.10)
        var high = estimate + quantile(residuals, 0.90)
        if metric.isCount { low = max(0, floor(low)); high = max(low, ceil(high)) }
        return (low, max(low, high))
    }

    func availability(player: Player, game: Game, now: Date, context: LiveContext? = nil) -> AvailabilityAssessment {
        let maximumAge: TimeInterval = game.kickoff.timeIntervalSince(now) <= 6 * 3600 ? 15 * 60 : 6 * 3600
        var warnings: [String] = []
        let sourceReports = context.map { $0.fetchedAt <= now ? $0.reports : [] } ?? []
        let matching = sourceReports.filter { report in
            let espnMatches = player.espnID.map { !$0.isEmpty && report.espnID == $0 } ?? false
            let identityMatches = (!player.id.isEmpty && report.playerID == player.id) || espnMatches
            return identityMatches && report.team == player.team &&
                (report.gameID == game.id || (report.gameID == nil && report.status == .injuredReserve))
        }
        let usable = matching.filter { report in
            let age = now.timeIntervalSince(report.checkedAt)
            guard age >= 0 && age <= maximumAge else { return false }
            if let reported = report.reportedAt {
                return reported <= now && (report.status == .injuredReserve || reported >= game.kickoff.addingTimeInterval(-7 * 86400))
            }
            if report.status == .injuredReserve { return true }
            // Undated roster/injury notices cannot establish current game participation.
            return [.active, .inactive].contains(report.status) && report.gameID == game.id &&
                (report.source.lowercased().contains("summary") || report.sourceURL.contains("summary"))
        }
        if matching.count > usable.count { warnings.append("Se ignoraron reportes vencidos, sin fecha verificable o con fecha futura; actualiza la disponibilidad.") }
        let latest = usable.filter { $0.status != .unknown }.sorted { a, b in
            let da = a.reportedAt ?? a.checkedAt, db = b.reportedAt ?? b.checkedAt
            if da != db { return da > db }
            if a.checkedAt != b.checkedAt { return a.checkedAt > b.checkedAt }
            return a.status.blocksProjection && !b.status.blocksProjection
        }
        var status = latest.first?.status ?? .unknown
        let currentWeekly = snapshot.injuries.filter {
            $0.playerID == player.id && $0.team == player.team && $0.season == game.season && $0.week == game.week &&
                ($0.kind == game.kind || (game.kind != "REG" && $0.kind == "POST"))
        }
        let weeklyChecked = snapshot.sources.filter { $0.name.lowercased().contains("lesiones") }.map(\.checkedAt).min() ?? snapshot.fetchedAt
        let weeklyAge = now.timeIntervalSince(weeklyChecked)
        let usableWeekly = weeklyAge >= 0 && weeklyAge <= 24 * 3600
        if usableWeekly && latest.isEmpty {
            for injury in currentWeekly {
                let text = injury.status.lowercased().trimmingCharacters(in: .whitespaces)
                if ["out", "doubtful"].contains(text) { status = text == "out" ? .out : .doubtful }
                else if text == "questionable" && !status.blocksProjection { status = .questionable }
                warnings.append("Reporte semanal: \(injury.status.missing ? "sin estatus de partido" : injury.status) · \(injury.practice) · \(injury.detail). Copia: \(weeklyChecked.formatted(.iso8601)).")
            }
        }
        if status == .unknown { warnings.append("La plantilla activa no confirma participación. Falta un reporte individual vigente para este partido.") }
        if status == .questionable { warnings.append("Participación cuestionable: la estimación sólo describe el caso en que juegue con su rol histórico.") }
        if let report = latest.first { warnings.append("Disponibilidad: \(report.status.title) · \(report.source). Revisado: \(report.checkedAt.formatted(.iso8601)).") }
        return AvailabilityAssessment(status: status, checkedAt: latest.first?.checkedAt ?? (usableWeekly && !currentWeekly.isEmpty ? weeklyChecked : nil),
                                      reports: usable, warnings: warnings)
    }

    private func indoor(_ game: Game) -> Bool {
        ["dome", "domed", "closed", "indoors", "indoor"].contains(game.roof.lowercased())
    }

    private func outdoor(_ game: Game) -> Bool {
        ["outdoors", "outdoor", "open"].contains(game.roof.lowercased())
    }

    private struct ClimateObservation {
        var date: Date
        var temperature: Double
        var wind: Double
        var base: Double
        var actual: Double
    }
    private struct ClimateModel {
        var meanTemperature: Double
        var meanWind: Double
        var temperatureSlope: Double
        var windSlope: Double
        var evidence: Int
        var improvement: Double
        func delta(temperature: Double, wind: Double) -> Double {
            (temperature - meanTemperature) / 20 * temperatureSlope + (wind - meanWind) / 20 * windSlope
        }
    }

    // Historical observed weather is training context, not proof that a forecast existed at that time.
    // The final chronological holdout must beat forecasts without weather before coefficients are used.
    private func climateModel(position: String, metric: Metric, cutoff: Date) -> ClimateModel? {
        var observations: [ClimateObservation] = []
        let candidates = snapshot.stats.filter { row in
            guard row.position == position, row.observed(metric) != nil, let game = games[row.gameID] else { return false }
            return game.completed && outdoor(game) && game.kickoff.addingTimeInterval(8 * 3600) < cutoff &&
                game.kickoff > cutoff.addingTimeInterval(-550 * 86400) && game.temperatureC != nil && game.windKmh != nil
        }.sorted { (games[$0.gameID]?.kickoff ?? .distantPast) < (games[$1.gameID]?.kickoff ?? .distantPast) }
        for row in candidates.suffix(500) {
            guard let game = games[row.gameID], let temperature = game.temperatureC, let wind = game.windKmh,
                  temperature.isFinite, wind.isFinite, (-70...65).contains(temperature), (0...200).contains(wind),
                  let actual = row.observed(metric) else { continue }
            let previous = observedRows(history(player: row.playerID, team: row.team, cutoff: game.kickoff), metric: metric)
            guard previous.count >= 4, opportunity(previous, metric: metric) >= minimumOpportunity(metric) else { continue }
            let base = point(previous, metric: metric, opponent: row.opponent, cutoff: game.kickoff)
            observations.append(ClimateObservation(date: game.kickoff, temperature: temperature, wind: wind, base: base, actual: actual))
        }
        guard observations.count >= 40 else { return nil }
        let splitDate = observations[Int(Double(observations.count) * 0.70)].date
        let training = observations.filter { $0.date < splitDate }
        let heldOut = observations.filter { $0.date >= splitDate }
        guard training.count >= 28, heldOut.count >= 12 else { return nil }
        let meanT = training.map(\.temperature).reduce(0, +) / Double(training.count)
        let meanW = training.map(\.wind).reduce(0, +) / Double(training.count)
        var tt = 4.0, ww = 4.0, tw = 0.0, ty = 0.0, wy = 0.0
        for row in training {
            let t = (row.temperature - meanT) / 20, w = (row.wind - meanW) / 20
            let residual = row.actual - row.base
            tt += t * t; ww += w * w; tw += t * w; ty += t * residual; wy += w * residual
        }
        let determinant = tt * ww - tw * tw
        guard determinant > 0 else { return nil }
        var result = ClimateModel(meanTemperature: meanT, meanWind: meanW,
            temperatureSlope: (ty * ww - wy * tw) / determinant,
            windSlope: (wy * tt - ty * tw) / determinant, evidence: heldOut.count, improvement: 0)
        var baseError = 0.0, adjustedError = 0.0
        for row in heldOut {
            let delta = boundedClimateDelta(result.delta(temperature: row.temperature, wind: row.wind), baseline: row.base)
            baseError += abs(row.base - row.actual)
            let forecast = metric.isCount ? max(0, row.base + delta) : row.base + delta
            adjustedError += abs(forecast - row.actual)
        }
        guard baseError > 0, adjustedError < baseError * 0.95 else { return nil }
        result.improvement = 1 - adjustedError / baseError
        return result
    }

    private func boundedClimateDelta(_ delta: Double, baseline: Double) -> Double {
        let limit = abs(baseline) * 0.15
        return min(limit, max(-limit, delta))
    }

    private func weatherAdjustment(weather: WeatherContext?, game: Game, player: Player, metric: Metric,
                                   now: Date, estimate: Double) -> (ProjectionAdjustment?, [String]) {
        if indoor(game) || weather?.indoor == true {
            return (nil, ["Estadio cerrado: el clima exterior no modifica la cifra."])
        }
        guard outdoor(game) || weather?.indoor == false else {
            return (nil, ["Techo sin confirmar: el clima se muestra como contexto y no modifica la cifra."])
        }
        guard let weather, let checked = weather.checkedAt, checked <= now,
              now.timeIntervalSince(checked) <= 6 * 3600,
              let validAt = weather.validAt, abs(validAt.timeIntervalSince(game.kickoff)) <= 3 * 3600,
              let temperature = weather.temperatureC, let wind = weather.windKmh,
              temperature.isFinite, wind.isFinite, (-70...65).contains(temperature), (0...200).contains(wind) else {
            return (nil, ["Clima sin pronóstico vigente y numérico para la hora del partido: no se aplica un factor supuesto."])
        }
        guard let learned = climateModel(position: player.position, metric: metric, cutoff: now), estimate > 0 else {
            return (nil, ["El clima se muestra como contexto. No hay suficientes datos históricos o mejora temporal demostrada para ajustar esta métrica."])
        }
        let delta = boundedClimateDelta(learned.delta(temperature: temperature, wind: wind), baseline: estimate)
        return (ProjectionAdjustment(name: "Clima", factor: (estimate + delta) / estimate,
            reason: "Coeficientes regularizados de temperatura y viento; mejora retrospectiva del MAE \(Int(learned.improvement * 100))% frente al mismo modelo sin clima. Límite de extrapolación ±15%.",
            evidenceCount: learned.evidence),
            ["Ajuste meteorológico aprendido con observaciones históricas. El error del pronóstico meteorológico y la precipitación no están calibrados."])
    }

    func make(player: Player, metric: Metric, now: Date = Date(), weather: WeatherContext? = nil,
              context: LiveContext? = nil, requireConfirmedAvailability: Bool = false) throws -> Projection {
        let snapshotAge = now.timeIntervalSince(snapshot.fetchedAt)
        guard snapshotAge >= 0 && snapshotAge <= 24 * 3600 else {
            throw PulseError.message("La descarga está vencida o tiene fecha futura. Actualiza los datos antes de generar otra proyección.")
        }
        guard metric.supports(player.position) else { throw PulseError.message("Esta métrica no corresponde a la posición.") }
        guard player.status == "ACT" else {
            throw PulseError.message("La plantilla no marca a \(player.name) como activo (\(player.status)). No se genera una proyección.")
        }
        guard let game = nextGame(for: player, now: now) else {
            throw PulseError.message("No hay próximo partido con hora confirmada para este equipo.")
        }
        let untilKickoff = game.kickoff.timeIntervalSince(now)
        guard untilKickoff < 16 * 86400 else { throw PulseError.message("El siguiente partido está a más de 16 días. Aún es pronto para proyectarlo.") }
        guard untilKickoff > 6 * 3600 || snapshotAge <= 6 * 3600 else {
            throw PulseError.message("El partido está próximo y las estadísticas tienen más de 6 horas. Actualiza los datos.")
        }
        let availability = availability(player: player, game: game, now: now, context: context)
        guard !availability.status.blocksProjection else {
            throw PulseError.message("\(availability.status.title). Se bloquea la proyección hasta un reporte vigente que confirme participación.")
        }
        guard !requireConfirmedAvailability || untilKickoff > 90 * 60 || availability.status == .active else {
            throw PulseError.message("Faltan 90 minutos o menos. Actualiza la disponibilidad: el modo estricto exige confirmación activa explícita para este partido.")
        }
        let allRows = history(player: player.id, team: player.team, cutoff: now)
        let rows = observedRows(allRows, metric: metric)
        guard rows.count >= 4 else {
            throw PulseError.message("Se necesitan al menos 4 partidos con esta estadística y el equipo actual. Hay \(rows.count). Los datos ausentes no se convierten en cero.")
        }
        guard opportunity(rows, metric: metric) >= minimumOpportunity(metric) else {
            throw PulseError.message("No hay suficiente volumen reciente para proyectar esta métrica.")
        }
        let covered = Set(snapshot.stats.map(\.gameID))
        if snapshot.games.contains(where: { $0.contains(player.team) && $0.completed && $0.kickoff < now.addingTimeInterval(-24 * 3600) && $0.kickoff > now.addingTimeInterval(-21 * 86400) && !covered.contains($0.id) }) {
            throw PulseError.message("Faltan estadísticas de un partido reciente del equipo. Espera a que el proveedor las publique.")
        }
        let choice = selected(rows, metric: metric, opponent: game.opponent(of: player.team), cutoff: now)
        var value = choice.estimate
        var warnings = snapshot.warnings + availability.warnings
        var adjustments: [ProjectionAdjustment] = []
        let factor = choice.usesCandidate ? opponentFactor(game.opponent(of: player.team), metric: metric, position: player.position, cutoff: now) : 1
        if factor != 1 {
            adjustments.append(ProjectionAdjustment(name: "Rival por posición", factor: factor,
                reason: "Volumen permitido por posición, reducido hacia la media de liga. Se usa junto al modelo que mejora la referencia temporal.", evidenceCount: choice.checks))
        }
        let (climate, climateWarnings) = weatherAdjustment(weather: weather, game: game, player: player, metric: metric, now: now, estimate: value)
        warnings += climateWarnings
        if let climate {
            value *= climate.factor; adjustments.append(climate)
            warnings.append("El rango usa residuos históricos del modelo sin clima. Su cobertura publicada no valida la cobertura de esta cifra ajustada por clima.")
        }
        if metric.isCount { value = max(0, value) }
        let range = interval(rows: rows, metric: metric, estimate: value)
        warnings.append("Estimación condicionada a que juegue y mantenga un rol parecido; no es una garantía ni una probabilidad de superar una línea.")
        if untilKickoff <= 90 * 60 && availability.status != .active {
            warnings.append("PARTICIPACIÓN SIN CONFIRMAR A MENOS DE 90 MINUTOS: esta cifra sólo sirve si el jugador participa. Revisa los inactivos oficiales; el modo estricto bloquea esta estimación.")
        }
        warnings.append(choice.usesCandidate ? "Volumen × eficiencia seleccionado con \(choice.checks) comparaciones anteriores al partido." :
            "Se utiliza la media de los últimos 5 partidos: el modelo de volumen y eficiencia no mejora la referencia con suficiente evidencia previa (\(choice.checks) comparaciones).")
        if allRows.count > rows.count { warnings.append("\(allRows.count - rows.count) partidos no contienen esta estadística y se excluyeron; los ceros registrados sí se incluyen.") }
        if let last = rows.last, let lastGame = games[last.gameID], now.timeIntervalSince(lastGame.kickoff) > 21 * 86400 {
            warnings.append("Sin estadísticas del jugador en los últimos 21 días; su rol puede haber cambiado.")
        }
        if range == nil { warnings.append("Muestra insuficiente para un rango empírico individual.") }
        else { warnings.append("Rango empírico de residuos cronológicos 10–90%; su cobertura real se comprueba en Validación.") }
        var relevantContext: LiveContext? = nil
        if let context, context.fetchedAt <= now {
            let news = context.news.filter { item in
                let identity = item.playerIDs.contains(player.id) || (player.espnID.map { item.playerIDs.contains($0) } ?? false)
                return (identity || item.teams.contains(player.team)) && item.publishedAt <= now && now.timeIntervalSince(item.publishedAt) <= 14 * 86400
            }
            relevantContext = LiveContext(fetchedAt: context.fetchedAt, reports: availability.reports, news: news,
                                          sources: context.sources, warnings: context.warnings)
            warnings += context.warnings
            if !news.isEmpty { warnings.append("Noticias recientes disponibles como contexto. Los titulares no confirman lesiones ni redistribuyen oportunidades entre compañeros.") }
        } else { warnings.append("Sin contexto vivo vigente de noticias y disponibilidad; actualiza antes del partido.") }
        return Projection(createdAt: now, player: player, game: game, metric: metric,
            estimate: value, low: range?.0, high: range?.1, sample: min(12, rows.count),
            defenseFactor: factor, recent: Array(rows.suffix(12)).compactMap { $0.observed(metric) }, warnings: warnings,
            model: choice.usesCandidate ? Self.version : "V2 · referencia temporal de 5 partidos",
            dataAsOf: snapshot.fetchedAt, baselineEstimate: choice.baseline, adjustments: adjustments,
            scenarios: [ScenarioEstimate(name: "Participa con rol histórico", estimate: value,
                explanation: "Escenario condicionado, sin probabilidad asignada."),
                ScenarioEstimate(name: "No participa", estimate: 0,
                explanation: "Si no juega, acumula cero. Este escenario no asigna una probabilidad a la ausencia.")],
            availability: availability, weather: weather, context: relevantContext)
    }

    func validate(metric: Metric, now: Date = Date()) -> ValidationReport {
        // Rolling-origin diagnostics use revised source files, not historical as-of snapshots.
        // Live news/availability and forecasts are excluded from historical scoring.
        let candidates = snapshot.stats.filter { row in
            guard let game = games[row.gameID], let value = row.observed(metric), !metric.isCount || value >= 0 else { return false }
            return game.completed && game.kickoff.addingTimeInterval(8 * 3600) < now && metric.supports(row.position)
        }.sorted {
            let d0 = games[$0.gameID]?.kickoff ?? .distantPast
            let d1 = games[$1.gameID]?.kickoff ?? .distantPast
            return d0 == d1 ? $0.id < $1.id : d0 > d1
        }
        var errors: [Double] = [], baselineErrors: [Double] = [], signedErrors: [Double] = []
        var covered = 0, intervals = 0
        for row in candidates {
            guard let game = games[row.gameID], let actual = row.observed(metric) else { continue }
            let previous = observedRows(history(player: row.playerID, team: row.team, cutoff: game.kickoff), metric: metric)
            guard previous.count >= 4, opportunity(previous, metric: metric) >= minimumOpportunity(metric) else { continue }
            let estimate = point(previous, metric: metric, opponent: row.opponent, cutoff: game.kickoff)
            errors.append(abs(estimate - actual)); signedErrors.append(estimate - actual)
            baselineErrors.append(abs(baseline(previous, metric: metric) - actual))
            if let range = interval(rows: previous, metric: metric, estimate: estimate) {
                intervals += 1
                if actual >= range.0 && actual <= range.1 { covered += 1 }
            }
            if errors.count == 400 { break }
        }
        return ValidationReport(count: errors.count,
            mae: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count),
            baselineMAE: baselineErrors.isEmpty ? nil : baselineErrors.reduce(0, +) / Double(baselineErrors.count),
            coverage: intervals == 0 ? nil : Double(covered) / Double(intervals), intervalCount: intervals,
            bias: signedErrors.isEmpty ? nil : signedErrors.reduce(0, +) / Double(signedErrors.count),
            model: "V2 · selección temporal, sin contexto vivo. Diagnóstico retrospectivo de fuentes revisadas.")
    }
}
