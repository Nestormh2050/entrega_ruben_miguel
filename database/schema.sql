-- ============================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 1: Modelo de Datos Relacional
-- Motor: MariaDB 12.x
-- ============================================================
-- Consideraciones de diseño:
--  * Modelo extensible a nuevos tipos de vehículo y tarifas.
--  * Moneda en centavos (INTEGER/DECIMAL) para evitar errores de
--    redondeo y flotante.
--  * Timestamps en UTC; los reportes convierten a zona local.
--  * Trazabilidad: tabla audit_log + triggers en operaciones críticas.
--  * Histórico: los cierres mensuales materializan estados; las
--    tarifas tienen vigencia (valid_from/valid_to) para reproducir
--    cobros históricos.
-- ============================================================

DROP DATABASE IF EXISTS neology_parking;
CREATE DATABASE neology_parking
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE neology_parking;

--------------------------------------------------------------
-- Tipos de vehículo (extensible)
--------------------------------------------------------------
CREATE TABLE vehicle_types (
    id              TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code            VARCHAR(20)         NOT NULL,
    name            VARCHAR(50)         NOT NULL,
    description     VARCHAR(255)        NULL,
    is_official     TINYINT(1)          NOT NULL DEFAULT 0
                        COMMENT '1 = exento de pago (vehículos oficiales)',
    is_resident     TINYINT(1)          NOT NULL DEFAULT 0
                        COMMENT '1 = aplicable a tarifa por minuto residencial',
    active          TINYINT(1)          NOT NULL DEFAULT 1,
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_vehicle_types PRIMARY KEY (id),
    CONSTRAINT uq_vehicle_types_code UNIQUE (code)
) ENGINE = InnoDB COMMENT 'Catálogo de tipos de vehículo';

--------------------------------------------------------------
-- Residentes
--------------------------------------------------------------
CREATE TABLE residents (
    id              INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    name            VARCHAR(120)        NOT NULL,
    email           VARCHAR(120)        NULL,
    phone           VARCHAR(30)         NULL,
    identifier      VARCHAR(30)         NULL
                        COMMENT 'Credencial/tarjeta de residente',
    active          TINYINT(1)          NOT NULL DEFAULT 1,
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_residents PRIMARY KEY (id),
    CONSTRAINT uq_residents_email UNIQUE (email),
    CONSTRAINT uq_residents_identifier UNIQUE (identifier)
) ENGINE = InnoDB COMMENT 'Residentes registrados con cobro mensual';

--------------------------------------------------------------
-- Vehículos
--------------------------------------------------------------
CREATE TABLE vehicles (
    id              INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    plate           VARCHAR(20)         NOT NULL,
    vehicle_type_id TINYINT UNSIGNED    NOT NULL,
    resident_id     INT UNSIGNED        NULL
                        COMMENT 'Solo para residentes; NULL para no residentes',
    model           VARCHAR(50)         NULL,
    color           VARCHAR(30)         NULL,
    active          TINYINT(1)          NOT NULL DEFAULT 1,
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_vehicles PRIMARY KEY (id),
    CONSTRAINT uq_vehicles_plate UNIQUE (plate),
    CONSTRAINT fk_vehicles_type FOREIGN KEY (vehicle_type_id)
        REFERENCES vehicle_types (id),
    CONSTRAINT fk_vehicles_resident FOREIGN KEY (resident_id)
        REFERENCES residents (id)
) ENGINE = InnoDB COMMENT 'Vehículos registrados';

--------------------------------------------------------------
-- Tarifas (con vigencia para permitir histórico)
--------------------------------------------------------------
CREATE TABLE tariffs (
    id              INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    vehicle_type_id TINYINT UNSIGNED    NOT NULL,
    price_per_minute   DECIMAL(10,4)    NOT NULL
                        COMMENT 'Precio por minuto en la moneda local',
    is_exempt       TINYINT(1)          NOT NULL DEFAULT 0
                        COMMENT '1 = vehículo oficial sin cobro',
    valid_from      DATETIME            NOT NULL,
    valid_to        DATETIME            NULL
                        COMMENT 'NULL = vigente desde valid_from',
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_tariffs PRIMARY KEY (id),
    CONSTRAINT fk_tariffs_type FOREIGN KEY (vehicle_type_id)
        REFERENCES vehicle_types (id),
    CONSTRAINT chk_tariffs_price_min CHECK (price_per_minute >= 0),
    CONSTRAINT chk_tariffs_range CHECK (valid_to IS NULL OR valid_to > valid_from)
) ENGINE = InnoDB COMMENT 'Tarifas por tipo de vehículo con vigencia';

--------------------------------------------------------------
-- Estancias (entradas y salidas)
--------------------------------------------------------------
CREATE TABLE stays (
    id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    vehicle_id      INT UNSIGNED        NOT NULL,
    ticket_number   VARCHAR(30)         NOT NULL
                        COMMENT 'Folio impreso del boleto',
    entry_time      DATETIME            NOT NULL,
    exit_time       DATETIME            NULL
                        COMMENT 'NULL = estancia abierta',
    tariff_id       INT UNSIGNED        NOT NULL
                        COMMENT 'Tarifa aplicada al momento de la entrada',
    paid            TINYINT(1)          NOT NULL DEFAULT 0,
    paid_at         DATETIME            NULL,
    amount          DECIMAL(12,2)       NULL
                        COMMENT 'Importe final (menos para oficiales)',
    open_key        INT UNSIGNED GENERATED ALWAYS AS (IF(exit_time IS NULL, vehicle_id, NULL)) STORED
                        COMMENT 'Solo valor distinto si la estancia está abierta (controla 1 abierta por vehículo)',
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_stays PRIMARY KEY (id),
    CONSTRAINT uq_stays_ticket UNIQUE (ticket_number),
    CONSTRAINT fk_stays_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicles (id),
    CONSTRAINT fk_stays_tariff FOREIGN KEY (tariff_id)
        REFERENCES tariffs (id),
    CONSTRAINT chk_stays_exit_gt_entry CHECK
        (exit_time IS NULL OR exit_time > entry_time),
    CONSTRAINT chk_stays_amount_nonneg CHECK (amount IS NULL OR amount >= 0),
    CONSTRAINT uq_stays_open_key UNIQUE (open_key)
        COMMENT 'Regla: un vehículo no puede tener más de una estancia abierta'
) ENGINE = InnoDB COMMENT 'Estancias del estacionamiento';

-- Índices para búsquedas frecuentes (detalle en indexes.sql)
CREATE INDEX idx_stays_entry ON stays (entry_time);
CREATE INDEX idx_stays_exit ON stays (exit_time);
CREATE INDEX idx_stays_status ON stays (exit_time, paid);

--------------------------------------------------------------
-- Cargos / Pagos
--------------------------------------------------------------
CREATE TABLE charges (
    id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    stay_id         BIGINT UNSIGNED     NOT NULL,
    resident_id     INT UNSIGNED        NULL
                        COMMENT 'Presente si es cargo acumulado de residente',
    amount          DECIMAL(12,2)       NOT NULL,
    charge_type     ENUM ('exempt','instant','accumulated')
                        NOT NULL DEFAULT 'instant'
                        COMMENT 'exempt=oficial, instant=no residente a la salida, accumulated=residencial mensual',
    status          ENUM ('pending','paid','closed')
                        NOT NULL DEFAULT 'pending',
    charged_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    paid_at         DATETIME            NULL,
    reference       VARCHAR(40)         NULL,
    CONSTRAINT pk_charges PRIMARY KEY (id),
    CONSTRAINT fk_charges_stay FOREIGN KEY (stay_id)
        REFERENCES stays (id),
    CONSTRAINT fk_charges_resident FOREIGN KEY (resident_id)
        REFERENCES residents (id),
    CONSTRAINT chk_charges_amount CHECK (amount >= 0)
) ENGINE = InnoDB COMMENT 'Cargos y pagos';

CREATE INDEX idx_charges_stay ON charges (stay_id);
CREATE INDEX idx_charges_resident ON charges (resident_id, charged_at);

--------------------------------------------------------------
-- Cierres mensuales (histórico conservado)
--------------------------------------------------------------
CREATE TABLE monthly_closes (
    id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    period          CHAR(7)             NOT NULL
                        COMMENT 'Periodo contable formato YYYY-MM',
    closed_at       DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_by       VARCHAR(64)         NOT NULL
                        COMMENT 'Usuario que ejecutó el cierre',
    total_charges   DECIMAL(14,2)       NOT NULL DEFAULT 0,
    stay_count      INT UNSIGNED        NOT NULL DEFAULT 0
                        COMMENT 'Estancias consideradas en el periodo',
    notes           VARCHAR(255)        NULL,
    CONSTRAINT pk_monthly_closes PRIMARY KEY (id),
    CONSTRAINT uq_monthly_closes_period UNIQUE (period)
) ENGINE = InnoDB COMMENT 'Cabecera de cierres mensuales (previene duplicados por UNIQUE period)';

--------------------------------------------------------------
-- Cierre mensual por residente (detalle)
--------------------------------------------------------------
CREATE TABLE monthly_close_items (
    id                  BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    monthly_close_id    BIGINT UNSIGNED     NOT NULL,
    resident_id         INT UNSIGNED        NOT NULL,
    total_minutes       INT UNSIGNED        NOT NULL DEFAULT 0,
    total_activities    INT UNSIGNED        NOT NULL DEFAULT 0,
    total_amount        DECIMAL(14,2)       NOT NULL DEFAULT 0,
    status              ENUM ('open','submitted','paid')
                        NOT NULL DEFAULT 'open',
    CONSTRAINT pk_monthly_close_items PRIMARY KEY (id),
    CONSTRAINT fk_mci_close FOREIGN KEY (monthly_close_id)
        REFERENCES monthly_closes (id),
    CONSTRAINT fk_mci_resident FOREIGN KEY (resident_id)
        REFERENCES residents (id),
    CONSTRAINT uq_mci_close_resident UNIQUE (monthly_close_id, resident_id)
) ENGINE = InnoDB COMMENT 'Detalle por residente en cada cierre mensual';

CREATE INDEX idx_mci_close ON monthly_close_items (monthly_close_id);

--------------------------------------------------------------
-- Auditoría de operaciones (Parte 5 realcionada)
--------------------------------------------------------------
CREATE TABLE audit_log (
    id              BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    table_name      VARCHAR(64)         NOT NULL,
    record_id       BIGINT UNSIGNED     NULL,
    action          ENUM ('INSERT','UPDATE','DELETE') NOT NULL,
    old_values      JSON                NULL
                        COMMENT 'Estado previo cuando existe',
    new_values      JSON                NULL
                        COMMENT 'Estado posterior cuando existe',
    changed_by      VARCHAR(64)         NOT NULL DEFAULT 'system',
    changed_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    description     VARCHAR(255)        NULL
                        COMMENT 'Descripción legible del cambio',
    CONSTRAINT pk_audit_log PRIMARY KEY (id)
) ENGINE = InnoDB COMMENT 'Histórico de cambios relevantes';

CREATE INDEX idx_audit_table_record ON audit_log (table_name, record_id);
CREATE INDEX idx_audit_changed_at ON audit_log (changed_at);

--------------------------------------------------------------
-- Triggers de auditoría (tablas críticas)
--------------------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_stays_audit_insert
AFTER INSERT ON stays FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_values, changed_by, description)
    VALUES ('stays', NEW.id, 'INSERT',
            JSON_OBJECT('vehicle_id', NEW.vehicle_id,
                        'entry_time', NEW.entry_time,
                        'ticket', NEW.ticket_number),
            'system', CONCAT('Entrada de vehículo ', NEW.ticket_number));
END$$

CREATE TRIGGER trg_stays_audit_update
AFTER UPDATE ON stays FOR EACH ROW
BEGIN
    IF OLD.exit_time <=> NEW.exit_time OR OLD.amount <=> NEW.amount
       OR OLD.paid <=> NEW.paid OR OLD.paid_at <=> NEW.paid_at THEN
        INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, description)
        VALUES ('stays', NEW.id, 'UPDATE',
                JSON_OBJECT('exit_time', OLD.exit_time, 'amount', OLD.amount, 'paid', OLD.paid, 'paid_at', OLD.paid_at),
                JSON_OBJECT('exit_time', NEW.exit_time, 'amount', NEW.amount, 'paid', NEW.paid, 'paid_at', NEW.paid_at),
                'system', CONCAT('Actualización de estancia ', NEW.ticket_number));
    END IF;
END$$

DELIMITER ;
