# Diagnóstico de Incidente — Estacionamiento Neology

## Escenario

La aplicación presenta tiempos de respuesta elevados. La base de datos alcanzó el **límite de conexiones**, existen **sesiones bloqueadas** y el **almacenamiento se encuentra al 85%** de capacidad.

---

## 1. Validaciones iniciales

| Paso | Comando | Qué se verifica |
|---|---|---|
| Estado del servicio | `systemctl status mariadb` / `SHOW GLOBAL STATUS;` | Si el servicio está corriendo y respondiendo. |
| Variables de entorno | `SHOW GLOBAL VARIABLES LIKE 'max_connections';` | Límite máximo configurado. |
| Conexiones actuales | `SHOW GLOBAL STATUS LIKE 'Threads_connected';` | Cuántas conexiones hay ahora vs. el límite. |
| Uso de disco | `df -h /var/lib/mysql/` | Espacio disponible en el volumen de datos. |
| Log de errores | `tail -100 /var/log/mysql/error.log` | Errores recientes o advertencias. |
| Procesos del sistema | `SHOW PROCESSLIST;` (en MariaDB) / `top` (en Linux) | Carga del sistema y procesos activos. |

---

## 2. Consultas de diagnóstico

```sql
-- Conexiones actuales vs. máximo
SELECT
    @@max_connections AS maximo,
    (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS
     WHERE VARIABLE_NAME = 'Threads_connected') AS conectadas,
    (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS
     WHERE VARIABLE_NAME = 'Max_used_connections') AS max_usado;

-- Sesiones bloqueadas (en MariaDB, buscar transacciones antiguas)
SELECT
    s.id AS pid,
    s.user,
    s.host,
    s.db,
    s.command,
    s.time AS segundos,
    s.state,
    t.trx_started,
    TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) AS trx_age,
    t.trx_rows_locked,
    t.trx_rows_modified
FROM information_schema.INNODB_TRX t
JOIN information_schema.PROCESSLIST s ON s.id = t.trx_mysql_thread_id
ORDER BY t.trx_started ASC;

-- Consultas de mayor consumo (si performance_schema está habilitado)
SELECT
    DIGEST_TEXT AS consulta,
    COUNT_STAR AS ejecuciones,
    SUM_TIMER_WAIT / 1e12 AS tiempo_total_seg,
    AVG_TIMER_WAIT / 1e12 AS tiempo_promedio_seg,
    SUM_ROWS_EXAMINED AS filas_escaneadas,
    SUM_ROWS_SENT AS filas_enviadas
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- Uso de disco por tabla
SELECT
    TABLE_NAME,
    ROUND(DATA_LENGTH / 1024 / 1024, 2) AS datos_mb,
    ROUND(INDEX_LENGTH / 1024 / 1024, 2) AS indices_mb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS total_mb,
    TABLE_ROWS AS filas_aprox
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'neology_parking'
ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;
```

---

## 3. Identificar sesiones bloqueadas

```sql
-- Buscar transacciones que llevan mucho tiempo abiertas (posible bloqueo)
SELECT
    r.trx_id AS transaccion_bloqueada,
    r.trx_mysql_thread_id AS pid_bloqueado,
    r.trx_query AS consulta_bloqueada,
    r.trx_wait_started AS esperando_desde,
    b.trx_id AS transaccion_bloqueadora,
    b.trx_mysql_thread_id AS pid_bloqueador,
    b.trx_query AS consulta_bloqueadora
FROM information_schema.INNODB_LOCK_WAITS w
JOIN information_schema.INNODB_TRX r ON r.trx_id = w.requesting_trx_id
JOIN information_schema.INNODB_TRX b ON b.trx_id = w.blocking_trx_id;

-- Verificar si hay lock de tabla (sistema de bloqueo heredado)
SHOW OPEN TABLES WHERE In_use > 0;
```

**¿Cómo identificar si una sesión es problemática?**
- Transacciones que llevan **más de 60 segundos** con cambios sin COMMIT.
- `trx_rows_locked` alto (> 1000 filas).
- `trx_rows_modified` alto sin COMMIT (escritura masiva sin finalizar).
- Transacciones en estado `LOCK WAIT`.

---

## 4. Consultas de mayor consumo

```sql
-- Top 5 consultas más lentas en la última hora
SELECT
    LEFT(DIGEST_TEXT, 120) AS consulta,
    COUNT_STAR AS ejecuciones,
    ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seg,
    ROUND(AVG_TIMER_WAIT / 1e12, 3) AS promedio_seg,
    SUM_ROWS_EXAMINED AS filas_escaneadas
FROM performance_schema.events_statements_summary_by_digest
WHERE FIRST_SEEN > DATE_SUB(NOW(), INTERVAL 1 HOUR)
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 5;

-- Verificar queries confull table scan
SELECT
    OBJECT_SCHEMA, OBJECT_NAME, COUNT_READ, COUNT_WRITE
FROM performance_schema.table_io_waits_summary_by_table
WHERE OBJECT_SCHEMA = 'neology_parking'
  AND COUNT_READ > 100000
ORDER BY COUNT_READ DESC;
```

---

## 5. Acciones inmediatas para estabilizar

| Prioridad | Acción | Comando |
|---|---|---|
| **Urgente** | Matar sesiones bloqueadas antiguas (solo si están confirmadas como innecesarias) | `KILL <pid>;` (necesita revisión previa de cada sesión) |
| **Urgente** | Aumentar temporalmente el límite de conexiones | `SET GLOBAL max_connections = 500;` |
| **Urgente** | Liberar espacio en disco | `PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 1 DAY);` (borrar binlogs antiguos) |
| **Alta** | Detener procesos no esenciales que consuman CPU/disco | Linux: `kill -STOP <PID>` (pausar, no matar) |
| **Alta** | Optimizar tablas grandes | `OPTIMIZE TABLE stays;` (reorganiza espacio fragmentado) |
| **Media** | Activar slow query log para monitoreo continuo | `SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 2;` |

---

## 6. Acciones preventivas

1. **Monitoreo proactivo:** configurar alertas de:
   - Conexiones > 80% del máximo.
   - Uso de disco > 75%.
   - Transacciones abiertas > 30 segundos.
2. **Pool de conexiones:** la aplicación debe usar un pool (HikariCP, etc.) con máximo controlado.
3. **Revisión de queries lentas:** implementar `slow_query_log` y revisar semanalmente.
4. **Limpieza de binlogs:** configurar `expire_logs_days = 7` o retención por tamaño.
5. **Tuning de InnoDB:**
   - `innodb_buffer_pool_size = 60%` de la RAM del servidor.
   - `innodb_log_file_size = 256M` para escrituras masivas.
6. **Particionamiento de la tabla `stays`** por meses (reduce el tamaño de las búsquedas).
7. **Respaldo automático diario** con verificación (ya implementado en `scripts/backup.sh`).

---

## 7. Riesgos antes de cancelar una sesión o consulta

| Riesgo | Consecuencia | Mitigación |
|---|---|---|
| Cancelar una transacción con cambios sin COMMIT | **Pérdida de datos** de las operaciones realizadas en esa transacción. | Verificar `trx_rows_modified`; si es > 0 y la transacción está en curso, considerar enviar COMMIT forzado en lugar de KILL. |
| Cancelar un usuario de la aplicación | La aplicación perderá la conexión y mostrará error al usuario final. | Coordinar con el equipo de desarrollo; detener primero el tráfico nuevo a la BD antes de KILL. |
| Cancelar una carga de datos en curso (LOAD DATA, INSERT masivo) | Datos parciales en la tabla, posible inconsistencia. | Verificar si es transaccional (dentro de BEGIN/COMMIT); si lo es, el rollback automático garantiza consistencia. |
| Cancelar un REPAIR o ALTER TABLE | Puede dejar la tabla en estado corrupto o a medio modificar. | **NUNCA cancelar** un ALTER TABLE en curso; esperar a que termine o ser consciente de que puede requerir restauración. |

**Regla de oro:** antes de cualquier `KILL`, ejecutar la consulta de diagnóstico de sesiones bloqueadas y entender completamente qué está haciendo cada sesión.

---

## 8. Consideraciones equivalentes para MariaDB y Oracle

| Diagnóstico | MariaDB | Oracle |
|---|---|---|
| Sesiones activas | `SHOW PROCESSLIST;` | `SELECT * FROM V$SESSION WHERE STATUS='ACTIVE';` |
| Transacciones bloqueadas | `information_schema.INNODB_LOCK_WAITS` | `SELECT * FROM V$LOCK;` + `V$SESSION_BLOCKERS` |
| Consultas lentas | `performance_schema.events_statements_summary_by_digest` | AWR (Automatic Workload Repository) / `V$SQL` |
| Espacio usado por tabla | `information_schema.TABLES` | `DBA_SEGMENTS` / `DBA_TABLES` |
| Matar sesión | `KILL <pid>;` | `ALTER SYSTEM KILL SESSION '<sid>,<serial#>' IMMEDIATE;` |
| Límite de conexiones | `SHOW VARIABLES LIKE 'max_connections';` | `SHOW PARAMETERS LIKE 'sessions';` |
| Monitoreo continuo | `performance_schema` + `slow_query_log` | AWR + ADDM + Enterprise Manager |
| Liberar espacio | `PURGE BINARY LOGS;` + `OPTIMIZE TABLE` | `ALTER TABLE ... SHRINK SPACE;` + `PURGE RECYCLEBIN;` |
| Tunning de memoria | `SET GLOBAL innodb_buffer_pool_size;` | `ALTER SYSTEM SET sga_target_size;` |

**Nota:** Oracle ofrece herramientas integradas (AWR, ADDM, Enterprise Manager) que automatizan gran parte de lo que en MariaDB se hace manualmente. Para un entorno crítico de alto volumen, estas herramientas justifican la licencia de Oracle Enterprise Edition.