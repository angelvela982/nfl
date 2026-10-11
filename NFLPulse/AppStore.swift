import Foundation
import SwiftUI
import BackgroundTasks

@MainActor
final class AppStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var saved: [SavedProjection] = []
    @Published var loading = false
    @Published var projecting = false
    @Published var error: String?
    @Published var message: String?
    @Published var projection: Projection?
    @Published var weather: WeatherContext?
    @Published var liveContext: LiveContext?
    @Published var availability: AvailabilityAssessment?
    @Published var selectionIssue: String?
    @Published var selectedPlayer: Player?
    @Published var selectedMetric: Metric = .rushing
    @Published var validation: ValidationReport?
    @Published var validating = false
    @Published var validatedMetric: Metric?
    @Published private(set) var continuousServiceURLString: String
    @Published var requireConfirmedAvailability: Bool {
        didSet { UserDefaults.standard.set(requireConfirmedAvailability, forKey: Self.strictKey) }
    }
    @Published var checkingService = false
    @Published var serviceStatusTitle = "Modo directo"
    @Published var serviceStatusDetail = "Las consultas se realizan mientras la app puede ejecutarse."
    @Published var serviceCheckedAt: Date?
    private let service = DataService()
    private var lastSnapshotAttempt: Date?
    private var lastContextAttempt: Date?
    private var snapshotWritable = true
    private var historyWritable = true
    private static let serviceKey = "NFLPulse.continuousServiceURL"
    private static let strictKey = "NFLPulse.requireConfirmedAvailability"
    static let backgroundID = "com.hermano.nflpulse.refresh"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NFLPulse", isDirectory: true)
    }

    var serverURL: URL? { Self.validServiceURL(continuousServiceURLString) }
    var busy: Bool { loading || projecting || validating }
    var selectedGame: Game? {
        guard let player = selectedPlayer, let snapshot else { return nil }
        return snapshot.games.filter { $0.contains(player.team) && !$0.completed && $0.kickoff > Date() }
            .min { $0.kickoff < $1.kickoff }
    }
    var contextRefreshInterval: TimeInterval {
        if let game = selectedGame, game.kickoff.timeIntervalSinceNow < 90 * 60 { return 2 * 60 }
        return 15 * 60
    }

    init() {
        let storedURL = UserDefaults.standard.string(forKey: Self.serviceKey) ?? ""
        continuousServiceURLString = Self.validServiceURL(storedURL) == nil ? "" : storedURL
        requireConfirmedAvailability = UserDefaults.standard.bool(forKey: Self.strictKey)
        var issues: [String] = []
        do { try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true) }
        catch { issues.append("No se pudo preparar el almacenamiento: \(error.localizedDescription)") }
        // Decode independently: a damaged snapshot must not discard prediction history.
        let snapshotURL = Self.directory.appendingPathComponent("snapshot.json")
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            do { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL)) }
            catch {
                let backup = Self.preserveCorrupt(snapshotURL, description: "datos")
                issues.append(backup.message); snapshotWritable = backup.preserved
            }
        }
        let historyURL = Self.directory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { saved = try JSONDecoder().decode([SavedProjection].self, from: Data(contentsOf: historyURL)) }
            catch {
                let backup = Self.preserveCorrupt(historyURL, description: "historial")
                issues.append(backup.message); historyWritable = backup.preserved
            }
        }
        if !issues.isEmpty { self.error = issues.joined(separator: "\n") }
        if !continuousServiceURLString.isEmpty {
            serviceStatusTitle = "Servicio sin comprobar"
            serviceStatusDetail = "Comprueba la conexión para conocer el estado del servicio."
        }
    }

    private static func preserveCorrupt(_ url: URL, description: String) -> (message: String, preserved: Bool) {
        let backup = url.deletingPathExtension().appendingPathExtension("corrupto-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            return ("No se pudo leer el \(description). Se conservó una copia del archivo dañado para recuperarlo.", true)
        } catch {
            return ("No se pudo leer el \(description) ni crear su respaldo. Se conserva el archivo original.", false)
        }
    }

    func select(_ player: Player) {
        selectedPlayer = player
        if player.position == "QB" { selectedMetric = .passing }
        else if ["RB", "FB"].contains(player.position) { selectedMetric = .rushing }
        else if ["K", "PK"].contains(player.position) { selectedMetric = .fieldGoals }
        else { selectedMetric = .receiving }
        projection = nil; weather = nil; liveContext = nil; availability = nil; selectionIssue = nil
        lastContextAttempt = nil
    }

    func selectMetric(_ metric: Metric) {
        selectedMetric = metric
        projection = nil; selectionIssue = nil
    }

    func refreshIfNeeded() async {
        guard !busy else { return }
        let now = Date()
        var updated = false
        let oldSnapshot = snapshot.map { now.timeIntervalSince($0.fetchedAt) > 6 * 3600 } ?? true
        if oldSnapshot && (lastSnapshotAttempt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true) {
            updated = await refresh()
        }
        guard !Task.isCancelled else { return }
        let oldContext = liveContext.map { now.timeIntervalSince($0.fetchedAt) >= contextRefreshInterval } ?? true
        let canRetry = lastContextAttempt.map { now.timeIntervalSince($0) >= contextRefreshInterval } ?? true
        if selectedPlayer != nil && (updated || (oldContext && canRetry)) { await projectSelection() }
        if serverURL != nil && (serviceCheckedAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true) {
            await checkServiceConnection()
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !busy else { return false }
        loading = true
        lastSnapshotAttempt = Date()
        defer { loading = false }
        do {
            let fresh = try await service.refresh()
            try Task.checkCancellation()
            guard snapshotWritable else { throw PulseError.message("No se sobrescriben los datos dañados mientras no exista un respaldo.") }
            try JSONEncoder().encode(fresh).write(to: Self.directory.appendingPathComponent("snapshot.json"), options: .atomic)
            snapshot = fresh
            if let selectedPlayer { self.selectedPlayer = fresh.players.first { $0.id == selectedPlayer.id } }
            projection = nil; weather = nil; liveContext = nil; availability = nil; selectionIssue = nil
            lastContextAttempt = nil; validation = nil; validatedMetric = nil
            do { try settle(with: fresh) }
            catch { self.error = "Los datos se actualizaron, pero no se pudo guardar el resultado del historial. \(error.localizedDescription)" }
            return true
        } catch is CancellationError { return false }
        catch {
            self.error = "No se completó la actualización. Se conserva la última copia válida. \(error.localizedDescription)"
            return false
        }
    }

    func refreshAll() async {
        _ = await refresh()
        if selectedPlayer != nil && snapshot != nil { await projectSelection() }
        if serverURL != nil { await checkServiceConnection() }
    }

    func projectSelection() async {
        guard let selectedPlayer else { return }
        await project(player: selectedPlayer, metric: selectedMetric)
    }

    func project(player: Player, metric: Metric) async {
        guard let snapshot, !busy else { return }
        guard metric.supports(player.position) else {
            selectionIssue = "Esta métrica no corresponde a la posición del jugador."; return
        }
        selectedPlayer = player; selectedMetric = metric
        projecting = true; projection = nil; selectionIssue = nil
        lastContextAttempt = Date()
        defer { projecting = false }
        guard let game = selectedGame else {
            liveContext = nil; weather = nil; availability = nil
            selectionIssue = "No hay un partido futuro publicado para este equipo. Actualiza el calendario."; return
        }
        let endpoint = serverURL
        async let freshContext = LiveContextService.fetch(player: player, game: game, now: Date(), serverURL: endpoint)
        async let freshWeather = WeatherService.fetch(game: game, now: Date())
        let (context, conditions) = await (freshContext, freshWeather)
        guard !Task.isCancelled else { return }
        liveContext = context; weather = conditions
        let now = Date()
        availability = ProjectionEngine(snapshot: snapshot).availability(player: player, game: game, now: now, context: context)
        let strict = requireConfirmedAvailability
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ProjectionEngine(snapshot: snapshot).make(player: player, metric: metric, now: now,
                    weather: conditions, context: context, requireConfirmedAvailability: strict)
            }.value
            try Task.checkCancellation()
            projection = result
            availability = result.availability ?? availability
        } catch is CancellationError { }
        catch { selectionIssue = error.localizedDescription }
    }

    func saveProjection() {
        guard let projection else { return }
        guard Date() < projection.game.kickoff else {
            error = "El partido ya comenzó. No se guardan predicciones después del inicio."; return
        }
        guard !saved.contains(where: {
            $0.projection.player.id == projection.player.id && $0.projection.game.id == projection.game.id
                && $0.projection.metric == projection.metric
        }) else {
            message = "Ya guardaste esta combinación. Se conserva la primera predicción para evaluar sin elegir el resultado más conveniente."; return
        }
        var next = saved
        next.insert(SavedProjection(projection: projection, actual: nil, settlement: nil), at: 0)
        do { try persist(next); saved = next; message = "Predicción guardada antes del partido, con sus fuentes y condiciones." }
        catch { self.error = "No se pudo guardar el historial. \(error.localizedDescription)" }
    }

    private func persist(_ rows: [SavedProjection]) throws {
        guard historyWritable else { throw PulseError.message("No se sobrescribe el historial dañado mientras no exista un respaldo.") }
        try JSONEncoder().encode(rows).write(to: Self.directory.appendingPathComponent("history.json"), options: .atomic)
    }

    private func settle(with snapshot: Snapshot) throws {
        let gameMap = Dictionary(snapshot.games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let statMap = Dictionary(snapshot.stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next = saved
        var changed = false
        for i in next.indices {
            let p = next[i].projection
            guard let game = gameMap[p.game.id], game.completed else { continue }
            let previous = next[i].actual
            if let actual = statMap["\(p.game.id):\(p.player.id)"]?.observed(p.metric) {
                if previous != actual {
                    if let previous, previous.isFinite {
                        var corrections = next[i].corrections ?? []
                        corrections.append(ResultCorrection(checkedAt: Date(), previous: previous, revised: actual))
                        next[i].corrections = corrections
                    }
                    next[i].actual = actual
                    next[i].settlement = previous == nil
                        ? "Resultado registrado · sujeto a correcciones oficiales"
                        : "Corrección del proveedor: \(String(format: "%.1f", previous!)) → \(String(format: "%.1f", actual)) · \(Date().formatted())"
                    changed = true
                }
            } else if previous == nil {
                let status = "Sin dato observado para esta métrica: pendiente o DNP. No se interpreta como cero."
                if next[i].settlement != status { next[i].settlement = status; changed = true }
            }
        }
        if changed { try persist(next); saved = next }
    }

    func validate(_ metric: Metric) async {
        guard let snapshot, !busy else { return }
        validating = true; validation = nil; validatedMetric = nil
        defer { validating = false }
        let result = await Task.detached(priority: .userInitiated) {
            ProjectionEngine(snapshot: snapshot).validate(metric: metric)
        }.value
        guard !Task.isCancelled else { return }
        validation = result; validatedMetric = metric
    }

    func exportHistory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NFLPulse-historial.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: url, options: .atomic)
        return url
    }

    private static func validServiceURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"), host != "::1", !host.hasPrefix("127."),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }

    func configureService(_ input: String) async {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty || Self.validServiceURL(raw) != nil else {
            error = "Introduce la URL HTTPS de tu servicio, sin contraseña, parámetros ni dirección local. Déjala vacía para usar las fuentes directamente."; return
        }
        continuousServiceURLString = raw
        UserDefaults.standard.set(raw, forKey: Self.serviceKey)
        serviceCheckedAt = nil; liveContext = nil; availability = nil; projection = nil; lastContextAttempt = nil
        await checkServiceConnection()
        if selectedPlayer != nil { await projectSelection() }
    }

    func checkServiceConnection() async {
        guard !checkingService else { return }
        guard let serverURL else {
            serviceStatusTitle = "Modo directo"
            serviceStatusDetail = "Sin servicio continuo configurado. Las fuentes se consultan mientras la app puede ejecutarse."
            serviceCheckedAt = nil; return
        }
        checkingService = true
        defer { checkingService = false }
        do {
            var request = URLRequest(url: serverURL.appendingPathComponent("health"))
            request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = payload["status"] as? String else {
                throw PulseError.message("El endpoint /health no devolvió un estado válido.")
            }
            switch status.lowercased() {
            case "ok":
                serviceStatusTitle = "Servicio operativo"
                serviceStatusDetail = "El servicio informa estado operativo. Cada consulta conserva las fechas y advertencias de las fuentes."
            case "degraded":
                serviceStatusTitle = "Servicio degradado"
                serviceStatusDetail = "Alguna fuente o tarea está fallando. Revisa las advertencias y la antigüedad de los reportes antes de usar una proyección."
            case "starting":
                serviceStatusTitle = "Servicio iniciando"
                serviceStatusDetail = "Todavía no está lista la primera actualización. Se indican las fuentes faltantes en cada consulta."
            default:
                serviceStatusTitle = "Estado del servicio desconocido"
                serviceStatusDetail = "El servicio respondió con un estado no reconocido. No se considera una conexión verificada."
            }
            if let scheduler = payload["schedulerRunning"] as? Bool, !scheduler {
                serviceStatusTitle = "Servicio degradado"
                serviceStatusDetail += " El proceso de actualización continua está detenido."
            }
            if let feeds = payload["feeds"] as? [String: [String: Any]], !feeds.isEmpty {
                let unavailable = feeds.values.filter { ($0["available"] as? Bool) != true }.count
                let stale = feeds.values.filter { ($0["available"] as? Bool) == true && ($0["fresh"] as? Bool) != true }.count
                if unavailable > 0 || stale > 0 {
                    serviceStatusTitle = "Servicio degradado"
                    serviceStatusDetail += " \(unavailable) fuentes sin datos y \(stale) fuentes con datos antiguos."
                }
                let dates = feeds.values.compactMap { feed -> Date? in
                    guard let raw = feed["checkedAt"] as? String else { return nil }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: raw) { return date }
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: raw)
                }
                if let oldest = dates.min() {
                    serviceStatusDetail += " Último éxito más antiguo de las fuentes: \(oldest.formatted(date: .abbreviated, time: .shortened))."
                }
            }
            serviceCheckedAt = Date()
        } catch is CancellationError { }
        catch {
            serviceStatusTitle = "Servicio sin conexión"
            serviceStatusDetail = "No se pudo comprobar /health. \(error.localizedDescription)"
            serviceCheckedAt = Date()
        }
    }

    func scheduleBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        // iOS chooses whether and when to run; the remote service is the continuous option.
        try? BGTaskScheduler.shared.submit(request)
    }
}
