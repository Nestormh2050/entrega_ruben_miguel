@echo off
REM ============================================================
REM Neology - Ejecuta todos los SQL de database/ en el orden correcto
REM Uso: run-all.cmd        (desde la raiz del proyecto)
REM ============================================================
setlocal enableextensions
cd /d "%~dp0"

set "MARIADB=docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026"
set "DB=neology_parking"

if not exist "database\schema.sql" (
    echo [ERROR] No se encuentra database\schema.sql. Ejecuta desde la raiz del proyecto.
    exit /b 1
)

docker inspect neology_mariadb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El contenedor neology_mariadb no esta corriendo.
    echo         Ejecuta primero: docker compose up -d
    exit /b 1
)

echo.
echo [1/9] schema.sql        ^(crea BD ^& tablas^)
type "database\schema.sql"        | %MARIADB%
if errorlevel 1 goto :error

echo [2/9] data.sql          ^(datos curados^)
type "database\data.sql"          | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [3/9] monthly-close.sql ^(procedimiento cierre^)
type "database\monthly-close.sql" | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [4/9] test_integridad.sql ^(suite 25 chequeos^)
type "database\test_integridad.sql" | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [5/9] generate-data.sql ^(generador masivo^)
type "database\generate-data.sql" | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [6/9] partitioning.sql ^(particiona audit_log^)
type "database\partitioning.sql" | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [7/9] indexes.sql       ^(indices idempotentes^)
type "database\indexes.sql"       | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [8/9] security.sql      ^(usuarios^)
type "database\security.sql"      | %MARIADB% %DB%
if errorlevel 1 goto :error

echo [8.5/9] sync-passwords  ^(credenciales desde .env^)
call "scripts\sync-passwords.cmd"
if errorlevel 1 goto :error

echo [9/9] queries.sql       ^(Q1-Q8^)
type "database\queries.sql"       | %MARIADB% %DB%
if errorlevel 1 goto :error

echo.
echo [OK] Todos los scripts terminaron sin error de consola.
exit /b 0

:error
echo.
echo [ERROR] Fallo en un script. Revisa el mensaje anterior.
exit /b 1