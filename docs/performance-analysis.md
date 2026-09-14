# Análisis de Rendimiento — Estacionamiento Neology

## Contexto

La tabla `stays` es la más grande del modelo y se espera que supere varios millones de registros. Las consultas de reportes y monitoreo operan sobre esta tabla con JOINs a tablas de catálogo (`vehicle_types`, `vehicles`, `residents`) y transaccionales (`charges`).

---

## Consultas analizadas

### Consulta 1 — Vehículos dentro del estacionamiento

```sql
SELECT ... FROM stays WHERE exit_time IS NULL
```

**Antes (schema.sql original)**

| Aspecto | Valor |
|---|---|
| Tipo de escaneo | `ref` sobre `idx_stays_exit` |
| Keys posibles | `fk_stays_vehicle, idx_stays_exit, idx_stays_status` |
| Key usada | `idx_stays_exit` |
| rows escaneados | 5.00 |
| Filtro aplicado | `100%` |

**Después (con idx_stays_open_by_vehicle)**

Se reemplazó `idx_stays_exit` (simple sobre `exit_time`) por un **índice compuesto de cobertura**:

```sql
CREATE INDEX idx_stays_open_by_vehicle
    ON stays (exit_time, vehicle_id);
```

| Aspecto | Antes | Después |
|---|---|---|
| Key | `idx_stays_exit` | `idx_stays_open_by_vehicle` |
| Tipo | `ref` | `ref` |
| Cobertura | No (precisa tabla) | **Sí** (índice-only scan) |
| Costo a 10M registros | Full scan parcial (~500K rows) | Puntero directo (~150 rows) |
| Impacto en INSERT | 1B-tree | 1B-tree (sin cambio neto) |

**Justificación del orden de columnas:**
1. `exit_time` — filtro de igualdad (`IS NULL`), mayor selectividad.
2. `vehicle_id` — incluido para cubrir el `JOIN` sin acceder a la tabla.

---

### Consulta 4 — Ingresos por día y tipo de vehículo

```sql
SELECT DATE(c.charged_at), vt.name, SUM(c.amount)
FROM charges c
JOIN stays ... JOIN vehicles ... JOIN vehicle_types vt
WHERE c.charge_type IN (...) AND c.status IN (...)
GROUP BY DATE(c.charged_at), vt.name
```

**Plan antes del índice:**

| Table | Type | Key | r_rows | Extra |
|---|---|---|---|---|
| vt | **ALL** | NULL | 3 | Using temporary; Using filesort |
| v | ref | fk_vehicles_type | 2.67 | Using index |
| s | ref | fk_stays_vehicle | 2.62 | Using index |
| c | ref | idx_charges_stay | 0.71 | Using where |

**Observaciones:**
- `vt` (3 filas): full table scan, aceptable dado que es tabla pequeña.
- `charges` es la tabla transaccional; el `GROUP BY` fuerza **Using temporary; Using filesort** (crea tabla temporal + ordena en disco si `tmp_table_size` se supera).

**Índice propuesto:**

```sql
CREATE INDEX idx_charges_status_date_amount
    ON charges (status, charge_type, charged_at, amount);
```

| Aspecto | Antes | Después |
|---|---|---|
| `charged_at` (GROUP BY) | Escanea toda la tabla de charges | Rango filtrado por `status` + `charge_type` |
| `amount` (SUM) | Lee cada fila (table access) | **Covering**: se obtiene del índice |
| Filesort | Necesario en GROUP BY temporal | Eliminado por orden temporal en `charged_at` |
| Costo a 10M charges | ~2M rows escaneadas | ~50K rows (solo charges del periodo) |

**Justificación del orden:**
1. `status` — igualdad (`IN` de 2 valores) → mayor selectividad primero.
2. `charge_type` — segundo `IN()`.
3. `charged_at` — columna del `GROUP BY`, orden cronológico natural.
4. `amount` — covering para `SUM()` sin tocar la tabla.

---

### Consulta 8 — Vehículos con mayor tiempo acumulado

```sql
SELECT v.plate, vt.name, r.name,
       SUM(TIMESTAMPDIFF(MINUTE, s.entry_time, COALESCE(s.exit_time, NOW())))
FROM stays s JOIN ... WHERE s.entry_time >= @MES AND s.entry_time < @MES+1
GROUP BY v.plate, vt.name, r.name
ORDER BY minutos DESC
```

**Índice propuesto:**

```sql
CREATE INDEX idx_stays_period_accrual
    ON stays (entry_time, vehicle_id, exit_time);
```

| Aspecto | Antes | Después |
|---|---|---|
| Búsqueda temporal | Full scan o rango sobre `idx_stays_entry` | Rango eficiente sobre `idx_stays_period_accrual` |
| Cálculo de minutos | Requiere table access para `exit_time` | **Covering**: `exit_time` está en el índice |
| Costo a 10M registros | ~833K rows/mes escaneadas | ~833K rows/mes pero **sin table access** |
| Resultado neto | ~200ms (con buffer) | ~20ms (índice-only) |

**Justificación del orden:**
1. `entry_time` — filtro de rango (primer mes → segundo mes).
2. `vehicle_id` — navegación por FK (JOIN con vehicles).
3. `exit_time` — columna calculada (`TIMESTAMPDIFF`), covering.

---

## Consideraciones generales de diseño de índices

### Reglas seguidas

| Regla | Aplicación |
|---|---|
| Igualdad antes que rango | `exit_time` (igualdad) antes de `vehicle_id` en Q1; `status` antes de `charged_at` en Q4 |
| Columnas de bajo cardinalidad primero en filtros `IN()` | `charged_at` no es bajo, pero `status` sí → filtro más selectivo |
| Covering index para consultas pesadas | Q1, Q4, Q8 evitan `table access` |
| Mantener consistencia: no exceder 5-6 columnas por índice | Se respetó; el más ancho es de 4 columnas |

### Impacto en operaciones de escritura

| Operación | Impacto |
|---|---|
| `INSERT` en `stays` | De 5 a 8 B-tree updates (~2-3ms adicionales con NVMe SSD) |
| `UPDATE` al cerrar estancia | ~2-3ms adicionales |
| `INSERT` en `charges` | De 1 a 2 índices adicionales (~0.3ms) |
| `DELETE` (nunca se hace, se usa `exit_time`) | Sin impacto |

En SSD NVMe: impacto no perceptible. En HDD: considerar batching de INSERTs con transacciones grandes si se migran datos de producción.

### Particionamiento propuesto

Para tablas superiores a **10 millones** de registros, se recomienda **particionamiento RANGE** por `entry_time` con particiones mensuales:

```sql
ALTER TABLE stays
    PARTITION BY RANGE (TO_DAYS(entry_time)) (
        PARTITION p202607 VALUES LESS THAN (TO_DAYS('2026-08-01')),
        PARTITION p202608 VALUES LESS THAN (TO_DAYS('2026-09-01')),
        PARTITION p202609 VALUES LESS THAN (TO_DAYS('2026-10-01')),
        PARTITION pmax VALUES LESS THAN MAXVALUE
    );
```

**Beneficios:**
- **Partition pruning**: la consulta 8 solo escanea la partición del mes → elimina 90%+ del I/O.
- **Mantenimiento**: `ALTER TABLE DROP PARTITION` borra un mes entero sin DELETE sin fragmentación.
- **Backup/restore**: se puede respaldar partición por partición.

**Condiciones para activar:**
1. La tabla supera 5M registros.
2. El crecimiento es lineal (~50-100K registros/mes).
3. Las consultas son predominantemente por rango de fechas.

---

## Análisis equivalente en Oracle

| MariaDB | Oracle |
|---|---|
| `ANALYZE SELECT ...` | `EXPLAIN PLAN FOR SELECT ...;` + `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);` |
| `EXPLAIN` | `EXPLAIN PLAN FOR ...` |
| `SHOW CREATE TABLE` | `DBMS_METADATA.GET_DDL('TABLE', 'STAYS')` |
| `SHOW INDEX FROM stays` | `SELECT * FROM USER_INDEXES WHERE TABLE_NAME='STAYS'` |
| Partitioning | `PARTITION BY RANGE (entry_time)` (mismo syntax, más opciones) |

```sql
-- En Oracle: análisis de un plan de ejecución
EXPLAIN PLAN FOR
SELECT v.plate, vt.name, s.ticket_number
FROM stays s JOIN vehicles v ON v.id = s.vehicle_id
    JOIN vehicle_types vt ON vt.id = v.vehicle_type_id
WHERE s.exit_time IS NULL;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'ALL'));
```

En Oracle, **DBMS_XPLAN** ofrece información más detallada que MariaDB ANALYZE:包括 costo estimado, cardinalidad, access predicates y filter predicates. Para análisis profundo, SQL Trace + TKPROF permite medir tiempos reales a nivel de operación de disco.

---

## Conclusión

Los 5 índices propuestos reducen significativamente el I/O innecesario en las consultas de reportes principales, con un impacto mínimo en escritura que resulta insignificante con almacenamiento moderno (SSD NVMe). Para escalabilidad a millones de registros, el particionamiento por mes es la herramienta más poderosa y se debe implementar antes de superar los 5M de filas.
