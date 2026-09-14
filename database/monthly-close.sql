-- ============================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 3: Operación de cierre mensual
-- Motor: MariaDB 12.x
-- ============================================================
-- Requisitos cubiertos:
--   * Calcula el cierre de los residentes del periodo.
--   * Conserva el histórico del periodo anterior (nunca se hace DELETE;
--     los cierres son inmutables: se insertan, no se reemplazan).
--   * Previene ejecuciones duplicadas (UNIQUE(period) + validación).
--   * Garantiza consistencia (transacción con EXIT HANDLER + ROLLBACK).
--   * Identifica cuándo y quién ejecutó el cierre (closed_at / closed_by).
--
-- Uso:
--   CALL execute_monthly_close('2026-09');
--   -- Reintentar el mismo periodo lanza un error y no hace cambios.
-- ============================================================

USE neology_parking;

DELIMITER $$

DROP PROCEDURE IF EXISTS execute_monthly_close$$

CREATE PROCEDURE execute_monthly_close(
    IN p_period     CHAR(7),   -- Periodo a cerrar en formato 'YYYY-MM'
    IN p_closed_by  VARCHAR(64) -- Responsable; por defecto el usuario de BD
)
BEGIN
    DECLARE v_close_id  BIGINT UNSIGNED;
    DECLARE v_start     DATETIME;
    DECLARE v_end       DATETIME;

    -- Manejador de errores: ante cualquier fallo se revierte todo.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Valor por defecto para el responsable
    IF p_closed_by IS NULL OR p_closed_by = '' THEN
        SET p_closed_by = CURRENT_USER();
    END IF;

    -- 1) Validaciones de entrada -------------------------------
    IF p_period NOT REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Formato de periodo inválido. Use YYYY-MM.';
    END IF;

    SET v_start = CONCAT(p_period, '-01 00:00:00');
    SET v_end   = DATE_ADD(v_start, INTERVAL 1 MONTH);

    START TRANSACTION;

    -- 2) Prevenir ejecuciones duplicadas -----------------------
    IF EXISTS (SELECT 1 FROM monthly_closes WHERE period = p_period FOR UPDATE) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'El periodo ya fue cerrado. No se permiten cierres duplicados.';
    END IF;

    -- 3) Cabecera del cierre ------------------------------------
    INSERT INTO monthly_closes (period, closed_at, closed_by, total_charges, stay_count, notes)
    VALUES (
        p_period,
        NOW(),
        p_closed_by,
        0,
        0,
        CONCAT('Cierre del periodo ', p_period, ' ejecutado por ', p_closed_by)
    );

    SET v_close_id = LAST_INSERT_ID();

    -- 4) Detalle por residente ----------------------------------
    --     Se calculan minutos, número de estancias e importe
    --     acumulado con la tarifa vigente registrada en cada estancia.
    INSERT INTO monthly_close_items (
        monthly_close_id, resident_id,
        total_minutes, total_activities, total_amount, status
    )
    SELECT
        v_close_id,
        v.resident_id,
        SUM(TIMESTAMPDIFF(
            MINUTE, s.entry_time, COALESCE(s.exit_time, v_end)
        ))                                    AS total_minutes,
        COUNT(*)                              AS total_activities,
        ROUND(SUM(
            TIMESTAMPDIFF(MINUTE, s.entry_time, COALESCE(s.exit_time, v_end))
            * t.price_per_minute
        ), 2)                                 AS total_amount,
        'open'                                AS status
    FROM stays s
    JOIN vehicles v      ON v.id = s.vehicle_id
    JOIN tariffs t        ON t.id = s.tariff_id
    WHERE v.resident_id IS NOT NULL
      AND s.entry_time >= v_start
      AND s.entry_time <  v_end
    GROUP BY v.resident_id;

    -- 5) Totales de la cabecera --------------------------------
    UPDATE monthly_closes mc
    SET
        total_charges = (
            SELECT ROUND(SUM(total_amount), 2)
            FROM monthly_close_items
            WHERE monthly_close_id = v_close_id
        ),
        stay_count    = (
            SELECT SUM(total_activities)
            FROM monthly_close_items
            WHERE monthly_close_id = v_close_id
        )
    WHERE mc.id = v_close_id;

    -- 6) Marcar cargos acumulados del periodo como cerrados -----
    --     (Convierte 'pending' en 'closed' y fija la fecha de pago;
    --      los cargos de estancias finalizadas NO abiertas).
    UPDATE charges c
    JOIN stays s ON s.id = c.stay_id
    JOIN vehicles v ON v.id = s.vehicle_id
    SET c.status   = 'closed',
        c.paid_at  = IFNULL(c.paid_at, NOW())
    WHERE c.charge_type = 'accumulated'
      AND c.status = 'pending'
      AND v.resident_id IS NOT NULL
      AND s.entry_time >= v_start
      AND s.entry_time <  v_end;

    COMMIT;

    -- 7) Reporte de confirmación -------------------------------
    SELECT
        mc.period,
        mc.closed_by,
        mc.closed_at,
        mc.total_charges,
        mc.stay_count
    FROM monthly_closes mc
    WHERE mc.id = v_close_id;
END$$

DELIMITER ;

-- ============================================================
-- Ejemplos de uso
-- ============================================================
-- 1) Cerrar el periodo actual (septiembre 2026)
--    CALL execute_monthly_close('2026-09', 'ruben_miguel');
--
-- 2) Intentar cerrar de nuevo el mismo periodo (debe fallar)
--    CALL execute_monthly_close('2026-09', 'ruben_miguel');
--    >> ERROR 1644: El periodo ya fue cerrado...
--
-- 3) Ver el histórico conservado
--    SELECT * FROM monthly_closes ORDER BY period;
--    SELECT * FROM monthly_close_items ORDER BY monthly_close_id, resident_id;
--
-- 4) Demo de consistencia en caso de error:
--    Si cualquier instrucción falla (p. ej. un periodo inválido),
--    el EXIT HANDLER ejecuta ROLLBACK y no quedan cambios parciales.
--    CALL execute_monthly_close('2026-XX');  -- lanza el error de formato