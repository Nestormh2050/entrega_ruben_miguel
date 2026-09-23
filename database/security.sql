-- ==============================================================================================
-- DBA - Prueba Técnica Neology
-- Sistema de Control de Acceso Vehicular (Estacionamiento)
-- Parte 5: Seguridad — Usuarios, roles y privilegios
-- Motor: MariaDB 12.x
-- =============================================================================================
-- Diseño:
--   * Principio de mínimo privilegio: cada usuario solo accede a lo estrictamente necesario.
--   * Separación de responsabilidades: las funciones de aplicación, reportes y operación
--     están en usuarios independientes.
--   * Auditoría: las operaciones de administración quedan registradas en audit_log
--     (schema.sql incluye triggers).
--   * Sin credenciales reales: cada contraseña debe sustituirse por un valor seguro
--     provisto por un gestor de secretos o variable de entorno.
--
-- ¡NUNCA incluir contraseñas reales en el repositorio!
-- ================================================================================================

USE neology_parking;
-- ============================================================
-- 1. Roles (si se desea encapsular en roles; se crean usuarios individuales
--    para mayor portabilidad; los roles son un complemento).
-- ============================================================
-- Opcional: crear roles agrupados (requiere MariaDB 10.0.2+)
-- CREATE ROLE 'role_parking_app', 'role_parking_report', 'role_parking_ops';
-- ============================================================
-- 2. Usuario de aplicación (CRUD en operación)
--    Acceso: INSERT/UPDATE/SELECT sobre stays, vehicles, charges, vehicle_types, residents.
--    Restringido: sin DELETE, sin DROP, sin ALTER.
--    Uso típico: la aplicación web/mobile que registra entradas y salidas.
-- ============================================================
CREATE USER IF NOT EXISTS 'parking_app'@'%'
    IDENTIFIED BY '<CAMBIAR_PASSWORD_APP>'
    PASSWORD EXPIRE NEVER;

-- Lectura de catálogos (escritura solo sobre estancias y pagos)
GRANT SELECT
    ON neology_parking.vehicle_types TO 'parking_app'@'%';

GRANT SELECT
    ON neology_parking.residents TO 'parking_app'@'%';

GRANT SELECT
    ON neology_parking.vehicles TO 'parking_app'@'%';

GRANT SELECT
    ON neology_parking.tariffs TO 'parking_app'@'%';

GRANT SELECT, INSERT, UPDATE
    ON neology_parking.stays TO 'parking_app'@'%';

GRANT SELECT, INSERT, UPDATE
    ON neology_parking.charges TO 'parking_app'@'%';

GRANT SELECT
    ON neology_parking.audit_log TO 'parking_app'@'%';

-- Permisos para ejecutar el procedimiento de cierre (controlado desde la aplicación)
GRANT EXECUTE
    ON PROCEDURE neology_parking.execute_monthly_close TO 'parking_app'@'%';

-- Auditoría: la aplicación se identifica en los triggers con CURRENT_USER().
-- ============================================================
-- 3. Usuario de reportes (solo lectura)
--    Acceso: SELECT sobre cualquier tabla. Ninguna escritura.
--    Uso típico: dashboards, Power BI, conectores de reportes.
-- ============================================================
CREATE USER IF NOT EXISTS 'parking_report'@'%'
    IDENTIFIED BY '<CAMBIAR_PASSWORD_REPORT>'
    PASSWORD EXPIRE NEVER;

GRANT SELECT
    ON neology_parking.* TO 'parking_report'@'%';

-- Restricción adicional: no puede ver datos sensibles de residentes.
-- Se logra con vistas si es necesario:
-- CREATE OR REPLACE VIEW neology_parking.v_stays_safe AS
--     SELECT s.id, s.ticket_number, s.entry_time, s.exit_time, s.amount, v.plate
--     FROM stays s JOIN vehicles v ON v.id = s.vehicle_id;
-- GRANT SELECT ON neology_parking.v_stays_safe TO 'parking_report'@'%';
-- ============================================================
-- 4. Usuario de operación y soporte
--    Acceso: SELECT + UPDATE (sin DELETE). Ejecución de diagnóstico.
--    Uso típico: DBA jr / operaciones que monitorean y ajustan.
-- ============================================================
CREATE USER IF NOT EXISTS 'parking_ops'@'%'
    IDENTIFIED BY '<CAMBIAR_PASSWORD_OPS>'
    PASSWORD EXPIRE NEVER;

GRANT SELECT, INSERT, UPDATE
    ON neology_parking.* TO 'parking_ops'@'%';

-- No DELETE (solo el DBA principal puede borrar registros)
-- No DROP, ALTER, GRANT (gestión de esquema es de DBA)
-- ============================================================
-- 5. Usuario DBA (administrador completo)
--    Acceso total. Debe usarse solo para tareas de administración.
--    Uso: el equipo de BD en labores de mantenimiento y soporte avanzado.
-- ============================================================
CREATE USER IF NOT EXISTS 'parking_dba'@'%'
    IDENTIFIED BY '<CAMBIAR_PASSWORD_DBA>'
    PASSWORD EXPIRE NEVER;

GRANT ALL PRIVILEGES
    ON neology_parking.* TO 'parking_dba'@'%';

GRANT SUPER ON *.* TO 'parking_dba'@'%';
-- ============================================================
-- 6. Auditoría de operaciones administrativas
--    Ya cubierta por los triggers en schema.sql (audit_log).
--    Este bloque se usa para registrar eventos manuales del DBA.
-- ============================================================
-- Función auxiliar para insertar registros de auditoría administrativa
DELIMITER $$

DROP PROCEDURE IF EXISTS log_admin_operation$$

CREATE PROCEDURE log_admin_operation(
    IN p_table   VARCHAR(64),
    IN p_action  VARCHAR(32),
    IN p_detail  VARCHAR(255)
)
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_values, changed_by, description)
    VALUES (p_table, NULL, 'INSERT',
            JSON_OBJECT('admin_user', CURRENT_USER(), 'detail', p_detail),
            CURRENT_USER(),
            CONCAT('[ADMIN] ', p_action, ': ', p_detail));
END$$

DELIMITER ;

-- Ejemplo de uso (desde la sesión del DBA):
-- CALL log_admin_operation('stays', 'BACKUP_ONLINE', 'Respaldo incrementales completado');
-- ============================================================
-- 7. Revocación de permisos (ejemplo: cuando un usuario deja el área)
-- ============================================================
-- Sintaxis para revocar todos los permisos de un usuario
-- REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'parking_ops'@'%';
-- DROP USER IF EXISTS 'parking_ops'@'%';

-- Para rotar contraseñas (manteniendo el usuario):
-- ALTER USER 'parking_app'@'%' IDENTIFIED BY '<NUEVA_PASSWORD_APP>';
-- ============================================================
-- 8. Manejo seguro de credenciales
-- ============================================================
-- Reglas para la implementación:
--   1. Las contraseñas se almacenan en gestor de secretos (Vault, AWS SSM, etc.).
--   2. La aplicación lee la contraseña de variables de entorno, NUNCA del código fuente.
--   3. Se usan contraseñas con mínimo 16 caracteres, combinando mayúsculas, minúsculas,
--      números y caracteres especiales.
--   4. Se aplica expiración de contraseña en producción: MySQL PASSWORD EXPIRE INTERVAL 90 DAY.
--   5. Se restringe acceso por IP: CREATE USER ...@'10.0.0.%' (solo red interna).
--   6. Se desactiva el login desde root: MySQL NO autentica root por TCP, solo socket/local.
-- ============================================================
-- Ejemplo de política de contraseñas (requiere validate_password plugin):
-- SET GLOBAL validate_password.length = 16;
-- SET GLOBAL validate_password.mixed_case_count = 1;
-- SET GLOBAL validate_password.number_count = 1;
-- SET GLOBAL validate_password.special_char_count = 1;

-- En MariaDB, también se puede exigir historial de contraseñas:
-- SET GLOBAL validate_password.number_of_history = 5;
