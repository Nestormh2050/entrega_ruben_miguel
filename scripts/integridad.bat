@echo off
REM Neology - Ejecuta la suite de integridad (25 chequeos)
REM Lee contrasenas del .env en la raiz del proyecto
setlocal enableextensions
cd /d "%~dp0\.."

if not exist ".env" (
    echo [ERROR] No existe .env. Copia .env.example a .env y define valores.
    exit /b 1
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do set "%%A=%%B"
if "%MARIADB_DBA_PASSWORD%"=="" (
    echo [ERROR] Falta MARIADB_DBA_PASSWORD en el .env.
    exit /b 1
)

"C:\Program Files\MariaDB 12.3\bin\mariadb.exe" -uparking_dba -p%MARIADB_DBA_PASSWORD% -h127.0.0.1 -P3305 -e "CALL neology_parking.test_integridad();"
if errorlevel 1 (
    echo [ERROR] Fallo la validacion de integridad.
    exit /b 1
)
exit /b 0