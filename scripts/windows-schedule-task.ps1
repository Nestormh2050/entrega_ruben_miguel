# ============================================================
# DBA - Prueba Técnica Neology
# Registro de respaldo automático en Windows Task Scheduler
# ============================================================
# Uso (PowerShell como Administrador):
#   powershell -ExecutionPolicy Bypass -File scripts\windows-schedule-task.ps1
#
# Crea los wrappers .bat y registra 3 tareas programadas:
#   - Neology_Backup_Diario       todos los días 02:00   respaldo + validación
#   - Neology_Integridad_Semanal  lunes 03:30            test_integridad()
#   - Neology_Particiones_Mensual día 1, 04:00           maint_partitions_audit()
#
# La contraseña debe proporcionarse en ejecución desatendida vía
# variable de entorno DB_BACKUP_PASSWORD. NUNCA guardarla en texto
# plano dentro de los scripts.
# ============================================================

$ErrorActionPreference = "Stop"

# ---------- Configuración ----------
$RepoPath      = "C:\Users\nesto\entrega_ruben_miguel"
$MariaBin      = "C:\Program Files\MariaDB 12.3\bin"
$BackupPs1     = Join-Path $RepoPath "scripts\windows-backup.ps1"
$BackupBat     = Join-Path $RepoPath "scripts\backup.bat"
$IntegrityBat  = Join-Path $RepoPath "scripts\integridad.bat"
$PartitionBat  = Join-Path $RepoPath "scripts\particiones.bat"

# ---------- backup.bat: llama a windows-backup.ps1 ----------
$backupBat = @"
@echo off
if "%DB_BACKUP_PASSWORD%"=="" (
    echo [ERROR] Variable DB_BACKUP_PASSWORD no definida.
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "$BackupPs1"
"@
Set-Content -LiteralPath $BackupBat -Value $backupBat -Encoding ASCII

# ---------- integridad.bat: ejecuta test_integridad ----------
$integrityBat = @"
@echo off
if "%DB_BACKUP_PASSWORD%"=="" (
    echo [ERROR] Variable DB_BACKUP_PASSWORD no definida.
    exit /b 1
)
"$MariaBin\mariadb.exe" -uroot -p%DB_BACKUP_PASSWORD% -h127.0.0.1 -P3305 -e "CALL neology_parking.test_integridad();"
"@
Set-Content -LiteralPath $IntegrityBat -Value $integrityBat -Encoding ASCII

# ---------- particiones.bat: mantiene particiones de audit_log ----------
$partitionBat = @"
@echo off
if "%DB_BACKUP_PASSWORD%"=="" (
    echo [ERROR] Variable DB_BACKUP_PASSWORD no definida.
    exit /b 1
)
"$MariaBin\mariadb.exe" -uroot -p%DB_BACKUP_PASSWORD% -h127.0.0.1 -P3305 -e "CALL neology_parking.maint_partitions_audit(202705);"
"@
Set-Content -LiteralPath $PartitionBat -Value $partitionBat -Encoding ASCII

# Nota: maint_partitions_audit crea la partición del mes siguiente al
# último existente; ajustar el YYYYMM según calendario en producción.

# ---------- Registrar tareas ----------
Write-Host "Registrando tareas programadas..." -ForegroundColor Cyan

schtasks /Create /F /TN "Neology_Backup_Diario" `
    /SC DAILY /ST 02:00 /TR "`"$BackupBat`"" | Out-Host

schtasks /Create /F /TN "Neology_Integridad_Semanal" `
    /SC WEEKLY /D MON /ST 03:30 /TR "`"$IntegrityBat`"" | Out-Host

schtasks /Create /F /TN "Neology_Particiones_Mensual" `
    /SC MONTHLY /D 1 /ST 04:00 /TR "`"$PartitionBat`"" | Out-Host

Write-Host ""
Write-Host "Tareas registradas:" -ForegroundColor Green
schtasks /Query /TN "Neology_Backup_Diario" | Out-Host
schtasks /Query /TN "Neology_Integridad_Semanal" | Out-Host
schtasks /Query /TN "Neology_Particiones_Mensual" | Out-Host

Write-Host ""
Write-Host "Para que corran desatendidas, asocie la contraseña con:
  schtasks /Change /TN Neology_Backup_Diario /RU <usuario> /RP <pass> /IT
  (equivalente para las otras dos tareas)."