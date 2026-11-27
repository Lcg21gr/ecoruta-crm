# EcoRuta CRM

CRM de EcoRuta Madrid en Python 3.12 y Streamlit. Conserva usuarios, clientes, historial, segmentación, recomendación, catálogo, test drives y encuestas. El correo sale por Gmail SMTP con **contraseña de aplicación**. En producción, PostgreSQL conserva los datos fuera del servidor web.

## Streamlit Community Cloud con Neon

1. Sube a la rama del repositorio los cambios de la versión Python. Puedes mantener el repositorio privado y conceder a Streamlit acceso a él. Nunca subas .env, archivos de secretos, bases de datos ni respaldos.
2. En Community Cloud, elige **Create app → Yup, I have an app**, usa el repositorio existente y selecciona la rama que contiene los cambios. Usa **streamlit_app.py** como archivo principal. Community Cloud instalará requirements.txt. No usa Docker ni pide un puerto. [Documentación de despliegue](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/deploy)
3. Elige el nombre de la URL y abre **Advanced settings → Secrets**. Pega los valores en formato TOML, sin sección entre corchetes. PUBLIC_URL debe coincidir con tu URL real y no debe llevar una ruta.

    ~~~toml
    APP_ENV = "production"
    CRM_MANAGE_SCHEMA = "0"
    SEED_DEMO = "0"
    PUBLIC_URL = "https://nombre-de-tu-app.streamlit.app"
    DATABASE_URL = "postgresql://usuario-limitado:CLAVE@HOST/base?sslmode=verify-full&channel_binding=require"
    GMAIL_USER = "tu-cuenta@gmail.com"
    GMAIL_APP_PASSWORD = "Contraseña de aplicación de esa cuenta"
    SMTP_HOST = "smtp.gmail.com"
    SMTP_PORT = "587"
    SMTP_SSL = "0"
    ~~~

4. Pulsa **Deploy**. Entra con tu usuario del CRM. Si ya existe la base de EcoRuta en Neon, no la vuelvas a importar, no actives el catálogo de demostración y utiliza la cadena de conexión del usuario de ejecución, no la del propietario. Si la base es nueva y no hay administrador, crea un secreto CRM_SETUP_TOKEN de al menos 32 caracteres después de inicializar el esquema.
5. Verifica los clientes en el panel y que la función de correo esté disponible. Las invitaciones y encuestas nuevas usan enlaces del tipo /?r=TOKEN. Para que un cliente sin cuenta de Streamlit pueda contestar, la app necesita visibilidad pública en Community Cloud. El acceso al panel sigue protegido por el login del CRM. Una app privada en Community Cloud agrega su propio control de acceso a **todas** las URLs, incluso la de los formularios. [Secretos de Community Cloud](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/secrets-management)

El correo se configura en **Secrets**, no en GitHub. Con el puerto 587 se usa STARTTLS y se valida el certificado. Para usar TLS desde el inicio, configura SMTP_PORT = "465" y SMTP_SSL = "1". La compatibilidad con SMTP depende de la salida de red del proveedor y debe comprobarse desde la app desplegada. Una pestaña nueva o una recarga completa pueden pedir el acceso al CRM otra vez. Los enlaces antiguos /r/TOKEN conservan su token en la base, pero para abrirlos en Community Cloud hay que usar la nueva URL /?r=TOKEN.

## Ejecutar en Docker Compose

Copia .env.docker.example a .env.docker, define POSTGRES_PASSWORD y CRM_SETUP_TOKEN con valores diferentes y guárdalo fuera de Git. Opcionalmente configura el correo en .env tomando .env.example como referencia. Después ejecuta lo siguiente.

~~~bash
docker compose --env-file .env.docker up -d --build
~~~

Abre http://localhost:8086. Compose conserva PostgreSQL 16 y publica el puerto 8086 solo en el equipo local. Si tienes una instalación Docker anterior, usa el mismo proyecto y volumen de PostgreSQL para conservar los datos. No ejecutes down -v sobre la instancia existente.

Para un servidor propio con dominio y Caddy, define CRM_DOMAIN y usa los dos archivos Compose.

~~~bash
docker compose --env-file .env.docker -f compose.yaml -f compose.https.yaml up -d --build
~~~

## Ejecutar local en macOS o Linux

Instala Python 3.12. En macOS abre iniciar-crm.command o ejecuta estos comandos.

~~~bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m ecoruta
~~~

Si no hay una conexión PostgreSQL en .env, el CRM utiliza SQLite. La ruta predeterminada es backend/data/ecoruta.db. Si quieres trabajar con tu SQLite anterior, apunta DB_PATH a una copia verificable de ese archivo. Un cambio local en SQLite no se refleja en Neon.

## Importar SQLite solo a un PostgreSQL vacío

Usa el comando con una **copia** del SQLite y una conexión PostgreSQL con permisos de inicialización. La importación rechaza una base con registros, conserva las cuentas, clientes, historial, catálogo, encuestas y enlaces, y reinicia los contadores según los identificadores importados. Las sesiones se vuelven a iniciar. No lo ejecutes sobre la base de Neon que ya contiene los clientes.

~~~bash
.venv/bin/python -m ecoruta --migrar-sqlite /ruta/a/copia.db
~~~

Para inicializar una base nueva sin importar datos, usa python -m ecoruta --init-db con un rol propietario y CRM_MANAGE_SCHEMA=1. En producción cambia después a un rol limitado con CRM_MANAGE_SCHEMA=0. El código Perl y el HTML anterior se conservan como referencia y ya no forman parte del despliegue. Las fotos y el esquema originales sí se reutilizan.
