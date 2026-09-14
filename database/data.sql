-- ============================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 1/2: Datos de prueba
-- Motor: MariaDB 12.x
-- ============================================================
-- Escenarios cubiertos:
--   * Vehículos oficiales (exentos)   -> stays 4, 10, 18
--   * Vehículos residentes (0.05/min) -> stays 1,2,5,7,8,11,12,14,15,16,20
--   * Vehículos no residentes (0.50/min a la salida) -> 3,6,9,13,17,19,21
--   * Estancias abiertas   -> 16,17,18,19 (dentro del estacionamiento)
--   * Estancias finalizadas -> resto
--   * Diferentes días y meses -> agosto (cerrado) y septiembre (en curso)
--   * Registros inconsistentes para la consulta 7 (detector de anomalías)
-- ============================================================

USE neology_parking;

--------------------------------------------------------------
-- Tipos de vehículo
--------------------------------------------------------------
INSERT INTO vehicle_types (id, code, name, description, is_official, is_resident, active) VALUES
    (1, 'OFICIAL',   'Vehículo Oficial',
     'Vehículos autorizados exentos de pago (administración, emergencias, directivos).', 1, 0, 1),
    (2, 'RESIDENTE', 'Vehículo Residente',
     'Vehiculos asociados a un residente; cobro mensual acumulado a 0.05/min.', 0, 1, 1),
    (3, 'GENERAL',   'Vehículo No Residente',
     'Visitantes y terceros; cobro de 0.50/min al registrar la salida.', 0, 0, 1);

--------------------------------------------------------------
-- Residentes
--------------------------------------------------------------
INSERT INTO residents (id, name, email, phone, identifier, active) VALUES
    (1, 'María González García', 'maria.gonzalez@example.com', '55-1111-2233', 'CRED-001', 1),
    (2, 'Juan Pérez López',      'juan.perez@example.com',      '55-2222-3344', 'CRED-002', 1),
    (3, 'Ana Martínez Ruiz',     'ana.martinez@example.com',    '55-3333-4455', 'CRED-003', 1);

--------------------------------------------------------------
-- Vehículos
--------------------------------------------------------------
INSERT INTO vehicles (id, plate, vehicle_type_id, resident_id, model, color, active) VALUES
    (1, 'OFI-001', 1, NULL, 'Sedán Administración', 'Rojo',   1),
    (2, 'RES-100', 2, 1,    'Aveo 2020',            'Blanco', 1),
    (3, 'RES-101', 2, 2,    'March 2019',           'Gris',   1),
    (4, 'RES-102', 2, 3,    'Versa 2021',           'Negro',  1),
    (5, 'GEN-001', 3, NULL, 'Jetta',                'Azul',   1),
    (6, 'GEN-002', 3, NULL, 'Camioneta Pickup',     'Blanco', 1),
    (7, 'RES-103', 2, 1,    'Civic 2018',           'Plata',  1),
    (8, 'OFI-002', 1, NULL, 'Unidad de Emergencia', 'Verde',  1);

--------------------------------------------------------------
-- Tarifas (con vigencia)
--------------------------------------------------------------
INSERT INTO tariffs (id, vehicle_type_id, price_per_minute, is_exempt, valid_from, valid_to) VALUES
    (1, 1, 0.0000, 1, '2026-01-01 00:00:00', NULL),
    (2, 2, 0.0500, 0, '2026-01-01 00:00:00', NULL),
    (3, 3, 0.5000, 0, '2026-01-01 00:00:00', NULL);

--------------------------------------------------------------
-- Estancias
--------------------------------------------------------------
-- Agosto 2026 (mes cerrado) -> estancias finalizadas
INSERT INTO stays (id, vehicle_id, ticket_number, entry_time, exit_time, tariff_id, paid, paid_at, amount) VALUES
    (1, 2, 'TICKET-0001', '2026-08-02 08:00:00', '2026-08-02 09:30:00', 2, 1, '2026-08-02 09:30:00', 4.50),
    (2, 3, 'TICKET-0002', '2026-08-03 09:00:00', '2026-08-03 11:00:00', 2, 1, '2026-08-03 11:00:00', 6.00),
    (3, 5, 'TICKET-0003', '2026-08-05 10:00:00', '2026-08-05 10:30:00', 3, 1, '2026-08-05 10:30:00', 15.00),
    (4, 1, 'TICKET-0004', '2026-08-06 08:30:00', '2026-08-06 14:30:00', 1, 1, '2026-08-06 14:30:00', 0.00),
    (5, 2, 'TICKET-0005', '2026-08-15 14:00:00', '2026-08-15 16:00:00', 2, 1, '2026-08-15 16:00:00', 6.00),
    (6, 6, 'TICKET-0006', '2026-08-20 09:00:00', '2026-08-20 09:45:00', 3, 1, '2026-08-20 09:45:00', 22.50),
    (7, 4, 'TICKET-0007', '2026-08-22 07:30:00', '2026-08-22 18:30:00', 2, 1, '2026-08-22 18:30:00', 33.00),
    (8, 3, 'TICKET-0008', '2026-08-28 12:00:00', '2026-08-28 13:00:00', 2, 1, '2026-08-28 13:00:00', 3.00);

-- Septiembre 2026 (mes en curso) -> estancias finalizadas y abiertas
INSERT INTO stays (id, vehicle_id, ticket_number, entry_time, exit_time, tariff_id, paid, paid_at, amount) VALUES
    (9,  5, 'TICKET-0009', '2026-09-01 08:00:00', '2026-09-01 08:45:00', 3, 1, '2026-09-01 08:45:00', 22.50),
    (10, 1, 'TICKET-0010', '2026-09-02 09:00:00', '2026-09-02 13:00:00', 1, 1, '2026-09-02 13:00:00', 0.00),
    (11, 2, 'TICKET-0011', '2026-09-03 08:30:00', '2026-09-03 10:00:00', 2, 1, '2026-09-03 10:00:00', 4.50),
    (12, 7, 'TICKET-0012', '2026-09-05 09:00:00', '2026-09-05 10:30:00', 2, 1, '2026-09-05 10:30:00', 4.50),
    (13, 6, 'TICKET-0013', '2026-09-07 11:00:00', '2026-09-07 11:30:00', 3, 1, '2026-09-07 11:30:00', 15.00),
    (14, 3, 'TICKET-0014', '2026-09-08 09:30:00', '2026-09-08 12:00:00', 2, 1, '2026-09-08 12:00:00', 7.50),
    (15, 4, 'TICKET-0015', '2026-09-10 08:00:00', '2026-09-10 10:00:00', 2, 1, '2026-09-10 10:00:00', 6.00);

-- Septiembre 2026 -> estancias ABIERTAS (vehículos actualmente dentro)
INSERT INTO stays (id, vehicle_id, ticket_number, entry_time, exit_time, tariff_id, paid, paid_at, amount) VALUES
    (16, 2, 'TICKET-0016', '2026-09-12 08:00:00', NULL, 2, 0, NULL, NULL),
    (17, 5, 'TICKET-0017', '2026-09-12 10:15:00', NULL, 3, 0, NULL, NULL),
    (18, 8, 'TICKET-0018', '2026-09-13 09:00:00', NULL, 1, 0, NULL, NULL),
    (19, 6, 'TICKET-0019', '2026-09-13 12:30:00', NULL, 3, 0, NULL, NULL);

--------------------------------------------------------------
-- Registros inconsistentes (para validar la consulta 7)
--   * 20: entrada en el futuro (estancia abierta con fecha futura)
--   * 21: marcada como pagada pero sin importe ni momento de pago
--------------------------------------------------------------
INSERT INTO stays (id, vehicle_id, ticket_number, entry_time, exit_time, tariff_id, paid, paid_at, amount) VALUES
    (20, 3, 'TICKET-0020', '2026-09-30 20:00:00', NULL, 2, 0, NULL, NULL),
    (21, 5, 'TICKET-0021', '2026-09-09 08:00:00', '2026-09-09 08:30:00', 3, 1, NULL, NULL);

--------------------------------------------------------------
-- Cargos / Pagos
--------------------------------------------------------------
-- Cargos de agosto (cerrados en el cierre mensual)
INSERT INTO charges (stay_id, resident_id, amount, charge_type, status, charged_at, paid_at) VALUES
    (1, 1,  4.50, 'accumulated', 'closed', '2026-08-02 09:30:00', '2026-09-01 02:00:00'),
    (2, 2,  6.00, 'accumulated', 'closed', '2026-08-03 11:00:00', '2026-09-01 02:00:00'),
    (3, NULL, 15.00, 'instant',   'paid',   '2026-08-05 10:30:00', '2026-08-05 10:30:00'),
    (4, NULL,  0.00, 'exempt',    'closed', '2026-08-06 14:30:00', NULL),
    (5, 1,  6.00, 'accumulated', 'closed', '2026-08-15 16:00:00', '2026-09-01 02:00:00'),
    (6, NULL, 22.50, 'instant',   'paid',   '2026-08-20 09:45:00', '2026-08-20 09:45:00'),
    (7, 3, 33.00, 'accumulated', 'closed', '2026-08-22 18:30:00', '2026-09-01 02:00:00'),
    (8, 2,  3.00, 'accumulated', 'closed', '2026-08-28 13:00:00', '2026-09-01 02:00:00');

-- Cargos de septiembre (en curso)
INSERT INTO charges (stay_id, resident_id, amount, charge_type, status, charged_at, paid_at) VALUES
    (9,  NULL, 22.50, 'instant', 'paid',    '2026-09-01 08:45:00', '2026-09-01 08:45:00'),
    (10, NULL,  0.00, 'exempt',  'closed',  '2026-09-02 13:00:00', NULL),
    (11, 1,  4.50, 'accumulated', 'pending', '2026-09-03 10:00:00', NULL),
    (12, 1,  4.50, 'accumulated', 'pending', '2026-09-05 10:30:00', NULL),
    (13, NULL, 15.00, 'instant', 'paid',     '2026-09-07 11:30:00', '2026-09-07 11:30:00'),
    (14, 2,  7.50, 'accumulated', 'pending', '2026-09-08 12:00:00', NULL),
    (15, 3,  6.00, 'accumulated', 'pending', '2026-09-10 10:00:00', NULL);

--------------------------------------------------------------
-- Cierre mensual de agosto 2026 (histórico conservado)
--------------------------------------------------------------
INSERT INTO monthly_closes (id, period, closed_at, closed_by, total_charges, stay_count, notes) VALUES
    (1, '2026-08', '2026-09-01 02:00:00', 'app_service',
     52.50, 8, 'Cierre de agosto; residentes acumulados liquidados en septiembre.');

INSERT INTO monthly_close_items (monthly_close_id, resident_id, total_minutes, total_activities, total_amount, status) VALUES
    (1, 1, 210, 2, 10.50, 'paid'),
    (1, 2, 180, 2,  9.00, 'paid'),
    (1, 3, 660, 1, 33.00, 'paid');
