# EcoRuta CRM

CRM comercial de EcoRuta Madrid. Mantiene el catálogo HEV/PHEV/BEV, recomendaciones según disponibilidad, tecnología y presupuesto, clientes y asesores, permisos de contacto, historial, invitaciones a pruebas de conducción, encuestas y exportación CSV.

El backend sigue en Perl y sirve la web y la API desde el mismo origen. Docker usa Starman y PostgreSQL 16. El arranque nativo en macOS sigue disponible con SQLite y `iniciar-crm.command`. Los dos modos usan bases separadas. Después de migrar, usa solo PostgreSQL para registrar cambios que quieras llevar al servidor.

## Arranque con Docker Compose

Requiere Docker con Compose moderno. En macOS, abre Docker Desktop antes de ejecutar los comandos.

Si aún no existe `.env.docker`, genéralo sin imprimir las claves:

```sh
( umask 077; set -C; printf 'POSTGRES_PASSWORD=%s\nCRM_SETUP_TOKEN=%s\n' \
    "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .env.docker )
```

- **Conservar datos existentes:** sigue primero la migración de la sección siguiente.
- **Instalación nueva:** ejecuta `docker compose --env-file .env.docker up -d --build --wait`. El catálogo se carga automáticamente y los clientes de ejemplo no se cargan salvo que pongas `SEED_DEMO=1` en una instalación nueva.

Abre **http://localhost:8086**. Si no hay administrador, el formulario pide el token `CRM_SETUP_TOKEN`. Si migraste un administrador existente, inicia sesión con su correo y contraseña habituales. Para registrar clientes en una instalación nueva, crea primero un usuario estándar desde **Equipo y correo**.

El servicio web queda ligado a localhost y PostgreSQL no publica el puerto 5432. El volumen `postgres_data` conserva los registros al recrear o detener los contenedores. No uses `docker compose down -v` para detener una instalación con datos.

`/livez` indica que el proceso web responde y `/healthz` comprueba la conexión a la base.

## Migrar desde SQLite a PostgreSQL

Haz la migración antes del primer arranque de la aplicación contra el destino. La base PostgreSQL debe estar vacía. El importador compara el conteo por tabla, rechaza sobrescribir registros y no modifica el original. Conserva usuarios y hashes de contraseña, catálogo, clientes, historial, encuestas, enlaces, envíos y plantilla. No copia las sesiones web.

En el corte definitivo, deja de registrar cambios en SQLite antes de tomar la copia. Si SQLite es ya una copia histórica y hubo cambios en PostgreSQL, usa un respaldo PostgreSQL para mover esos cambios.

```sh
umask 077
mkdir -p backups
SNAPSHOT="$PWD/backups/ecoruta-$(date +%Y%m%d-%H%M%S).db"
sqlite3 backend/data/ecoruta.db ".backup '$SNAPSHOT'"
sqlite3 "$SNAPSHOT" 'PRAGMA journal_mode=DELETE; PRAGMA quick_check;'
docker compose --env-file .env.docker up -d --wait db
docker compose --env-file .env.docker build crm
docker compose --env-file .env.docker run --rm --no-deps \
  --user "$(id -u):$(id -g)" \
  --volume "$SNAPSHOT:/tmp/origen.db:ro" crm --migrar-sqlite /tmp/origen.db
docker compose --env-file .env.docker up -d --wait crm
```

Los enlaces de respuesta conservan su token. Los correos que ya salieron seguirán apuntando al dominio escrito en el momento del envío. Si cambias de dominio, conserva el anterior apuntando al CRM o reenvía las invitaciones que hagan falta.

## Despliegue

### En una VM Linux con Docker Compose

Esta opción ejecuta el mismo conjunto de servicios en el servidor. Como candidata gratuita, Oracle Cloud ofrece instancias *Always Free*. Está sujeto a disponibilidad en la región y Oracle puede recuperar instancias inactivas. [Condiciones de Oracle Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

1. Instala Docker y Compose en la VM. Copia el código sin respaldos ni archivos de entorno. Crea `.env.docker` en la VM, con claves propias y `CRM_DOMAIN=crm.tudominio.com`. Configura el correo en un `.env` aparte con permisos 600.
2. Apunta el DNS del dominio a la IP de la VM. Permite tráfico entrante TCP a 80 y 443 en la nube y en el firewall de la VM. El puerto 443/UDP es opcional para HTTP/3. No publiques el puerto directo del CRM ni el de PostgreSQL.
3. Si vas a conservar datos, migra o restaura la base antes de levantar el servicio web. Para SQLite, usa los pasos anteriores hasta el comando de importación. Después ejecuta:

```sh
docker compose --env-file .env.docker -f compose.yaml -f compose.https.yaml up -d --build --wait
```

Caddy solicita y renueva el certificado. Verifica el sitio desde la URL pública, confirma el acceso con los roles y envía un correo de prueba solo a un buzón propio. Luego prueba el botón de respuesta de una encuesta de prueba para confirmar que apunta al dominio correcto.

### Sin administrar una VM, Neon Free con un servicio web externo

**Koyeb ya no ofrece el alta gratuita a cuentas nuevas.** Los pasos de Koyeb aplican a organizaciones que ya conservan un plan compatible. Para una cuenta nueva, Render Free puede alojar el contenedor y conectarse a Neon, pero el correo debe usar una integración HTTPS porque el plan gratuito de Render bloquea los puertos SMTP. [Anuncio oficial de Koyeb](https://www.koyeb.com/blog/koyeb-is-joining-mistral-ai-to-build-the-future-of-ai-infrastructure), [Límites de Render Free](https://render.com/docs/free).

**Render Free con una base ya importada.** Crea un Web Service con runtime Docker, selecciona Free y usa `/livez` como ruta de salud. Configura `APP_ENV=production`, `CRM_MANAGE_SCHEMA=0` y `DATABASE_URL` como secreto con un usuario de PostgreSQL limitado a las tablas y secuencias del CRM. Con ese ajuste de esquema, las migraciones se aplican por separado con un usuario propietario. Si no defines `PUBLIC_URL`, EcoRuta usa automáticamente `RENDER_EXTERNAL_URL`. No configures Gmail SMTP en el plan gratuito. [Web Services de Render](https://render.com/docs/web-services), [Variables de Render](https://render.com/docs/environment-variables).

Koyeb puede construir este `Dockerfile` desde GitHub y terminar HTTPS. Usa Neon para persistir. El contenedor gratuito de Koyeb no admite volúmenes y se suspende después de una hora sin tráfico. La primera visita puede tardar. Es una opción para pruebas o un piloto, no una garantía de disponibilidad para operación comercial. [Instancias de Koyeb](https://www.koyeb.com/docs/reference/instances), [Plan gratuito de Neon](https://neon.com/blog/neon-free-plan-1-gb-per-project).

1. Crea una base PostgreSQL 16 en Neon. Si vas a migrar, importa antes del primer despliegue, usando el endpoint directo de Neon. En un archivo privado fuera del repositorio guarda `DATABASE_URL=postgresql://…` con `sslmode=verify-full` y conserva `channel_binding=require` si viene en la cadena.
2. Si tu origen es SQLite, utiliza la imagen Docker para importar la copia de seguridad a la base vacía. Elige como archivo el snapshot indicado arriba y como archivo de entorno una ruta privada legible por el CLI local.

```sh
docker build -t ecoruta-crm:local .
docker run --rm --env-file /ruta/privada/neon.env \
  --user "$(id -u):$(id -g)" \
  --volume "$SNAPSHOT:/tmp/origen.db:ro" ecoruta-crm:local --migrar-sqlite /tmp/origen.db
```

3. Sube solo el código a un repositorio y conecta el Web Service gratuito de Koyeb con el constructor Dockerfile. Publica el puerto 8080 y enruta `/` a ese puerto. Configura la comprobación HTTP en `/livez`, que no mantiene despierta la base por sí sola. [Despliegue desde GitHub](https://www.koyeb.com/docs/build-and-deploy/deploy-with-git), [Health checks](https://www.koyeb.com/docs/run-and-scale/health-checks).
4. Configura como variables o secretos de Koyeb:

| Variable | Valor |
| --- | --- |
| `APP_ENV` | `production` |
| `PORT` | `8080` |
| `PUBLIC_URL` | Dirección HTTPS pública asignada al servicio, sin ruta final |
| `DATABASE_URL` | Cadena PostgreSQL de Neon, con TLS y verificación |
| `CRM_SETUP_TOKEN` | Token aleatorio de 32 caracteres o más si aún no existe un administrador |
| `GMAIL_USER`, `GMAIL_APP_PASSWORD` | Cuenta remitente y contraseña de aplicación, si se enviará correo |
| `SMTP_SSL`, `SMTP_PORT` | `0` y `587` para STARTTLS |

Koyeb recomienda 587 para SMTP cifrado. Render Free bloquea 465 y 587, por lo que el envío Gmail directo no funciona allí con esta configuración. Revisa que los términos, la región y el acceso sean adecuados antes de alojar datos comerciales. [Puertos en Koyeb](https://www.koyeb.com/docs/faqs/general), [Límites de Render Free](https://render.com/docs/free).

## Correo y copias de seguridad

El correo es opcional. En Compose toma la configuración de `.env` si existe. El modelo está en `.env.example`. El valor de `PUBLIC_URL` se usa en invitaciones, encuestas y avisos. Usa HTTPS en internet. Con una URL local, los clientes no podrán abrir los enlaces desde otro equipo. Los envíos masivos deben probarse primero con un destinatario propio. No se requiere exponer la base para que los formularios de respuesta funcionen.

Para respaldar PostgreSQL de Compose, crea un archivo fuera de la imagen con permisos privados:

```sh
umask 077
mkdir -p backups
docker compose --env-file .env.docker exec -T db \
  pg_dump -U ecoruta -d ecoruta --format=custom --exclude-table-data=public.sesiones \
  > "backups/ecoruta-$(date +%Y%m%d-%H%M%S).dump"
```

Conserva una copia fuera del servidor y comprueba la restauración en una base vacía antes de cambiar DNS. Usa `pg_restore --exit-on-error --single-transaction --no-owner --no-privileges -d <base-vacía> <archivo.dump>`. No incluyas `.env`, `.env.docker`, el SQLite original ni respaldos en Git.

## Verificación

`tests/smoke.py` usa solo la biblioteca estándar de Python. Ejecútalo **solo contra una base nueva, desechable, sin datos demo ni correo real**. Crea un administrador, ejercita los permisos, crea clientes en paralelo y comprueba recomendación, historial, invitaciones omitidas, encuestas públicas y borrado.

```sh
python3 tests/smoke.py http://localhost:8086 --setup-env .env.docker
```

En un entorno nativo sin token omite `--setup-env`. Para comprobar que el servidor marca la cookie como segura, añade `--secure-cookie` al ejecutar contra un entorno configurado con HTTPS.
