#!/usr/bin/env bash
# ============================================================
# DBA - Prueba Técnica Neology
# scripts/partition-stays.sql  (NO EJECUTAR sin revisar)
# ============================================================
# MOTIVO: MariaDB/InnoDB NO admite Foreign Keys en tablas
# particionadas, y todo índice único debe incluir la columna de
# partición. La tabla `stays` hoy depende de ambas características:
#   * FK a vehicles y tariffs, y FK entrante desde charges.
#   * uq_stays_open_key (regla "una estancia abierta por vehículo").
#
# Este archivo DOCUMENTA la migración que se requeriría para
# particionar `stays` por RANGE mensual (TO_DAYS(entry_time)).
# Se deja comentado a propósito: NO ejecutarlo contra la BD.
# ============================================================

-- ── 0. Requiere backup completo previo (scripts/backup.sh) ──

-- ── 1. Quitar FKs que dependen o afectan a stays ──
-- ALTER TABLE stays DROP FOREIGN KEY fk_stays_vehicle;
-- ALTER TABLE stays DROP FOREIGN KEY fk_stays_tariff;
-- ALTER TABLE charges DROP FOREIGN KEY fk_charges_stay;

-- ── 2. Reconstruir claves para incluir entry_time ──
--    PK      -> (id, entry_time)
--    uq_ticket-> UNIQUE (ticket_number, entry_time)  [se debilita]
--    open_key-> se ABANDONA como UNIQUE (no puede incluir la
--               columna de partición sin violentar la regla).
-- ALTER TABLE stays
--     MODIFY id BIGINT UNSIGNED NOT NULL,          -- quita AUTO_INCREMENT
--     DROP FOREIGN KEY fk_stays_vehicle,
--     DROP FOREIGN KEY fk_stays_tariff,
--     DROP KEY uq_stays_ticket,
--     DROP KEY uq_stays_open_key,
--     DROP PRIMARY KEY,
--     ADD PRIMARY KEY (id, entry_time),
--     ADD UNIQUE KEY uq_stays_ticket (ticket_number, entry_time),
--     ADD INDEX idx_stays_ticket (ticket_number),
--     ADD INDEX idx_stays_open (open_key),
--     ADD CONSTRAINT fk_stays_vehicle FOREIGN KEY (vehicle_id)
--         REFERENCES vehicles(id),
--     ADD CONSTRAINT fk_stays_tariff FOREIGN KEY (tariff_id)
--         REFERENCES tariffs(id),
--     MODIFY id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

-- ── 3. Recuperar la regla open_key con un trigger ──
-- (reemplaza -con límites de concurrencia- el UNIQUE perdido)
DELIMITER $$
-- CREATE TRIGGER trg_stays_no_doble_abierta
-- BEFORE INSERT ON stays FOR EACH ROW
-- BEGIN
--     IF NEW.exit_time IS NULL AND EXISTS (
--         SELECT 1 FROM stays
--         WHERE vehicle_id = NEW.vehicle_id AND exit_time IS NULL
--     ) THEN
--         SIGNAL SQLSTATE '45000'
--             SET MESSAGE_TEXT = 'El vehículo ya tiene una estancia abierta';
--     END IF;
-- END$$
DELIMITER ;

-- ── 4. Particionar por RANGE mensual (TO_DAYS) ──
-- ALTER TABLE stays
--     PARTITION BY RANGE (TO_DAYS(entry_time)) (
--         PARTITION p202608 VALUES LESS THAN (TO_DAYS('2026-09-01')),
--         PARTITION p202609 VALUES LESS THAN (TO_DAYS('2026-10-01')),
--         PARTITION pa_siguientes VALUES LESS THAN (TO_DAYS('2030-01-01'))
--     );

-- ── 5. Recrear el FK entrante de charges ──
--    OJO: en InnoDB no puede existir FK sobre tabla particionada
--    (ni como padre ni como hijo). charges quedaría SIN FK a
--    stays; la integridad se delega a la aplicación o triggers.
-- ALTER TABLE charges ADD CONSTRAINT fk_charges_stay
--     FOREIGN KEY (stay_id) REFERENCES stays(id);

-- ============================================================
-- RECOMENDACIÓN FINAL: mantener `stays` NO particionada.
--  * El volumen estimado (24 meses de estancias ≈ 0.6 GB) es
--    manejable sin particionar.
--  * Particionar exige sacrificar FKs y la garantía declarativa
--    de open_key, debilitando el modelo sin beneficio real hoy.
--  * La tabla `audit_log` YA quedó particionada (partitioning.sql)
--    y monotiza el archivado de auditoría mensual.
--  * Si stays creciera > 5-10 GB, migrar con este plan y
--    auditoría reforzada.
-- ============================================================