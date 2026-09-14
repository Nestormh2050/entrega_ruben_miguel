-- ============================================================
-- DBA - Prueba Técnica Neology
-- Generación automática de datos de prueba
-- Procedimiento: generate_test_data
-- Motor: MariaDB 12.x
-- ============================================================
-- Uso:
--   SOURCE database/generate-data.sql;
--   CALL generate_test_data(
--        p_months_back    => 3,
--        p_stays_per_day  => 20,
--        p_num_residents  => 30,
--        p_num_nonresid   => 50,
--        p_num_officials  => 10,
--        p_open_stays     => 15,
--        p_clean_first    => TRUE
--   );
--
-- Reglas de negocio respetadas:
--   * UNIQUE(plate), UNIQUE(ticket_number)
--   * open_key UNIQUE: solo UNA estancia abierta por vehículo
--   * CHECK: exit_time > entry_time, amount >= 0
--   * Oficiales sin cobro (amount=0, charge exempt)
--   * Residentes: tarifa acumulada mensual (0.05/min), charge accumulated
--   * No residentes: pago a la salida (0.50/min), charge instant paid
-- ============================================================

USE neology_parking;

DELIMITER $$

DROP PROCEDURE IF EXISTS generate_test_data$$

CREATE PROCEDURE generate_test_data(
    IN p_months_back   INT,
    IN p_stays_per_day INT,
    IN p_num_residents INT,
    IN p_num_nonresid  INT,
    IN p_num_officials INT,
    IN p_open_stays    INT,
    IN p_clean_first   BOOLEAN
)
BEGIN
    DECLARE v_ticket_seq    INT DEFAULT 1;
    DECLARE v_plate_seq     INT DEFAULT 1;
    DECLARE v_stay_id       BIGINT;
    DECLARE v_resident_id   INT;
    DECLARE v_vtype_official TINYINT;
    DECLARE v_vtype_resident TINYINT;
    DECLARE v_vtype_general  TINYINT;
    DECLARE v_tariff_ofc      INT;
    DECLARE v_tariff_res      INT;
    DECLARE v_tariff_gen      INT;
    DECLARE v_day            DATE;
    DECLARE v_entrada        DATETIME;
    DECLARE v_salida         DATETIME;
    DECLARE v_min            INT;
    DECLARE v_cost           DECIMAL(12,2);
    DECLARE v_vehicle_id     INT;
    DECLARE v_vehicle_type   TINYINT;
    DECLARE v_vehicle_tarif  INT;
    DECLARE v_vehicle_resid  INT;
    DECLARE v_vehicles_libres INT;
    DECLARE v_idx            INT DEFAULT 0;
    DECLARE v_row            INT DEFAULT 0;

    -- Limpieza opcional en orden correcto de dependencias (FK)
    IF p_clean_first THEN
        DELETE FROM monthly_close_items;
        DELETE FROM monthly_closes;
        DELETE FROM charges;
        DELETE FROM stays;
        DELETE FROM vehicles;
        DELETE FROM tariffs;
        DELETE FROM residents;
        DELETE FROM vehicle_types;
        DELETE FROM audit_log;
        ALTER TABLE stays AUTO_INCREMENT = 1;
        ALTER TABLE vehicles AUTO_INCREMENT = 1;
    END IF;

    ------------------------------------------------------
    -- 1. Catálogo de tipos de vehículo
    ------------------------------------------------------
    INSERT INTO vehicle_types (code, name, description, is_official, is_resident)
    VALUES ('OFICIAL', 'Vehículo Oficial', 'Exento de pago', 1, 0),
           ('RESIDENTE', 'Vehículo Residente', 'Tarifa residencial mensual', 0, 1),
           ('GENERAL', 'Vehículo No Residente', 'Tarifa por minuto a la salida', 0, 0);

    SELECT id INTO v_vtype_official FROM vehicle_types WHERE code = 'OFICIAL';
    SELECT id INTO v_vtype_resident FROM vehicle_types WHERE code = 'RESIDENTE';
    SELECT id INTO v_vtype_general  FROM vehicle_types WHERE code = 'GENERAL';

    ------------------------------------------------------
    -- 2. Tarifas vigentes
    ------------------------------------------------------
    INSERT INTO tariffs (vehicle_type_id, price_per_minute, is_exempt, valid_from)
    VALUES (v_vtype_official, 0.0000, 1, '2020-01-01 00:00:00'),
           (v_vtype_resident, 0.0500, 0, '2020-01-01 00:00:00'),
           (v_vtype_general,  0.5000, 0, '2020-01-01 00:00:00');

    SELECT id INTO v_tariff_ofc FROM tariffs WHERE vehicle_type_id = v_vtype_official;
    SELECT id INTO v_tariff_res FROM tariffs WHERE vehicle_type_id = v_vtype_resident;
    SELECT id INTO v_tariff_gen FROM tariffs WHERE vehicle_type_id = v_vtype_general;

    ------------------------------------------------------
    -- 3. Residentes y sus vehículos
    ------------------------------------------------------
    SET v_idx = 1;
    WHILE v_idx <= p_num_residents DO
        INSERT INTO residents (name, email, phone, identifier)
        VALUES (CONCAT('Residente Generado ', v_idx),
                CONCAT('residente', v_idx, '@neology.test'),
                CONCAT('555-', LPAD(v_idx, 4, '0')),
                CONCAT('CRED-', LPAD(v_idx, 5, '0')));
        SET v_resident_id = LAST_INSERT_ID();

        INSERT INTO vehicles (plate, vehicle_type_id, resident_id, model, color)
        VALUES (CONCAT('RES-', LPAD(1000 + v_plate_seq, 4, '0')),
                v_vtype_resident, v_resident_id, 'Modelo Genérico', 'Gris');
        SET v_plate_seq = v_plate_seq + 1;
        SET v_idx = v_idx + 1;
    END WHILE;

    ------------------------------------------------------
    -- 4. Vehículos no residentes
    ------------------------------------------------------
    SET v_idx = 1;
    WHILE v_idx <= p_num_nonresid DO
        INSERT INTO vehicles (plate, vehicle_type_id, model, color)
        VALUES (CONCAT('GEN-', LPAD(1000 + v_plate_seq, 4, '0')),
                v_vtype_general, 'Modelo Genérico', 'Azul');
        SET v_plate_seq = v_plate_seq + 1;
        SET v_idx = v_idx + 1;
    END WHILE;

    ------------------------------------------------------
    -- 5. Vehículos oficiales
    ------------------------------------------------------
    SET v_idx = 1;
    WHILE v_idx <= p_num_officials DO
        INSERT INTO vehicles (plate, vehicle_type_id, model, color)
        VALUES (CONCAT('OFI-', LPAD(1000 + v_plate_seq, 4, '0')),
                v_vtype_official, 'Modelo Oficial', 'Blanco');
        SET v_plate_seq = v_plate_seq + 1;
        SET v_idx = v_idx + 1;
    END WHILE;

    ------------------------------------------------------
    -- 6. Estancias cerradas
    ------------------------------------------------------
    SET v_day = DATE_SUB(CURDATE(), INTERVAL p_months_back MONTH);

    WHILE v_day < CURDATE() DO
        SET v_row = 0;
        WHILE v_row < p_stays_per_day DO
            -- Selecciona un vehículo aleatorio con su tarifa y residente
            SELECT v.id, v.vehicle_type_id, v.resident_id,
                   IF(v.vehicle_type_id = v_vtype_official, v_tariff_ofc,
                      IF(v.vehicle_type_id = v_vtype_resident, v_tariff_res, v_tariff_gen))
            INTO v_vehicle_id, v_vehicle_type, v_vehicle_resid, v_vehicle_tarif
            FROM vehicles v
            ORDER BY RAND()
            LIMIT 1;

            -- Hora de entrada 07:00–20:59; duración 15–300 min
            SET v_entrada = TIMESTAMP(v_day,
                    MAKETIME(FLOOR(RAND() * 14) + 7, FLOOR(RAND() * 60), 0));
            SET v_min = 15 + FLOOR(RAND() * 286);
            SET v_salida = DATE_ADD(v_entrada, INTERVAL v_min MINUTE);

            -- Costo según tipo
            IF v_vehicle_type = v_vtype_official THEN
                SET v_cost = 0.00;
            ELSEIF v_vehicle_type = v_vtype_resident THEN
                SET v_cost = ROUND(v_min * 0.0500, 2);
            ELSE
                SET v_cost = ROUND(v_min * 0.5000, 2);
            END IF;

            INSERT INTO stays (vehicle_id, ticket_number, entry_time, exit_time,
                               tariff_id, paid, paid_at, amount)
            VALUES (v_vehicle_id,
                    CONCAT('TICKET-', LPAD(v_ticket_seq, 6, '0')),
                    v_entrada, v_salida, v_vehicle_tarif, 1, v_salida, v_cost);
            SET v_stay_id = LAST_INSERT_ID();
            SET v_ticket_seq = v_ticket_seq + 1;

            -- Cargo según regla de cobro
            IF v_vehicle_type = v_vtype_official THEN
                INSERT INTO charges (stay_id, amount, charge_type, status, charged_at, paid_at)
                VALUES (v_stay_id, 0.00, 'exempt', 'closed', v_salida, v_salida);
            ELSEIF v_vehicle_type = v_vtype_resident THEN
                INSERT INTO charges (stay_id, resident_id, amount, charge_type, status, charged_at, paid_at)
                VALUES (v_stay_id, v_vehicle_resid, v_cost, 'accumulated', 'paid',
                        v_salida, v_salida);
            ELSE
                INSERT INTO charges (stay_id, amount, charge_type, status, charged_at, paid_at)
                VALUES (v_stay_id, v_cost, 'instant', 'paid', v_salida, v_salida);
            END IF;

            SET v_row = v_row + 1;
        END WHILE;
        SET v_day = DATE_ADD(v_day, INTERVAL 1 DAY);
    END WHILE;

    ------------------------------------------------------
    -- 7. Estancias abiertas (una por vehículo distinto)
    ------------------------------------------------------
    SELECT COUNT(*) INTO v_vehicles_libres
    FROM vehicles v
    WHERE NOT EXISTS (SELECT 1 FROM stays s WHERE s.vehicle_id = v.id
                      AND s.exit_time IS NULL);

    IF v_vehicles_libres > 0 THEN
        SET v_row = 0;
        SET v_idx = 1;
        WHILE v_idx <= LEAST(p_open_stays, v_vehicles_libres) DO
            SELECT v.id, v.vehicle_type_id,
                   IF(v.vehicle_type_id = v_vtype_official, v_tariff_ofc,
                      IF(v.vehicle_type_id = v_vtype_resident, v_tariff_res, v_tariff_gen))
            INTO v_vehicle_id, v_vehicle_type, v_vehicle_tarif
            FROM vehicles v
            WHERE NOT EXISTS (SELECT 1 FROM stays s WHERE s.vehicle_id = v.id
                              AND s.exit_time IS NULL)
            ORDER BY RAND()
            LIMIT 1;

            SET v_entrada = TIMESTAMP(
                    DATE_SUB(CURDATE(), INTERVAL FLOOR(RAND() * 3) + 1 DAY),
                    MAKETIME(FLOOR(RAND() * 12) + 7, FLOOR(RAND() * 60), 0));

            INSERT INTO stays (vehicle_id, ticket_number, entry_time, exit_time,
                               tariff_id, paid, paid_at, amount)
            VALUES (v_vehicle_id,
                    CONCAT('TICKET-', LPAD(v_ticket_seq, 6, '0')),
                    v_entrada, NULL, v_vehicle_tarif, 0, NULL, NULL);
            SET v_ticket_seq = v_ticket_seq + 1;
            SET v_idx = v_idx + 1;
        END WHILE;
    END IF;

    ------------------------------------------------------
    -- 8. Resumen de lo generado
    ------------------------------------------------------
    SELECT
        (SELECT COUNT(*) FROM vehicle_types) AS tipos,
        (SELECT COUNT(*) FROM residents)     AS residentes,
        (SELECT COUNT(*) FROM vehicles)      AS vehiculos,
        (SELECT COUNT(*) FROM stays)         AS estancias,
        (SELECT COUNT(*) FROM charges)       AS cargos;

END$$

DELIMITER ;
