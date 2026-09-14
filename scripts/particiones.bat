@echo off
if "%DB_BACKUP_PASSWORD%"=="" (
    echo [ERROR] Variable DB_BACKUP_PASSWORD no definida.
    exit /b 1
)
"C:\Program Files\MariaDB 12.3\bin\mariadb.exe" -uroot -p%DB_BACKUP_PASSWORD% -h127.0.0.1 -P3305 -e "CALL neology_parking.maint_partitions_audit(202705);"
