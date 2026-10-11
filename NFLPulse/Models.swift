import Foundation

enum Metric: String, Codable, CaseIterable, Identifiable {
    case passing = "passing_yards", rushing = "rushing_yards"
    case receiving = "receiving_yards", receptions = "receptions"
    case carries = "carries", passAttempts = "attempts", completions = "completions"
    case targets = "targets", fieldGoals = "fg_made", fieldGoalAttempts = "fg_att", extraPoints = "pat_made"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .passing: return "Yardas de pase"
        case .rushing: return "Yardas de carrera"
        case .receiving: return "Yardas de recepción"
        case .receptions: return "Recepciones"
        case .carries: return "Acarreos"
        case .passAttempts: return "Intentos de pase"
        case .completions: return "Pases completos"
        case .targets: return "Objetivos de pase"
        case .fieldGoals: return "Goles de campo anotados"
        case .fieldGoalAttempts: return "Intentos de gol de campo"
        case .extraPoints: return "Puntos extra anotados"
        }
    }
    var short: String { title }
    var unit: String {
        switch self {
        case .passing, .rushing, .receiving: return "yardas"
        case .receptions: return "recepciones"
        case .carries: return "acarreos"
        case .passAttempts, .fieldGoalAttempts: return "intentos"
        case .completions: return "pases completos"
        case .targets: return "objetivos"
        case .fieldGoals: return "goles de campo"
        case .extraPoints: return "puntos extra"
        }
    }
    var isCount: Bool { ![Metric.passing, .rushing, .receiving].contains(self) }
    func supports(_ position: String) -> Bool {
        switch self {
        case .passing, .passAttempts, .completions: return position == "QB"
        case .fieldGoals, .fieldGoalAttempts, .extraPoints: return ["K", "PK"].contains(position)
        default: return ["QB", "RB", "FB", "WR", "TE"].contains(position)
        }
    }
}

struct Player: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var team: String
    var position: String
    var status: String
    var espnID: String? = nil
}

struct Game: Identifiable, Codable, Hashable {
    var id: String
    var season: Int
    var week: Int
    var kind: String
    var kickoff: Date
    var home: String
    var away: String
    var stadium: String
    var roof: String
    var location: String
    var completed: Bool
    var temperatureC: Double? = nil
    var windKmh: Double? = nil
    func opponent(of team: String) -> String { team == home ? away : home }
    func contains(_ team: String) -> Bool { home == team || away == team }
}

struct StatLine: Codable, Identifiable {
    var playerID: String
    var gameID: String
    var season: Int
    var week: Int
    var team: String
    var opponent: String
    var position: String
    var passing: Double
    var rushing: Double
    var receiving: Double
    var receptions: Double
    var attempts: Double
    var carries: Double
    var targets: Double
    var completions: Double? = nil
    var fieldGoals: Double? = nil
    var fieldGoalAttempts: Double? = nil
    var extraPoints: Double? = nil
    var id: String { "\(gameID):\(playerID)" }
    func observed(_ metric: Metric) -> Double? {
        let v: Double?
        switch metric {
        case .passing: v = passing
        case .rushing: v = rushing
        case .receiving: v = receiving
        case .receptions: v = receptions
        case .carries: v = carries
        case .passAttempts: v = attempts
        case .targets: v = targets
        case .completions: v = completions
        case .fieldGoals: v = fieldGoals
        case .fieldGoalAttempts: v = fieldGoalAttempts
        case .extraPoints: v = extraPoints
        }
        guard let v, v.isFinite else { return nil }
        return v
    }
    // Compatibility for v0.1 callers; missing values are NEVER converted to zero.
    func value(_ metric: Metric) -> Double { observed(metric) ?? .nan }
}

struct Injury: Codable {
    var playerID: String
    var team: String
    var week: Int
    var season: Int
    var kind: String
    var status: String
    var practice: String
    var detail: String
}

struct SourceStamp: Codable, Identifiable {
    var name: String
    var url: String
    var checkedAt: Date
    var modified: String?
    var rows: Int
    var id: String { name }
}

struct Snapshot: Codable {
    var fetchedAt: Date
    var season: Int
    var players: [Player]
    var games: [Game]
    var stats: [StatLine]
    var injuries: [Injury]
    var sources: [SourceStamp]
    var warnings: [String]
    var lastGameDate: Date? {
        let ids = Set(stats.map(\.gameID))
        return games.filter { ids.contains($0.id) && $0.completed }.map(\.kickoff).max()
    }
}

enum AvailabilityStatus: String, Codable {
    case unknown, active, questionable, doubtful, out, inactive, injuredReserve
    var title: String {
        switch self {
        case .unknown: return "Participación sin confirmar"
        case .active: return "Activo según reporte del partido"
        case .questionable: return "Cuestionable"
        case .doubtful: return "Dudoso"
        case .out: return "Baja reportada"
        case .inactive: return "Inactivo para el partido"
        case .injuredReserve: return "Reserva de lesionados"
        }
    }
    var blocksProjection: Bool { [.out, .doubtful, .inactive, .injuredReserve].contains(self) }
}

struct AvailabilityReport: Codable, Identifiable {
    var id: String
    var playerID: String?
    var espnID: String?
    var name: String
    var team: String
    var status: AvailabilityStatus
    var detail: String
    var reportedAt: Date?
    var checkedAt: Date
    var gameID: String?
    var source: String
    var sourceURL: String
}

struct NewsItem: Codable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var url: String
    var publishedAt: Date
    var source: String
    var playerIDs: [String]
    var teams: [String]
}

struct LiveContext: Codable {
    var fetchedAt: Date
    var reports: [AvailabilityReport]
    var news: [NewsItem]
    var sources: [SourceStamp]
    var warnings: [String]
}

struct AvailabilityAssessment: Codable {
    var status: AvailabilityStatus
    var checkedAt: Date?
    var reports: [AvailabilityReport]
    var warnings: [String]
}

struct WeatherContext: Codable {
    var title: String
    var detail: String
    var checkedAt: Date?
    var temperatureC: Double? = nil
    var windKmh: Double? = nil
    var precipitationProbability: Double? = nil
    var indoor: Bool? = nil
    var sourceURL: String? = nil
    var validAt: Date? = nil
}

struct ProjectionAdjustment: Codable, Identifiable {
    var name: String
    var factor: Double
    var reason: String
    var evidenceCount: Int
    var id: String { name }
}

struct ScenarioEstimate: Codable, Identifiable {
    var name: String
    var estimate: Double
    var explanation: String
    var id: String { name }
}

struct Projection: Codable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date
    var player: Player
    var game: Game
    var metric: Metric
    var estimate: Double
    var low: Double?
    var high: Double?
    var sample: Int
    var defenseFactor: Double
    var recent: [Double]
    var warnings: [String]
    var model: String
    var dataAsOf: Date
    var baselineEstimate: Double? = nil
    var adjustments: [ProjectionAdjustment]? = nil
    var scenarios: [ScenarioEstimate]? = nil
    var availability: AvailabilityAssessment? = nil
    var weather: WeatherContext? = nil
    var context: LiveContext? = nil
}

struct SavedProjection: Codable, Identifiable {
    var projection: Projection
    var actual: Double?
    var settlement: String?
    var corrections: [ResultCorrection]? = nil
    var id: UUID { projection.id }
}

struct ResultCorrection: Codable, Identifiable {
    var id: UUID = UUID()
    var checkedAt: Date
    var previous: Double?
    var revised: Double
}

struct ValidationReport {
    var count: Int
    var mae: Double?
    var baselineMAE: Double?
    var coverage: Double?
    var intervalCount: Int
    var bias: Double? = nil
    var model: String? = nil
}

enum PulseError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

extension String {
    var missing: Bool { isEmpty || self == "NA" || self == "null" }
}
