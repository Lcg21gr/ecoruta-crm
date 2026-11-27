from dataclasses import dataclass, field
from os import environ
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
IMAGES = ROOT / "frontend" / "img"
SCHEMA = ROOT / "backend" / "schema.sql"
NAME = "EcoRuta Madrid"


class ConfigError(ValueError):
    pass


def file_env(path):
    values = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                value = value.strip()
                if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                if key.strip().isidentifier():
                    values[key.strip()] = value
    return values


@dataclass(frozen=True)
class Settings:
    database_url: str = field(default="", repr=False)
    db_host: str = ""
    db_port: int = 5432
    db_name: str = "ecoruta"
    db_user: str = "ecoruta"
    db_password: str = field(default="", repr=False)
    db_sslmode: str = "prefer"
    db_transport: str = "auto"
    sqlite_path: Path = ROOT / "backend/data/ecoruta.db"
    public_url: str = ""
    setup_token: str = field(default="", repr=False)
    production: bool = False
    manage_schema: bool = True
    seed_demo: bool = False
    port: int = 8086
    bind: str = "127.0.0.1"
    gmail_user: str = ""
    gmail_password: str = field(default="", repr=False)
    from_name: str = NAME
    notify_email: str = ""
    smtp_host: str = "smtp.gmail.com"
    smtp_port: int = 465
    smtp_ssl: bool = True
    smtp_ca: str = ""

    @property
    def postgres(self):
        return bool(self.database_url or self.db_host)

    def validate(self):
        if self.production and not self.postgres:
            raise ConfigError("Configura PostgreSQL en producción para conservar los datos.")
        if self.db_transport not in ("auto", "tcp", "neon-websocket"):
            raise ConfigError("CRM_DB_TRANSPORT debe ser auto, tcp o neon-websocket.")
        if self.db_transport == "neon-websocket" and not self.database_url:
            raise ConfigError("El WebSocket de Neon requiere DATABASE_URL.")
        if self.public_url:
            url = urlsplit(self.public_url)
            if (
                url.scheme not in ("http", "https") or not url.hostname
                or url.username or url.password or url.query or url.fragment or url.path
            ):
                raise ConfigError("PUBLIC_URL debe ser el origen del CRM, sin ruta ni parámetros.")
            if self.production and url.scheme != "https":
                raise ConfigError("PUBLIC_URL debe usar HTTPS en producción.")
        elif self.production:
            raise ConfigError("Configura PUBLIC_URL con la URL pública HTTPS del CRM.")
        if self.setup_token and len(self.setup_token) < 32:
            raise ConfigError("CRM_SETUP_TOKEN debe tener al menos 32 caracteres.")
        return self

    @classmethod
    def load(cls, extra=None):
        values = file_env(ROOT / ".env") | {k: str(v) for k, v in (extra or {}).items()} | dict(environ)

        def val(key, default=""):
            return values.get(key, default).strip()

        def flag(key, default=False):
            return val(key, str(default)).lower() in {"1", "true", "yes"}

        def port(key, default):
            value = val(key, str(default))
            if not value.isdecimal() or not 1 <= int(value) <= 65535:
                raise ConfigError(f"{key} debe ser un puerto de 1 a 65535.")
            return int(value)

        http_port = port("PORT", 8086)
        prod = val("APP_ENV") == "production"
        gmail = val("GMAIL_USER")
        ssl_mode = flag("SMTP_SSL", True)
        return cls(
            database_url=val("DATABASE_URL"), db_host=val("DB_HOST"), db_port=port("DB_PORT", 5432),
            db_name=val("DB_NAME", "ecoruta"), db_user=val("DB_USER", "ecoruta"), db_password=val("DB_PASSWORD"),
            db_sslmode=val("DB_SSLMODE", "prefer"), db_transport=val("CRM_DB_TRANSPORT", "auto"),
            sqlite_path=Path(val("DB_PATH", str(cls.sqlite_path))),
            public_url=(val("PUBLIC_URL") or val("RENDER_EXTERNAL_URL") or ("" if prod else f"http://localhost:{http_port}")).rstrip("/"),
            setup_token=val("CRM_SETUP_TOKEN"), production=prod, manage_schema=flag("CRM_MANAGE_SCHEMA", not prod),
            seed_demo=flag("SEED_DEMO"), port=http_port, bind=val("BIND_HOST", "127.0.0.1"),
            gmail_user=gmail, gmail_password="".join(val("GMAIL_APP_PASSWORD").split()),
            from_name=val("MAIL_FROM_NAME", NAME), notify_email=val("NOTIFY_EMAIL", gmail),
            smtp_host=val("SMTP_HOST", "smtp.gmail.com"), smtp_port=port("SMTP_PORT", 465 if ssl_mode else 587),
            smtp_ssl=ssl_mode, smtp_ca=val("SMTP_CA_FILE"),
        ).validate()
