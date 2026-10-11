import SwiftUI
import Charts

enum Palette {
    static let gold = Color(red: 1, green: 0.76, blue: 0.28)
    static let base = Color(red: 0.045, green: 0.055, blue: 0.075)
    static let panel = Color(red: 0.09, green: 0.105, blue: 0.13)
    static let teal = Color(red: 0.37, green: 0.86, blue: 0.76)
}

private func sourceURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
    return url
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        TabView {
            NavigationStack { ProjectView() }.tabItem { Label("Proyectar", systemImage: "waveform.path.ecg") }
            NavigationStack { HistoryView() }.tabItem { Label("Historial", systemImage: "clock.arrow.circlepath") }
            NavigationStack { DataView() }.tabItem { Label("Datos", systemImage: "chart.bar.doc.horizontal") }
        }
        .tint(Palette.gold)
        .alert("Aviso", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Entendido") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Historial", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("Entendido") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct ProjectView: View {
    @EnvironmentObject var store: AppStore
    @State private var showPlayers = false
    private var availableMetrics: [Metric] {
        guard let player = store.selectedPlayer else { return Metric.allCases }
        return Metric.allCases.filter { $0.supports(player.position) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NFL").font(.largeTitle.weight(.black))
                    Text("PULSE").font(.largeTitle.weight(.black)).foregroundStyle(Palette.gold)
                    Spacer()
                    Text("BETA 0.2").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                if let data = store.snapshot {
                    freshness(data)
                    Panel {
                        Text("TU PRÓXIMA PROYECCIÓN").font(.caption.weight(.semibold)).foregroundStyle(Palette.gold)
                        Button { showPlayers = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(store.selectedPlayer?.name ?? "Selecciona un jugador").font(.title3.bold()).foregroundStyle(.white)
                                    Text(store.selectedPlayer.map { "\($0.position) · \($0.team)" } ?? "Busca por nombre o equipo")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "magnifyingglass").foregroundStyle(Palette.gold)
                            }.padding(.vertical, 8)
                        }.disabled(store.busy)
                        Divider()
                        Picker("Estadística", selection: Binding(get: { store.selectedMetric }, set: { metric in
                            store.selectMetric(metric)
                            Task { await store.projectSelection() }
                        })) {
                            ForEach(availableMetrics) { item in Text(item.title).tag(item) }
                        }.pickerStyle(.menu).disabled(store.busy || store.selectedPlayer == nil)
                        if let player = store.selectedPlayer, let game = store.selectedGame {
                            HStack {
                                Image(systemName: "shield.lefthalf.filled").foregroundStyle(Palette.teal)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("vs. \(game.opponent(of: player.team))").bold()
                                    Text(game.kickoff, format: .dateTime.weekday().day().month().hour().minute())
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(game.stadium).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button { Task { await store.projectSelection() } } label: {
                            HStack {
                                if store.projecting { ProgressView().tint(.black) }
                                Image(systemName: "bolt.fill")
                                Text(store.projecting ? "Consultando y calculando…" : "Consultar y proyectar").bold()
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                            .disabled(store.selectedPlayer == nil || store.busy)
                        Text("Consulta disponibilidad, noticias y clima antes de calcular. Solo aparecen métricas compatibles con la posición.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let issue = store.selectionIssue {
                        Panel {
                            Label("Proyección no disponible", systemImage: "exclamationmark.shield").font(.headline).foregroundStyle(Palette.gold)
                            Text(issue).font(.subheadline)
                            Text("Puedes revisar abajo los reportes y sus fuentes aunque la proyección esté bloqueada.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let projection = store.projection { ProjectionCard(projection: projection) }
                    if store.liveContext != nil || store.weather != nil {
                        ContextCard(context: store.liveContext, availability: store.availability, weather: store.weather)
                    }
                    if store.projection == nil {
                        Label("Las proyecciones expresan una estimación y pueden fallar. Ningún reporte garantiza participación ni rendimiento.", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Panel {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(Palette.gold)
                        Text(store.loading ? "Consultando fuentes…" : "Primero, datos reales").font(.title2.bold())
                        Text("Descarga estadísticas, calendario y plantillas. Los reportes recientes se consultan al seleccionar un jugador.")
                            .foregroundStyle(.secondary)
                        if store.loading { ProgressView() }
                        else { Button("Descargar datos") { Task { await store.refreshAll() } }.buttonStyle(.borderedProminent).foregroundStyle(.black) }
                    }
                }
            }.padding(20)
        }.background(Palette.base).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refreshAll() } } label: {
                        if store.loading { ProgressView() } else { Label("Actualizar", systemImage: "arrow.clockwise") }
                    }.disabled(store.busy)
                }
            }
            .sheet(isPresented: $showPlayers) {
                PlayerPicker(players: store.snapshot?.players ?? []) { player in
                    store.select(player)
                    Task { await store.projectSelection() }
                }
            }
    }
    private func freshness(_ data: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Temporada \(String(data.season)) · estadísticas nflverse", systemImage: "externaldrive.badge.checkmark")
            Text("Descarga: \(data.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            if let latest = data.lastGameDate {
                Text("Último partido con datos: \(latest.formatted(date: .abbreviated, time: .omitted))")
            }
            if Date().timeIntervalSince(data.fetchedAt) > 6 * 3600 {
                Text("Copia antigua: actualiza antes de proyectar").foregroundStyle(Palette.gold).bold()
            }
        }.font(.subheadline).foregroundStyle(.secondary)
    }
}

struct PlayerPicker: View {
    let players: [Player]
    let select: (Player) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var filtered: [Player] {
        players.filter { query.isEmpty || "\($0.name) \($0.team) \($0.position)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List(filtered) { player in
                Button { select(player); dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.name).foregroundStyle(.primary).bold()
                            Text("\(player.position) · \(player.team)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if player.status != "ACT" { Text(player.status).font(.caption).foregroundStyle(Palette.gold) }
                    }.padding(.vertical, 4)
                }
            }.searchable(text: $query, prompt: "Jugador, equipo o posición")
                .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: query) } }
                .navigationTitle("Jugadores")
                .toolbar { Button("Listo") { dismiss() } }
        }.tint(Palette.gold)
    }
}

struct ProjectionCard: View {
    @EnvironmentObject var store: AppStore
    let projection: Projection
    private var conditional: Bool { projection.availability?.status != .active }
    var body: some View {
        Panel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(projection.player.name).font(.title2.bold())
                    Text("\(projection.player.team) · vs. \(projection.game.opponent(of: projection.player.team))").foregroundStyle(.secondary)
                }
                Spacer()
                Text(conditional ? "CONDICIONAL" : "ESTIMACIÓN").font(.caption.bold()).foregroundStyle(Palette.gold)
            }
            Divider()
            Text(projection.metric.title.uppercased()).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.gold)
            Text(projection.estimate, format: .number.precision(.fractionLength(1)))
                .font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Text("Estimación media · no es un mínimo ni una garantía").font(.subheadline).foregroundStyle(.secondary)
            if conditional {
                Label("Condicionada a que juegue con una carga comparable al historial. Su participación aún no está confirmada.", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.subheadline).foregroundStyle(Palette.gold)
            }
            if let low = projection.low, let high = projection.high {
                HStack {
                    Text("\(low, specifier: "%.1f")")
                    Rectangle().fill(LinearGradient(colors: [Palette.gold.opacity(0.3), Palette.gold], startPoint: .leading, endPoint: .trailing)).frame(height: 6)
                    Text("\(high, specifier: "%.1f")")
                }.font(.headline.monospacedDigit())
                Text("Rango orientativo P10–P90 de errores históricos, condicionado a participación comparable. Puede quedar fuera; la cobertura futura se mide en tu historial.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("No hay evidencia suficiente para mostrar un rango de errores.").font(.subheadline).foregroundStyle(Palette.gold)
            }
            if let baseline = projection.baselineEstimate {
                Text("Referencia sin ajustes: \(baseline, specifier: "%.1f") \(projection.metric.unit)").font(.subheadline)
            }
            Text("\(projection.sample) partidos comparables · modelo \(projection.model)").font(.caption).foregroundStyle(.secondary)
            Text("Datos deportivos hasta: \(projection.dataAsOf.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let adjustments = projection.adjustments, !adjustments.isEmpty {
                DisclosureGroup("Desglose de ajustes") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(adjustments) { adjustment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(adjustment.name): \((adjustment.factor - 1) * 100, specifier: "%+.1f") %").bold()
                                Text(adjustment.reason)
                                Text("\(adjustment.evidenceCount) observaciones de apoyo").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.font(.subheadline).padding(.top, 8)
                }
            }
            if let scenarios = projection.scenarios, !scenarios.isEmpty {
                DisclosureGroup("Escenarios de sensibilidad") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scenarios) { scenario in
                            Text("\(scenario.name): \(scenario.estimate, specifier: "%.1f")").bold()
                            Text(scenario.explanation).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Son supuestos para comparar escenarios; no se les asigna una probabilidad.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            Divider()
            Text("Partidos registrados, del más antiguo al reciente").font(.subheadline).foregroundStyle(.secondary)
            Chart(Array(projection.recent.enumerated()), id: \.offset) { entry in
                BarMark(x: .value("Partido", entry.offset + 1), y: .value(projection.metric.unit, entry.element))
                    .foregroundStyle(Palette.gold.gradient).cornerRadius(4)
            }.frame(height: 150).accessibilityLabel("Rendimiento en los últimos partidos registrados")
            ForEach(Array(projection.warnings.enumerated()), id: \.offset) { warning in
                Label(warning.element, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Palette.gold)
            }
            Button { store.saveProjection() } label: {
                Label("Guardar antes del partido", systemImage: "bookmark").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }
}

struct ContextCard: View {
    let context: LiveContext?
    let availability: AvailabilityAssessment?
    let weather: WeatherContext?
    var body: some View {
        Panel {
            Label("Disponibilidad y contexto", systemImage: "newspaper").font(.headline)
            if let availability {
                Text(availability.status.title).font(.headline).foregroundStyle(availability.status == .active ? Palette.teal : Palette.gold)
                if let checked = availability.checkedAt {
                    Text("Reporte consultado: \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(availability.reports) { report in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.detail).font(.subheadline)
                        if let published = report.reportedAt {
                            Text("Publicado: \(published.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("La fuente no informó la fecha de publicación.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let url = sourceURL(report.sourceURL) { Link(report.source, destination: url).font(.caption) }
                    }
                }
                ForEach(Array(availability.warnings.enumerated()), id: \.offset) { warning in
                    Text(warning.element).font(.subheadline).foregroundStyle(Palette.gold)
                }
            } else {
                Text("Participación sin confirmar").foregroundStyle(Palette.gold)
            }
            if let weather {
                Divider()
                Label(weather.title, systemImage: "cloud.sun").font(.headline)
                Text(weather.detail).font(.subheadline).foregroundStyle(.secondary)
                if let valid = weather.validAt { Text("Pronóstico válido: \(valid.formatted())").font(.caption).foregroundStyle(.secondary) }
                if let checked = weather.checkedAt { Text("Consulta: \(checked.formatted())").font(.caption).foregroundStyle(.secondary) }
                if let raw = weather.sourceURL, let url = sourceURL(raw) { Link("Fuente del clima", destination: url).font(.caption) }
            }
            if let context {
                Divider()
                Text("Noticias recientes").font(.headline)
                Text("Consulta: \(context.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if context.news.isEmpty {
                    Text("No se encontraron noticias relacionadas en las fuentes consultadas. Esto no confirma que no haya novedades.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(context.news) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = sourceURL(item.url) { Link(item.title, destination: url).font(.subheadline.bold()) }
                        else { Text(item.title).font(.subheadline.bold()) }
                        if !item.summary.isEmpty { Text(item.summary).font(.subheadline).foregroundStyle(.secondary) }
                        Text("\(item.source) · \(item.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Text("Los titulares se muestran como evidencia para revisar. No se convierten automáticamente en porcentajes de rendimiento.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(context.warnings.enumerated()), id: \.offset) { warning in
                    Label(warning.element, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Palette.gold)
                }
                DisclosureGroup("Fuentes del contexto") {
                    ForEach(context.sources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            if let url = sourceURL(source.url) { Link(source.name, destination: url) }
                            else { Text(source.name) }
                            Text("\(source.rows) registros · consulta \(source.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            Text("Publicación/modificación: \(source.modified ?? "no informada")").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var export: URL?
    private var settledMetrics: [Metric] {
        Metric.allCases.filter { metric in store.saved.contains { $0.projection.metric == metric && $0.actual?.isFinite == true } }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Lo proyectado, frente a lo real.").font(.title2.bold())
                Text("Se conserva la primera predicción por jugador, partido y métrica. Cada actualización consulta resultados y posibles correcciones del proveedor.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !settledMetrics.isEmpty {
                    Panel {
                        Label("Evaluación prospectiva", systemImage: "chart.xyaxis.line").font(.headline)
                        Text("Predicciones guardadas antes del inicio. Se mide cada métrica y versión del modelo por separado; no se suman yardas e intentos.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(settledMetrics) { metric in prospectiveSummary(metric) }
                        Text("Solo se evalúan resultados disponibles. Los pendientes y DNP sin fila no se convierten en cero; esta selección puede afectar el error observado.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if store.saved.isEmpty {
                    ContentUnavailableView("Aún no hay predicciones", systemImage: "bookmark", description: Text("Guarda una proyección antes del inicio para medirla después."))
                }
                ForEach(store.saved) { entry in
                    Panel {
                        Text(entry.projection.player.name).font(.headline)
                        Text("\(entry.projection.metric.title) · vs. \(entry.projection.game.opponent(of: entry.projection.player.team))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            valueBox("PROYECCIÓN", entry.projection.estimate)
                            Spacer()
                            if let actual = entry.actual, actual.isFinite { valueBox("REAL", actual) }
                            else { Text("Pendiente").foregroundStyle(Palette.gold) }
                        }
                        if let actual = entry.actual, actual.isFinite {
                            Text("Error absoluto: \(abs(actual - entry.projection.estimate), specifier: "%.1f") \(entry.projection.metric.unit)").font(.subheadline)
                            if let low = entry.projection.low, let high = entry.projection.high {
                                Text(actual >= low && actual <= high ? "Resultado dentro del rango guardado" : "Resultado fuera del rango guardado")
                                    .font(.caption).foregroundStyle(Palette.gold)
                            }
                        }
                        Text("Guardada: \(entry.projection.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Modelo: \(entry.projection.model)").font(.caption).foregroundStyle(.secondary)
                        if let status = entry.settlement { Text(status).font(.caption).foregroundStyle(.secondary) }
                        if let corrections = entry.corrections, !corrections.isEmpty {
                            DisclosureGroup("\(corrections.count) correcciones del resultado") {
                                ForEach(corrections) { correction in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let previous = correction.previous {
                                            Text("\(previous, specifier: "%.1f") → \(correction.revised, specifier: "%.1f") \(entry.projection.metric.unit)")
                                        }
                                        Text("Consultada: \(correction.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.top, 6)
                                }
                            }.font(.subheadline)
                        }
                        DisclosureGroup("Evidencia conservada") {
                            Text(entry.projection.availability?.status.title ?? "La versión original no guardó contexto de disponibilidad.")
                                .font(.subheadline)
                            Text(entry.projection.weather?.detail ?? "Sin clima guardado.").font(.subheadline).foregroundStyle(.secondary)
                            ForEach(Array(entry.projection.warnings.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.caption).foregroundStyle(Palette.gold)
                            }
                            if let context = entry.projection.context {
                                Text("Contexto consultado: \(context.fetchedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                ForEach(context.sources) { source in
                                    if let url = sourceURL(source.url) { Link(source.name, destination: url).font(.caption) }
                                    Text("Fuente consultada: \(source.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(context.news) { item in
                                    if let url = sourceURL(item.url) { Link(item.title, destination: url).font(.caption) }
                                }
                            }
                        }
                    }
                }
                if !store.saved.isEmpty {
                    if let export { ShareLink(item: export) { Label("Compartir historial JSON", systemImage: "square.and.arrow.up") } }
                    Button("Preparar exportación") {
                        do { export = try store.exportHistory() }
                        catch { store.error = error.localizedDescription }
                    }.buttonStyle(.bordered)
                }
            }.padding(20)
        }.background(Palette.base).navigationTitle("Historial")
    }
    private func prospectiveSummary(_ metric: Metric) -> some View {
        let models = Set(store.saved.filter { $0.projection.metric == metric && $0.actual?.isFinite == true }.map { $0.projection.model }).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(models, id: \.self) { model in prospectiveModelSummary(metric, model: model) }
        }
    }
    private func prospectiveModelSummary(_ metric: Metric, model: String) -> some View {
        let rows = store.saved.filter { $0.projection.metric == metric && $0.projection.model == model && $0.actual?.isFinite == true }
        let mae = rows.reduce(0.0) { $0 + abs($1.actual! - $1.projection.estimate) } / Double(rows.count)
        let bias = rows.reduce(0.0) { $0 + ($1.projection.estimate - $1.actual!) } / Double(rows.count)
        let intervals = rows.filter {
            guard let low = $0.projection.low, let high = $0.projection.high else { return false }
            return low.isFinite && high.isFinite && low <= high
        }
        let covered = intervals.filter { $0.actual! >= $0.projection.low! && $0.actual! <= $0.projection.high! }.count
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("\(metric.title) · n = \(rows.count)").font(.subheadline.bold())
            Text(model).font(.caption).foregroundStyle(.secondary)
            Text("Error medio: \(mae, specifier: "%.2f") \(metric.unit) · sesgo: \(bias, specifier: "%+.2f")").font(.subheadline)
            if !intervals.isEmpty {
                Text("Cobertura del rango: \(Double(covered) / Double(intervals.count) * 100, specifier: "%.1f") % · n = \(intervals.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func valueBox(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1))).font(.title.bold()).monospacedDigit()
        }
    }
}

struct DataView: View {
    @EnvironmentObject var store: AppStore
    @State private var metric: Metric = .rushing
    @State private var serviceInput = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Panel {
                    Label("Actualización y cobertura", systemImage: "externaldrive").font(.headline)
                    Text("En primer plano, el contexto del jugador seleccionado se consulta cada 15 minutos y cada 2 minutos dentro de los 90 minutos previos al partido. Las estadísticas se renuevan cada 6 horas. Puedes actualizar todo manualmente.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("iOS decide si permite actualizar en segundo plano. Para consultar fuentes de forma continua con la app cerrada, configura un servicio remoto que permanezca funcionando.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let snapshot = store.snapshot {
                        Text("Descarga: \(snapshot.fetchedAt.formatted())").font(.subheadline)
                        if let last = snapshot.lastGameDate {
                            Text("Último partido con estadísticas: \(last.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                        }
                        ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { item in Text(item.element).font(.subheadline).foregroundStyle(Palette.gold) }
                        DisclosureGroup("Fuentes de estadísticas") {
                            ForEach(snapshot.sources) { source in
                                VStack(alignment: .leading, spacing: 4) {
                                    Divider()
                                    if let url = sourceURL(source.url) { Link(source.name, destination: url) }
                                    else { Text(source.name) }
                                    Text("\(source.rows) filas · consulta \(source.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                    Text("Modificación del archivo: \(source.modified ?? "no informada por el servidor")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button(store.loading ? "Actualizando…" : "Actualizar todo ahora") { Task { await store.refreshAll() } }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(store.busy)
                }
                Panel {
                    Label("Servicio continuo opcional", systemImage: "network").font(.headline)
                    Text("Introduce la URL HTTPS de tu servicio desplegado. Déjala vacía para consultar las fuentes públicas directamente. No requiere introducir secretos aquí.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("https://tu-servicio.example", text: $serviceInput)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        .disabled(store.busy || store.checkingService)
                    HStack {
                        Button("Guardar y comprobar") { Task { await store.configureService(serviceInput) } }
                        Spacer()
                        if store.checkingService { ProgressView() }
                        else if store.serverURL != nil { Button("Comprobar") { Task { await store.checkServiceConnection() } } }
                    }.buttonStyle(.bordered).disabled(store.busy || store.checkingService)
                    Text(store.serviceStatusTitle).font(.headline).foregroundStyle(Palette.gold)
                    Text(store.serviceStatusDetail).font(.subheadline).foregroundStyle(.secondary)
                    if let checked = store.serviceCheckedAt { Text("Comprobación: \(checked.formatted())").font(.caption).foregroundStyle(.secondary) }
                    Text("Una URL guardada no prueba que el servicio funcione: revisa su estado y las fechas de cada fuente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Panel {
                    Label("Participación y criterios", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                    Toggle("Exigir participación confirmada cerca del inicio", isOn: Binding(get: { store.requireConfirmedAvailability }, set: { value in
                        store.requireConfirmedAvailability = value
                        store.projection = nil
                        Task { await store.projectSelection() }
                    })).disabled(store.busy)
                    Text("Con este criterio, la falta de confirmación reciente bloquea el cálculo dentro de los 90 minutos previos al inicio. Las fuentes gratuitas pueden no publicar una lista definitiva de activos. Sin este criterio se permite una estimación condicional, claramente marcada.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Bajas, inactivos, reserva de lesionados y jugadores dudosos reportados bloquean siempre la proyección. No se interpreta la ausencia de un reporte como buena salud.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                validationPanel
                Panel {
                    Text("Cómo se calcula").font(.headline)
                    Text("Combina el historial reciente del jugador con un ajuste conservador de la defensa rival. El clima se consulta para el partido; solo modifica la cifra cuando hay muestra histórica y una comparación temporal favorable. En otro caso se muestra como contexto y se explica el límite. El desglose muestra factores, muestra y límites para cada cálculo.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Las noticias y reportes se consultan antes de calcular. Los titulares no reciben multiplicadores automáticos: revisa cambios de rol, lesiones y novedades junto con la evidencia. Los escenarios describen supuestos y no garantizan una probabilidad de acierto.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Fuentes y frecuencia · nflverse", destination: URL(string: "https://nflreadr.nflverse.com/articles/nflverse_data_schedule.html")!)
                    Link("Clima · Open-Meteo (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                    Link("Noticias y reportes · ESPN", destination: URL(string: "https://www.espn.com/nfl/")!)
                    Text("Los datos y tu historial se guardan en este dispositivo. Las consultas contactan GitHub/nflverse, ESPN, Open-Meteo y, si lo configuras, tu servicio. El clima usa coordenadas aproximadas de la zona del estadio; la app no solicita tu ubicación personal.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.background(Palette.base).navigationTitle("Datos y método")
            .onAppear { serviceInput = store.continuousServiceURLString }
    }
    private var validationPanel: some View {
        Panel {
            Label("Medir el modelo histórico", systemImage: "chart.bar").font(.headline)
            Text("Cada predicción usa solo partidos anteriores y se compara contra una media reciente de referencia. Esta prueba mide el componente estadístico: no inventa noticias, disponibilidad ni pronósticos históricos.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Métrica", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.title).tag($0) }
            }.disabled(store.validating)
            Button(store.validating ? "Evaluando…" : "Calcular error histórico") { Task { await store.validate(metric) } }
                .buttonStyle(.bordered).disabled(store.busy || store.snapshot == nil)
            if store.validating { ProgressView() }
            if let report = store.validation, store.validatedMetric == metric {
                Text("\(report.count) registros evaluados").font(.headline)
                if let mae = report.mae, let baseline = report.baselineMAE {
                    Text("Error medio absoluto: \(mae, specifier: "%.2f") \(metric.unit)")
                    Text("Referencia reciente: \(baseline, specifier: "%.2f") \(metric.unit)")
                    Text(mae < baseline ? "Menor error que la referencia en esta muestra." : "El modelo no mejora la referencia en esta muestra.")
                        .foregroundStyle(Palette.gold)
                }
                if let bias = report.bias { Text("Sesgo medio: \(bias, specifier: "%+.2f") \(metric.unit)") }
                if let coverage = report.coverage {
                    Text("Cobertura observada del rango: \(coverage * 100, specifier: "%.1f") % (\(report.intervalCount) registros)")
                }
                if report.count == 0 { Text("No hay suficientes registros elegibles para esta métrica.").foregroundStyle(Palette.gold) }
            }
            Text("Los archivos pueden contener correcciones posteriores. Solo se evalúan jugadores con datos observados, no todos los activos; la muestra puede estar sesgada. Comprueba la evaluación prospectiva del Historial para medir la versión completa tal como se usó antes de cada partido.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
