import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WeatherService {
    // Approximate home metro coordinates, not precise stadium measurements.
    // Never use the home city for a neutral/international game.
    static let metros: [String: (String, Double, Double)] = [
        "ARI": ("Glendale", 33.53, -112.26), "ATL": ("Atlanta", 33.76, -84.40),
        "BAL": ("Baltimore", 39.28, -76.62), "BUF": ("Orchard Park", 42.77, -78.79),
        "CAR": ("Charlotte", 35.23, -80.85), "CHI": ("Chicago", 41.86, -87.62),
        "CIN": ("Cincinnati", 39.10, -84.52), "CLE": ("Cleveland", 41.51, -81.70),
        "DAL": ("Arlington", 32.75, -97.09), "DEN": ("Denver", 39.74, -105.02),
        "DET": ("Detroit", 42.34, -83.05), "GB": ("Green Bay", 44.50, -88.06),
        "HOU": ("Houston", 29.68, -95.41), "IND": ("Indianapolis", 39.76, -86.16),
        "JAX": ("Jacksonville", 30.32, -81.64), "KC": ("Kansas City", 39.05, -94.48),
        "LA": ("Inglewood", 33.95, -118.34), "LAR": ("Inglewood", 33.95, -118.34),
        "LAC": ("Inglewood", 33.95, -118.34), "LV": ("Las Vegas", 36.09, -115.18),
        "MIA": ("Miami Gardens", 25.96, -80.24), "MIN": ("Minneapolis", 44.97, -93.26),
        "NE": ("Foxborough", 42.09, -71.26), "NO": ("New Orleans", 29.95, -90.08),
        "NYG": ("East Rutherford", 40.81, -74.07), "NYJ": ("East Rutherford", 40.81, -74.07),
        "PHI": ("Philadelphia", 39.90, -75.17), "PIT": ("Pittsburgh", 40.45, -80.02),
        "SEA": ("Seattle", 47.60, -122.33), "SF": ("Santa Clara", 37.40, -121.97),
        "TB": ("Tampa", 27.98, -82.50), "TEN": ("Nashville", 36.17, -86.77),
        "WAS": ("Landover", 38.91, -76.86)
    ]
    // These named venues may be used for neutral games; the home team's city may not.
    static let neutralVenues: [String: (String, Double, Double)] = [
        "wembley stadium": ("Wembley, Londres", 51.556, -0.2796),
        "tottenham hotspur stadium": ("Tottenham, Londres", 51.6043, -0.0664),
        "allianz arena": ("Múnich", 48.2188, 11.6247),
        "deutsche bank park": ("Fráncfort", 50.0686, 8.6455),
        "arena corinthians": ("São Paulo", -23.5453, -46.4742),
        "neo quimica arena": ("São Paulo", -23.5453, -46.4742)
    ]
    static let homeVenues: [String: [String]] = [
        "ARI": ["State Farm Stadium"], "ATL": ["Mercedes-Benz Stadium"], "BAL": ["M&T Bank Stadium"],
        "BUF": ["Highmark Stadium", "New Highmark Stadium"], "CAR": ["Bank of America Stadium"], "CHI": ["Soldier Field"],
        "CIN": ["Paycor Stadium", "Paul Brown Stadium"], "CLE": ["Huntington Bank Field", "Cleveland Browns Stadium", "FirstEnergy Stadium"],
        "DAL": ["AT&T Stadium"], "DEN": ["Empower Field at Mile High", "Sports Authority Field at Mile High"],
        "DET": ["Ford Field"], "GB": ["Lambeau Field"], "HOU": ["NRG Stadium"], "IND": ["Lucas Oil Stadium"],
        "JAX": ["EverBank Stadium", "TIAA Bank Field", "EverBank Field"], "KC": ["GEHA Field at Arrowhead Stadium", "Arrowhead Stadium"],
        "LA": ["SoFi Stadium"], "LAR": ["SoFi Stadium"], "LAC": ["SoFi Stadium"], "LV": ["Allegiant Stadium"],
        "MIA": ["Hard Rock Stadium"], "MIN": ["U.S. Bank Stadium", "US Bank Stadium"], "NE": ["Gillette Stadium"],
        "NO": ["Caesars Superdome", "Mercedes-Benz Superdome"], "NYG": ["MetLife Stadium"], "NYJ": ["MetLife Stadium"],
        "PHI": ["Lincoln Financial Field"], "PIT": ["Acrisure Stadium", "Heinz Field"], "SEA": ["Lumen Field", "CenturyLink Field"],
        "SF": ["Levi's Stadium"], "TB": ["Raymond James Stadium"], "TEN": ["Nissan Stadium"],
        "WAS": ["Northwest Stadium", "FedExField", "FedEx Field"]
    ]
    struct Payload: Decodable { var hourly: Hourly; var hourly_units: Units? }
    struct Units: Decodable {
        var temperature_2m: String?
        var wind_speed_10m: String?
        var precipitation_probability: String?
    }
    struct Hourly: Decodable {
        var time: [Double]
        var temperature_2m: [Double?]
        var precipitation_probability: [Double?]
        var wind_speed_10m: [Double?]
    }
    static func fetch(game: Game, now: Date = Date()) async -> WeatherContext {
        if ["dome", "closed"].contains(game.roof.lowercased()) {
            return WeatherContext(title: "Recinto cerrado según calendario", detail: "El clima exterior no describe las condiciones dentro del estadio. Revisa cambios de apertura del techo.", checkedAt: nil, indoor: true)
        }
        guard let metro = venue(game: game) else {
            return WeatherContext(title: "Ubicación por confirmar", detail: "No se asigna clima de la ciudad local a una sede neutral o internacional.", checkedAt: nil)
        }
        guard game.kickoff > now, game.kickoff.timeIntervalSince(now) < 15 * 86400 else {
            return WeatherContext(title: "Fuera del horizonte meteorológico", detail: "Vuelve a consultar cuando se acerque el partido.", checkedAt: nil)
        }
        let raw = "https://api.open-meteo.com/v1/forecast?latitude=\(metro.1)&longitude=\(metro.2)&hourly=temperature_2m,precipitation_probability,wind_speed_10m&forecast_days=16&timeformat=unixtime&timezone=GMT&temperature_unit=celsius&wind_speed_unit=kmh&precipitation_unit=mm"
        do {
            var request = URLRequest(url: URL(string: raw)!)
            request.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PulseError.message("Open-Meteo devolvió HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            return try parse(data: data, game: game, now: now, sourceURL: raw, location: metro.0)
        } catch {
            return WeatherContext(title: "Clima no disponible", detail: "No se asumen condiciones favorables. \(error.localizedDescription)", checkedAt: nil)
        }
    }

    static func venue(game: Game) -> (String, Double, Double)? {
        let key = venueKey(game.stadium)
        // nflverse occasionally labels an international home-designated matchup as Home.
        if let international = neutralVenues[key] { return international }
        guard game.location.lowercased() == "home", let known = homeVenues[game.home],
              known.map(venueKey).contains(key) else { return nil }
        return metros[game.home]
    }

    static func venueKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func parse(data: Data, game: Game, now: Date, sourceURL: String, location: String) throws -> WeatherContext {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let units = payload.hourly_units, units.temperature_2m == "°C",
              ["km/h", "kmh"].contains(units.wind_speed_10m ?? ""), units.precipitation_probability == "%" else {
            throw PulseError.message("El proveedor meteorológico cambió de unidades o formato.")
        }
        let hourly = payload.hourly
        let target = game.kickoff.timeIntervalSince1970
        guard !hourly.time.isEmpty, hourly.time.allSatisfy(\.isFinite),
              let i = hourly.time.indices.min(by: { abs(hourly.time[$0] - target) < abs(hourly.time[$1] - target) }),
              abs(hourly.time[i] - target) <= 3600,
              i < hourly.temperature_2m.count, i < hourly.wind_speed_10m.count,
              i < hourly.precipitation_probability.count,
              let temp = hourly.temperature_2m[i], temp.isFinite, (-100...70).contains(temp),
              let wind = hourly.wind_speed_10m[i], wind.isFinite, (0...500).contains(wind),
              let rain = hourly.precipitation_probability[i], rain.isFinite, (0...100).contains(rain) else {
            throw PulseError.message("Sin pronóstico válido para la hora de inicio.")
        }
        let indoor: Bool? = ["outdoors", "open"].contains(game.roof.lowercased()) ? false : nil
        return WeatherContext(title: "\(Int(temp.rounded())) °C · viento \(Int(wind.rounded())) km/h · lluvia \(Int(rain.rounded())) %",
            detail: "Open-Meteo · área de \(location), próxima al estadio · hora del inicio. Techo: \(game.roof.missing ? "sin confirmar" : game.roof). La proyección muestra si hay evidencia histórica suficiente para aplicar un ajuste.",
            checkedAt: now, temperatureC: temp, windKmh: wind, precipitationProbability: rain,
            indoor: indoor, sourceURL: sourceURL, validAt: Date(timeIntervalSince1970: hourly.time[i]))
    }
}
