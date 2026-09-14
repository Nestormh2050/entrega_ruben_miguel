# MariaDB — Guía de instalación y levantamiento

Documentación para instalar y levantar **MariaDB** en dos entornos:

- **Windows (nativo)** — instalación del servicio directamente en el sistema.
- **Docker** — despliegue aislado y reproducible con `docker-compose`.

> Ambos métodos exponen el mismo puerto del host (**`3305`**) para que las
> aplicaciones cliente usen la misma cadena de conexión sin importar el entorno.
> **Ejecuta solo un método a la vez** para evitar el conflicto de puerto.

---

## Requisitos

| Entorno | Requisitos |
|---|---|
| Windows nativo | Windows 10/11, permisos de administrador, PowerShell |
| Docker | Docker Desktop (o Docker Engine + Compose v2) |

---

## 1. Instalación en Windows (nativo)

### 1.1 Instalación automática (script)

El script `windows/install-mariadb.ps1` descarga el MSI oficial de MariaDB,
verifica su hash SHA256 e instala el servicio de forma silenciosa.

```powershell
# Ejecutar en una consola de PowerShell COMO ADMINISTRADOR
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\windows\install-mariadb.ps1 -RootPassword "<TU_PASSWORD>"
```

Parámetros disponibles:

| Parámetro | Default | Descripción |
|---|---|---|
| `-Version` | `12.3.3` | Versión de MariaDB a instalar |
| `-ServiceName` | `MariaDB` | Nombre del servicio de Windows |
| `-Port` | `3305` | Puerto TCP |
| `-RootPassword` | *(obligatorio)* | Contraseña del usuario `root` |

### 1.2 Instalación manual (MSI)

1. Descarga el MSI oficial:
   `https://downloads.mariadb.org/rest-api/mariadb/<VERSION>/mariadb-<VERSION>-winx64.msi`
2. Instala de forma silenciosa desde una consola **como administrador**:

   ```powershell
   msiexec /i "mariadb-12.3.3-winx64.msi" SERVICENAME=MariaDB PASSWORD="<TU_PASSWORD>" PORT=3305 /qn
   ```

3. El servicio queda corriendo automáticamente.

### 1.3 Verificación

```powershell
# Servicio en ejecución
Get-Service MariaDB

# Puerto a la escucha
Get-NetTCPConnection -State Listen -LocalPort 3305

# Conexión
mariadb --host=127.0.0.1 --port=3305 --user=root --password="<TU_PASSWORD>" `
        -e "SELECT VERSION(), @@port;"
```

### 1.4 Operación del servicio

```powershell
Start-Service MariaDB        # iniciar
Stop-Service MariaDB         # detener
Restart-Service MariaDB      # reiniciar
Set-Service MariaDB -StartupType Manual   # no arrancar al iniciar Windows
```

### 1.5 Agregar el cliente al PATH (opcional)

```powershell
$bin = "C:\Program Files\MariaDB 12.3\bin"
$path = [Environment]::GetEnvironmentVariable('Path','User')
if (($path -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', "$path;$bin", 'User')
}
```

Cierra y reabre la terminal para aplicar el cambio.

### 1.6 Datos y configuración

| Elemento | Ruta |
|---|---|
| Directorio de datos | `C:\Program Files\MariaDB 12.3\data\` |
| Archivo de configuración | `C:\Program Files\MariaDB 12.3\data\my.ini` |
| Cliente | `C:\Program Files\MariaDB 12.3\bin\mariadb.exe` |

---

## 2. Levantamiento con Docker

### 2.1 Preparar variables de entorno

```bash
cp .env.example .env
# Edita .env y define tus credenciales
```

Contenido de `.env`:

```dotenv
MARIADB_ROOT_PASSWORD=tu_password_seguro
MARIADB_DATABASE=appdb
MARIADB_USER=appuser
MARIADB_PASSWORD=tu_password_de_app
HOST_PORT=3305
```

### 2.2 Levantar el contenedor

```bash
docker compose up -d
```

### 2.3 Verificación

```bash
docker compose ps
docker compose logs -f mariadb
docker exec -it mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT VERSION();"
```

### 2.4 Operación

```bash
docker compose stop      # detener sin borrar datos
docker compose start     # volver a levantar
docker compose down      # eliminar contenedor (los datos persisten en el volumen)
docker compose down -v   # eliminar contenedor Y datos (¡destructivo!)
```

Los datos persisten en el volumen Docker `mariadb_data`.

---

## 3. Cadenas de conexión

| Entorno | Host | Puerto | Usuario | Base de datos |
|---|---|---|---|---|
| Windows nativo | `127.0.0.1` | `3305` | `root` | *(todas)* |
| Docker | `127.0.0.1` | `3305` | `root` / `appuser` | `appdb` |

**JDBC**

```
jdbc:mariadb://127.0.0.1:3305/<BASE_DE_DATOS>
```

**Python (SQLAlchemy)**

```python
mariadb+mariadbconnector://<USUARIO>:<PASSWORD>@127.0.0.1:3305/<BASE_DE_DATOS>
```

---

## 4. Seguridad — IMPORTANTE

- **Nunca** subas el archivo `.env` ni contraseñas reales al repositorio.
- El `.gitignore` incluido ya excluye `.env` y directorios de datos.
- Usa **placeholders** en la documentación y comparte las credenciales por un canal seguro.
- Cambia la contraseña de `root` por defecto inmediatamente después de instalar.
- Para producción, crea un usuario con privilegios limitados en lugar de usar `root`.

---

## 5. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| El puerto 3305 está ocupado | Otro servicio o instancia previa | `Get-NetTCPConnection -State Listen -LocalPort 3305` y detén el proceso |
| `Access denied for user 'root'` | Contraseña incorrecta | Verifica la contraseña usada al instalar |
| El contenedor no levanta | Puerto del host ocupado | Cambia `HOST_PORT` en `.env` |
| El servicio no inicia | `my.ini` mal formado o datos corruptos | Revisa el Visor de eventos de Windows y `my.ini` |

---

## Estructura del repositorio

```
mariadb-docs/
├── README.md
├── docker-compose.yml
├── .env.example
├── .gitignore
└── windows/
    └── install-mariadb.ps1
```
