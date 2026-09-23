@echo off
REM ============================================================
REM Neology - Ejecuta solo las consultas queries.sql (Q1-Q8)
REM Muestra cada consulta y su titulo en pantalla (UTF-8)
REM Uso: queries.cmd        (desde la raiz del proyecto)
REM ============================================================
setlocal enableextensions
cd /d "%~dp0"

set "MARIADB=docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026"
set "DB=neology_parking"

if not exist "database\queries.sql" (
    echo [ERROR] No se encuentra database\queries.sql. Ejecuta desde la raiz del proyecto.
    exit /b 1
)

docker inspect neology_mariadb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El contenedor neology_mariadb no esta corriendo.
    echo         Ejecuta primero: docker compose up -d
    exit /b 1
)

echo.
echo Ejecutando consultas Q1-Q8 ...
echo.
chcp 65001 >nul
type "database\queries.sql" | %MARIADB% -v -t %DB%
if errorlevel 1 (
    echo.
    echo [ERROR] Fallo al ejecutar las consultas. Revisa el mensaje anterior.
    exit /b 1
)

echo.
echo [OK] Consultas Q1-Q8 terminaron sin error de consola.
exit /b 0