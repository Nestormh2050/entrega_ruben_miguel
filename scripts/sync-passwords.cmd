@echo off
REM ============================================================
REM Neology - Sincroniza contraseñas de usuarios con el .env
REM Re-aplica ALTER USER con las credenciales del .env real
REM (corrige el desfase de security.sql al recrear el contenedor)
REM ============================================================
setlocal enableextensions
cd /d "%~dp0\.."

if not exist ".env" (
    echo [ERROR] No existe .env. Copia .env.example a .env y define valores.
    exit /b 1
)

REM ---- Leer .env (clave=valor, ignorar comentarios) ----
for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do set "%%A=%%B"

REM ---- Valores por defecto si faltan ----
if "%MARIADB_PASSWORD%"=="" set "MARIADB_PASSWORD=parking_app_2026"
if "%MARIADB_REPORT_PASSWORD%"=="" set "MARIADB_REPORT_PASSWORD=parking_report_2026"
if "%MARIADB_OPS_PASSWORD%"=="" set "MARIADB_OPS_PASSWORD=parking_ops_2026"
if "%MARIADB_DBA_PASSWORD%"=="" set "MARIADB_DBA_PASSWORD=parking_dba_2026"

echo Sincronizando credenciales desde .env ...^(sin mostrar valores^)
docker exec neology_mariadb mariadb -uroot -p%MARIADB_ROOT_PASSWORD% -e "ALTER USER 'parking_app'@'%%' IDENTIFIED BY '%MARIADB_PASSWORD%'; ALTER USER 'parking_report'@'%%' IDENTIFIED BY '%MARIADB_REPORT_PASSWORD%'; ALTER USER 'parking_ops'@'%%' IDENTIFIED BY '%MARIADB_OPS_PASSWORD%'; ALTER USER 'parking_dba'@'%%' IDENTIFIED BY '%MARIADB_DBA_PASSWORD%'; FLUSH PRIVILEGES;"
if errorlevel 1 (
    echo [ERROR] Fallo al sincronizar credenciales.
    exit /b 1
)
echo [OK] Credenciales sincronizadas.

REM ---- Verificar acceso de los usuarios ----
docker exec neology_mariadb mariadb -uparking_app -p%MARIADB_PASSWORD% neology_parking -e "SELECT CURRENT_USER() AS usuario;" >nul 2>&1
if errorlevel 1 (
    echo [WARN] parking_app no pudo conectarse con la contrasena del .env
) else (
    echo [OK] parking_app  -^> conecta
)

docker exec neology_mariadb mariadb -uparking_report -p%MARIADB_REPORT_PASSWORD% neology_parking -e "SELECT CURRENT_USER() AS usuario;" >nul 2>&1
if errorlevel 1 (
    echo [WARN] parking_report no pudo conectarse
) else (
    echo [OK] parking_report -^> conecta
)

docker exec neology_mariadb mariadb -uparking_ops -p%MARIADB_OPS_PASSWORD% neology_parking -e "SELECT CURRENT_USER() AS usuario;" >nul 2>&1
if errorlevel 1 (
    echo [WARN] parking_ops no pudo conectarse
) else (
    echo [OK] parking_ops    -^> conecta
)

docker exec neology_mariadb mariadb -uparking_dba -p%MARIADB_DBA_PASSWORD% neology_parking -e "SELECT CURRENT_USER() AS usuario;" >nul 2>&1
if errorlevel 1 (
    echo [WARN] parking_dba no pudo conectarse
) else (
    echo [OK] parking_dba    -^> conecta
)

exit /b 0