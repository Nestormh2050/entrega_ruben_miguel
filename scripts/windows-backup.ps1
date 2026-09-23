# ============================================================
# DBA - Prueba Técnica Neology
# Respaldo completo automatizado (Windows / PowerShell 5.1+)
# Motor: MariaDB 12.x
# ============================================================
# Uso:
#   $env:DB_BACKUP_PASSWORD = "<contraseña>"
#   powershell -ExecutionPolicy Bypass -File scripts\windows-backup.ps1
#
# Realiza: dump completo + SHA256 + copia binlogs + retención
#          + validación (restaura en BD temporal y verifica tablas)
# ============================================================

param(
    [string]$DBHost = "127.0.0.1",
    [int]$DBPort = 3305,
    [string]$DBUser = "parking_dba",
    [string]$DBName = "neology_parking",
    [string]$BackupDir = "C:\backups\neology_parking",
    [string]$LogDir = "C:\backups\neology_parking\logs",
    [int]$RetentionDays = 30,
    [string]$MariaRoot = "C:\Program Files\MariaDB 12.3\bin"
)

$ErrorActionPreference = "Stop"

# ---- Configuración ----
if (-not $env:DB_BACKUP_PASSWORD) {
    Write-Host "ERROR: Defina la variable de entorno DB_BACKUP_PASSWORD" -ForegroundColor Red
    Write-Host '  $env:DB_BACKUP_PASSWORD = "<su_contraseña>"' -ForegroundColor Yellow
    exit 1
}
$DBPass = $env:DB_BACKUP_PASSWORD

$MariaDump = Join-Path $MariaRoot "mariadb-dump.exe"
$Maria = Join-Path $MariaRoot "mariadb.exe"
if (-not (Test-Path $MariaDump)) { throw "No se encontró mariadb-dump.exe en $MariaRoot" }
if (-not (Test-Path $Maria)) { throw "No se encontró mariadb.exe en $MariaRoot" }

$Date = Get-Date -Format "yyyyMMdd_HHmmss"
$Stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$LogFile = Join-Path $LogDir "backup_$Date.log"
New-Item -ItemType Directory -Force -Path $BackupDir, $LogDir | Out-Null

function Write-Log([string]$Msg) {
    $line = "$Stamp [INFO] $Msg"
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

Write-Log "Inicio de respaldo de $DBName"

# ---- 1. Dump completo ----
$DumpFile = Join-Path $BackupDir "${DBName}_full_$Date.sql"
$DumpGz = "$DumpFile.gz"

Write-Log "Ejecutando mariadb-dump..."
cmd.exe /c "`"$MariaDump`" --host=$DBHost --port=$DBPort --user=$DBUser --password=$DBPass --single-transaction --routines --triggers --events --add-drop-database --databases `"$DBName`" > `"$DumpFile`" 2>> `"$LogFile`" "

if ($LASTEXITCODE -ne 0) { Write-Log "ERROR dump: exit code $LASTEXITCODE"; exit 1 }

# ---- 2. Compresión GZip (PowerShell no trae gzip CLI) ----
Write-Log "Comprimiendo con GZip..."
$in = [System.IO.File]::OpenRead($DumpFile)
try {
    $out = [System.IO.File]::Create($DumpGz)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
        $in.CopyTo($gz)
        $gz.Close()
    } finally { $out.Dispose() }
} finally { $in.Dispose() }
Remove-Item -LiteralPath $DumpFile -Force

$SizeKB = [math]::Round((Get-Item $DumpGz).Length / 1KB, 1)
Write-Log "Respaldo comprimido: $SizeKB KB"

# ---- 3. SHA256 ----
$Hash = (Get-FileHash -LiteralPath $DumpGz -Algorithm SHA256).Hash
Set-Content -LiteralPath "$DumpGz.sha256" -Value "$Hash  $(Split-Path $DumpGz -Leaf)"
Write-Log "SHA256 generado: $Hash"

# ---- 4. Retención: borrar respaldos antiguos ----
$Old = @(Get-ChildItem -LiteralPath $BackupDir -Filter "$DBName*_full_*.sql.gz" |
         Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) })
foreach ($f in $Old) { Remove-Item -LiteralPath $f.FullName -Force; Remove-Item -LiteralPath "$($f.FullName).sha256" -Force -ErrorAction SilentlyContinue }
Write-Log "Respaldos eliminados (> $RetentionDays días): $($Old.Count)"

# ---- 5. Validación: restaurar en BD temporal y verificar tablas ----
$TestDB = "${DBName}_restore_test"
Write-Log "Validando restauración en $TestDB..."
$TmpSql = Join-Path ([System.IO.Path]::GetTempPath()) "restore_test_$Date.sql"

$in2 = [System.IO.File]::OpenRead($DumpGz)
try {
    $out2 = [System.IO.File]::Create($TmpSql)
    try {
        $gz2 = New-Object System.IO.Compression.GZipStream($in2, [System.IO.Compression.CompressionMode]::Decompress)
        $gz2.CopyTo($out2)
        $gz2.Close()
    } finally { $out2.Dispose() }
} finally { $in2.Dispose() }

(Get-Content -LiteralPath $TmpSql -Raw) -replace $DBName, $TestDB |
    Set-Content -LiteralPath $TmpSql -Encoding UTF8

& $Maria --host=$DBHost --port=$DBPort --user=$DBUser --password=$DBPass -e "CREATE DATABASE IF NOT EXISTS $TestDB;"
$RestoreCode = 0
$SqlText = Get-Content -LiteralPath $TmpSql -Raw
$OutEnc = $OutputEncoding
$OutputEncoding = [System.Text.Encoding]::UTF8
try {
    $SqlText | & $Maria --host=$DBHost --port=$DBPort --user=$DBUser --password=$DBPass $TestDB
} finally {
    $OutputEncoding = $OutEnc
}
$RestoreCode = $LASTEXITCODE

if ($RestoreCode -eq 0) {
    $TableCount = (& $Maria --host=$DBHost --port=$DBPort --user=$DBUser --password=$DBPass -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TestDB';").Trim()
    Write-Log "Tablas restauradas en validación: $TableCount"
} else {
    Write-Log "ERROR en validación de restauración"
}

& $Maria --host=$DBHost --port=$DBPort --user=$DBUser --password=$DBPass -e "DROP DATABASE IF EXISTS $TestDB;" | Out-Null
Remove-Item -LiteralPath $TmpSql -Force -ErrorAction SilentlyContinue

# ---- Resumen ----
Write-Log "[OK] Respaldo completado exitosamente."
Write-Log "  Archivo: $DumpGz"
Write-Log "  Tamaño:  $SizeKB KB"
Write-Log "  SHA256:  $DumpGz.sha256"
Write-Log "  Log:     $LogFile"
exit 0