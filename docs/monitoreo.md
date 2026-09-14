# Propuesta de Monitoreo — Estacionamiento Neology

## Objetivo

Disponer de visibilidad continua sobre la base de datos `neology_parking` para anticipar fallos antes de que afecten la operación del estacionamiento, cumpliendo los objetivos de recuperación definidos (RPO ≤ 1 h, RTO ≤ 4 h).

La propuesta cubre:
1. Métricas críticas y umbrales de alerta.
2. Herramientas y arquitectura de monitoreo.
3. Dashboards y paneles de control.
4. Gestión de alertas y escalamiento.
5. Detección proactiva de degradación.
6. Equivalencias para Oracle Enterprise.

---

## 1. Métricas críticas y umbrales de alerta

| Área | Métrica | Umbral de ADVERTENCIA | Umbral de CRÍTICO | Acción sugerida |
|---|---|---|---|---|
| **Recursos** | % uso CPU | > 70 % promedio 5 min | > 85 % | Revisar queries lentas; escalar CPU |
| **Recursos** | % uso RAM | > 75 % | > 90 % | Ajustar `innodb_buffer_pool_size`; revisar mysqld |
| **Recursos** | % espacio en disco | > 70 % | > 85 % | Rotar binlogs, archivar datos, ampliar volumen |
| **Conexiones** | `Threads_connected` / `max_connections` | > 70 % | > 85 % | Revisar pool de la aplicación; matar sesiones zombi |
| **Conexiones** | Conexiones abortadas (`Aborted_connects`) | > 5 / min | > 20 / min | Posible ataque o credenciales fallando |
| **Queries lentas** | `Slow_queries` (/min) | > 5 | > 50 | Capturar en `slow_query_log` y optimizar |
| **Queries lentas** | Query individual > 2 s | 1-5 eventos/hora | > 10 eventos/hora | Optimizar con EXPLAIN; revisar índices |
| **Operación** | `Uptime` reinicio inesperado | — | Reinicio no planificado | Revisar crash; validar respaldos |
| **Escritura** | `Innodb_rows_inserted` / seg | Caída > 50 % respecto a tendencia | — | Revisar aplicación o bloqueos |
| **InnoDB** | `Innodb_buffer_pool_read_requests` vs `reads` | hit ratio < 98 % | < 95 % | Aumentar buffer pool; revisar índices |
| **Bloqueos** | Transacciones abiertas > 30 s | 1-3 | > 5 | Revisar `INNODB_TRX`; matar si procede |
| **Réplica** | `Seconds_Behind_Master` | > 30 s | > 120 s | Revisar red o carga del esclavo |
| **Respaldo** | Último backup exitoso | > 26 h | > 50 h | Revisar job de backup |

---

## 2. Arquitectura de monitoreo

### Stack recomendado (Open Source)

```text
+------------------+    scrape   +--------------------+
| MariaDB          |    :9104    |  Prometheus        |
| (expose metrics) | <---------> |  (TSDB + reglas)   |
+------------------+             +---------+----------+
+------------------+                        | alerts
| Linux server     | scrape :9100           v
| node_exporter    | <--------->    +------+--------+
+------------------+                |  Alertmanager |
                                    +------+--------+
                                       |   |   |
                  +--------------------+   |   +-------------------+
                  |                       |                       |
            +-----v-----+          +------v------+          +-----v-----+
            |  Slack    |          |  Correo     |          |  PagerDuty |
            |  (aviso)  |          |  (diario)   |          | (crítico)  |
            +-----------+          +-------------+          +-----------+
```

| Componente | Función |
|---|---|
| **Prometheus** | Almacena series de tiempo de métricas y evalúa reglas de alerta cada 15-30 s |
| **mariadb_exporter** (exporter local) | Expone métricas del servidor MariaDB vía `SHOW GLOBAL STATUS`, `SHOW GLOBAL VARIABLES` y `performance_schema` |
| **node_exporter** | Expone métricas del sistema (CPU, RAM, disco, red) |
| **Grafana** | Dashboards visuales; acceso por roles (viewer/editor/admin) |
| **Alertmanager** | Rutea alertas a Slack/Correo/PagerDuty con silencios y deduplicación |

### Alternativas mínimas (si no hay infraestructura adicional)

| Opción | Descripción |
|---|---|
| **mysqltuner** + cron + correo | Script que analiza variables y recomienda tuning; salida por correo diario |
| **mariadb-admin extended-status** | Monitoreo manual desde CLI: `mariadb-admin extended-status` |
| **Performance Schema report** | Reporte programado: `performance_schema.events_statements_summary_by_digest` para top queries |
| **pt-heartbeat** (Percona Toolkit) | Verifica conectividad y réplica con latencia real |

---

## 3. Dashboards en Grafana

Paneles (panels) agrupados en 3 dashboards:

### a) Dashboard «Pantalla operativa» (nocturna kiosk)
- Estancias abiertas en este momento.
- Restadas: operaciones por hora (entradas/salidas).
- Ingresos acumulados del día.
- Alarmas activas (rojo intermitente si hay incidentes).

### b) Dashboard «Base de datos»
- `Threads_connected` con límite y % de uso.
- Queries por segundo (QPS).
- Hit ratio del buffer pool InnoDB.
- Transacciones abiertas más antiguas.
- `Slow_queries` y top 10 queries por tiempo acumulado.
- Tamaño de tablas y crecimiento diario.

### c) Dashboard «Infraestructura»
- CPU, memoria, disco y red del servidor.
- Estado de la réplica (`Seconds_Behind_Master`).
- Estado y antigüedad del último respaldo.
- Lista de binlogs y rotación esperada.

Plantillas listas para importar: «MySQL Overview» de Percona (compatible con MariaDB) ajustando `job="mariadb"`.

---

## 4. Gestión de alertas

### Prioridades y escalamiento

| Prioridad | Canal | Horario | Ejemplos |
|---|---|---|---|
| **P1 — Crítico** | PagerDuty + Slack + correo | 24/7 | BD caída, réplica rota > 5 min, disco 85 %, conexiones 85 % |
| **P2 — Alto** | Slack + correo | 24/7 | Queries lentas en aumento, transacciones bloqueadas > 30 s |
| **P3 — Medio** | Slack | Horario laboral | Backup > 26 h, hit ratio < 98 % |
| **P4 — Informativo** | Slack (canal #dba-la) | Resumen diario | Reporte de tendencias y consumo |

### Reglas de alerta (ejemplo en PromQL)

```yaml
groups:
  - name: neology_parking
    rules:
      - alert: MariaDBDown
        expr: up{job="mariadb"} == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "MariaDB no responde en {{ $labels.instance }}"
      - alert: MariaDBConnectionsHigh
        expr: mysql_global_status_threads_connected
              / mysql_global_variables_max_connections * 100 > 85
        for: 5m
        labels: { severity: critical }
      - alert: MariaDBDiskSpaceCritical
        expr: node_filesystem_avail_bytes{mountpoint="/var/lib/mysql"}
              / node_filesystem_size_bytes{mountpoint="/var/lib/mysql"} * 100 < 15
        for: 10m
        labels: { severity: critical }
      - alert: MariaDBSlowQueriesRising
        expr: rate(mysql_global_status_slow_queries[5m]) > 50
        for: 10m
        labels: { severity: warning }
      - alert: MariaDBOldestTransaction
        expr: mysql_information_schema_innodb_trx_age_seconds > 30
        for: 2m
        labels: { severity: warning }
```

---

## 5. Detección proactiva de degradación

### Consultas administrativas programadas (cada 15 min)

```sql
-- Top 10 de queries por tiempo acumulado en la última hora
SELECT
    LEFT(DIGEST_TEXT, 90) AS query,
    COUNT_STAR            AS ejecuciones,
    ROUND(SUM_TIMER_WAIT / 1e12, 2) AS seg_total,
    ROUND(AVG_TIMER_WAIT  / 1e12, 3) AS seg_promedio,
    SUM_ROWS_EXAMINED     AS filas_leidas
FROM performance_schema.events_statements_summary_by_digest
WHERE LAST_SEEN > DATE_SUB(NOW(), INTERVAL 1 HOUR)
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- Transacciones abiertas que pueden causar bloqueos
SELECT
    s.id AS pid, s.user, s.host, s.db, s.command,
    s.time AS segundos, t.trx_started, s.state
FROM information_schema.INNODB_TRX t
JOIN information_schema.PROCESSLIST s ON s.id = t.trx_mysql_thread_id
WHERE TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) > 30;

-- Tablas que crecen más rápido (para planear archivado/particionado)
SELECT
    TABLE_NAME,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS tamano_mb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024
          / DATEDIFF(NOW(), FROM_UNIXTIME(1)) * 24, 2)    AS aprox_mb_por_hora
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'neology_parking'
ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;
```

### Healtcheck del contenedor (Docker)

Ya incluido en `docker-compose.yml`:
```yaml
healthcheck:
  test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

### Reporte semanal automático
- Ejecución de `test_integridad()` y envío del resultado.
- Resumen de `slow_query_log` con queries candidatas a optimización.
- Crecimiento de tablas y estimación del próximo particionamiento.

---

## 6. Equivalencias para Oracle Enterprise

| Necesidad | MariaDB (Open Source) | Oracle Enterprise |
|---|---|---|
| Métricas en tiempo real | `performance_schema` + exporter | Enterprise Manager Cloud Control |
| Análisis de rendimiento | Análisis manual de `events_statements_summary` | AWR + ADDM (auto diagnóstico) |
| Alertas configurables | Prometheus + Alertmanager | EM Alert Rules + emcli |
| Baselines y tendencias | Prometheus (retensión TSDB) | AWR Baselines |
| Recomendaciones de índices | Análisis manual + EXPLAIN | SQL Tuning Advisor |
| Dashboards | Grafana | EM Dashboards / BI Publisher |
| Calidad de servicio (RPO/RTO) | Replicación + backup programado | Data Guard (failover automático) |
| Capacidad planificada | `information_schema` + growth script | Graduate / Capacity Planning de EM |

**Recomendación:** para el tamaño esperado del sistema (miles de estancias/día), la suite Prometheus + Grafana + mariadb exporter es suficiente y de costo cero. Oracle Enterprise justificaría su licencia si el volumen exige auto-diagnóstico (ADDM) y failover automático con cómputo de pérdida cero.

---

## 7. Plan de implementación

| Fase | Actividad | Tiempo estimado |
|---|---|---|
| **1** | Instalar `node_exporter` y `mariadb_exporter` en el servidor | 2-3 h |
| **2** | Configurar Prometheus (scrape + reglas de alerta) y Alertmanager | 3-4 h |
| **3** | Instalar Grafana e importar dashboards MySQL Overview | 2-3 h |
| **4** | Conectar canales de notificación (Slack, correo, PagerDuty) | 2-3 h |
| **5** | Definir umbrales con datos reales y probar alertas P1 | 2-3 h |
| **6** | Programar reportes semanales (`test_integridad` + slow queries) | 2 h |
| **Total** | | **~13-18 h** |