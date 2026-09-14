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
#  00 04 1 * *   mantenimiento de particiones de audit_log
#  00 05 1 * *   archivado mensual (scripts/archive.sh, si se activa)
#
# La contraseña la provee /etc/neology/mariadb.env (modo 600).
# ============================================================

set -euo pipefail

REPO="/opt/entrega_ruben_miguel"
MYSQL_CLIENT=$(command -v mariadb || command -v mysql)

# Config mínima
CONF_DIR="/etc/neology"
CONF_FILE="$CONF_DIR/mariadb.env"
if [ ! -f "$CONF_FILE" ]; then
    echo "Creando $CONF_FILE (edítalo con la contraseña real, chmod 600)..."
    mkdir -p "$CONF_DIR"
    echo 'export DB_BACKUP_PASSWORD="CAMBIAR_PASSWORD"' > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    echo "IMPORTANTE: edita $CONF_FILE y pon la contraseña real."
fi

# Cron jobs (se instalan en el crontab del usuario actual)
CRON_JOBS=(
    "0 2 * * *   . /etc/neology/mariadb.env; $REPO/scripts/backup.sh >> /var/log/neology_parking/cron.log 2>&1"
    "30 3 * * 1  . /etc/neology/mariadb.env; $MYSQL_CLIENT -h127.0.0.1 -P3305 -u parking_dba -p\$DB_BACKUP_PASSWORD -e 'CALL neology_parking.test_integridad();' >> /var/log/neology_parking/cron.log 2>&1"
    "0 4 1 * *   . /etc/neology/mariadb.env; $MYSQL_CLIENT -h127.0.0.1 -P3305 -u parking_dba -p\$DB_BACKUP_PASSWORD -e 'CALL neology_parking.maint_partitions_audit(202705);' >> /var/log/neology_parking/cron.log 2>&1"
)

mkdir -p /var/log/neology_parking

# Anexa líneas si no existen
( crontab -l 2>/dev/null || true ) > /tmp/neology_cron.$$
for j in "${CRON_JOBS[@]}"; do
    if ! grep -Fq "neology_parking" /tmp/neology_cron.$$; then
        echo "$j" >> /tmp/neology_cron.$$
    fi
done
crontab /tmp/neology_cron.$$
rm -f /tmp/neology_cron.$$

echo "Crontab actualizado:"
crontab -l
echo "Nota: ajusta 202705 al próximo mes y REVISA $CONF_FILE (contraseña)."