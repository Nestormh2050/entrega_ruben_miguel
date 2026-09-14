# Diseño NoSQL — Auditoría y Eventos del Sistema

## Contexto

El sistema de estacionamiento genera una cantidad significativa de eventos de auditoría: entradas, salidas, pagos, cierres mensuales, cambios de configuración y accesos de usuarios. Estos eventos son:
- **Alta escritura:** se generan continuamente durante la operación.
- **Consultas por rango de tiempo:** los reportes de auditoría filtran por fecha y tipo de evento.
- **Crecimiento acumulativo:** no se eliminan; se archivan por periodos.
- **Estructura semi-variable:** los metadatos de cada evento son diferentes.

Una base de datos relacional (MySQL/MariaDB) puede manejarlos, pero a medida que el volumen crece, una base de datos NoSQL orientada a documentos ofrece ventajas en rendimiento de escritura, escalado horizontal y flexibilidad del modelo.

---

## Tecnología seleccionada: MongoDB

**Justificación:**
- Modelo de documentos BSON que se adapta a la variabilidad de los eventos.
- Escritura optimizada (no requiere JOINs).
- Índices de rango eficientes sobre campos de fecha.
- Escalado horizontal via sharding (útil a millones de eventos/mes).
- Integración nativa con la mayoría de lenguajes de programación.
- Community Server gratuito y bien documentado.

**Alternativa considerada:** Redis (rápido pero volátil y no orientado a consultas complejas). Elasticsearch (bueno para búsqueda de texto, pero excesivo para este caso). Cassandra (bueno para escritura masiva, pero el modelo de datos es más rígido). MongoDB es el mejor equilibrio para auditoría estructurada.

---

## Ejemplo de documento

```json
{
  "_id": ObjectId("66e4a1b2c3d4e5f6a7b8c9d0"),
  "event_type": "stay.entry",
  "timestamp": ISODate("2026-09-14T08:30:00Z"),
  "source": "parking_app",
  "db_user": "parking_app@%",
  "ip_address": "10.0.1.50",
  "entity": {
    "collection": "stays",
    "id": 12345,
    "ticket": "TICKET-0016"
  },
  "action": "INSERT",
  "details": {
    "vehicle_plate": "RES-100",
    "vehicle_type": "RESIDENTE",
    "resident_name": "María González García",
    "entry_time": ISODate("2026-09-14T08:30:00Z"),
    "tariff_applied": 0.05
  },
  "metadata": {
    "application_version": "2.1.0",
    "session_id": "abc123def456",
    "correlation_id": "req-789012"
  },
  "retention": {
    "expires_at": ISODate("2027-09-14T00:00:00Z"),
    "archive_bucket": "cold-storage-2026"
  }
}
```

**Estructura flexible:** cada tipo de evento (`stay.entry`, `stay.exit`, `monthly.close`, `admin.grant`, `security.login失败`) tiene sus propios campos en `details`, sin necesidad de alterar esquemas.

---

## Estrategia de índices

| Índice | Campo(s) | Tipo | Justificación |
|---|---|---|---|
| 1 | `timestamp` | Descending | Consultas por rango de tiempo (más recientes primero) |
| 2 | `event_type` + `timestamp` | Compound | Filtrar por tipo de evento dentro de un rango |
| 3 | `entity.collection` + `entity.id` | Compound | Auditoría de una entidad específica (ej. todos los eventos de un vehículo) |
| 4 | `source` + `timestamp` | Compound | Auditoría por aplicación/origen |
| 5 | `retention.expires_at` | TTL | **Índice TTL**: MongoDB elimina automáticamente documentos expirados |

```javascript
// Creación de índices
db.audit_events.createIndex({ timestamp: -1 });
db.audit_events.createIndex({ event_type: 1, timestamp: -1 });
db.audit_events.createIndex({ "entity.collection": 1, "entity.id": 1, timestamp: -1 });
db.audit_events.createIndex({ source: 1, timestamp: -1 });
db.audit_events.createIndex({ "retention.expires_at": 1 }, { expireAfterSeconds: 0 });
```

---

## Consultas principales

```javascript
// 1. Eventos de un vehículo específico en los últimos 30 días
db.audit_events.find({
  "entity.collection": "stays",
  "details.vehicle_plate": "RES-100",
  timestamp: { $gte: new Date(Date.now() - 30*24*60*60*1000) }
}).sort({ timestamp: -1 });

// 2. Auditoría de cambios administrativos (quién modificó qué)
db.audit_events.find({
  event_type: { $in: ["admin.grant", "admin.revoke", "admin.schema_change"] },
  timestamp: { $gte: ISODate("2026-09-01"), $lt: ISODate("2026-10-01") }
}).sort({ timestamp: -1 });

// 3. Resumen de eventos por día (aggregate pipeline)
db.audit_events.aggregate([
  { $match: { timestamp: { $gte: ISODate("2026-09-01"), $lt: ISODate("2026-10-01") } } },
  { $group: {
      _id: { $dateToString: { format: "%Y-%m-%d", date: "$timestamp" } },
      total: { $sum: 1 },
      entradas: { $sum: { $cond: [{ $eq: ["$event_type", "stay.entry"] }, 1, 0] } },
      salidas: { $sum: { $cond: [{ $eq: ["$event_type", "stay.exit"] }, 1, 0] } }
  }},
  { $sort: { _id: 1 } }
]);
```

---

## Retención y crecimiento esperado

| Métrica | Valor |
|---|---|
| Eventos estimados por día | ~300-500 (estancias + auditoría de acceso + pagos) |
| Tamaño promedio por documento | ~1 KB |
| Crecimiento mensual | ~15 MB |
| Retención operativa | 12 meses (documentos calientes) |
| Retención en archivado | 5 años (documentos en cold storage / S3) |
| TTL automático | `expires_at` a 12 meses |

**Estrategia de archivado:**
- Documentos > 12 meses se migran a un bucket S3/GCS con formato JSON-lines.
- Se mantiene un índice ligero en MongoDB con metadatos de resumen.
- La consulta de documentos históricos se realiza desde el bucket (no desde MongoDB).

---

## Consistencia requerida

| Nivel | Justificación |
|---|---|
| **Escritura: acknowledged** (W=1) | Suficiente; no se requiere confirmación de réplica para cada evento individual. |
| **Lectura: local** (default) | Aceptable; un ligero desfase de milisegundos entre réplicas no afecta auditoría. |
| **Transacciones multi-documento** | No requeridas; cada evento es independiente. |

Si se requiere consistencia fuerte (ej. cierre mensual): usar transacciones de MongoDB 4.0+ (multi-document ACID).

---

## Ventajas vs. modelo relacional

| Aspecto | MongoDB | MariaDB (relacional) |
|---|---|---|
| Escritura de eventos | Muy rápida (append-only, sin transacciones) | Rápida pero con overhead de índices y triggers |
| Flexibilidad del modelo | Cada evento tiene su propia estructura | Requiere tabla polymórfica o columnas JSON |
| Escalado horizontal | Nativo (sharding) | Limitado (replicación vertical) |
| Retención/TTL | Automático con TTL index | Manual (DELETE periódico o particionamiento) |
| Consistencia fuerte | Opcional (transactions) | Siempre (ACID) |
| Consultas complejas (JOINs) | Limitadas ($lookup) | Nativas y optimizadas |

---

## Información que NO debería almacenarse en MongoDB

| Tipo de dato | Motivo | Dónde sí va |
|---|---|---|
| Datos transaccionales de negocio (estancias, pagos) | Requieren integridad referencial y ACID | MariaDB (relacional) |
| Catálogos (tipos de vehículo, tarifas) | Datos pequeños, pocas escrituras, muchas lecturas con FK | MariaDB |
| Información de residentes y vehículos (PII) | Datos sensibles; requieren control de acceso estricto y auditoría relacional | MariaDB con cifrado en reposo |
| Estados financieros y cierres mensuales | Requieren atomicidad y trazabilidad contable | MariaDB (con procedimientos transaccionales) |
| Datos de autenticación de usuarios | Credenciales y tokens; requieren seguridad estricta | MariaDB + Vault/gestor de secretos |

**Regla general:** MongoDB es un complemento para eventos y logs, NO un reemplazo del modelo relacional para los datos de negocio del estacionamiento.