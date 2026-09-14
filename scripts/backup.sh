#!/bin/bash
# ============================================================
# DBA - Prueba Técnica Neology
# Parte 6: Estrategia de respaldo — Respaldo completo
# Motor: MariaDB 12.x / Linux (o Git Bash / WSL en Windows)
# ============================================================
# Uso:
#   chmod +x scripts/backup.sh
#   ./scripts/backup.sh
#
# Configuración: editar las variables del encabezado.
# ============================================================

set -euo pipefail

# ---- Configuración (editable) ----
DB_HOST="127.0.0.1"
DB_PORT="3305"
DB_USER="parking_dba"
# Contraseña: se lee de la variable de entorno DB_BACKUP_PASSWORD
# (nunca incluirla en el script)
if [ -z "${DB_BACKUP_PASSWORD:-}" ]; then
    echo "ERROR: Defina la variable DB_BACKUP_PASSWORD antes de ejecutar."
    echo "  export DB_BACKUP_PASSWORD='<su_contraseña>'"
    exit 1
fi
DB_PASS="$DB_BACKUP_PASSWORD"
DB_NAME="neology_parking"
BACKUP_DIR="/var/backups/neology_parking"
LOG_DIR="/var/log/neology_parking"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30  # Días de retención para respaldos antiguos

# ---- Crear directorios ----
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
LOGFILE="$LOG_DIR/backup_${DATE}.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Inicio de respaldo de $DB_NAME" | tee -a "$LOGFILE"

# ---- 1. Respaldo completo (mysqldump) ----
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Ejecutando mysqldump..." | tee -a "$LOGFILE"

mysqldump \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --password="$DB_PASS" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --add-drop-database \
    --databases "$DB_NAME" \
    2>>"$LOGFILE" \
    | gzip > "${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz"

DUMP_SIZE=$(du -h "${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz" | cut -f1)
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Respaldo completo: ${DUMP_SIZE}" | tee -a "$LOGFILE"

# ---- 2. Verificación de integridad (SHA256) ----
sha256sum "${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz" \
    > "${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz.sha256"
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Hash SHA256 generado." | tee -a "$LOGFILE"

# ---- 3. Copia de binlogs para respaldo incremental (si está habilitado) ----
BINLOG_DIR=$(mysql --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --password="$DB_PASS" \
    -N -e "SHOW VARIABLES LIKE 'log_bin_basename';" 2>/dev/null \
    | awk '{print $2}')

if [ -n "$BINLOG_DIR" ]; then
    BINLOG_PATH=$(dirname "$BINLOG_DIR")
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Binlogs: $BINLOG_PATH" | tee -a "$LOGFILE"
    mkdir -p "${BACKUP_DIR}/binlog_${DATE}"
    # Copiar binlogs recientes
    cp -v "$BINLOG_PATH"/mysql-bin.* "${BACKUP_DIR}/binlog_${DATE}/" >> "$LOGFILE" 2>&1 || true
fi

# ---- 4. Copia fuera del sitio (opcional). Definir en el encabezado.
#        Ejemplos: rsync/scp/rclone a bucket S3 o servidor remoto.
#        OFFSITE_TARGET="usuario@backup:/backups/neology"
#        OFFSITE_TARGET="rclone:neology-backups:/"
OFFSITE_TARGET="${OFFSITE_TARGET:-}"
if [ -n "$OFFSITE_TARGET" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Copiando a destino externo..." | tee -a "$LOGFILE"
    rsync -av "$BACKUP_DIR"/ "${OFFSITE_TARGET}" >> "$LOGFILE" 2>&1 || \
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Copia externa falló (revisar)" | tee -a "$LOGFILE"
fi

# ---- 5. Limpieza de respaldos antiguos (retención) ----
DELETED=$(find "$BACKUP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete -print | wc -l)
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Respaldos eliminados (> ${RETENTION_DAYS} días): ${DELETED}" | tee -a "$LOGFILE"

# ---- 6. Validación: restaurar dump a una BD temporal de prueba ----
TEST_DB="neology_parking_restore_test"
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Validación: restaurando en ${TEST_DB}..." | tee -a "$LOGFILE"

gunzip -c "${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz" \
    | sed "s/neology_parking/${TEST_DB}/g" \
    | mysql --host="$DB_HOST" --port="$DB_PORT" \
        --user="$DB_USER" --password="$DB_PASS" >> "$LOGFILE" 2>&1

# Verificar conteo de tablas
TABLE_COUNT=$(mysql --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --password="$DB_PASS" \
    -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${TEST_DB}';")
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Tablas restauradas en test: ${TABLE_COUNT}" | tee -a "$LOGFILE"

# Limpiar BD de prueba
mysql --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --password="$DB_PASS" \
    -e "DROP DATABASE IF EXISTS ${TEST_DB};" >> "$LOGFILE" 2>&1

# ---- Resumen ----
echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] Respaldo completado exitosamente." | tee -a "$LOGFILE"
echo "  Archivo: ${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz" | tee -a "$LOGFILE"
echo "  Tamaño:  ${DUMP_SIZE}" | tee -a "$LOGFILE"
echo "  SHA256:  ${BACKUP_DIR}/${DB_NAME}_full_${DATE}.sql.gz.sha256" | tee -a "$LOGFILE"
echo "  Log:     ${LOGFILE}" | tee -a "$LOGFILE"

exit 0