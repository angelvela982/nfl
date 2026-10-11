# Servicio de contexto NFLPulse 0.2

Servicio opcional Python 3.12+, sin dependencias externas, credenciales ni API de pago. Consulta lesiones, noticias, plantillas y partidos públicos de ESPN por HTTPS. El iPhone puede conectarse al servicio mediante su URL HTTPS en Configuración. Los pronósticos meteorológicos se consultan por separado desde la app.

El servicio tiene un hilo programador: consulta los feeds generales cada 15 minutos aunque el iPhone esté cerrado. Conserva durante un día las consultas de equipo, fecha y resumen del partido solicitadas por clientes. Cambia a 2 minutos desde 6 horas antes hasta 4 horas después del inicio de cualquier partido observado. Hay como máximo 4 solicitudes al proveedor simultáneas, 32 tareas pendientes, 16 clientes HTTP concurrentes, un timeout de 10 segundos al proveedor y un límite de 16 MiB por respuesta. Los destinos del proveedor son fijos; un cliente no puede proporcionar URLs de descarga.

## Ejecutar y comprobar

Desde la raíz del proyecto:

```bash
python3 -m unittest discover -s server/tests -v
python3 -m server --host 127.0.0.1 --port 8765 --cache-dir /workspace/nfl/server/data
```

En otra terminal:

```bash
curl --fail http://127.0.0.1:8765/health
curl --fail --get http://127.0.0.1:8765/v1/context \
  --data-urlencode 'player_id=00-0039849' \
  --data-urlencode 'espn_id=4432708' \
  --data-urlencode 'name=Marvin Harrison Jr.' \
  --data-urlencode 'team=ARI' \
  --data-urlencode 'game_id=2026_05_DET_ARI' \
  --data-urlencode 'kickoff=2026-10-11T20:25:00Z' \
  --data-urlencode 'season=2026' \
  --data-urlencode 'week=5'
```

La consulta es un ejemplo histórico de la auditoría; selecciona el partido y jugador actuales en la app. `espn_id` es opcional: sin él, el nombre exacto debe identificar a un solo jugador en la plantilla del equipo. `player_id` y `game_id` corresponden a nflverse. Las respuestas usan camelCase y fechas ISO8601 UTC; `news[].playerIDs` contiene **IDs de ESPN**, mientras `reports[].playerID` conserva el GSIS solicitado. Se aceptan `LA`/`LAR` y `WAS`/`WSH`; la respuesta emplea `LA` y `WAS`, como nflverse.

`GET /health` devuelve `starting`, `ok` o `degraded`, `schedulerRunning`, `refreshIntervalSeconds` y `feeds`. Cada feed muestra `available`, `fresh`, `checkedAt`, `attemptedAt`, `lastRefreshSucceeded` y `error`. HTTP 200 indica que el proceso responde; `status=ok` indica además que el programador está vivo y los feeds generales tienen una descarga reciente sin error. Un despliegue debe revisar ambos niveles.

`GET /v1/context` devuelve el contrato `LiveContext` de Swift: `fetchedAt`, `reports`, `news`, `sources` y `warnings`. `fetchedAt` indica cuándo se ensambló la respuesta; **no** renueva los reportes ni las fuentes. Si una descarga falla, se conserva la última respuesta válida, su fecha original y la advertencia del fallo. La escritura en disco usa un archivo temporal, `fsync` y reemplazo atómico. No comparte un archivo de caché entre procesos.

## Identidad y disponibilidad

Los reportes sólo se asocian tras corroborar equipo, nombre exacto y, cuando existe, ID ESPN en una plantilla reciente. La fuente de lesiones de la liga no entrega `athlete.id` en el esquema observado: se obtiene del enlace oficial `https://www.espn.com/nfl/player/_/id/{id}/...`; nunca se usa el ID del reporte como ID del jugador. Si la identidad es ambigua, el servicio devuelve una advertencia y omite los reportes.

Una baja se vincula al GSIS del partido únicamente cuando el scoreboard corrobora equipo, temporada, semana y hora de inicio ±5 minutos, y la fecha del reporte está entre los siete días anteriores al inicio y la fecha actual. Los reportes de otra temporada, marcas de tiempo futuras o feeds con una actualización de más de seis horas se descartan. `checkedAt` de un reporte conserva la menor fecha entre la descarga válida y `timestamp` de ESPN. La reserva de lesionados actual puede aparecer sin partido específico.

ESPN es un proveedor público sin contrato estable y puede omitir novedades o publicar información retrasada. El backend **no dispone de una lista completa verificada de activos e inactivos antes de cada partido**. El campo general `athlete.status=Active`, la aparición en una plantilla o la ausencia de lesiones no confirma participación. En una muestra real, Drew Kendall figuraba como `Active` en la plantilla general y `Out` en el reporte de lesión. No se transforma un titular, noticia de traspaso, rumor, `didNotPlay` del boxscore o ausencia de reportes en un estado de participación. Cerca del inicio, la app puede exigir una confirmación oficial adicional y suspender la proyección.

Las noticias se filtran por las categorías explícitas del jugador o equipo. `categories[].id` es una categoría editorial: se usan `athlete.id`/`athleteId` y `team.id`/`teamId`, que son identificadores distintos. Las noticias del equipo se muestran como contexto y no modifican automáticamente la cuota de trabajo del jugador.

## Desplegar con HTTPS

Este proyecto incluye la implementación y el contenedor; no se ha publicado un servicio externo. Para mantener las consultas cuando el iPhone no está abierto, elige un host persistente que no suspenda el proceso por inactividad. Un servicio que escala a cero interrumpe el programador.

Construcción desde la raíz:

```bash
docker build -f server/Dockerfile -t nflpulse-context:0.2 .
docker run --rm --name nflpulse-context \
  -p 127.0.0.1:8080:8080 \
  -v nflpulse-context-data:/data \
  nflpulse-context:0.2
```

El contenedor usa un usuario sin privilegios. Guarda `/data` en un volumen persistente. Usa una sola instancia por archivo de caché; otras instancias deben tener archivos separados. Coloca el puerto detrás del ingreso HTTPS del proveedor o un proxy con un certificado válido. Por ejemplo, con un dominio propio y Caddy:

```caddyfile
contexto.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Sustituye el dominio de ejemplo y configura su DNS y certificado. Permite la salida HTTPS a `site.api.espn.com`; nunca desactives verificación TLS. Configura en la app la URL base `https://tu-dominio`, sin `/v1/context`. Comprueba `/health` por HTTPS y consulta un jugador actual antes de usarlo. Configura reinicio del proceso y supervisión de `status`, `schedulerRunning` y fechas de los feeds.

## Auditoría y pruebas

```bash
python3 -m server.audit_provider --date 20261011 --event 401872991
```

`provider-audit.json` registra resultados propios; no sustituye errores por ejemplos. Durante esta implementación, el proxy inicialmente devolvía 403. Después se observaron descargas reales HTTP 200 de lesiones, noticias, scoreboard, plantilla y resumen NFL el 11 de octubre de 2026. La fuente de lesiones tenía 8,761,015 bytes, por lo que se ajustó el límite y se compactan biografías y medios antes de persistir la caché.

`fixtures/espn-*-redacted.json` contiene subconjuntos de esas respuestas reales, con procedencia y redacciones documentadas en `_fixture_metadata`. `fixtures/live-context.json` es el contrato generado a partir de esos subconjuntos con un reloj fijo para reproducir pruebas; no es un feed de producción. Los casos artificiales de identidad duplicada y titulares están identificados como pruebas en el código. Las pruebas verifican el programador independiente, errores de actualización, conservación de fechas, identidad ambigua, vinculación del partido, rechazo de esquemas/URLs desconocidos y la respuesta HTTP completa que decodifica Swift.
