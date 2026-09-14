# Estrategia de Respaldo, Restauración y Recuperación — Estacionamiento Neology

## Objetivo

Garantizar la disponibilidad e integridad de la base de datos `neology_parking` ante fallos de hardware, errores humanos, ransomware o desastres naturales, minimizando la pérdida de datos (RPO) y el tiempo de inactividad (RTO).

---

## RPO y RTO definidos

| Métrica | Objetivo | Justificación |
|---|---|---|
| **RPO** (Recovery Point Objective) | ≤ 1 hora | Los registros de estancias y pagos son operaciones en vivo; no más de 1 hora de pérdida es aceptable para un estacionamiento comercial. |
| **RTO** (Recovery Time Objective) | ≤ 4 horas | El sistema debe restaurarse antes del siguiente turno de operación para no afectar cobros. |

---

## Estrategia de respaldo

### 1. Respaldo completo (full backup)

- **Herramienta:** `mysqldump` con `--single-transaction` (no bloquea escrituras en InnoDB).
- **Frecuencia:** una vez al día a las 02:00 AM (fuera de horario pico).
- **Retención:** 30 días en disco local + copia a almacenamiento externo.
- **Archivo de salida:** `neology_parking_full_YYYYMMDD_HHMMSS.sql.gz`
- **Verificación:** SHA256 generado automáticamente tras cada respaldo.
- **Scripts:** `scripts/backup.sh` (ejecución automatizable via cron).

### 2. Respaldos incrementales (binary logs)

- **Habilitar binlogs:** `log_bin = mysql-bin`, `binlog_format = ROW`.
- **Frecuencia de rotación:** `expire_logs_days = 7` (mínimo).
- **Copia incremental:** los binlogs se copian al directorio de respaldos en cada backup completo.
- **Uso:** permiten la **recuperación a un punto en el tiempo** (PITR).

### 3. Validación periódica de respaldos

- Después de cada backup completo, se restaura el dump en una BD temporal de prueba (`neology_parking_restore_test`).
- Se verifica el conteo de tablas y una estimación de filas.
- La BD de prueba se elimina tras la validación.
- Se registra el resultado en `/var/log/neology_parking/`.

### 4. Retención y cifrado

| Nivel | Política |
|---|---|
| **Disco local** | Respaldos de 30 días; más antiguos se eliminan automáticamente. |
| **Almacenamiento externo** | Respaldo mensual copiado a bucket cifrado (S3 con SSE-KMS o equivalente). |
| **Cifrado del dump** | Se recomienda cifrar con GPG antes de transferir: `gpg --symmetric --cipher-algo AES256 dump.sql.gz` |
| **Cifrado en tránsito** | Si se transfiere por red: SCP/SFTP o TLS. |

### 5. Replicación y recuperación ante desastres

**Réplica en tiempo real (MariaDB):**
```sql
-- En el servidor primario:
CHANGE MASTER TO
    MASTER_HOST='<replica_ip>',
    MASTER_USER='repl_user',
    MASTER_PASSWORD='<repl_password>',
    MASTER_AUTO_POSITION=1;
START SLAVE;
```

**Réplica a distancia geográfica:**
- La réplica se ubica en otra zona de disponibilidad o región.
- Sincronización asincrónica para no afectar la latencia del primario.
- En caso de desastre: promover la réplica a primario y redirigir el tráfico (cambiar DNS o usar proxy).

---

## Restauración

### Restauración completa (desde backup)

```bash
export DB_BACKUP_PASSWORD='<contraseña_dba>'
./scripts/restore.sh /var/backups/neology_parking/neology_parking_full_YYYYMMDD_HHMMSS.sql.gz
```

### Recuperación a un punto en el tiempo (PITR)

```bash
# Restaurar el dump más reciente anterior al incidente
./scripts/restore.sh /var/backups/neology_parking/neology_parking_full_20260913_020000.sql.gz \
    --point-in-time '2026-09-14 10:30:00'
```

**Flujo:**
1. Se restaura el dump completo anterior al punto deseado.
2. Se aplican los binlogs secuencialmente hasta la marca de tiempo especificada.
3. Se verifica la integridad de los datos.

---

## Alternativa para Oracle

| Operación | MariaDB | Oracle |
|---|---|---|
| Respaldo completo | `mysqldump --single-transaction` | `RMAN BACKUP DATABASE;` |
| Respaldos incrementales | Binary logs | `RMAN BACKUP INCREMENTAL LEVEL 1 DATABASE;` |
| Restauración completa | `mysql < dump.sql` | `RMAN RESTORE DATABASE;` + `RECOVER DATABASE;` |
| PITR | `mysqlbinlog + restore` | `RMAN UNTIL TIME 'YYYY-MM-DD HH24:MI:SS';` |
| Alta disponibilidad | Réplica MariaDB (binlog) | Data Guard (sincrónico/asincrónico) |
| Validación | Restaurar en BD temporal | `RMAN VALIDATE DATABASE;` |
| Cifrado | GPG antes de transferir | TDE (Transparent Data Encryption) nativo de Oracle |

**Ventajas de Oracle para este escenario:**
- RMAN gestiona respaldos incrementales de forma automática.
- Data Guard ofrece conmutación automática (failover) con pérdida de datos cero.
- TDE cifra datos en reposo sin cambios en la aplicación.
- Flashback permite recuperar tablas individuales a un momento específico sin restaurar toda la BD.

---

## Limitaciones conocidas

- `mysqldump` en tablas muy grandes (> 10GB) es lento; para esas escalas se recomienda `mariabackup` (backup físico).
- La restauración de puntos en el tiempo requiere binlogs disponibles; si se pierden, solo se puede restaurar al último backup completo.
- La réplica asincrónica puede tener algunos segundos de desfase (aceptable para este escenario).