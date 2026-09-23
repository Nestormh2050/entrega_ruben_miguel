#!/bin/bash
# ============================================================
# DBA - Prueba Técnica Neology
# Parte 6: Estrategia de respaldo — Restauración
# Motor: MariaDB 12.x / Linux (o Git Bash / WSL en Windows)
# ============================================================
# Uso:
#   chmod +x scripts/restore.sh
#   ./scripts/restore.sh /var/backups/neology_parking/neology_parking_full_20260914_120000.sql.gz
#
# Opciones:
#   --point-in-time  Restauración a un punto en el tiempo usando binlogs
#   --skip-validation Omitir la verificación post-restauración
#
# ¡ATENCIÓN! Este script ELIMINA la base de datos existente antes de restaurar.
# ============================================================

set -euo pipefail

# ---- Configuración ----
DB_HOST="127.0.0.1"
DB_PORT="3305"
DB_USER="parking_dba"
if [ -z "${DB_BACKUP_PASSWORD:-}" ]; then
    echo "ERROR: Defina DB_BACKUP_PASSWORD."
    exit 1
fi
DB_PASS="$DB_BACKUP_PASSWORD"
DB_NAME="neology_parking"
LOG_DIR="/var/log/neology_parking"
DATE=$(date +%Y%m%d_%H%M%S)
LOGFILE="$LOG_DIR/restore_${DATE}.log"

# ---- Parámetros ----
BACKUP_FILE=""
POINT_IN_TIME=""
SKIP_VALIDATION=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --point-in-time)
            POINT_IN_TIME="$2"
            shift 2
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$BACKUP_FILE" ]; then
    echo "Uso: $0 <archivo_backup.sql.gz> [--point-in-time 'YYYY-MM-DD HH:MM:SS'] [--skip-validation]"
    echo ""
    echo "Ejemplos:"
    echo "  $0 /var/backups/neology_parking/neology_parking_full_20260914_120000.sql.gz"
    echo "  $0 /var/backups/neology_parking/neology_parking_full_20260914_120000.sql.gz --point-in-time '2026-09-14 10:30:00'"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: El archivo $BACKUP_FILE no existe."
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Inicio de restauración" | tee -a "$LOGFILE"
echo "  Backup: $BACKUP_FILE" | tee -a "$LOGFILE"

# ---- 1. Verificación SHA256 ----
if [ -f "${BACKUP_FILE}.sha256" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Verificando SHA256..." | tee -a "$LOGFILE"
    if sha256sum -c "${BACKUP_FILE}.sha256" >> "$LOGFILE" 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Integridad verificada." | tee -a "$LOGFILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] El archivo está corrupto o fue alterado." | tee -a "$LOGFILE"
        exit 1
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] No existe archivo SHA256. Omitiendo verificación." | tee -a "$LOGFILE"
fi

# ---- 2. Confirmación de seguridad ----
echo ""
echo "⚠️  ADVERTENCIA: Esto ELIMINará la base de datos '${DB_NAME}' existente."
echo "    Se creará un respaldo de seguridad antes de continuar."
read -p "¿Continuar? (s/N): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Cancelado."
    exit 0
fi

# ---- 3. Respaldo de seguridad de la BD actual ----
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Creando respaldo de seguridad..." | tee -a "$LOGFILE"
mysqldump \
    --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --password="$DB_PASS" \
    --single-transaction --routines --triggers --events \
    --databases "$DB_NAME" \
    2>>"$LOGFILE" \
    | gzip > "${LOG_DIR}/${DB_NAME}_pre_restore_${DATE}.sql.gz"
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Respaldo de seguridad creado." | tee -a "$LOGFILE"

# ---- 4. Restauración del dump ----
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Restaurando desde backup..." | tee -a "$LOGFILE"

# Opción: eliminar BD antes de restaurar (si el dump incluye CREATE DATABASE)
gunzip -c "$BACKUP_FILE" 2>>"$LOGFILE" \
    | mysql --host="$DB_HOST" --port="$DB_PORT" \
        --user="$DB_USER" --password="$DB_PASS" \
        --force 2>>"$LOGFILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Dump restaurado." | tee -a "$LOGFILE"

# ---- 5. Restauración a punto en el tiempo (usando binlogs) ----
if [ -n "$POINT_IN_TIME" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Aplicando binlogs hasta: ${POINT_IN_TIME}" | tee -a "$LOGFILE"

    # Buscar el último binlog del respaldo
    BINLOG_DIR=$(mysql --host="$DB_HOST" --port="$DB_PORT" \
        --user="$DB_USER" --password="$DB_PASS" \
        -N -e "SHOW VARIABLES LIKE 'log_bin_basename';" 2>/dev/null \
        | awk '{print $2}')
    BINLOG_PATH=$(dirname "$BINLOG_DIR")

    # Aplicar binlogs uno por uno hasta el punto en el tiempo
    for binlog in "$BINLOG_PATH"/mysql-bin.*; do
        if mysqlbinlog --stop-datetime="$POINT_IN_TIME" "$binlog" 2>>"$LOGFILE" \
            | mysql --host="$DB_HOST" --port="$DB_PORT" \
                --user="$DB_USER" --password="$DB_PASS" 2>>"$LOGFILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Aplicado: $(basename $binlog)" | tee -a "$LOGFILE"
        fi
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Punto en el tiempo alcanzado: ${POINT_IN_TIME}" | tee -a "$LOGFILE"
fi

# ---- 6. Validación post-restauración ----
if [ "$SKIP_VALIDATION" = false ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Validando restauración..." | tee -a "$LOGFILE"

    TABLE_COUNT=$(mysql --host="$DB_HOST" --port="$DB_PORT" \
        --user="$DB_USER" --password="$DB_PASS" \
        -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
    echo "  Tablas: ${TABLE_COUNT}" | tee -a "$LOGFILE"

    ROW_COUNT=$(mysql --host="$DB_HOST" --port="$DB_PORT" \
        --user="$DB_USER" --password="$DB_PASS" \
        -N -e "SELECT SUM(table_rows) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND engine='InnoDB';")
    echo "  Estimación de filas: ${ROW_COUNT}" | tee -a "$LOGFILE"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] Restauración completada." | tee -a "$LOGFILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Validación omitida." | tee -a "$LOGFILE"
fi

exit 0
