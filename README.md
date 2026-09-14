# DBA — Prueba Técnica Neology

> **Entrega:** Rubén Miguel Martínez  
> **Rama:** `entrega/ruben-miguel`  
> **Sistema:** Control de acceso vehicular para estacionamiento

---

## Estructura del repositorio

```
entrega_ruben_miguel/
├── database/
│   ├── schema.sql              # Modelo de datos completo
│   ├── data.sql                # Datos de prueba
│   ├── queries.sql             # 8 consultas de negocio
│   ├── indexes.sql             # Índices de optimización
│   ├── monthly-close.sql       # Procedimiento de cierre mensual
│   └── security.sql            # Usuarios, roles y privilegios
├── scripts/
│   ├── backup.sh               # Respaldo completo + validación
│   └── restore.sh              # Restauración + PITR
├── docs/
│   ├── modelo-datos.md         # Documentación del modelo + diagrama ER
│   ├── performance-analysis.md # Análisis de rendimiento y optimización
│   ├── backup-recovery.md      # Estrategia de respaldo, RPO/RTO
│   ├── incident-response.md    # Diagnóstico de incidentes
│   └── nosql-design.md         # Propuesta NoSQL para auditoría
├── evidencias/                 # Resultados de ejecución en MariaDB local
├── docker-compose.yml          # Levantamiento de MariaDB
├── .env.example                # Plantilla de credenciales
├── .gitignore                  # Excluye .env, datos, logs
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

## Ejecutar el cierre mensual

```sql
SOURCE database/monthly-close.sql;

-- Ejecutar cierre de septiembre 2026
CALL execute_monthly_close('2026-09', 'ruben_miguel');

-- Intentar duplicar (debe fallar con error)
CALL execute_monthly_close('2026-09', 'ruben_miguel');
```

---

## Aplicar índices de optimización

```sql
SOURCE database/indexes.sql;
-- Agrega 5 índices compuestos para optimizar las consultas principales
```

---

## Configurar usuarios y privilegios

```sql
SOURCE database/security.sql;
-- Crea los usuarios: parking_app, parking_report, parking_ops, parking_dba
-- Reemplazar <CAMBIAR_PASSWORD_*> por contraseñas seguras antes de usar
```

---

## Ejecutar respaldo

```bash
chmod +x scripts/backup.sh
export DB_BACKUP_PASSWORD='<contraseña>'
./scripts/backup.sh
```

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
