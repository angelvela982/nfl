# Evaluación ejecutada · beta 0.2

Se ejecutó el motor Swift sobre estadísticas publicadas de 2025 y 2026, consultadas el 2026-10-11T06:19:58Z. Cada métrica usa sus 400 observaciones elegibles más recientes. No se utilizaron resultados del partido objetivo para seleccionar el modelo.

| Métrica | Registros | MAE versión 2 | MAE media de 5 | Reducción de error | Cobertura del rango |
|---|---:|---:|---:|---:|---:|
| Yardas de pase | 400 | 67.532 | 68.910 | 2.00% | 63.6% (261) |
| Yardas de carrera | 400 | 19.453 | 19.758 | 1.54% | 68.3% (360) |
| Yardas de recepción | 400 | 22.541 | 22.901 | 1.57% | 66.9% (366) |
| Recepciones | 400 | 1.622 | 1.639 | 1.05% | 86.1% (366) |
| Acarreos | 400 | 3.395 | 3.423 | 0.80% | 77.5% (360) |
| Intentos de pase | 400 | 7.874 | 8.118 | 3.00% | 69.7% (261) |
| Pases completos | 400 | 5.439 | 5.606 | 2.98% | 74.3% (261) |
| Objetivos de pase | 400 | 2.024 | 2.057 | 1.57% | 85.0% (366) |
| Goles de campo anotados | 400 | 1.097 | 1.098 | 0.08% | 87.8% (288) |
| Intentos de gol de campo | 400 | 1.167 | 1.183 | 1.42% | 88.9% (288) |
| Puntos extra anotados | 400 | 1.191 | 1.206 | 1.25% | 89.2% (288) |

MAE = error absoluto medio, en las unidades de la métrica. La reducción observada frente a la referencia está entre 0.08% y 3.00%; es modesta. No implica que cada jugador mejore ni que el siguiente partido tenga menos error. La referencia es la media simple de cinco partidos, no una comparación directa con la beta 0.1.

La cobertura corresponde únicamente a observaciones con rango disponible y al modelo base retrospectivo. No es una promesa de cobertura del 80%; el error puede quedar fuera. Se requiere validación prospectiva de las proyecciones guardadas, particularmente de los ajustes de clima.

El modelo candidato estima volumen y eficiencia regularizada con el historial del jugador; estratifica el rival por posición y limita el ajuste a ±15%. Se usa sólo cuando al menos seis comparaciones anteriores muestran menor error que la referencia. En otro caso conserva la media de cinco. Esta selección es una regla de la beta, no una optimización global o una validación definitiva.

El ajuste de clima necesita al menos 40 observaciones exteriores, 28 de entrenamiento y 12 en una separación posterior por fecha. Los coeficientes regularizados de temperatura y viento deben reducir MAE al menos 5% en esa comparación antes de aplicarse, con un límite de ±15%. Usa clima histórico observado, que no equivale al pronóstico conocido antes del partido. Precipitación, noticias y disponibilidad no se evalúan numéricamente en esta tabla.

Los archivos históricos pueden contener correcciones posteriores. Sólo se puntúan jugadores con una fila individual observada, historial suficiente en su equipo y volumen mínimo; DNP y ausencia de fila no se convierten en cero. La muestra no representa todos los jugadores activos. La tabla no es una tasa de acierto, no estima rentabilidad ni probabilidades de superar una línea.

Las once métricas produjeron al menos una proyección con jugadores y partidos reales durante la prueba. También se consultaron correctamente noticias/lesiones ESPN y pronóstico Open-Meteo con el lector Swift. El servidor local respondió con un reporte Out de Marvin Harrison Jr. vinculado por IDs al partido correspondiente, tres noticias y cinco fuentes. Estos son casos funcionales de la consulta, no una prueba de completitud de todos los reportes.

Evidencia: `validation-v0.2.json`, `context-audit-v0.2.json`, `server-smoke-v0.2.json`, `source-audit-v0.2.json` y `../VERIFICACION.json`. La compilación y revisión visual en Xcode siguen pendientes.
