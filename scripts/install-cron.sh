#!/usr/bin/env bash
# ============================================================
# DBA - Prueba Técnica Neology
# Instalación de respaldo automático en Linux (cron)
# ============================================================
# Uso:
#   sudo ./scripts/install-cron.sh
#
# Altas crontab para el usuario que ejecuta el script (DBAs):
#  00 02 * * *   backup diario (RPO <= 1 h cubierto por binlogs)
#  30 03 * * 1   test_integridad() semanal
#  00 04 1 * *   mantenimiento de particiones de audit_log (mes en curso + 1)
#
# La contraseña la provee /etc/neology/mariadb.env (modo 600).
# ============================================================

set -euo pipefail

# ---- Configuración editable ----
# Ruta del repositorio: por defecto la detecta desde la ubicación de este script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NEOLOGY_REPO:-$(dirname "$SCRIPT_DIR")}"
# Puerto del servidor MariaDB (3306 = nativo en Linux; 3305 = contenedor Docker).
DB_PORT="${NEOLOGY_DB_PORT:-3306}"
# Cliente: se detecta automáticamente.
MYSQL_CLIENT=$(command -v mariadb || command -v mysql)

CONF_DIR="/etc/neology"
CONF_FILE="$CONF_DIR/mariadb.env"

# ---- Verificar requisitos ----
if [ ! -x "$REPO/scripts/backup.sh" ]; then
    echo "ERROR: No se encuentra $REPO/scripts/backup.sh"
    echo "Exporta NEOLOGY_REPO=/ruta/al/repositorio o ejecuta desde el repositorio." >&2
    exit 1
fi
if [ -z "$MYSQL_CLIENT" ]; then
    echo "ERROR: No se encontró el cliente mariadb/mysql. Instálalo o ajusta PATH." >&2
    exit 1
fi

# ---- Secreto ----
if [ ! -f "$CONF_FILE" ]; then
    echo "Creando $CONF_FILE (edítalo con la contraseña real, chmod 600)..."
    mkdir -p "$CONF_DIR"
    echo 'export DB_BACKUP_PASSWORD="CAMBIAR_PASSWORD"' > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    echo "IMPORTANTE: edita $CONF_FILE y pon la contraseña real."
fi

# ---- Próximo mes para las particiones (AAAAMM) ----
NEXT_MONTH=$(date -d "+1 month" '+%Y%m' 2>/dev/null || date -v +1m '+%Y%m')

# ---- Cron jobs (se instalan en el crontab del usuario actual) ----
CRON_JOBS=(
    "0 2 * * *   . $CONF_FILE; $REPO/scripts/backup.sh >> /var/log/neology_parking/cron.log 2>&1"
    "30 3 * * 1  . $CONF_FILE; $MYSQL_CLIENT -h127.0.0.1 -P$DB_PORT -u parking_dba -p\$DB_BACKUP_PASSWORD -e 'CALL neology_parking.test_integridad();' >> /var/log/neology_parking/cron.log 2>&1"
    "0 4 1 * *   . $CONF_FILE; $MYSQL_CLIENT -h127.0.0.1 -P$DB_PORT -u parking_dba -p\$DB_BACKUP_PASSWORD -e 'CALL neology_parking.maint_partitions_audit($NEXT_MONTH);' >> /var/log/neology_parking/cron.log 2>&1"
)

mkdir -p /var/log/neology_parking

# ---- Anexa cada línea si su firma aún no existe en el crontab ----
TMP_CRON=$(mktemp /tmp/neology_cron.XXXXXX)
trap 'rm -f "$TMP_CRON"' EXIT
crontab -l 2>/dev/null || true > "$TMP_CRON"
for j in "${CRON_JOBS[@]}"; do
    SIGNATURE=$(echo "$j" | tr -s ' ' | awk '{print $1, $2, $3, $4, $5}')
    if ! grep -Fq "$SIGNATURE" "$TMP_CRON"; then
        echo "$j" >> "$TMP_CRON"
        echo "Agregado: $SIGNATURE"
    else
        echo "Ya existe: $SIGNATURE"
    fi
done
crontab "$TMP_CRON"

echo "Crontab actualizado:"
crontab -l
echo "Nota: REVISA $CONF_FILE (contraseña real) y ajusta NEOLOGY_DB_PORT si no es $DB_PORT."