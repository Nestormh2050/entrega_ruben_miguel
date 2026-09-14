# Comparación Detallada: MariaDB vs Oracle Database

> Contexto: decisión de motor para `neology_parking` (prueba técnica DBA Neology).
> Premisa del proyecto: el sistema mantiene un **control vehicular** con estancias,
> tarifas, cierres mensuales y auditoría (`audit_log` JSON), y exige ser Open Source
> y operar con presupuesto de licenciamiento cero.

---

## 1. Resumen ejecutivo

| | **MariaDB** | **Oracle Database** |
|---|---|---|
| **Versión analizada** | 12.3 (Community) | 23ai / 19c / 21c (EE, SE2, FREE) |
| **Licencia** | GPLv2 — sin costo | Comercial por procesador/usuario (EE carísima; SE2 limitada; FREE solo para desarrollo/pruebas) |
| **TCO inicial** | $0 + hardware | Licencia EE ~ $47,500/processador + soporte 22 %/año (referenciales 2026) |
| **Modelo** | Servidor único + storage engines (InnoDB por defecto) | Instancia (SGA + procesos de background) + base de datos sobre archivos/ASM |
| **Mejor caso de uso** | Aplicaciones web/OLTP de costo contenido, estándar SQL | Cargas OLTP y **OLAP** críticas, alta disponibilidad corporativa, PL/SQL pesado |
| **Veredicto para `neology_parking`** | **Adecuado** (requisito Open Source, volumen < 10 GB, SQL sencillo) | Descartado por licencia (a menos que la empresa ya pague Oracle) |

---

## 2. Arquitectura

| Aspecto | MariaDB | Oracle |
|---|---|---|
| **Modelo de procesos** | Un solo proceso `mysqld` con hilos por conexión; motores de almacenamiento enchufables | Instancia = SGA + PGA + procesos background (PMON, SMON, DBWn, LGWR, CKPT, ARCn) y listener Oracle Net |
| **Diccionario de datos** | Tablas InnoDB internas del sistema (diccionario en archivos de datos, 12.x) | Diccionario en `sys`/`dictionary` + catálogo compilado (`data dictionary cache`) |
| **Arquitectura multiusuario** | Multi-template; inexistente el concepto PDB/CDB | **CDB/PDB** (multi-tenant), plugeable desde 12c |
| **SGA compartida** | Buffer pool InnoDB + cachés propios por motor | Buffer cache compartido, shared pool, large pool, Java pool, redolog buffer; gestión automática (AMM/ASMM) |
| **Configuración dinámica** | Variables `SET GLOBAL` en caliente (muchas) | Parámetros con `ALTER SYSTEM` (algunos requieren reinicio) |
| **Secuencias/IDENTITY** | `AUTO_INCREMENT` (por tabla); `SEQUENCE` desde 10.3 | `SEQUENCE` de base de datos; `GENERATED ... AS IDENTITY` desde 12c |
| **Arranque** | `service mariadb start` / systemd | `STARTUP` vía SQL*Plus (nomount→mount→open) |

### Implicancias para Neology
- MariaDB es **mucho más simple de administrar**: no hay instancia/PDB/listener ni
  fases de arranque; opera el `docker-compose` / servicio local del proyecto.
- La memoria se dimensiona casi solo con `innodb_buffer_pool_size`
  (p. ej. 70 % de RAM), contra la decena de pools que exige Oracle.

---

## 3. Concurrencia y transacciones

| Característica | MariaDB (InnoDB) | Oracle |
|---|---|---|
| **ACID** | Sí | Sí |
| **MVCC** | Sí — versión en undo log del buffer pool | Sí — segmentos **undo** con `read consistency` garantizada |
| **Lecturas consistentes** | No bloquean lecturas SELECT (incluso REPEATABLE READ) | Ninguna lectura bloquea escritores; escrituras no bloquean lecturas |
| **Aislamiento por defecto** | REPEATABLE READ | READ COMMITTED |
| **Aislamientos soportados** | READ UNCOMMITTED, READ COMMITTED, REPEATABLE READ, SERIALIZABLE | READ COMMITTED, SERIALIZABLE, READ ONLY, READ WRITE |
| **Deadlocks** | Detectados automáticamente (`innodb_deadlock_detect`); se deshace una transacción | Detectados y resueltos por ORA-00060; la víctima se rastrea en trace |
| **Bloqueos ciegos (gap locks)** | Existen en REPEATABLE READ (índices) | No existe "gap lock" explícito; se usan latches |
| **Lobos/texto** | CLOB/TEXT/BLOB | LOB con `chunk`, `RETENTION`, `PCTVERSION`, tablespace LOB dedicado |
| **Hot backup online** | `mariabackup` online sin detener servicio | `BEGIN BACKUP`/`ALTER TABLESPACE ... BEGIN BACKUP`; o RMAN online |

**Nota práctica:** la mayoría de diferencias no impactan este proyecto (consultas de
reporte sin bloqueos, cargas puntuales de cierre mensual).

---

## 4. Lenguaje SQL y procedimientos

### 4.1 Funciones más comunes (tabla de conversión Oracle → MariaDB)

| Oracle | MariaDB | Nota |
|---|---|---|
| `NVL(a, b)` | `IFNULL(a, b)` o `COALESCE` | `COALESCE` existe en ambos |
| `'' = NULL` | `'' <> NULL` (vacío es valor) | **ojo**: semántica de cadena vacía distinta |
| `SYSDATE` / `CURRENT_TIMESTAMP` | `NOW()` / `CURRENT_TIMESTAMP` | Y `SYSDATE()` existe en MariaDB con otro sentido (fecha del query) |
| `TO_DATE(fmt)` / `TO_CHAR(fmt)` | `STR_TO_DATE` / `DATE_FORMAT` | sintaxis de formato distinta (`YYYY` igual, `FMMM` no) |
| `ROWNUM` | `LIMIT n` / `FETCH FIRST n ROWS ONLY` | 12.x admite `FETCH ... ONLY` |
| `ROWNUM` para paginación | `LIMIT off, n` | equivalente directo |
| `LISTAGG(...)` | `GROUP_CONCAT(...)` | separador por defecto distinto (`,` vs sin) |
| `DUAL` | `DUAL` (compatibilidad) | 12.x no exige FROM |
| `TRUNC()` fechas | `DATE(dt)` / `DATE_FORMAT` | |
| `CONNECT BY` | CTE recursiva (`WITH RECURSIVE`) | MariaDB no tiene CONNECT BY |

### 4.2 Funcionalidades analíticas y avanzadas

| Capacidad | MariaDB 12.x | Oracle |
|---|---|---|
| Ventanas (`ROW_NUMBER`, `RANK`, `LAG`, `LEAD`) | Sí | Sí (símbolo histórico: las introdujo Oracle 8i) |
| Agrupaciones de cubo | `WITH ROLLUP`; parcial | `ROLLUP`, `CUBE`, `GROUPING SETS` completos |
| `PIVOT` / `UNPIVOT` | No nativo | Sí |
| Expresiones regulares | `REGEXP_*` | `REGEXP_LIKE` + contador de retroceso |
| JSON | tipo `JSON` + funciones `JSON_*` | `JSON` con `JSON_TABLE`, indexación de hash, `SONIC` |
| Full-text | FULLTEXT index + boolean mode | Oracle Text (soporte lingüístico amplio) |
| Modelado jerárquico | CTE recursiva | `CONNECT BY` + `LEVEL` + `SYS_CONNECT_BY_PATH` |
| Secuencias | Sí (10.3+) | Sí (maduras, con cache/order/cycle) |

### 4.3 PL/SQL vs procedimientos almacenados

| Aspecto | MariaDB (SP/SQL) | Oracle PL/SQL |
|---|---|---|
| **Paquetes** | No existe paquete; procedimientos/funciones sueltos | **Packages** con especificación + cuerpo, estado compartido |
| **Manejo de errores** | `SIGNAL`/`RESIGNAL` (SQLSTATE), `DECLARE ... HANDLER` | `RAISE_APPLICATION_ERROR`, `EXCEPTION WHEN ...` |
| **Tipos compuestos** | No hay RECORD/colección nativos hasta 12.x (avanza) | RECORD, TABLE OF, arrays asociativos, cursor%ROWTYPE |
| **Refcursors** | Soporte parcial | Cursor variables completos |
| **Compilación** | Interpretado al guardar | Compilación + cache en shared pool (explica quedadas en primera ejecución) |
| **Módulos** | Objetos con `DELIMITER $$` (requisito de SOURCE stdin) | Procedure Packages por defecto |

Para este proyecto el punto crítico es que los procedimientos
(`execute_monthly_close`, `generate_test_data`, `test_integridad`,
`maint_partitions_audit`) quedaron bien cubiertos por el SQL procedural de MariaDB
con `SIGNAL` para errores.

---

## 5. Índices y optimización

| Característica | MariaDB | Oracle |
|---|---|---|
| **Estructura por defecto** | B-tree de InnoDB; el PK es **clustered** | B-tree; tablas heap (sin cluster por defecto), IOT opcional |
| **Índices de bits** | No | Sí (bitmap, ideal para baja cardinalidad en DSS) |
| **Índices por función/expresión** | Sí (12.x) | Sí (mun maduro; puede indexar hasta transformaciones) |
| **Índices invisibles** | Sí | Sí |
| **Descendentes** | Sí | Sí |
| **Índice único condicional / parcial** | Sí (filtro `WHERE` en índice) | No directo (usar índices en función) |
| **Covertura (covering)** | Sí (todo índice incluye PK) | Sí (`INDEX ... INCLUDE`) |
| **Optimizador** | CBO basado, `EXPLAIN ANALYZE` en 12.x | CBO con histogramas, `EXPLAIN PLAN`, `DBMS_XPLAN` |
| **Muestreo/estadísticas** | `ANALYZE TABLE`; estadísticas automáticas mejoradas 12.x | Stats automáticas con auto-sampling; `DBMS_STATS` |
| **Hints** | `/*+ INDEX(...) */` | Hint set mucho mayor (leading, materialize, para//...ora) |
| **Scan de rangos índice** | Sí (sin skip-scan completo) | Skip-scan funcional para prefijos faltantes |

**Conclusión parcial:** ambos optimizan las mismas consultas del proyecto (índice en
`(vehicle_id, entry_time)`, cubrimiento para reportes); Oracle tiene herramientas
extra de tuning (SQL Tuning Advisor) que en MariaDB se cubren con EXPLAIN + revisión manual.

---

## 6. Particionamiento (punto crítico para este proyecto)

| Aspecto | MariaDB (InnoDB) | Oracle |
|---|---|---|
| **Métodos** | RANGE, LIST, HASH, KEY | RANGE, **LIST**, **HASH**, **COMPOSITE (range-hash/range-list)**, **INTERVAL** |
| **Particionado automático** | Manual (procedimiento `maint_partitions_audit`) | **Interval partitioning**: Oracle crea particiones solas |
| **Pruning por expresión** | Requiere columna/base literal; `TO_DAYS(fecha)` pruna; expresiones compuestas no | Pruning por rango/éstimación, incluye sobre funciones (`TO_DATE` + literal) |
| **FK sobre tabla particionada** | **NO permitido** (InnoDB) | **Permitido** (si PK/UK incluye columna de partición o usa índice global) |
| **Índices únicos sin columna de partición** | No permitidos | **Permitidos** con índices globales |
| **Índices particionados locales/globales** | Los índices son particionados automáticamente con la tabla | Controle total: `LOCAL` vs `GLOBAL` |
| **Maintenance** | `REORGANIZE PARTITION` sobre tabla completa; $limitado$ | `ALTER TABLE ... SPLIT/MERGE/MOVE PARTITION` con comandos dedicados, sin reorganización íntegra |
| **Espacios/tablespaces por partición** | No (todo en un tablespace) | Sí: cada partición puede vivir en tablespace distinto |
| **Sub-particiones** | No | Sí (hasta miles por tabla) |

**Ejemplo ya vivido en `neology_parking`:** `audit_log` se particionó por RANGE
`TO_DAYS(changed_at)` y su PK pasó a `(id, changed_at)` **porque InnoDB exige que todo
índice único incluya la columna de partición y prohíbe FK**. En Oracle habría sido
posible mantener FK a `stays` (poco frecuente aquí) y una PK simple, particionar
`stays` por `entry_time` sin dropear sus FKs, y usar `INTERVAL` para no mantener
meses manualmente. **Es la mayor brecha técnica entre ambos motores detectada en el
proyecto.**

---

## 7. Alta disponibilidad y réplica

| Capacidad | MariaDB | Oracle |
|---|---|---|
| **Réplica asíncrona** | Master→replicas (binlog/GTID) | Data Guard físico/lógico (redo shipping) |
| **Réplica sincrona/multi-master** | **Galera Cluster** (3 nodos, sync, quorum) | RAC (misma base en shared storage, no es réplica) |
| **Failover automático** | Manual/MaxScale; `semisync` reduce pérdida | Data Guard `Fast-Start Failover` (RTO < 30 s) |
| **Proxy/distribuidor** | **MaxScale** (rwsplit, pooling, failover) | Oracle Net + servicios de listener; FAN (Fast App Notification) |
| **Lee configuraciones activas** | Réplica para lectura; DB_ROLE separado | Active Data Guard (requiere licencia) |
| **Migración de datos en caliente** | `MariaDB Replication` desde dump | Data Pump + Logical Standby / XTTS |
| **Escalado de escritura** | Sharding a nivel de aplicación | RAC + Sharding (Oracle Database sharding) |

Para Neology (un solo edificio, horario 06:00-22:00) la arquitectura de referencia
sigue siendo: primario + réplica en espera (RPO ≤ 1 h con binlogs/PITR ya documentado;
RTO ≤ 4 h), sin necesidad de Galera/RAC.

---

## 8. Respaldo y recuperación

| Aspecto | MariaDB | Oracle |
|---|---|---|
| **Lógico** | `mysqldump` / `mariadb-dump` | `Data Pump` (expdp/impdp) |
| **Físico** | `mariabackup` (online, incremental) | **RMAN** (block-level, incremental, Validated) |
| **PITR** | Binlogs + `mysqlbinlog` | Archivelogs + `RECOVER DATABASE UNTIL TIME` |
| **Restauración validada** | Restaurar a BD temporal (nuestro backup automático lo hace) | `RMAN RESTORE VALIDATE` + `DBMS_BACKUP_RESTORE` |
| **Flashback** | No nativo (siempre contar con PITR) | **Flashback Query / Table / Database** (acá la gran ventaja) |
| **Compresión / cifrado** | Vía gzip/externo o `--compress` | RMAN nativo (compresión + cifrado TDE) |
| **Catálogo de backups** | Por convención de archivos | `RMAN catalog` en otra BD (o controlfile) |
| **Duplicación de instancia/hora** | Máxima con replicación | `DUPLICATE DATABASE` a cualquier punto |

**Cobertura en el repo:** respaldo automático implementado (dump+hash+validación,
retención 30 días, binlogs); en Oracle el equivalente se haría con
`rman backup database plus archivelog` + `schedule` de `DBMS_SCHEDULER`.

---

## 9. Monitoreo y diagnóstico

| Aspecto | MariaDB | Oracle |
|---|---|---|
| **Métricas de rendimiento** | `performance_schema` + `information_schema` + variables de estado | **AWR** (repositorio histórico), `V$` views |
| **Snapshots históricos** | Requiere exporter + TSDB (Prometheus) | AWR snapshots (por defecto 1 h) + `dba_hist` |
| **Diagnóstico crítico** | `SHOW ENGINE INNODB STATUS`, slow log | **ADDM** (auto diagnostica), **ASH** (sesiones activas), wait events |
| **Tuning asistido** | Manual/`mysqltuner` | SQL Tuning Advisor, SQL Plan Management |
| **Alertas** | Exporter + Alertmanager/Grafana (se implementó en monitoreo.md) | Enterprise Manager Cloud Control + alertas de estado |
| **Acciones correctivas** | `KILL` de hilos; variables globales | `ALTER SYSTEM KILL SESSION`, resource manager |
| **Bloqueos** | `INFORMATION_SCHEMA.INNODB_TRX/LOCKS` | `DBA_BLOCKERS`, `DBA_WAITERS`, `SELECT ... FOR UPDATE` diagnosis |

---

## 10. Seguridad

| Capacidad | MariaDB | Oracle |
|---|---|---|
| **Login/auth** | Plugins: mysql_native_password, SHA-256, Unix socket, PAM, LDAP | Native + Kerberos, LDAP, Radius, SSO |
| **Roles** | Sí (desde 10.x/12.x, con `SET ROLE`) | Sí, maduro (2.000+ privilegios granulares) |
| **Cifrado en reposo** | Encriptación de tablespace de InnoDB (con key management) | **TDE** (columnas/tablespaces completo) |
| **TLS** | Sí (SSL/TLS) | Nativo + red encriptada obligatoria (23ai) |
| **Cifrado de columnas** | Solo a nivel de función (e.g. `MD5`/`AES_ENCRYPT`) | Column encryption transparente |
| **Vista/VDP (row-level)** | `VIEW` securizada manualmente (no VPD) | **Virtual Private Database**: seguridad a nivel de fila aplicada al query |
| **Auditoría** | `audit log` propios + nuestra tabla `audit_log` | Audit avanzado (sysaud, archivos), auditoría de datos de red como estándar |
| **Privilegios por objeto** | GRANT por tabla/base | GRANT por esquema/objeto/etiqueta/unidad de negocio |

En el repo la seguridad se cubrió con usuarios acotados
(`parking_app`, `parking_report`, `parking_ops`, `parking_dba`), TLS, y `audit_log`.
Oracle Enterprise excedería drásticamente por herramientas.

---

## 11. Escalabilidad y tamaño

| | MariaDB | Oracle |
|---|---|---|
| **OLTP escalable** | Réplicas de lectura + sharding | RAC (misma BD en cluster) + sharding |
| **OLAP/DSS masivo** | No es materia; falta bitmap/parallel query completo | **Parallel Query / DBRM**, bitmap, Exadata (extremo) |
| **Tamaño típico manejado** | Decenas de GB a pocos TB por servidor | TB a PB (con ASM/Exadata) |
| **Caché de columna** | No | Column store (In-Memory) |
| **Threads por core moderno** | Beneficia en máquinas multi-core | Licencia EE → alto costo por núcleo (prima por diseño de bajar cores) |

Neology: volumen estimado < 10 GB / 24 meses → ambos sobran; el límite lo pone el
**costo** (Oracle licencia el host, no la base).

---

## 12. Costos de licenciamiento (2026, referencial)

| Concepto | MariaDB | Oracle DB EE |
|---|---|---|
| **Licencia de servidor** | $0 (GPL) | ~ $47,500 por procesador core (x 2 sockets/8 core = ~ $380 K) |
| **Soporte anual** | Opcional (empresas como Percona); 0 bajo GPL | ~ 22 % del costo de licencia/año |
| **Mínimo facturable** | $0 | generalmente 2 sockets / 100 usuarios |
| **Oracle FREE / SE2** | — | FREE: sin costo, prueba/desarrollo y <16 cores; SE2: licencia reducida (hasta 16 threads, 1 socket en muchos casos) |
| **Cloud** | MariaDB SkySQL/PaaS en los 3 hyperscalers | Autonomous DB / RDS Oracle (costo alto) |

**Conclusión:** para una **PyME/estacionamiento** el ahorro en licencia de Oracle
(> $380 K iniciales + soporte) financia 10+ años de hardware propio de MariaDB.

---

## 13. Migración Oracle → MariaDB (si la empresa trae Oracle)

1. **Inventario** de objetos: tablas, PK/FK, secuencias (`NEXTVAL` → `AUTO_INCREMENT`), vistas, paquetes PL/SQL, jobs.
2. **Traducción de tipos**: `NUMBER` → `DECIMAL`/`INT`, `VARCHAR2(n)` → `VARCHAR(n)`, `DATE` con hora → `DATETIME`, CLOB → LONGTEXT.
3. **SEMÁNTICA de cadenas**:  adjustar el tratamiento de `'' (NULL en Oracle) → '` vacío en MariaDB`→ detección con saved queries.
4. **Lenguaje**: convertir PL/SQL (paquetes, `RAISE_APPLICATION_ERROR`) a procedimientos con `SIGNAL`; DUAL opcional.
5. **Fecha**: verificar `SYSDATE` → `NOW()` y formatos `TO_CHAR/TO_DATE` → `DATE_FORMAT/STR_TO_DATE`.
6. **Análisis**: reemplazo de `CONNECT BY` → CTE recursiva; `ROWNUM` → `LIMIT`.
7. **Carga**: orden por FK (`tariffs → vehicles → stays → charges`) con `--single-transaction`.
8. **Pruebas**: ejecutar `test_integridad()` (25 chequeos) + queries Q1-Q8 sobre el dato migrado; cierre mensual de consistencia, y `generate_test_data` para volúmenes.

---

## 14. Tabla de decisión final para `neology_parking`

| Criterio | MariaDB | Oracle | Gana |
|---|---|---|---|
| Costo/licencia | $0, Open Source | $380 K+ EE | MariaDB |
| Complejidad operativa | Baja (1 proceso + compose) | Alta (SGA, listener, fases, CDB/PDB) | MariaDB |
| SQL estándar del proyecto | Cubierto | Cubierto | Empate |
| PL/SQL / paquetes | Suficiente (`SIGNAL`, SP) | Superior | Oracle |
| Particionado flexible | Limitado (FK/UK) | **Flexible** (interval, global idx, composite) | Oracle |
| Flashback / PITR | PITR por binlogs | Flashback nativo | Oracle |
| Monitoreo | Excelente + PROM (implementado) | AWR/ADDM/Q calendario | Oracle |
| Alta disponibilidad | Réplica + MaxScale/Galera | RAC + Data Guard FST | Oracle |
| Requisito de la prueba | **"Debe ser Open Source"** | NO cumple requisito | MariaDB |

**Recomendación:** mantener **MariaDB 12.3** como motor de la solución. Oracle solo si
(1) existiera licencia corporativa paga O (2) el negocio escalara a OLAP masivo con
Enterprise Edition justificada. Las brechas identificadas (particionado, flashback) no
gravitan en el volumen ni patrones de consulta actuales y se documentaron sus
soluciones equivalentes.

---

## 15. Equivalentes rápidos (cheat sheet)

| Tarea | MariaDB | Oracle |
|---|---|---|
| Ver base en uso | `SELECT DATABASE();` | `SELECT sys_context('USERENV','DB_NAME') FROM dual;` |
| Listar tablas | `SHOW TABLES;` | `SELECT table_name FROM user_tables;` |
| Plan de ejecución | `EXPLAIN ANALYZE SELECT ...` | `EXPLAIN PLAN FOR ...` + `DBMS_XPLAN.DISPLAY` |
| Contar sesiones | `SHOW PROCESSLIST;` | `SELECT ... FROM v$session;` |
| Matar sesión | `KILL <id>;` | `ALTER SYSTEM KILL SESSION '<sid>,<serial>';` |
| Reiniciar seq para prueba | `ALTER TABLE t AUTO_INCREMENT=1;` | `ALTER SEQUENCE ... RESTART START WITH 1;` |
| Reorg índices | `OPTIMIZE TABLE t;` | `ALTER INDEX ... REBUILD;` |
| Respaldar BD | `mariadb-dump --single-transaction ...` | `expdp schemas=...` / `backup` RMAN |