# NFL Pulse · iPhone · versión inicial 0.1

Aplicación nativa escrita en SwiftUI para uso personal. Requiere iOS 17 o posterior y una Mac con Xcode compatible con la versión de iOS de tu iPhone.

**Estado de entrega:** proyecto de código fuente preparado. No es un IPA firmado, no está instalado y no fue compilado ni ejecutado en un simulador de iPhone en el entorno de creación. Se verificaron la sintaxis con un analizador de Swift, la estructura del proyecto, los formatos y acceso a fuentes reales, y una implementación independiente en Python de la fórmula. Las pruebas Swift incluidas y el comportamiento visual deben verificarse en Xcode antes de considerar esta versión lista para usar.

## Abrir en tu Mac

1. Descarga y descomprime el ZIP. Conserva la carpeta completa.
2. Instala Xcode desde la Mac App Store; ábrelo y completa la instalación de componentes de iOS.
3. Abre **NFLPulse.xcodeproj**. Para ejecutar la aplicación, no abras `Package.swift` en su lugar.
4. En la barra superior, selecciona el esquema **NFLPulse** y un simulador de iPhone que tengas instalado. Pulsa **▶ Run**. El simulador permite comprobar la app sin firmarla para un dispositivo físico.
5. La primera apertura consulta internet. Si la fuente no responde, la app mostrará el error y permitirá reintentar; no cargará datos inventados.

## Instalar en tu iPhone

1. En Xcode → Settings → Accounts, agrega tu Apple Account en la interfaz de Apple. No compartas contraseñas ni códigos conmigo.
2. Conecta tu iPhone a la Mac, desbloquéalo y acepta confiar en la computadora si aparece la solicitud.
3. Selecciona el proyecto **NFLPulse**, el target **NFLPulse** y **Signing & Capabilities**.
4. Mantén **Automatically manage signing** activado y selecciona tu **Personal Team**.
5. Si el identificador ya está ocupado, cambia **Bundle Identifier** por uno propio, por ejemplo `com.joseangel.nflpulse.personal`. El identificador de actualización de segundo plano en `Info.plist` y `AppStore.swift` debe seguir coincidiendo entre esos dos archivos; no es necesario cambiarlo junto con el bundle.
6. Selecciona tu iPhone como destino. Xcode puede pedir habilitar **Developer Mode** en Ajustes → Privacidad y seguridad del iPhone y reiniciarlo. Sigue las instrucciones que muestre Xcode.
7. Pulsa **▶ Run**. Si iOS pide confiar en el certificado de desarrollo, sigue la indicación del dispositivo.

Apple permite probar en dispositivos propios con Personal Team gratuito, pero sus perfiles caducan a los siete días y hay que volver a compilar e instalar. La distribución por App Store/TestFlight tiene otros requisitos. Fuente: https://developer.apple.com/help/account/basics/about-your-developer-account

## Qué incluye

- Buscador por jugador, posición o equipo de la plantilla descargada.
- Próximo rival y hora del calendario, convertida a la zona horaria de tu dispositivo.
- Yardas de pase, carrera y recepción; número de recepciones.
- Gráfica de hasta doce partidos registrados con el equipo actual.
- Media estimada y rango orientativo construido con errores históricos, cuando hay muestra suficiente.
- Reportes semanales de lesiones disponibles. Bloqueo de `Out`, `Doubtful` y jugadores fuera de plantilla `ACT`.
- Clima aproximado del área de la ciudad local a la hora del inicio. No se asigna una ciudad incorrecta a partidos neutrales; los recintos cerrados se identifican según el calendario.
- Descarga manual, consulta al abrir después de seis horas e intento de actualización en segundo plano.
- Historial local que conserva la primera predicción por jugador/partido/métrica, sin reemplazarla por otra más conveniente después.
- Comparación automática con el resultado publicado al actualizar y exportación JSON del historial.
- Evaluación retrospectiva por métrica frente a una media simple de cinco partidos.

## Cómo probarla

1. Espera la primera descarga y entra en **Datos**. Comprueba la temporada, la fecha de consulta y el último partido con estadísticas.
2. En **Proyectar**, busca un jugador activo con al menos cuatro partidos registrados en su equipo actual. Elige una métrica con volumen suficiente.
3. Pulsa **Proyectar jugador**. Revisa el próximo rival, la cifra, las advertencias y el clima.
4. Guarda la proyección antes de que comience el partido.
5. Después del partido y de la publicación de estadísticas, pulsa **Actualizar**. Consulta el resultado y el error en **Historial**.
6. En **Datos**, elige una métrica y pulsa **Calcular error histórico**. Un error más bajo es mejor; si la referencia sencilla gana, la app lo dirá.

No todos los jugadores tendrán proyección: un novato con tres registros, un jugador que acaba de cambiar de equipo, un suplente sin volumen, una baja o un partido sin hora confirmada producen un mensaje explicativo. Esto es intencional.

## Qué significa la proyección

El modelo inicial es transparente y sencillo, no una IA entrenada ni una réplica del algoritmo de las capturas. No conocemos el algoritmo de esa aplicación ni su historial completo de fallos.

1. Toma hasta doce partidos anteriores registrados para el jugador **con su equipo actual**, dentro de 550 días.
2. Da al partido más reciente peso 1, al anterior 0.85, después 0.85², etc.
3. Ajusta la media con la producción total permitida por el rival en hasta ocho partidos previos, comparada con la liga. Reduce ese ajuste hacia cero según la muestra y lo limita a ±15 %.
4. Conserva las filas con cero. Nunca convierte datos ausentes en ceros.
5. El rango usa los percentiles 10 y 90 de hasta dieciséis errores individuales calculados cronológicamente. Requiere al menos seis errores. **No es un mínimo, máximo ni un intervalo validado de cobertura del 80 %.**

El resultado es una estimación media condicionada a que el jugador participe y mantenga un rol parecido. Las yardas pueden ser negativas; las recepciones se mantienen no negativas en el rango. Una estimación de 4.6 recepciones representa una media, no que se pueda registrar una fracción de recepción en un partido.

## Lo que todavía limita la precisión

- El clima se muestra como contexto; **no modifica numéricamente la proyección**. Primero se necesita medir su efecto con datos históricos apropiados.
- Las lesiones del jugador permiten avisar y bloquear bajas claras. Todavía no se redistribuyen oportunidades por lesiones de compañeros, cambios de quarterback o de línea ofensiva.
- Una fila ausente de lesiones no significa que esté sano. `ACT` tampoco confirma que vaya a jugar. No hay confirmación de inactivos de último minuto.
- Los valores iniciales de ponderación y ajuste son heurísticos. No se optimizaron con una separación formal entre entrenamiento, validación y prueba.
- Las estadísticas pueden omitir jugadores sin registro individual. La estimación y evaluación están condicionadas a esas observaciones; no modelan explícitamente DNP, probabilidad de participar o partidos con cero sin fila.
- Los datos históricos se corrigen después de los partidos. La evaluación retrospectiva excluye partidos futuros al calcular cada predicción, pero no recrea exactamente lo que se sabía entonces.
- Los datos gratuitos pueden retrasarse o cambiar de formato. La app conserva su copia anterior si falla la actualización y bloquea nuevas proyecciones si la descarga tiene más de 24 horas. La fecha de descarga no garantiza que la fuente haya publicado novedades.
- iOS decide cuándo ejecutar trabajo en segundo plano: **no hay una actualización diaria garantizada mientras la app permanece cerrada**. Para eso haría falta una tarea programada en un servidor, con mantenimiento y operación propios. Abrir o actualizar la app vuelve a consultar las fuentes.
- Los horarios pendientes no se inventan; esos partidos no están disponibles para proyectar.
- Los recintos con techo retráctil y las ubicaciones aproximadas requieren verificar las condiciones del estadio. No se asume que el pronóstico urbano equivalga al interior.

## Verificaciones realizadas aquí

`AUDITORIA.json` conserva fecha, URLs, hashes y cantidades de filas de cinco archivos reales descargados: estadísticas 2025 y 2026, calendario, plantilla 2026 y lesiones 2026. Las fuentes de 2026 consultadas contenían registros hasta semana 4.

Una reproducción independiente en Python de la fórmula, con hasta 400 registros elegibles recientes por métrica, produjo:

| Métrica | Registros | Error absoluto medio del modelo | Error de media simple de cinco |
|---|---:|---:|---:|
| Yardas de pase | 400 | 64.75 yardas | 68.64 yardas |
| Yardas de carrera | 400 | 19.15 yardas | 20.09 yardas |
| Yardas de recepción | 400 | 20.57 yardas | 21.48 yardas |
| Recepciones | 400 | 1.54 recepciones | 1.57 recepciones |

La cobertura observada de los rangos fue aproximadamente 62 %, 65 %, 69 % y 84 %, respectivamente, sobre los registros con rango disponible. Por eso no se anuncian como intervalos del 80 % ni como pisos/techos seguros. Los números cambiarán al incorporar partidos nuevos.

**Estos resultados no son una tasa de acierto, no son probabilidades de superar una línea, no prueban rentabilidad y no sustituyen la ejecución de las pruebas de Swift.** No se evaluaron apuestas ni cuotas.

## Verificación pendiente en tu Mac

Para las diez pruebas del núcleo, abre Terminal dentro de esta carpeta y ejecuta:

```bash
swift test
```

Cubren CSV con comillas/saltos, fechas y horario de verano, ceros, datos futuros, lesión vigente frente a una antigua, copias obsoletas, muestra insuficiente, clima de sede neutral y serialización. Se ejecutan mediante el paquete `NFLPulseCore`; el proyecto de Xcode es para la aplicación.

Para comprobar la compilación del target iOS sin instalarlo:

```bash
xcodebuild -project NFLPulse.xcodeproj -scheme NFLPulse -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Para repetir la auditoría independiente con datos de la fuente (requiere Python 3.9 o posterior e internet):

```bash
python3 scripts/audit_sources.py --season 2026
```

El script usa solo la biblioteca estándar de Python. Esa auditoría no ejecuta Swift ni valida la interfaz.

Revisa también en el simulador/iPhone: búsqueda, generación, bloqueo de baja, desconexión de red conservando caché, guardado duplicado, actualización tras partido y legibilidad con texto grande. La revisión visual y las pruebas de instalación están pendientes.

## Archivos

| Archivo | Función |
|---|---|
| `NFLPulse.xcodeproj` | Proyecto para abrir directamente en Xcode |
| `NFLPulse/Views.swift` | Interfaz nativa en español |
| `NFLPulse/ProjectionEngine.swift` | Fórmula y evaluación cronológica |
| `NFLPulse/DataService.swift` | Descarga, validación y lectura de fuentes |
| `NFLPulse/WeatherService.swift` | Pronóstico aproximado de Open-Meteo |
| `NFLPulse/AppStore.swift` | Caché, historial, actualización y exportación |
| `NFLPulseTests/CoreTests.swift` | Pruebas del núcleo pendientes de ejecutar en Swift |
| `AUDITORIA.json` | Evidencia de fuentes y reproducción numérica en Python |
| `scripts/create_project.py` | Regenera la estructura de Xcode sin dependencias |

## Datos, privacidad y atribución

La app no tiene servidor propio, cuenta, publicidad, analítica ni clave secreta. Descarga datos directamente del proveedor. Guarda caché e historial en Application Support del dispositivo; al desinstalar la app podrías perderlos. Usa exportación JSON para conservar tu historial.

Las peticiones de estadísticas van a GitHub/nflverse. Las de clima van a Open-Meteo usando coordenadas aproximadas de la ciudad anfitriona, sin solicitar tu ubicación personal. Los proveedores pueden recibir la IP de la conexión.

Fuentes:

- nflverse / nflreadr: https://nflreadr.nflverse.com/reference/load_player_stats.html
- Frecuencia y disponibilidad: https://nflreadr.nflverse.com/articles/nflverse_data_schedule.html
- Datos originales: https://github.com/nflverse/nflverse-data
- Calendario: https://github.com/nflverse/nfldata
- Clima y documentación: https://open-meteo.com/en/docs
- Atribución meteorológica: Open-Meteo, datos bajo CC BY 4.0; la API gratuita se contempla para este uso personal no comercial. Condiciones: https://open-meteo.com/en/terms
- Desarrollo personal iOS: https://developer.apple.com/help/account/basics/about-your-developer-account

NFL Pulse es un nombre provisional para tu proyecto personal, sin afiliación con la NFL. No se redistribuyen en el ZIP las fotos originales, logos de equipos ni los CSV completos de terceros.

## Siguientes etapas

Primero: compilar, instalar y probar esta base en tu Mac/iPhone. Después: reunir predicciones prospectivas, calibrar rangos por posición y volumen, incorporar disponibilidad/participación y cambios de rol, medir ajustes de clima y lesiones de compañeros. TD y otras métricas se dejan para una versión posterior, como acordamos.
