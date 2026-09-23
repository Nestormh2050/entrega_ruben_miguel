# ============================================================
# DBA - Prueba Técnica Neology
# Registro de respaldo automático en Windows Task Scheduler
# ============================================================
# Uso (PowerShell como Administrador):
#   powershell -ExecutionPolicy Bypass -File scripts\windows-schedule-task.ps1
#
# Registra 3 tareas programadas:
#   - Neology_Backup_Diario       todos los días 02:00   respaldo + validación
#   - Neology_Integridad_Semanal  lunes 03:30            test_integridad()
#   - Neology_Particiones_Mensual día 1, 04:00           maint_partitions_audit()
#
# Las contraseñas se leen de .env en tiempo de ejecución (los .bat
# asociados), NUNCA se guardan en texto plano.
# Para ejecución desatendida: registre las tareas con un usuario y
# contraseña de dominio vía /RU /RP (ver final del documento).
# ============================================================

$ErrorActionPreference = "Stop"

# ---------- Configuración ----------
$RepoPath      = Split-Path -Parent $PSScriptRoot   # raíz del proyecto
$MariaBin      = "C:\Program Files\MariaDB 12.3\bin"
$IntegrityBat  = Join-Path $RepoPath "scripts\integridad.bat"
$PartitionBat  = Join-Path $RepoPath "scripts\particiones.bat"

if (-not (Test-Path "$MariaBin\mariadb.exe")) {
    Write-Host "ERROR: No se encontro mariadb.exe en $MariaBin" -ForegroundColor Red
    exit 1
}

# ---------- integridad.bat: ejecuta test_integridad ----------
$nl = [Environment]::NewLine
$integrityLines = @(
    '@echo off'
    'REM Neology - Ejecuta la suite de integridad (25 chequeos)'
    'REM Lee contrasenas del .env en la raiz del proyecto'
    'setlocal enableextensions'
    'cd /d "%~dp0\.."'
    ''
    'if not exist ".env" ('
    '    echo [ERROR] No existe .env. Copia .env.example a .env y define valores.'
    '    exit /b 1'
    ')'
    ''
    'for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do set "%%A=%%B"'
    'if "%MARIADB_DBA_PASSWORD%"=="" ('
    '    echo [ERROR] Falta MARIADB_DBA_PASSWORD en el .env.'
    '    exit /b 1'
    ')'
    ''
    "`"$MariaBin\mariadb.exe`" -uparking_dba -p%MARIADB_DBA_PASSWORD% -h127.0.0.1 -P3305 -e `"CALL neology_parking.test_integridad();`""
    'if errorlevel 1 ('
    '    echo [ERROR] Fallo la validacion de integridad.'
    '    exit /b 1'
    ')'
    'exit /b 0'
)
[System.IO.File]::WriteAllText($IntegrityBat, ($integrityLines -join $nl), [System.Text.Encoding]::ASCII)

# ---------- particiones.bat: mantiene particiones de audit_log ----------
$nextMonth = (Get-Date).AddMonths(1).ToString("yyyyMM")
$partitionLines = @(
    '@echo off'
    'REM Neology - Mantiene las particiones de audit_log'
    'REM Lee contrasenas del .env en la raiz del proyecto'
    'setlocal enableextensions'
    'cd /d "%~dp0\.."'
    ''
    'if not exist ".env" ('
    '    echo [ERROR] No existe .env. Copia .env.example a .env y define valores.'
    '    exit /b 1'
    ')'
    ''
    'for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do set "%%A=%%B"'
    'if "%MARIADB_DBA_PASSWORD%"=="" ('
    '    echo [ERROR] Falta MARIADB_DBA_PASSWORD en el .env.'
    '    exit /b 1'
    ')'
    ''
    "`"$MariaBin\mariadb.exe`" -uparking_dba -p%MARIADB_DBA_PASSWORD% -h127.0.0.1 -P3305 -e `"CALL neology_parking.maint_partitions_audit($nextMonth);`""
    'if errorlevel 1 ('
    '    echo [ERROR] Fallo el mantenimiento de particiones.'
    '    exit /b 1'
    ')'
    'exit /b 0'
)
[System.IO.File]::WriteAllText($PartitionBat, ($partitionLines -join $nl), [System.Text.Encoding]::ASCII)

Write-Host "Generados:" -ForegroundColor Cyan
Write-Host "  $IntegrityBat"
Write-Host "  $PartitionBat"

# ---------- Registrar tareas ----------
Write-Host "Registrando tareas programadas..." -ForegroundColor Cyan

$BackupBat = Join-Path $RepoPath "scripts\backup.bat"

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
Write-Host "Para que corran desatendidas, asocie credenciales a cada tarea:"
Write-Host "  schtasks /Change /TN Neology_Backup_Diario /RU <usuario> /RP <contrasena> /IT"
Write-Host "  schtasks /Change /TN Neology_Integridad_Semanal /RU <usuario> /RP <contrasena> /IT"
Write-Host "  schtasks /Change /TN Neology_Particiones_Mensual /RU <usuario> /RP <contrasena> /IT"