# DBA — Prueba Técnica Neology

> **Entrega:** Rubén Miguel Martínez  
> **Rama:** `main` (canónica; consolidada desde `entrega/ruben-miguel`)  
> **Sistema:** Control de acceso vehicular para estacionamiento

---

## Estructura del repositorio

```
entrega_ruben_miguel/
├── database/
│   ├── schema.sql              # Modelo de datos completo
│   ├── data.sql                # Datos de prueba (manualmente curados)
│   ├── generate-data.sql       # Procedimiento de generación automática a escala
│   ├── test_integridad.sql     # Suite de pruebas automáticas (25 chequeos)
│   └── partitioning.sql        # Particionado RANGE mensual de audit_log (TO_DAYS)
│   ├── queries.sql             # 8 consultas de negocio
│   ├── indexes.sql             # Índices de optimización
│   ├── monthly-close.sql       # Procedimiento de cierre mensual
│   └── security.sql            # Usuarios, roles y privilegios
├── scripts/
│   ├── backup.sh               # Respaldo completo + validación (Linux/mariabackup)
│   ├── restore.sh              # Restauración + PITR
│   ├── windows-backup.ps1      # Respaldo completo + validación (Windows)
│   ├── backup.bat              # Wrapper de backup (Task Scheduler)
│   ├── integridad.bat          # Wrapper test_integridad semanal
│   ├── particiones.bat         # Wrapper mantenimiento de particiones
│   ├── windows-schedule-task.ps1  # Registra las tareas en Task Scheduler
│   ├── install-cron.sh         # Instala respaldo automático en cron (Linux)
│   └── partition-stays.sql     # Migración documentada de stays (no ejecutar)
├── docs/
│   ├── modelo-datos.md         # Documentación del modelo + diagrama ER
│   ├── performance-analysis.md # Análisis de rendimiento y optimización
│   ├── backup-recovery.md      # Estrategia de respaldo, RPO/RTO
│   ├── incident-response.md    # Diagnóstico de incidentes
│   ├── monitoreo.md            # Propuesta de monitoreo y alertas
│   ├── archivado.md            # Estrategia de archivado y retención
│   ├── nosql-design.md         # Propuesta NoSQL para auditoría
│   └── mariadb-vs-oracle.md    # Comparación detallada de motores
├── evidencias/                 # Resultados de ejecución en MariaDB local
├── docker-compose.yml          # Levantamiento de MariaDB
├── .env.example                # Plantilla de credenciales
├── .gitignore                  # Excluye .env, datos, logs
├── .vscode/                    # Config de editor: extensiones recomendadas
└── README.md                   # Este archivo
```

---

## Instrucciones para levantar MariaDB

### Opción A — Docker (recomendado)

```bash
# 1. Copiar variables de entorno
cp .env.example .env
# Editar .env con tus contraseñas

# 2. Levantar el contenedor
docker compose up -d

# 3. Verificar
docker compose ps
docker compose logs mariadb
```

El contenedor crea automáticamente la base de datos `neology_parking` y ejecuta los archivos `database/*.sql` en orden.

Puerto: **3305** (configurable vía `HOST_PORT` en `.env`).

### Opción B — MariaDB local (Windows)

```powershell
# Descargar e instalar MariaDB
winget install MariaDB.Server

# Configurar puerto 3305 (para evitar conflicto con MySQL en 3306)
# Editar C:\Program Files\MariaDB 12.3\data\my.ini → port=3305
# Reiniciar servicio:
Restart-Service MariaDB
```

---

## Instrucciones para crear la estructura

```bash
# Con Docker
docker compose exec mariadb mariadb -uroot -p

# Sin Docker (desde la terminal, requiere MariaDB instalado)
mariadb --host=127.0.0.1 --port=3305 --user=root -p
```

Una vez dentro de MariaDB:

```sql
SOURCE database/schema.sql;
-- Crea la base de datos neology_parking con todas las tablas, constraints e índices
```

---

## Instrucciones para cargar los datos

```sql
SOURCE database/data.sql;
-- Inserta datos de prueba: tipos de vehículo, residentes, vehículos,
-- tarifas, estancias (abiertas, cerradas, inconsistentes), cargos,
-- cierre mensual de agosto y auditoría
```

---

## Instrucciones para ejecutar las consultas

```sql
SOURCE database/queries.sql;
```

Las 8 consultas:
1. Vehículos dentro del estacionamiento (abiertos)
2. Duración e importe de una estancia específica
3. Reporte mensual de residentes
4. Ingresos por día y tipo de vehículo
5. Promedio de permanencia por tipo de vehículo
6. Vehículos con más de una estancia abierta (debe retornar vacío: regla forzada por BD)
7. Registros con fechas o estados inconsistentes
8. Vehículos con mayor tiempo acumulado durante el mes

---

## Generar datos automáticamente (a escala)

Para probar las consultas con volúmenes grandes en lugar de los 21 registros curados:

```sql
SOURCE database/generate-data.sql;

CALL generate_test_data(
   p_months_back    => 12,   -- meses hacia atrás
   p_stays_per_day  => 150,  -- estancias promedio por día
   p_num_residents  => 80,   -- residentes con su vehículo
   p_num_nonresid   => 120,  -- vehículos no residentes
   p_num_officials  => 30,   -- vehículos oficiales
   p_open_stays     => 25,   -- estancias abiertas (vehículos distintos)
   p_clean_first    => TRUE  -- TRUE limpia los datos previos
);
```

El procedimiento respeta todas las reglas de negocio y constraints del modelo
(placa/ticket únicos, una sola estancia abierta por vehículo, `exit_time > entry_time`,
oficiales sin cobro, residentes con tarifa acumulada mensual y no residentes pagando
a la salida).

---

## Ejecutar el cierre mensual

```sql
SOURCE database/monthly-close.sql;

-- Ejecutar cierre de septiembre 2026
CALL execute_monthly_close('2026-09', 'ruben_miguel');

-- Intentar duplicar (debe fallar con error)
CALL execute_monthly_close('2026-09', 'ruben_miguel');
```

---

## Ejecutar las pruebas automáticas de integridad

```sql
SOURCE database/test_integridad.sql;
CALL test_integridad();
```

La suite ejecuta **25 chequeos** agrupados en:

| Grupo | Qué valida |
|---|---|
| **Unicidad** | placas, tickets y "una sola estancia abierta por vehículo" |
| **CHECK constraints** | `exit_time > entry_time`, importes y precios no negativos, rangos de tarifa válidos |
| **Reglas de pago** | pagada sin `paid_at/amount`, importe ≠ minutos × tarifa, entrada en el futuro |
| **Integridad referencial** | FK de stays, vehicles, charges y monthly_close_items sin referencias huérfanas |
| **Reglas de negocio** | residente con `resident_id`, no residente sin él, `accumulated` con residente, `exempt` en cero, coherencia de cierres mensuales |

Resultado esperado:
- **INTEGRIDAD OK** (0 violaciones) sobre datos generados con `generate_test_data`.
- **VIOLACIONES DETECTADAS** sobre `data.sql`, que incluye 3 anomalías intencionales
  (entrada futura y pago incompleto) usadas en la consulta Q7 de la prueba.

---

## Aplicar índices de optimización

```sql
SOURCE database/indexes.sql;
-- Agrega 5 índices compuestos para optimizar las consultas principales
```

---

## Implementar particionamiento mensual

```sql
SOURCE database/partitioning.sql;
-- Particiona audit_log por RANGE mensual (TO_DAYS) con pruning verificado.
-- Cambia su PK a (id, changed_at), requisito del motor.

-- Mantenimiento mensual (cron): asegura cobertura del periodo pedido
CALL maint_partitions_audit(202704);   -- crea el mes siguiente si falta
CALL maint_partitions_audit(202704);   -- no-op si ya está cubierto
```

**Nota técnica:** `stays`/`charges` NO se pueden particionar porque InnoDB no
admite Foreign Keys en tablas particionadas y sus índices únicos no incluyen la
columna de partición. La migración documentada (con sus tradeoffs) está en
`scripts/partition-stays.sql`; la recomendación es mantener `stays` sin
particionar a este volumen (≈0.6 GB a 24 meses).

---

## Configurar usuarios y privilegios

```sql
SOURCE database/security.sql;
-- Crea los usuarios: parking_app, parking_report, parking_ops, parking_dba
-- Reemplazar <CAMBIAR_PASSWORD_*> por contraseñas seguras antes de usar
```

---

## Automatizar los respaldos

### Windows (Task Scheduler)

```powershell
# 1. Probar el respaldo manualmente (usa la misma contraseña del .env):
$env:DB_BACKUP_PASSWORD = "<contraseña>"
powershell -ExecutionPolicy Bypass -File scripts\windows-backup.ps1

# 2. Registrar las 3 tareas (como Administrador):
powershell -ExecutionPolicy Bypass -File scripts\windows-schedule-task.ps1
#    Crea los wrappers *.bat y registra:
#      - Neology_Backup_Diario      todos los días 02:00
#      - Neology_Integridad_Semanal  lunes 03:30
#      - Neology_Particiones_Mensual día 1,  04:00

# 3. Asociar credenciales para ejecución desatendida:
schtasks /Change /TN Neology_Backup_Diario /RU <usuario> /RP <pass>
```

El respaldo diario hace, en una sola pasada:
1. **Dump completo** (`--single-transaction --routines --triggers --events`)
2. **Compresión GZip** y **hash SHA256**
3. **Retención** (30 días por defecto)
4. **Validación de restauración** en BD temporal y conteo de tablas
5. Copia de binlogs cuando están habilitados (cubren RPO ≤ 1 h junto al PITR)

### Linux (cron)

```bash
chmod +x scripts/install-cron.sh scripts/backup.sh
sudo ./scripts/install-cron.sh   # instala cron + /etc/neology/mariadb.env
```

Agenda: backup diario 02:00, `test_integridad()` lunes 03:30, particiones el día 1 a las 04:00.

### Contraseñas

Nunca se guardan en texto plano dentro del repositorio: se leen de la variable de
entorno `DB_BACKUP_PASSWORD` (Windows) o de `/etc/neology/mariadb.env` (Linux, chmod 600).

---

## Supuestos y decisiones técnicas

| Decisión | Justificación |
|---|---|
| `open_key` GENERATED + UNIQUE | Fuerza "una sola estancia abierta por vehículo" directamente en la BD, sin depender de la lógica de la aplicación. |
| Estancias abiertas en cierre mensual se prorratean al final del mes (`COALESCE(exit_time, v_end)`) | El cierre contabiliza todo el tiempo del mes; las estancias que siguen abiertas se cortan al `v_end`. Se debe documentar para contabilidad. |
| Tarifas con `valid_from` / `valid_to` | Permite reproducir cálculos históricos exactos aunque las tarifas cambien después. |
| `audit_log` con JSON | Almacena cambios de cualquier tabla sin necesidad de columnas específicas por tabla. |
| Sin DELETE en datos de negocio | Estancias y cargos nunca se eliminan; la información se conserva para trazabilidad. |
| MariaDB 12.3 como motor principal | Requiere Open Source; compatible con la mayoría de proveedores Cloud; sin licencias propietarias. |

---

## Limitaciones conocidas

- **mysqldump** es lento para tablas > 10 GB; para esos casos usar `mariabackup` (backup físico).
- Los datos de prueba representan un escenario pequeño (~20 estancias). A millones de registros se requiere particionamiento.
- La réplica asincrónica (documentada en backup-recovery.md) puede tener hasta unos segundos de desfase.
- `performance_schema` consume memoria (~5%); puede desactivarse en servidores con poca RAM si no se necesita monitoreo.
- Las contraseñas en `security.sql` son placeholders; **nunca deben subirse al repositorio con valores reales**.
