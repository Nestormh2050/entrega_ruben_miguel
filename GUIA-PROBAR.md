# Guía para probar el proyecto en local

> Sistema de control de acceso vehicular — `neology_parking` (MariaDB 12.x)

## Preparación (una vez)

### Opción A — Docker (recomendado)

```cmd
cd C:\Users\nesto\entrega_ruben_miguel
cp .env.example .env        :: edita las contraseñas
docker compose up -d        :: levanta MariaDB en localhost:3305
```

### Opción B — MariaDB nativo (Windows)

El servicio instalado ocupa el puerto `3305`. Asegúrate de **no tener ambos activos**
(puerto en conflicto).

---

## Cargar esquema y datos (en este orden)

Desde `C:\Users\nesto\entrega_ruben_miguel`:

```cmd
type database\schema.sql          | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026
type database\data.sql            | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\monthly-close.sql   | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\test_integridad.sql | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\generate-data.sql   | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\partitioning.sql    | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\indexes.sql         | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
type database\security.sql        | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
```

> Cada archivo es idempotente y puede re-ejecutarse sin romper nada.
> `schema.sql` es la excepción: hace `DROP DATABASE`, así que ejecútalo primero.

---

## Pruebas (esperadas)

### 1. Consultas de negocio Q1–Q8

```cmd
type database\queries.sql | docker exec -i neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
```

Esperado: Q6 vacío (regla "1 estancia abierta" cumplida) y Q7 con 3 anomalías.

### 2. Suite de integridad (25 chequeos)

```sql
CALL test_integridad();
```

- Sobre `data.sql` → **VIOLACIONES DETECTADAS (3)** (anomalías intencionales)
- Sobre datos generados → **INTEGRIDAD OK**

### 3. Generar datos a escala

```sql
CALL generate_test_data(3, 20, 30, 50, 10, 15, TRUE);
CALL test_integridad();   -- debe dar INTEGRIDAD OK
```

### 4. Cierre mensual

```sql
CALL execute_monthly_close('2026-09', 'ruben_miguel');  -- 1ra vez: crea el cierre
CALL execute_monthly_close('2026-09', 'ruben_miguel');  -- 2da vez: error por duplicado
```

### 5. Particionado de `audit_log`

```sql
SELECT PARTITION_NAME FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='neology_parking' AND TABLE_NAME='audit_log'
  AND PARTITION_NAME IS NOT NULL;
CALL maint_partitions_audit(202704);  -- crea el mes si falta; no-op si ya cubre
```

### 6. Consola interactiva

```cmd
docker exec -it neology_mariadb mariadb -uroot -proot_neology_2026 neology_parking
```

---

## Automatización (opcional)

- **Windows:** `scripts\windows-schedule-task.ps1` registra 3 tareas (backup diario 02:00,
  integridad lunes 03:30, particiones día 1 04:00).
- **Linux:** `scripts\install-cron.sh` instala las mismas en cron.
- La contraseña se lee de `DB_BACKUP_PASSWORD`; nunca en texto plano.