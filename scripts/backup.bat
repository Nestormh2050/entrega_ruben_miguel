@echo off
REM ============================================================
REM Neology - Respaldo completo de la base de datos
REM Lee la contrasena del usuario DBA desde el .env y ejecuta
REM scripts\windows-backup.ps1 (dump + gzip + SHA256 + validacion)
REM Uso: backup.bat      (doble clic o desde cualquier carpeta)
REM ============================================================
setlocal enableextensions
cd /d "%~dp0\.."

if not exist ".env" (
    echo [ERROR] No existe .env. Copia .env.example a .env y define valores.
    exit /b 1
)

if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    echo [ERROR] No se encontro PowerShell.
    exit /b 1
)

REM ---- Leer .env (clave=valor, ignorar comentarios) ----
for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do set "%%A=%%B"

REM ---- Contrasena del DBA (sin valores por defecto: es un secreto) ----
if "%MARIADB_DBA_PASSWORD%"=="" (
    echo [ERROR] Falta MARIADB_DBA_PASSWORD en el .env.
    exit /b 1
)

docker inspect neology_mariadb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El contenedor neology_mariadb no esta corriendo.
    echo         Ejecuta primero: docker compose up -d
    exit /b 1
)

echo Iniciando respaldo de la base de datos neology_parking ...
set "DB_BACKUP_PASSWORD=%MARIADB_DBA_PASSWORD%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-backup.ps1"
if errorlevel 1 (
    echo.
    echo [ERROR] Fallo el respaldo. Revisa el mensaje anterior.
    exit /b 1
)

echo.
echo [OK] Respaldo completado. Archivos en C:\backups\neology_parking
exit /b 0