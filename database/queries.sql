-- ==================================================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 2: Consultas SQL (Q1 - Q8)
-- Motor: MariaDB 12.x
-- ===================================================================================
-- Convenciones:
--   * Duración en minutos con TIMESTAMPDIFF.
--   * Para estancias abiertas se usa el momento actual (NOW()) como
--     corte temporal; los importes de abiertas son estimados.
--   * Los importes se calculan con la tarifa vigente registrada en
--     la estancia (stays.tariff_id).
-- ====================================================================================
-- ÍNDICE DE CONSULTAS
--   Q1  Vehículos actualmente dentro del estacionamiento
--   Q2  Duración e importe de una estancia                (param: @STAY_ID)
--   Q3  Reporte mensual de residentes                     (param: @PERIODO)
--   Q4  Ingresos por día y tipo de vehículo
--   Q5  Promedio de permanencia por tipo de vehículo
--   Q6  Vehículos con más de una estancia abierta (debe salir vacío)
--   Q7  Registros con fechas/importes inconsistentes
--   Q8  Vehículos con mayor tiempo acumulado en el mes    (param: @PERIODO_MES)
-- ====================================================================================

USE neology_parking;

-- ====================================================================================
--  Q1  |  Vehículos actualmente dentro del estacionamiento
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q1: Vehículos actualmente dentro del estacionamiento'            AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT
    v.plate,
    vt.name                                    AS tipo_vehiculo,
    r.name                                     AS residente,
    s.ticket_number                            AS folio,
    s.entry_time                               AS hora_entrada,
    TIMESTAMPDIFF(MINUTE, s.entry_time, NOW()) AS minutos_dentro
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
LEFT JOIN residents r ON r.id = v.resident_id
WHERE s.exit_time IS NULL
ORDER BY s.entry_time;

-- ====================================================================================
--  Q2  |  Duración e importe de una estancia
--       (Reemplaza @STAY_ID por el id de la estancia, ej. 3)
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q2: Duración e importe de una estancia (param: @STAY_ID)'        AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SET @STAY_ID = 3;

SELECT
    s.id,
    v.plate,
    vt.name                                   AS tipo_vehiculo,
    s.ticket_number,
    s.entry_time,
    s.exit_time,
    TIMESTAMPDIFF(
        MINUTE,
        s.entry_time,
        COALESCE(s.exit_time, NOW())
    )                                         AS duracion_minutos,
    t.price_per_minute                        AS tarifa_x_minuto,
    ROUND(
        TIMESTAMPDIFF(
            MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
        ) * t.price_per_minute,
        2
    )                                         AS importe_calculado,
    s.amount                                  AS importe_registrado,
    CASE
        WHEN t.is_exempt = 1 THEN 'EXENTO (vehículo oficial)'
        WHEN s.exit_time IS NULL THEN 'ESTIMADO (estancia abierta)'
        ELSE 'PAGADO'
    END                                       AS estado_cobro
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
JOIN tariffs t        ON t.id = s.tariff_id
WHERE s.id = @STAY_ID;

-- ====================================================================================
--  Q3  |  Reporte mensual de residentes
--       (Reemplaza @PERIODO con el periodo en formato "YYYY-MM")
--       Se apoya en el cierre mensual para periodos cerrados y lo
--       recalcula en vivo para el periodo en curso.
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q3: Reporte mensual de residentes (param: @PERIODO)'             AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SET @PERIODO = '2026-09';

-- 3a. Periodos cerrados (histórico materializado)
SELECT '--- Q3a: Periodos cerrados (histórico) ---'                     AS 'PARTE';
SELECT
    mci.resident_id,
    r.name                                 AS residente,
    mc.period                              AS periodo,
    mci.total_minutes                      AS minutos,
    mci.total_activities                   AS estancias,
    mci.total_amount                       AS importe,
    mci.status,
    mc.closed_by                           AS cerrado_por,
    mc.closed_at                           AS cerrado_en
FROM monthly_close_items mci
JOIN residents r       ON r.id = mci.resident_id
JOIN monthly_closes mc ON mc.id = mci.monthly_close_id
WHERE mc.period = @PERIODO
ORDER BY r.name;

-- 3b. Periodo en curso (cálculo en vivo sobre estancias de residentes)
SELECT '--- Q3b: Periodo en curso (cálculo en vivo) ---'                AS 'PARTE';
SELECT
    v.resident_id,
    r.name                                             AS residente,
    DATE_FORMAT(s.entry_time, '%Y-%m')                 AS periodo,
    COALESCE(SUM(TIMESTAMPDIFF(
        MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
    )), 0)                                             AS minutos_acumulados,
    COUNT(*)                                           AS estancias,
    ROUND(COALESCE(SUM(
        TIMESTAMPDIFF(
            MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
        ) * t.price_per_minute
    ), 0), 2)                                          AS importe_acumulado
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN tariffs t        ON t.id = s.tariff_id
JOIN residents r      ON r.id = v.resident_id
WHERE v.resident_id IS NOT NULL
  AND DATE_FORMAT(s.entry_time, '%Y-%m') = @PERIODO
  AND s.entry_time <= NOW()   -- se excluyen entradas futuras (anomalía de Q7)
GROUP BY v.resident_id, r.name, DATE_FORMAT(s.entry_time, '%Y-%m')
ORDER BY importe_acumulado DESC;

-- ====================================================================================
--  Q4  |  Ingresos por día y por tipo de vehículo
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q4: Ingresos por día y por tipo de vehículo'                     AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT
    DATE(c.charged_at)                            AS dia,
    vt.name                                       AS tipo_vehiculo,
    COUNT(DISTINCT s.id)                          AS estancias,
    ROUND(SUM(c.amount), 2)                       AS ingresos
FROM charges c
JOIN stays s      ON s.id = c.stay_id
JOIN vehicles v   ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
-- Se excluyen cargos exentos (oficiales) y pendientes
WHERE c.charge_type IN ('instant','accumulated')
  AND c.status IN ('paid','closed')
GROUP BY DATE(c.charged_at), vt.name
ORDER BY dia, vt.name;

-- ====================================================================================
--  Q5  |  Promedio de permanencia por tipo de vehículo
--       (Considera únicamente estancias finalizadas, con salida)
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q5: Promedio de permanencia por tipo de vehículo'                AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT
    vt.name                                  AS tipo_vehiculo,
    COUNT(*)                                 AS estancias_finalizadas,
    ROUND(AVG(TIMESTAMPDIFF(
        MINUTE, s.entry_time, s.exit_time
    )), 2)                                   AS promedio_minutos,
    CONCAT(
        FLOOR(AVG(TIMESTAMPDIFF(MINUTE, s.entry_time, s.exit_time)) / 60),
        'h ',
        MOD(ROUND(AVG(TIMESTAMPDIFF(MINUTE, s.entry_time, s.exit_time))), 60),
        'm'
    )                                        AS promedio_formateado
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
WHERE s.exit_time IS NOT NULL
GROUP BY vt.name
ORDER BY promedio_minutos DESC;

-- ====================================================================================
--  Q6  |  Vehículos con más de una estancia abierta
--       (La regla está forzada por el UNIQUE de open_key: solo debe
--        devolver filas si los datos son inconsistentes)
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q6: Vehículos con más de una estancia abierta (debe salir vacío)' AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT
    v.plate,
    vt.name          AS tipo_vehiculo,
    COUNT(*)         AS estancias_abiertas
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
WHERE s.exit_time IS NULL
GROUP BY v.plate, vt.name
HAVING COUNT(*) > 1;

-- ====================================================================================
--  Q7  |  Registros con fechas/importes inconsistentes
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q7: Registros con fechas/importes inconsistentes'                AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
-- 7a. Salida anterior a la entrada (bloqueada por CHECK; escaneo defensivo)
SELECT 'exit_antes_entrada'        AS inconsistencia, s.id, v.plate, s.entry_time, s.exit_time
FROM stays s
JOIN vehicles v ON v.id = s.vehicle_id
WHERE s.exit_time IS NOT NULL AND s.exit_time <= s.entry_time

UNION

-- 7b. Entradas en el futuro (incluye el dato de prueba TICKET-0020)
SELECT 'entrada_en_futuro'         AS inconsistencia, s.id, v.plate, s.entry_time, s.exit_time
FROM stays s
JOIN vehicles v ON v.id = s.vehicle_id
WHERE s.entry_time > NOW()

UNION

-- 7c. Marcada como pagada pero sin momento de pago o sin importe
--     (incluye el dato de prueba TICKET-0021)
SELECT 'pagada_datos_incompletos'  AS inconsistencia, s.id, v.plate, s.entry_time, s.exit_time
FROM stays s
JOIN vehicles v ON v.id = s.vehicle_id
WHERE s.paid = 1
  AND (s.paid_at IS NULL OR s.amount IS NULL)

UNION

-- 7d. Importe registrado que no coincide con el cálculo de la tarifa
--     (una estancia pagada debe igualar minutos * tarifa)
SELECT 'importe_no_coincide'       AS inconsistencia, s.id, v.plate, s.entry_time, s.exit_time
FROM stays s
JOIN vehicles v ON v.id = s.vehicle_id
JOIN tariffs t   ON t.id = s.tariff_id
WHERE s.paid = 1
  AND s.exit_time IS NOT NULL
  AND ROUND(TIMESTAMPDIFF(MINUTE, s.entry_time, s.exit_time) * t.price_per_minute, 2)
      <> ROUND(IFNULL(s.amount, -1), 2);

-- ====================================================================================
--  Q8  |  Vehículos con mayor tiempo acumulado durante el mes
--       (Reemplaza @PERIODO_MES con el primer día del mes, ej. 2026-09-01)
-- ====================================================================================
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SELECT 'Q8: Vehículos con mayor tiempo acumulado durante el mes (@PERIODO_MES)' AS 'CONSULTA EN EJECUCION';
SELECT '================================================================' AS 'CONSULTA EN EJECUCION';
SET @PERIODO_MES = '2026-09-01';

SELECT
    v.plate,
    vt.name                                   AS tipo_vehiculo,
    r.name                                    AS residente,
    SUM(TIMESTAMPDIFF(
        MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
    ))                                        AS minutos_acumulados,
    CONCAT(
        FLOOR(SUM(TIMESTAMPDIFF(
            MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
        )) / 60), 'h ',
        MOD(SUM(TIMESTAMPDIFF(
            MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())
        )), 60), 'm'
    )                                         AS tiempo_formateado
FROM stays s
JOIN vehicles v      ON v.id = s.vehicle_id
JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
LEFT JOIN residents r ON r.id = v.resident_id
WHERE s.entry_time >= @PERIODO_MES
  AND s.entry_time < DATE_ADD(@PERIODO_MES, INTERVAL 1 MONTH)
  AND s.entry_time <= NOW()   -- se excluyen entradas futuras (anomalía de Q7)
GROUP BY v.plate, vt.name, r.name
ORDER BY minutos_acumulados DESC;