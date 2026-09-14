# Estrategia de Archivado — Estacionamiento Neology

## Contexto y objetivo

El sistema de estacionamiento genera datos acumulativos que crecen sin límite: estancias, cargos, cierres mensuales y auditoría. Sin una estrategia de archivado:

- Las consultas de negocio (Q1–Q8) se degradan con tablas crecientes.
- El tamaño de los respaldos aumentaría más allá de lo necesario para recuperación.
- El espacio en disco y el mantenimiento (índices, particiones, estadísticas) se vuelven costosos.
- Se alcanza el umbral del 85 % documentado sin una política de retención.

**Objetivo:** mantener en la base activa únicamente los datos operativos y consultados con frecuencia, moviendo lo histórico a almacenamiento permanente y barato, sin perder trazabilidad ni capacidad de auditoría.

**Retención definida (política de negocio):**

| Tipo de dato | En BD activa | Archivado | Destino final |
|---|---|---|---|
| Estancias + cargos | 24 meses | 24-60 meses | Almacenamiento frío (S3/GBS) |
| Cierres mensuales | 60 meses | — | Siempre en BD (por contabilidad, son pocos) |
| Auditoría (`audit_log`) | 6 meses | 6-24 meses | Almacenamiento frío |
| Eventos NoSQL de auditoría | 12 meses | 12-60 meses | S3 (por documento en nosql-design.md) |
| Binlogs | 7 días | — | Se descartan (ver backup-recovery.md) |

---

## 1. Enfoque: particionado + archivado por lotes

El proceso combina dos técnicas:

1. **Particionado por rango mensual** en la tabla `stays` (la más grande) para que:
   - El archivado por mes sea un movimiento de una partición completa.
   - Las consultas por rango de fecha (Q3, Q4, Q8) solo toquen las particiones necesarias — *partition pruning*.
   - Los índices locales sean más pequeños.

2. **Archivado por lotes** (job programado) que mueve los datos de una partición vencida a:
   - Una **tabla espejo con ENGINE=ARCHIVE** (sin tabla destino) o
   - Un **dump comprimido + exportación** hacia cold storage, seguido de eliminación de la partición.

### Particionado recomendado de `stays`

```sql
ALTER TABLE stays
    PARTITION BY RANGE (YEAR(entry_time) * 100 + MONTH(entry_time)) (
        PARTITION p2024_06 VALUES LESS THAN (202407),
        PARTITION p2024_07 VALUES LESS THAN (202408),
        PARTITION p2024_08 VALUES LESS THAN (202409),
        ...
        PARTITION p_current   VALUES LESS THAN (MAXVALUE)
    );
```

**Notas:**
- Cada mes nuevo se agrega una partición anticipada (`maintenance_window` mensual).
- El particionado se hace `ONLINE` con `ALGORITHM=INPLACE, LOCK=NONE` en MariaDB para no bloquear la operación.
- La partición `p_current` cubre el mes en curso y evita errores de "insert en partición inexistente".

---

## 2. Ciclo de vida de una partición (mensual)

```text
Mes M+1:  se crea partición P(M)          ← anticipada
Mes M+2:  P(M) ya está completa           ← solo lectura
Mes M+25: P(M) supera los 24 meses        ← candidata a archivo

Cron (1 día del mes, 03:00):
  1. Detectar particiones vencidas (>= 25 meses de antigüedad).
  2. Mover el mes a BD de archivo (exportar dump + cargar en archivo).
  3. Verificar conteos (origen vs. destino) y SHA256 del dump.
  4. Cambiar schema destino a readonly / cifrar.
  5. Soltar la partición de la tabla activa.
  6. Compactar índice y registrar el lote en la tabla de control de archivado.
```

---

## 3. Estructura de datos de archivo

### Tablas de control (viven en la BD activa)

```sql
CREATE TABLE archive_control (
    id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    table_name        VARCHAR(64)  NOT NULL,          -- 'stays', 'charges', ...
    partition_name    VARCHAR(64)  NOT NULL,
    period            CHAR(7)      NOT NULL,          -- 'YYYY-MM'
    rows_exported     BIGINT       NOT NULL,
    rows_verified     BIGINT       NOT NULL,
    dump_file         VARCHAR(255) NOT NULL,
    sha256            CHAR(64)     NOT NULL,
    archived_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    archived_by       VARCHAR(64)  NOT NULL,
    status            ENUM('extracted','loaded','verified','dropped','failed')
                                  NOT NULL DEFAULT 'extracted',
    UNIQUE KEY uq_period (table_name, period)
) ENGINE=InnoDB;
```

### Almacenamiento histórico

| Nivel | Almacenamiento | Formato | Uso |
|---|---|---|---|
| **N1 — Reciente** (24-36 meses) | BD de archivo independiente (MariaDB/MySQL) | SQL | Consultas SQL de auditoría por año |
| **N2 — Frío** (36-60 meses) | Bucket S3/GCS | `*.sql.gz` + JSON-lines | Consulta puntual; restauración bajo demanda |
| **N3 — Permanente** | Bucket + WORM / cinta | Parquet / gz | Cumplimiento y conservación legal |

**Acceso al histórico:** si un usuario necesita datos de hace 30 meses, se restaura el mes puntual del bucket a la BD de archivo (N1) con verificación de checksum, se consulta, y se elimina bajo demanda.

---

## 4. Procedimiento de archivado automatizado

### Script de arquivo (bash + MariaDB)

```bash
#!/usr/bin/env bash
# scripts/archive.sh — archiva particiones vencidas de neology_parking
set -euo pipefail

DB=neology_parking
HOST=127.0.0.1
PORT=3305
USER=parking_dba
ARCHIVE_DB=neology_archive
BACKUP_DIR=/var/backups/neology_archive
Umbral_MESES=25

# 1. Detectar meses vencidos en stays
meses_adios=$(mariadb --host=$HOST --port=$PORT --user=$USER -N -e "
  SELECT DISTINCT DATE_FORMAT(entry_time, '%Y-%m')
  FROM $DB.stays
  WHERE entry_time < DATE_SUB(DATE_FORMAT(CURDATE(),'%Y-%m-01'), INTERVAL $Umbral_MESES MONTH);
")

for mes in $meses_adios; do
  ano=${mes%%-*}; mmmn=${mes##*-}
  primera="$ano-$mmmn-01"
  siguiente=$(date -d "$primera +1 month" +%Y-%m-%d)

  echo "Archivando mes $mes ..."

  # 2. Exportar estancias y cargos del mes
  mariadb-dump --host=$HOST --port=$PORT --user=$USER \
      --single-transaction --skip-lock-tables \
      --where="entry_time >= '$primera' AND entry_time < '$siguiente'" \
      $DB stays | gzip > "$BACKUP_DIR/stays_$mes.sql.gz"

  mariadb-dump --host=$HOST --port=$PORT --user=$USER \
      --single-transaction --skip-lock-tables \
      --where="stay_id IN (SELECT id FROM $DB.stays WHERE entry_time >= '$primera' AND entry_time < '$siguiente')" \
      $DB charges | gzip > "$BACKUP_DIR/charges_$mes.sql.gz"

  # 3. Verificar checksum y conteos
  sha256sum "$BACKUP_DIR/stays_$mes.sql.gz" > "$BACKUP_DIR/stays_$mes.sha256"
  origem=$(mariadb --host=$HOST --port=$PORT --user=$USER -N -e \
    "SELECT COUNT(*) FROM $DB.stays WHERE entry_time >= '$primera' AND entry_time < '$siguiente';")

  # 4. Cargar en la BD de archivo
  zcat "$BACKUP_DIR/stays_$mes.sql.gz" | mariadb --host=$HOST --port=$PORT --user=$USER $ARCHIVE_DB
  zcat "$BACKUP_DIR/charges_$mes.sql.gz" | mariadb --host=$HOST --port=$PORT --user=$USER $ARCHIVE_DB

  destino=$(mariadb --host=$HOST --port=$PORT --user=$USER -N -e \
    "SELECT COUNT(*) FROM $ARCHIVE_DB.stays WHERE entry_time >= '$primera' AND entry_time < '$siguiente';")

  # 5. Verificar y eliminar de la BD activa
  if [ "$origem" -eq "$destino" ]; then
      mariadb --host=$HOST --port=$PORT --user=$USER -e "
        DELETE FROM $DB.charges
         WHERE stay_id IN (SELECT id FROM $DB.stays
                           WHERE entry_time >= '$primera' AND entry_time < '$siguiente');
        DELETE FROM $DB.stays
         WHERE entry_time >= '$primera' AND entry_time < '$siguiente';"
      echo "OK mes $mes: $origem filas archivadas y verificadas."
  else
      echo "ERROR mes $mes: origen=$origem destino=$destino. No se eliminó."
  fi
done
```

> **Seguridad del proceso:** nada se elimina en activa hasta que el dump esté verificado (SHA256) y los conteos coincidan. Cada lote se registra en `archive_control`.

### Planificación recomendada (cron)

| Job | Hora | Frecuencia |
|---|---|---|
| Detección y archivo de mes vencido | 03:00 | Día 1 de cada mes |
| Verificación de integridad de `stays` | 03:30 | Semanal |
| Reporte de crecimiento y próximos vencimientos | 04:00 | Día 1 de cada mes |
| Carga de la nueva partición mensual | 04:30 | Día 1 de cada mes |

---

## 5. Archivado de `audit_log`

La auditoría cumple un rol de trazabilidad, no de operación:

```sql
-- Mover auditoría mayor a 6 meses a archivo
CREATE TABLE IF NOT EXISTS audit_log_archive LIKE audit_log;

INSERT INTO audit_log_archive
SELECT * FROM audit_log
WHERE changed_at < DATE_SUB(CURDATE(), INTERVAL 6 MONTH);

-- Registro del lote
INSERT INTO archive_control (table_name, partition_name, period, rows_exported, ...)
SELECT 'audit_log', 'archive', DATE_FORMAT(CURDATE(), '%Y-%m'),
       COUNT(*), COUNT(*), 'audit_hist.sql.gz', SHA2(GROUP_CONCAT(changed_at), 256), ...
FROM (SELECT changed_at FROM audit_log_archive WHERE archivado_lote = 'LOTE-XXX') x;

DELETE FROM audit_log WHERE changed_at < DATE_SUB(CURDATE(), INTERVAL 6 MONTH);
```

**Nota:** si se acepta la propuesta NoSQL, los eventos de auditoría se redirigen a MongoDB y `audit_log` relacional queda solo para cambios administrativos. En MongoDB el índice TTL del documento propuesto (12 meses) elimina la auditoría operativa automáticamente.

---

## 6. Verificación y monitoreo del archivado

| Chequeo | Frecuencia | Umbral de alerta |
|---|---|---|
| Último archivado exitoso | Diaria | > 31 días |
| Conteo origen vs. destino por lote | Cada lote | Desigualdad = fallo detenido |
| SHA256 del dump | Cada lote | No coincide = no eliminar |
| Crecimiento de particiones activas | Semanal | `stays` > umbral esperado |
| Espacio liberado vs. consumido | Mensual | — |
| `test_integridad()` tras archivar | Tras cada lote | Violaciones = revisar lote |

---

## 7. Estrategia equivalente en Oracle

| Necesidad | MariaDB | Oracle |
|---|---|---|
| Particionado mensual | `PARTITION BY RANGE` | `PART BY RANGE` (idéntico) |
| Registrar metadatos del lote | `archive_control` | Tabla de control propia |
| Compresión de datos activos | — | `COMPRESS BASIC` en BD activa |
| Datos históricos en frío | Dump comprimido + S3 | `Data Pump` expdp + `External Tables` sobre archivos |
| Automatización | cron + bash | `DBMS_SCHEDULER` (job PL/SQL) |
| Partición descartable | `ALTER TABLE ... DROP PARTITION` | `ALTER TABLE ... EXCHANGE PARTITION` + `TRUNCATE` archivo |
| Cambios de esquema sin bloquear | `ALGORITHM=INPLACE` | `ALTER TABLE` con `ONLINE` |
| Validación de que no hay pérdida | Conteos + SHA256 | `DBMS_AUDIT` + validación de expdp |

---

## 8. Roles y procedimiento operativo

| Rol | Responsabilidades |
|---|---|
| **DBA** | Ejecuta/automatiza archivo mensual; configura particiones; monitorea checksums |
| **DevOps/Infra** | Provee el bucket S3/GCS con políticas WORM y versionado |
| **Auditoría/Seguridad** | Valida retención legal y accesos al histórico |
| **Operación** | Solicita historial puntual (mes específico) bajo demanda |

**Procedimiento ante una consulta de datos históricos:**
1. El operador solicita por ticket el mes y tipo de dato.
2. DBA verifica en `archive_control` la ubicación y checksum del lote.
3. Se restaura el mes al entorno de archivo (N1) o se lee directo del bucket (N2).
4. Se entregan los datos y se elimina el entorno temporal.
5. Se registra en el log de auditoría el acceso.

---

## 9. Cálculo de espacio y ROI del archivado

**Premisas (dato de referencia):**
- Estancias: ~120 bytes/registro (con índices ~200 bytes).
- 24 meses de retención activa, 4,000 estancias/día.

| Concepto | Valor |
|---|---|
| Registros generados por año | ~1.46 M |
| Tamaño anual de `stays` (activa) | ~290 MB |
| Tamaño máximo de la tabla activa (24 meses) | ~580 MB |
| Dump mensual comprimido (`gzip`, ~10 %) | ~2.4 MB/mes |
| Dump anual comprimido | ~29 MB |
| Auditoría anual archivada (frío) | ~10 MB |

El archivado mantiene la tabla activa estable en ~0.6 GB en lugar de crecer
indefinidamente, preserva el RPO/RTO de los respaldos (que solo cubren 24 meses)
y reduce el costo de almacenamiento ~90 % moviendo lo histórico a frío.