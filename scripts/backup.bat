@echo off
if "%DB_BACKUP_PASSWORD%"=="" (
    echo [ERROR] Variable DB_BACKUP_PASSWORD no definida.
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nesto\entrega_ruben_miguel\scripts\windows-backup.ps1"
