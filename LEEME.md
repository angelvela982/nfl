# NFL Pulse para iPhone · beta 0.2

Código fuente de la segunda versión de tu proyecto. La aplicación usa SwiftUI y requiere iOS 17 o posterior. Conserva el historial de la beta 0.1. Incluye un núcleo que puede probarse en Linux/macOS y un servicio Python opcional para actualizar fuentes con la app cerrada.

**Esta entrega no es un IPA firmado ni una instalación en tu iPhone.** La compilación y las pruebas realizadas están en `VERIFICACION.json`; el simulador, la interfaz y la firma requieren Xcode en una Mac. No se promete una precisión que no se haya medido.

## Qué cambia

- Once métricas: yardas de pase/carrera/recepción, recepciones, acarreos, intentos de pase, pases completos, objetivos de pase, goles de campo anotados, intentos de gol de campo y puntos extra anotados.
- Selección por jugador/equipo/posición, incluidos pateadores. Se muestran solamente las métricas compatibles.
- Modelo de volumen y eficiencia con referencia simple y evaluación cronológica; datos ausentes siguen siendo ausentes, nunca ceros inventados.
- Clima del partido: temperatura, viento, probabilidad de precipitación y techo. Un ajuste numérico necesita evidencia histórica; si falta, la app explica por qué mantiene la cifra. La probabilidad de lluvia no se convierte en precipitación observada.
- Reportes de lesiones y contexto del partido mediante ESPN, combinados con los reportes semanales de nflverse. Identidad por GSIS/ESPN y equipo; fuentes y fechas visibles.
- Noticias recientes con enlaces y procedencia. Un titular no se convierte automáticamente en una baja, una probabilidad de jugar o un cambio de oportunidades.
- Bloqueo de bajas reportadas vigentes. Ausencia de reporte = participación desconocida. Una estimación sin participación confirmada se identifica como **condicional a que juegue**.
- Opción para exigir participación confirmada cerca del inicio. Puede impedir proyecciones cuando las fuentes gratuitas no publican una lista explícita de activos.
- Actualización de contexto en primer plano, reintentos limitados, caché y avisos de fuentes antiguas/fallidas. Servicio continuo opcional con programador y almacenamiento persistente.
- Historial con la primera predicción anterior al partido, resultado, error, cobertura del rango y registro de correcciones. Exportación JSON con el contexto utilizado.

## Abrir y probar en tu Mac

1. Abre `NFLPulse.xcodeproj` en Xcode compatible con iOS 17.
2. Selecciona el esquema **NFLPulse** y un simulador de iPhone. Pulsa Run.
3. Espera la descarga, elige jugador y métrica y revisa **Disponibilidad y contexto**. Puedes leer noticias incluso si el motor bloquea la proyección.
4. Guarda una predicción antes del inicio. Después de que se publiquen los resultados, actualiza y consulta **Historial**.
5. En **Datos**, calcula el error histórico por métrica. El historial prospectivo sirve para evaluar el conjunto completo con noticias y pronóstico tal como se conocían antes del juego.

```bash
swift test --jobs 4
xcodebuild -project NFLPulse.xcodeproj -scheme NFLPulse \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
python3 -m unittest discover -s server/tests -v
```

La auditoría de red es una prueba optativa separada: descarga datos reales y ejecuta el motor Swift, no una reproducción de la fórmula en otro lenguaje.

```bash
NFLPULSE_LIVE_TESTS=1 \
NFLPULSE_AUDIT_OUTPUT="$PWD/docs/validation-v0.2.json" \
NFLPULSE_CONTEXT_AUDIT_OUTPUT="$PWD/docs/context-audit-v0.2.json" \
  bash scripts/test-core.sh --filter LiveSourceTests
```

Comprueba en simulador/iPhone: búsqueda y pateadores, texto grande, desconexión conservando historial, bloqueo de Out, participación desconocida, cambio de jugador/métrica durante consultas, exportación y cierre/reapertura. Las pruebas del núcleo no reemplazan esta revisión.

Para instalar en un iPhone físico, selecciona tu Apple Account y Team en Xcode → Signing & Capabilities, conecta el dispositivo y ejecuta. Personal Team gratuito tiene perfiles de duración limitada; TestFlight/App Store requieren los procesos de Apple. No hay credenciales de Apple incluidas.

## Actualización autónoma

La app funciona en modo directo sin cuentas ni claves de datos. iOS decide cuándo ejecutar tareas en segundo plano: **no garantiza consultas continuas mientras la app está cerrada**.

Para que la recolección siga funcionando independientemente del teléfono, ejecuta el servicio incluido en una máquina que permanezca encendida:

```bash
python3 -m server --host 127.0.0.1 --port 8765 --cache-dir server/data
```

En otra terminal, ejecuta `python3 scripts/smoke-service.py` para comprobar el servicio con un jugador y un partido actuales. Consulta `server/README.md` para Docker, persistencia, comprobaciones y despliegue detrás de HTTPS. El servicio consulta las fuentes en su propio programador y conserva las fechas originales cuando una descarga falla. La conexión HTTP local se usa para desarrollo interno; en el iPhone se configura una URL **HTTPS** del servicio en **Datos → Servicio continuo**.

El servicio está implementado y se valida localmente; **no está desplegado públicamente**. El código incluye la configuración necesaria para alojarlo. Un proceso local no se convierte en un servicio permanente por descargar el ZIP. No incluye notificaciones push: los cambios se muestran cuando la app puede consultar el servicio.

## Precisión y límites de los datos gratuitos

El objetivo es reducir el error con evidencia, no afirmar que una cifra es segura. `docs/EVALUACION-v0.2.md` describe los resultados ejecutados y sus límites.

- Una media no predice el resultado exacto. Los rangos se construyen con errores anteriores; su cobertura se mide y no se vende como una probabilidad garantizada.
- Se requieren historial y volumen. Novatos, jugadores recién transferidos, suplentes sin volumen y métricas ausentes pueden no tener proyección.
- El modelo depende de que se mantenga un rol comparable. Lesiones de compañeros y anuncios se muestran como contexto; sin un modelo de oportunidades validado no se aplica una redistribución arbitraria.
- La disponibilidad puede cambiar tras la consulta. No existe una garantía de detectar toda noticia o lesión inmediatamente. ESPN es una interfaz pública sin garantía contractual; nflverse también tiene retrasos y puede revisar resultados.
- Los estados `Active` de una plantilla general **no confirman que alguien vaya a jugar**. El estado desconocido permanece explícito.
- Descargar un archivo hoy no significa que se hayan publicado novedades. Las fuentes guardan su fecha de consulta y, cuando se ofrece, de publicación/modificación.
- La evaluación retrospectiva usa únicamente partidos anteriores al objetivo para calcular cada estimación, pero los archivos actuales pueden contener correcciones posteriores. No reconstruye las noticias, la plantilla o el pronóstico exactos disponibles entonces.
- El pronóstico se consulta en la zona del estadio. No sustituye mediciones dentro del recinto ni confirma por sí solo la apertura de un techo retráctil.

## Fuentes y privacidad

Fuentes gratuitas elegidas para esta beta: nflverse/nfldata para calendario, estadísticas, plantillas y lesiones semanales; ESPN para noticias y reportes del partido; Open-Meteo para pronóstico.

- https://github.com/nflverse/nflverse-data
- https://github.com/nflverse/nfldata
- https://nflreadr.nflverse.com/articles/nflverse_data_schedule.html
- https://www.espn.com/nfl/
- https://open-meteo.com/ · atribución CC BY 4.0; consultar las condiciones para uso comercial.

Sin anuncios, analítica, localización del usuario ni claves incrustadas. El historial se guarda en el dispositivo; expórtalo antes de desinstalar. Las conexiones revelan la IP a los proveedores. Si configuras el servicio, éste recibe el identificador del jugador/equipo/partido solicitado; sus registros normales no guardan la consulta completa.

## Desarrollo en este entorno Linux

```bash
bash scripts/install-swift-linux.sh /workspace/toolchains
bash scripts/test-core.sh
python3 -m unittest discover -s server/tests -v
```

La instalación local de Swift verifica TLS, SHA-256 y firma oficial. Xcode y el SDK iOS no están disponibles en Linux. `.github/workflows/validate.yml` añade pruebas del núcleo/servicio y compilación de simulador en macOS para futuras ejecuciones de CI.

Los archivos de la beta original y su auditoría están en `docs/archive/`. `scripts/audit_sources.py` se conserva como reproducción **de la fórmula 0.1**; no evalúa el motor de la versión 0.2.
