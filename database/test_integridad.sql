-- ============================================================
-- DBA - Prueba Técnica Neology
-- Pruebas automáticas de integridad
-- Procedimiento: test_integridad
-- Motor: MariaDB 12.x
-- ============================================================
-- Uso:
--   SOURCE database/test_integridad.sql;
--   CALL test_integridad();
--
-- Cada chequeo devuelve el número de violaciones; 0 = PASS.
-- El reporte final clasifica el resultado como:
--   * INTEGRIDAD OK          si todos los chequeos pasan
--   * VIOLACIONES DETECTADAS si al menos uno falla
--
-- Nota: los datos curados de data.sql incluyen 3 anomalías
-- intencionales (entrada futura y pago incompleto) que esta
-- suite detecta; ejecutar generate_test_data(...) y luego
-- test_integridad() para una validación 100 % limpia.
-- ============================================================

USE neology_parking;

DELIMITER $$

DROP PROCEDURE IF EXISTS test_integridad$$

CREATE PROCEDURE test_integridad()
BEGIN
    DECLARE v_total_violaciones INT DEFAULT 0;
    DECLARE v_total_checks INT DEFAULT 0;

    DROP TEMPORARY TABLE IF EXISTS _reporte;
    CREATE TEMPORARY TABLE _reporte (
        chequeo     VARCHAR(120) NOT NULL,
        violaciones INT          NOT NULL,
        estado      VARCHAR(10)  NOT NULL
    ) ENGINE = MEMORY;

    ----------------------------------------------------------
    -- 1. Reglas de unicidad
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'UQ: placas duplicadas en vehicles',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM (SELECT plate FROM vehicles GROUP BY plate HAVING COUNT(*) > 1) v;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'UQ: ticket_number duplicados en stays',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM (SELECT ticket_number FROM stays GROUP BY ticket_number HAVING COUNT(*) > 1) s;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'UQ: vehículo con más de una estancia abierta',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM (SELECT vehicle_id FROM stays
          WHERE exit_time IS NULL
          GROUP BY vehicle_id HAVING COUNT(*) > 1) s;

    ----------------------------------------------------------
    -- 2. Chequeos CHECK constraints
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'CHK: exit_time <= entry_time',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays WHERE exit_time IS NOT NULL AND exit_time <= entry_time;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'CHK: amount negativo en stays',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays WHERE amount < 0;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'CHK: amount negativo en charges',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM charges WHERE amount < 0;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'CHK: tariffs con precio negativo',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM tariffs WHERE price_per_minute < 0;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'CHK: tariffs rango invertido (valid_to <= valid_from)',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM tariffs WHERE valid_to IS NOT NULL AND valid_to <= valid_from;

    ----------------------------------------------------------
    -- 3. Reglas de pago e importes
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: estancia con entrada en el futuro',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays WHERE entry_time > NOW();
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: estancia pagada sin paid_at o amount',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays WHERE paid = 1 AND (paid_at IS NULL OR amount IS NULL);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: importe pagado <> minutos*tarifa',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays s
    JOIN tariffs t ON t.id = s.tariff_id
    WHERE s.paid = 1 AND s.exit_time IS NOT NULL
      AND ROUND(TIMESTAMPDIFF(MINUTE, s.entry_time, s.exit_time) * t.price_per_minute, 2)
          <> ROUND(IFNULL(s.amount, -1), 2);

    ----------------------------------------------------------
    -- 4. Integridad referencial (FK)
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: stays sin vehículo válido',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays s
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v WHERE v.id = s.vehicle_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: stays sin tarifa válida',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM stays s
    WHERE NOT EXISTS (SELECT 1 FROM tariffs t WHERE t.id = s.tariff_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: vehicles sin tipo de vehículo válido',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM vehicles v
    WHERE NOT EXISTS (SELECT 1 FROM vehicle_types vt WHERE vt.id = v.vehicle_type_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: vehicles con resident_id inexistente',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM vehicles v
    WHERE v.resident_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM residents r WHERE r.id = v.resident_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: charges sin estancia válida',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM charges c
    WHERE NOT EXISTS (SELECT 1 FROM stays s WHERE s.id = c.stay_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: charges con resident_id inexistente',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM charges c
    WHERE c.resident_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM residents r WHERE r.id = c.resident_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: monthly_close_items sin cabecera válida',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM monthly_close_items mci
    WHERE NOT EXISTS (SELECT 1 FROM monthly_closes mc WHERE mc.id = mci.monthly_close_id);

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'FK: monthly_close_items sin residente válido',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM monthly_close_items mci
    WHERE NOT EXISTS (SELECT 1 FROM residents r WHERE r.id = mci.resident_id);

    ----------------------------------------------------------
    -- 5. Reglas de negocio por tipo de cobro
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: vehículo RESIDENTE sin resident_id',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM vehicles v
    JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
    WHERE vt.is_resident = 1 AND v.resident_id IS NULL;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: vehículo NO residencial con resident_id',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM vehicles v
    JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
    WHERE vt.is_resident = 0 AND v.resident_id IS NOT NULL;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: carga accumulated sin resident_id',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM charges WHERE charge_type = 'accumulated' AND resident_id IS NULL;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: charge exempt con importe distinto de cero',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM charges WHERE charge_type = 'exempt' AND amount <> 0;

    ----------------------------------------------------------
    -- 6. Consistencia del detalle de cierres mensuales
    ----------------------------------------------------------
    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: mci sin coherencia total (minutos/actividades/importe)',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM monthly_close_items
    WHERE total_minutes = 0 AND total_activities = 0 AND total_amount <> 0;

    INSERT INTO _reporte (chequeo, violaciones, estado)
    SELECT 'REG: mci con protagonista duplicado por cierre',
           COUNT(*),
           IF(COUNT(*) = 0, 'PASS', 'FAIL')
    FROM (SELECT monthly_close_id, resident_id
          FROM monthly_close_items
          GROUP BY monthly_close_id, resident_id
          HAVING COUNT(*) > 1) mci;

    ----------------------------------------------------------
    -- 7. Resumen
    ----------------------------------------------------------
    SELECT SUM(violaciones) INTO v_total_violaciones FROM _reporte;
    SELECT COUNT(*) INTO v_total_checks FROM _reporte;

    SELECT * FROM _reporte ORDER BY violaciones DESC, chequeo;

    SELECT
        CONCAT(v_total_checks, ' chequeos ejecutados, ',
               v_total_violaciones, ' violaciones') AS resumen,
        IF(v_total_violaciones = 0, 'INTEGRIDAD OK', 'VIOLACIONES DETECTADAS')
            AS estado_global;

    DROP TEMPORARY TABLE _reporte;
END$$

DELIMITER ;
