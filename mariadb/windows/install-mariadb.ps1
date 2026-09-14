<#
.SYNOPSIS
    Instala MariaDB Server en Windows de forma silenciosa.

.DESCRIPTION
    Descarga el MSI oficial de MariaDB, verifica su hash SHA256 e instala
    el servicio de Windows con el nombre, puerto y contraseña indicados.

.PARAMETER Version
    Versión de MariaDB a instalar (default: 12.3.3).

.PARAMETER ServiceName
    Nombre del servicio de Windows (default: MariaDB).

.PARAMETER Port
    Puerto TCP (default: 3305).

.PARAMETER RootPassword
    Contraseña del usuario root (obligatorio).

.PARAMETER SkipHashCheck
    Omite la verificación SHA256 (solo para versiones no listadas).

.EXAMPLE
    .\install-mariadb.ps1 -RootPassword "MiPasswordSeguro"

.NOTES
    Requiere ejecutarse como Administrador.
#>

[CmdletBinding()]
param(
    [string]$Version = "12.3.3",
    [string]$ServiceName = "MariaDB",
    [int]$Port = 3305,
    [Parameter(Mandatory = $true)]
    [string]$RootPassword,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = "Stop"

# Hashes SHA256 conocidos por versión
$knownHashes = @{
    "12.3.3" = "811A38A862C1C55325B6BA8A757B381923E51DEE4FE3CDE95887B0AE2490C02D"
}

# ------------------------------------------------------------
# Verificar privilegios de administrador
# ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Se requieren privilegios de administrador. Relanzando..." -ForegroundColor Yellow
    $args = "-Version `"$Version`" -ServiceName `"$ServiceName`" -Port $Port -RootPassword `"$RootPassword`""
    if ($SkipHashCheck) { $args += " -SkipHashCheck" }
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", $args
    exit
}

# ------------------------------------------------------------
# Descargar el MSI
# ------------------------------------------------------------
$fileName = "mariadb-$Version-winx64.msi"
$url      = "https://downloads.mariadb.org/rest-api/mariadb/$Version/$fileName"
$tempDir  = Join-Path $env:TEMP "mariadb-install"
$msiPath  = Join-Path $tempDir $fileName

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

Write-Host "[1/4] Descargando MariaDB $Version ..." -ForegroundColor Cyan
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing

# ------------------------------------------------------------
# Verificar hash SHA256
# ------------------------------------------------------------
if ($SkipHashCheck) {
    Write-Host "[2/4] Verificación de hash OMITIDA (-SkipHashCheck)." -ForegroundColor Yellow
}
elseif ($knownHashes.ContainsKey($Version)) {
    Write-Host "[2/4] Verificando hash SHA256 ..." -ForegroundColor Cyan
    $actual = (Get-FileHash $msiPath -Algorithm SHA256).Hash
    if ($actual -ne $knownHashes[$Version]) {
        throw "El hash SHA256 no coincide. Descarga corrupta o alterada.`nEsperado: $($knownHashes[$Version])`nObtenido: $actual"
    }
    Write-Host "      Hash OK." -ForegroundColor Green
}
else {
    Write-Warning "No hay hash conocido para la versión $Version. Use -SkipHashCheck para continuar."
    throw "Versión sin hash registrado."
}

# ------------------------------------------------------------
# Instalación silenciosa
# ------------------------------------------------------------
Write-Host "[3/4] Instalando servicio '$ServiceName' en el puerto $Port ..." -ForegroundColor Cyan
$logFile = Join-Path $tempDir "install.log"
$msiArgs = @(
    "/i", "`"$msiPath`"",
    "SERVICENAME=$ServiceName",
    "PASSWORD=$RootPassword",
    "PORT=$Port",
    "/qn",
    "/L*v", "`"$logFile`""
)
$proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "La instalación falló con código $($proc.ExitCode). Revisa: $logFile"
}

# ------------------------------------------------------------
# Verificación
# ------------------------------------------------------------
Write-Host "[4/4] Verificando el servicio ..." -ForegroundColor Cyan
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    throw "El servicio '$ServiceName' no fue creado."
}

$listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " MariaDB instalado correctamente" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host " Servicio : $ServiceName [$($svc.Status)]"
Write-Host " Puerto   : $Port $(if ($listening) { '(escuchando)' } else { '(aun no escucha)' })"
Write-Host " Host     : 127.0.0.1"
Write-Host " Root user: root"
Write-Host " Datadir  : C:\Program Files\MariaDB $Version\data\"
Write-Host ""
Write-Host "Prueba de conexion:" -ForegroundColor Cyan
Write-Host "  mariadb --host=127.0.0.1 --port=$Port --user=root --password=`"<TU_PASSWORD>`" -e `"SELECT VERSION();`""
