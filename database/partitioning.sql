-- ============================================================
-- DBA - Prueba Técnica Neology
-- Particionamiento implementado
-- Motor: MariaDB 12.x
-- ============================================================
-- Ejecutar DESPUÉS de schema.sql + data.sql:
--   SOURCE database/partitioning.sql;
--
-- Qué se particiona AHORA:
--   audit_log  por RANGE mensual con TO_DAYS(changed_at).
--   Es la tabla apta sin modificar el modelo: no tiene FK ni
--   índices únicos ajenos a la columna de partición.
--
-- Por qué TO_DAYS():
--   Es la expresión del conjunto prunable de MariaDB. MySQL/MariaDB
--   NO pruna correctamente expresiones compuestas tipo
--   YEAR(c)*100+MONTH(c); con TO_DAYS un rango de fechas en WHERE
--   toca solo las particiones necesarias (verificado con EXPLAIN
--   PARTITIONS). TO_DAYS queda permitido porque la PK ya incluye
--   changed_at (todo índice único debe contener la columna).
--
-- Por qué NO se particiona stays/charges (restricción del motor):
--   1. InnoDB NO admite FK en tablas particionadas. stays tiene
--      FK a vehicles y tariffs, y charges tiene FK a stays.
--   2. Todo índice único debe contener la columna de partición.
--      stays.open_key (regla "una estancia abierta por vehículo")
--      no la incluye; incluirla rompería esa regla.
--   scripts/partition-stays.sql documenta la migración necesaria
--   (dropear FKs + reconstruir claves + triggers de respaldo) si
--   se decide particionar stays en el futuro.
-- ============================================================

USE neology_parking;

--------------------------------------------------------------
-- 0. Idempotencia: si ya estaba particionada, quitar particiones
--    (verificando antes si realmente tiene particiones)
-- ------------------------------------------------------------
SET @audit_has_partitions = (
    SELECT COUNT(*)
    FROM information_schema.PARTITIONS
    WHERE TABLE_SCHEMA = 'neology_parking'
      AND TABLE_NAME   = 'audit_log'
      AND PARTITION_NAME IS NOT NULL
);

SET @stmt_remove_partition = IF(
    @audit_has_partitions > 0,
    'ALTER TABLE audit_log REMOVE PARTITIONING',
    'SELECT ''audit_log no estaba particionada; no se requiere REMOVE'' AS nota'
);
PREPARE s_remove_partition FROM @stmt_remove_partition;
EXECUTE s_remove_partition;
DEALLOCATE PREPARE s_remove_partition;

--------------------------------------------------------------
-- 1. Cambiar PK de audit_log a (id, changed_at)
--    Requisito de particionado: la PK debe incluir la columna
--    de la expresión de partición. id sigue siendo único.
--    Pasos separados porque MariaDB no combina MODIFY
--    (AUTO_INCREMENT) con DROP PRIMARY KEY en una sola ALTER.
--------------------------------------------------------------
ALTER TABLE audit_log
    MODIFY id BIGINT UNSIGNED NOT NULL;

ALTER TABLE audit_log
    DROP PRIMARY KEY,
    ADD PRIMARY KEY (id, changed_at);

ALTER TABLE audit_log
    MODIFY id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

--------------------------------------------------------------
-- 2. Particionar por RANGE mensual con TO_DAYS
--    Nombres de partición: pYYYYMM (frontera = día 1 del mes next)
--------------------------------------------------------------
ALTER TABLE audit_log
    PARTITION BY RANGE (TO_DAYS(changed_at)) (
        PARTITION p202608 VALUES LESS THAN (TO_DAYS('2026-09-01')),
        PARTITION p202609 VALUES LESS THAN (TO_DAYS('2026-10-01')),
        PARTITION p202610 VALUES LESS THAN (TO_DAYS('2026-11-01')),
        PARTITION p202611 VALUES LESS THAN (TO_DAYS('2026-12-01')),
        PARTITION p202612 VALUES LESS THAN (TO_DAYS('2027-01-01')),
        PARTITION p202701 VALUES LESS THAN (TO_DAYS('2027-02-01')),
        PARTITION p202702 VALUES LESS THAN (TO_DAYS('2027-03-01')),
        PARTITION pa_siguientes VALUES LESS THAN (TO_DAYS('2030-01-01'))
    );

--------------------------------------------------------------
-- 3. Mantenimiento: asegura la cobertura del periodo pedido
--    creando (si falta) la partición del MES SIGUIENTE al
--    último creado, comparable con p_anio_mes. Solo se crean
--    meses en orden cronológico, respetando VALUES LESS THAN
--    estrictamente crecientes.
--    Uso (cron mensual): CALL maint_partitions_audit(202703);
--    pedir un mes ya cubierto es un no-op.
--------------------------------------------------------------
DELIMITER $$

DROP PROCEDURE IF EXISTS maint_partitions_audit$$

CREATE PROCEDURE maint_partitions_audit(IN p_anio_mes INT)
-- p_anio_mes: YYYYMM del mes mínimo que debe quedar cubierto
BEGIN
    DECLARE v_max_border INT;
    DECLARE v_fecha      VARCHAR(8);   -- YYYYMM de la frontera actual
    DECLARE v_anio       INT;
    DECLARE v_mes        INT;
    DECLARE v_nombre     VARCHAR(16);
    DECLARE v_limite     INT;
    DECLARE v_sql        VARCHAR(400);

    -- Frontera más alta de las particiones fijas (excluyendo colchón)
    SELECT MAX(PARTITION_DESCRIPTION) INTO v_max_border
    FROM information_schema.PARTITIONS
    WHERE TABLE_SCHEMA   = 'neology_parking'
      AND TABLE_NAME     = 'audit_log'
      AND PARTITION_NAME <> 'pa_siguientes';

    -- Mes que inicia en esa frontera (p. ej. 202703)
    SET v_fecha = DATE_FORMAT(
        FROM_UNIXTIME((v_max_border - 719528) * 86400), '%Y%m');

    IF v_fecha >= p_anio_mes THEN
        SELECT CONCAT('Cobertura ya alcanza ', v_fecha, '. Sin acción.') AS resultado;
    ELSE
        -- Mes a crear = el que inicia en la frontera actual
        SET v_anio = CAST(SUBSTRING(v_fecha, 1, 4) AS UNSIGNED);
        SET v_mes  = CAST(SUBSTRING(v_fecha, 5, 2) AS UNSIGNED);

        IF v_mes = 12 THEN
            SET v_anio = v_anio + 1;
            SET v_mes  = 1;
        ELSE
            SET v_mes  = v_mes + 1;
        END IF;

        SET v_fecha  = CONCAT(v_anio, LPAD(v_mes, 2, '0'));
        SET v_nombre = CONCAT('p', v_fecha);
        SET v_limite = TO_DAYS(DATE_ADD(
            STR_TO_DATE(CONCAT(v_fecha, '01'), '%Y%m%d'),
            INTERVAL 1 MONTH));

        -- Separa el colchón: partición nueva + colchón con misma frontera
        SET v_sql = CONCAT(
            'ALTER TABLE audit_log REORGANIZE PARTITION pa_siguientes INTO (',
            ' PARTITION ', v_nombre,
            ' VALUES LESS THAN (', CAST(v_limite AS CHAR), '),',
            ' PARTITION pa_siguientes VALUES LESS THAN (TO_DAYS(''2030-01-01'')))'
        );
        SET @ddl = v_sql;
        PREPARE stmt FROM @ddl;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;

        SELECT CONCAT('Partición ', v_nombre, ' creada (cubre ', v_fecha, ')')
            AS resultado;
    END IF;
END$$

DELIMITER ;
