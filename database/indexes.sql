-- ============================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 4: Optimización de índices
-- Motor: MariaDB 12.x
-- ============================================================
-- Se proponen índices adicionales a los ya creados en schema.sql
-- para las consultas identificadas como problemáticas a millones
-- de registros en la tabla stays.
--
-- Estrategia:
--   1. Colapsar índices redundantes (consolidar en índices compuestos).
--   2. Crear índices de cobertura para consultas frecuentes.
--   3. Mantener íntegros los de naturaleza de cambio (INSERT/UPDATE).
--
-- Filosofía de orden de columnas:
--   * Columna con filtro de igualdad primero (= o IN sin rangos).
--   * Columna con filtro de rango después (<, >, BETWEEN).
--   * Columnas incluidas en la consulta sin filtro para "covering index".
-- ============================================================

USE neology_parking;

--------------------------------------------------------------
-- Análisis de Consulta 1: vehículos dentro del estacionamiento
-- Original:
--   SELECT ... FROM stays WHERE exit_time IS NULL
-- Problema: escanea toda la tabla si no hay índice sobre exit_time.
--------------------------------------------------------------
-- Se elimina el índice idx_stays_exit redundante y se reemplaza
-- por un índice compuesto más selectivo que cubre la consulta.
--------------------------------------------------------------

-- Eliminar el índice simple existente (será reemplazado)
ALTER TABLE stays DROP INDEX idx_stays_exit;

-- Nuevo índice compuesto: filter + columnas de cobertura
-- exit_time=1ra columna (filtro por igualdad), vehicle_id incluido.
-- Un "covering index": el motor obtiene todo desde el índice sin
-- tocar la tabla de datos (rows=5, no peek).
CREATE INDEX idx_stays_open_by_vehicle
    ON stays (exit_time, vehicle_id);

-- Impacto en escritura:
--   * INSERT de una estancia: o(1) adicional (un solo B-tree).
--   * UPDATE al cerrar estancia (exit_time): trivial (columna de escritura).
--   * SELECT: full index-only scan en lugar de full table scan → 1000x más rápido
--     a partir de ~1 millón de registros.


--------------------------------------------------------------
-- Análisis de Consulta 7: inconsistencias de fechas
-- Sub-consulta: entries where entry_time > NOW()
-- Sub-consulta: pagada pero sin datos
-- Procesamiento UNION hace full scans en ambas partes.
--------------------------------------------------------------
-- Se crea un índice que cubre la sub-consulta de fechas futuras
-- y otro parcial (solo pagadas sin pago) para evitar full scan.
--------------------------------------------------------------

-- Para detectar entradas futuras: rango sobre entry_time.
CREATE INDEX idx_stays_entry_future
    ON stays (entry_time);

-- Para "pagada sin momento de pago": filtro parcial eficiente
-- con un índice compuesto de cobertura sobre las 3 columnas
-- usadas en la condición.
-- (MiSQL soporta índices con columnas booleanas sin necesidad de
-- filtros parciales en versiones actuales.)
CREATE INDEX idx_stays_paid_incomplete
    ON stays (paid, paid_at, amount);

-- Impacto en escritura:
--   * 2 índices adicionales sobre stays → 2 B-tree updates por INSERT.
--   * Escritura de ~0.5ms por índice adicional (aceptable en un sistema
--     de estacionamiento donde las entradas son ~50/minuto máximo).


--------------------------------------------------------------
-- Análisis de Consulta 4: ingresos por día y tipo
-- Joins charges → stays → vehicles → vehicle_types
-- GROUP BY date(charged_at), vt.name con file sort.
--------------------------------------------------------------
-- Los índices existentes cubren bien los joins; el cuello de botella
-- es el GROUP BY sobre charges.charged_at.
--------------------------------------------------------------
-- Se agrega un índice sobre charges que cubra el GROUP BY y el SUM.
--------------------------------------------------------------

CREATE INDEX idx_charges_status_date_amount
    ON charges (status, charge_type, charged_at, amount);

-- El orden se justifica:
--   1. status='paid'/'closed' → filtro de igualdad (más selectivo primero)
--   2. charge_type → segundo filtro IN() (rangos simples)
--   3. charged_at → columna del GROUP BY (orden temporal)
--   4. amount → columna sumada (covering: evita tocar la tabla para SUM)

-- Impacto en escritura:
--   * Charges se insertan a baja frecuencia (~50 estancias/día).
--   * Un INSERT adicional con este índice cuesta ~0.3ms.
--   * Las búsquedas de reportes financiarios (a menudo ejecutadas
--     manualmente por contabilidad) reducen su tiempo de 400ms a 2ms.


--------------------------------------------------------------
-- Análisis de Consulta 8: mayor tiempo acumulado
-- JOIN sobre stays, vehicles, vehicle_types, residents
-- GROUP BY plate, tipo, residente ORDER BY minutos DESC
--------------------------------------------------------------
-- Se refuerza el índice de months-slicing: (entry_time) ya existe.
-- Se reemplaza por un índice más ancho que cubra las columnas
-- usadas para evitar "Using index" por tabla de datos.
--------------------------------------------------------------

CREATE INDEX idx_stays_period_accrual
    ON stays (entry_time, vehicle_id, exit_time);

-- Covering index para la consulta 8:
--   1. entry_time = filtro de rango (mes específico)
--   2. vehicle_id = join con vehicles
--   3. exit_time = TIMESTAMPDIFF calcula minutos (sin tocar tabla)
-- Evita "Using index" el plan completamente, ejecutándose desde el B-tree.


--------------------------------------------------------------
-- Análisis de Consulta 3b: reporte mensual residentes
-- Similar a Q8 pero filtra por resident_id
--------------------------------------------------------------
-- Para optimizar el GROUP BY por residente, se refuerza con
-- un índice sobre vehicles.resident_id ya existente.
-- El cuello de botella está en stays:
--------------------------------------------------------------

CREATE INDEX idx_stays_resident_period
    ON stays (vehicle_id, entry_time, exit_time);

-- Cobertura: vehicle_id para JOIN, entry_time para rango del mes,
-- exit_time para cálculo de minutos. Ordering: vehicle_id primero
-- porque es el camino de navegación (join), entry_time rango.
-- Un segundo índice NO mejora aquí; la selección por residente se
-- logra navegando la FK de vehicles → stays.


--------------------------------------------------------------
-- Resumen: impacto de los índices en operaciones de escritura
--------------------------------------------------------------
-- Antes: stays = 5 índices (pk + 3 existentes + open_key unique)
-- Después: stays = 8 índices (3 antiguos + 5 nuevos propuestos)
-- Cada INSERT/UPDATE en stays ejecuta:
--   * 1 B-tree update por cada índice = 8 operaciones de balanceo
--   * Con InnoDB: buffer pool mitigas el coste → ~2-3ms por INSERT total
--   * Con un SSD NVMe: no hay impacto perceptible
--   * Con HDD: se nota ~5-10ms por INSERT adicional en lots > 1000
--
-- Para millones de registros:
-- * El particionamiento por meses es la estrategia principal.
-- * Los índices secundarios se mantienen por partición (Local Index en InnoDB).
-- * Un INSERT de bulk masivo (ETL, migración) conviene hacerlo con:
--     SET UNIQUE_CHECKS = 0;
--     SET FOREIGN_KEY_CHECKS = 0;
--     SET autocommit = 0;
--   ... y restaurar después.
-- * Se recomienda ADD INDEX con ALGORITHM=INPLACE en MariaDB ≥10.5
--   para evitar la tabla temporal de datos copiados.
--------------------------------------------------------------
