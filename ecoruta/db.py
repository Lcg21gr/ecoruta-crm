from contextlib import closing, contextmanager, suppress
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
from urllib.parse import urlsplit

from .config import SCHEMA, ConfigError
from .domain import now, RuleError
from .neon import LOCAL_PORT, is_neon_host, postgres_socket

SEED = Path(__file__).with_name("seed.json")
TABLES = {
    "usuarios": "id,nombre,email,rol,pass_hash,creado",
    "catalogo": "id,modelo,version,tec,precio,recarga,uso,base,disponible",
    "clientes": "id,nombre,apellido,telefono,email,origen,permiso,canal,tecnologia,presupuesto,compra_dias,carga,asesor,vehiculo,creado",
    "interacciones": "id,cliente_id,fecha,canal,evento,resultado,responsable,accion",
    "encuestas": "id,cliente_id,tipo,canal,enviada,estado,respuestas,respondida",
    "envios": "id,cliente_id,tipo,destinatario,asunto,estado,detalle,fecha,usuario",
    "config": "clave,valor",
    "enlaces": "id,token,tipo,cliente_id,encuesta_id,vehiculo,fecha_propuesta,creado,respondido,respuesta,resumen,leido",
}


class Query:
    def __init__(self, connection, postgres):
        self.connection = connection
        self.postgres = postgres

    def run(self, sql, args=()):
        if self.postgres:
            sql = sql.replace("?", "%s")
        return self.connection.execute(sql, args)

    def one(self, sql, args=()):
        row = self.run(sql, args).fetchone()
        return dict(row) if row is not None else None

    def all(self, sql, args=()):
        return [dict(row) for row in self.run(sql, args).fetchall()]

    def next_id(self, entity):
        if entity not in ("clientes", "encuestas"):
            raise ValueError("Contador no válido")
        row = self.one("UPDATE contadores SET ultimo=ultimo+1 WHERE entidad=? RETURNING ultimo", (entity,))
        if row is None:
            raise ConfigError("La base de datos no tiene inicializados sus contadores.")
        return f"{entity[0].upper()}{row['ultimo']:03d}"


class Database:
    def __init__(self, settings):
        self.settings = settings

    @contextmanager
    def _open(self):
        s = self.settings
        if s.postgres:
            import psycopg
            from psycopg.rows import dict_row

            options = {"connect_timeout": 8, "row_factory": dict_row}
            if s.database_url:
                try:
                    url = urlsplit(s.database_url)
                    host = url.hostname
                except ValueError:
                    raise ConfigError("DATABASE_URL debe ser una URL de PostgreSQL válida.") from None
                if url.scheme not in ("postgres", "postgresql") or not host:
                    raise ConfigError("DATABASE_URL debe ser una URL de PostgreSQL válida.")
                if s.db_transport == "neon-websocket" or (
                    s.db_transport == "auto" and s.production and is_neon_host(host)
                ):
                    with postgres_socket(host) as directory:
                        # libpq solo atraviesa el socket local. El cliente WebSocket
                        # cifra y valida el nombre del servidor al conectarse a Neon.
                        with closing(psycopg.connect(
                            s.database_url, host=directory, hostaddr="", port=LOCAL_PORT,
                            sslmode="disable", sslrootcert="", sslnegotiation="postgres",
                            channel_binding="disable", gssencmode="disable", **options,
                        )) as conn:
                            yield conn
                    return
                if s.production:
                    options.update(sslmode="verify-full", sslrootcert="system")
                with closing(psycopg.connect(s.database_url, **options)) as conn:
                    yield conn
                return
            with closing(psycopg.connect(
                host=s.db_host, port=s.db_port, dbname=s.db_name, user=s.db_user,
                password=s.db_password, sslmode=s.db_sslmode, **options,
            )) as conn:
                yield conn
            return
        s.sqlite_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with closing(sqlite3.connect(s.sqlite_path, timeout=8, isolation_level=None)) as conn:
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys=ON")
            yield conn

    @contextmanager
    def transaction(self, write=False):
        with self._open() as conn:
            q = Query(conn, self.settings.postgres)
            try:
                if write and q.postgres:
                    q.run("SELECT pg_advisory_xact_lock(420706810)")
                if not q.postgres:
                    q.run("BEGIN IMMEDIATE" if write else "BEGIN")
                yield q
                conn.commit()
            except BaseException:
                with suppress(Exception):
                    conn.rollback()
                raise

    def prepare(self):
        if not self.settings.manage_schema:
            with self.transaction() as q:
                q.one("SELECT ultimo FROM contadores LIMIT 1")
            return
        with self.transaction(write=True) as q:
            initialize(q, self.settings.seed_demo)

    def import_sqlite(self, source):
        if not self.settings.postgres:
            raise RuleError("El destino de la migración debe ser PostgreSQL.")
        if not source.is_file():
            raise RuleError("El archivo SQLite de origen no existe.")
        with self.transaction(write=True) as target, closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as src:
            src.execute("BEGIN")
            if src.execute("PRAGMA quick_check").fetchone()[0] != "ok" or src.execute("PRAGMA foreign_key_check").fetchone():
                raise RuleError("SQLite no pasó la verificación de integridad.")
            schema(target)
            for table in (*TABLES, "contadores", "sesiones"):
                if target.one(f"SELECT 1 FROM {table} LIMIT 1"):
                    raise RuleError(f"El destino no está vacío ({table}). No se modificaron los datos.")
            counts = {}
            for table, columns in TABLES.items():
                sqlite_columns = columns.replace("id,", "rowid AS id,", 1) if table == "enlaces" else columns
                rows = src.execute(f"SELECT {sqlite_columns} FROM {table}")
                marks = ",".join("?" for _ in columns.split(","))
                counts[table] = 0
                for row in rows:
                    target.run(f"INSERT INTO {table} ({columns}) VALUES ({marks})", row)
                    counts[table] += 1
                if target.one(f"SELECT count(*) AS n FROM {table}")["n"] != counts[table]:
                    raise RuleError(f"No coinciden los registros migrados de {table}.")
            for table in ("usuarios", "interacciones", "envios", "enlaces"):
                target.run(f"SELECT setval(pg_get_serial_sequence('{table}','id'), GREATEST(COALESCE(MAX(id),1),1), COUNT(*)>0) FROM {table}")
            init_counters(target)
            return counts


def schema(q):
    content = SCHEMA.read_text(encoding="utf-8")
    auto_id = "BIGSERIAL PRIMARY KEY" if q.postgres else "INTEGER PRIMARY KEY AUTOINCREMENT"
    link_id = "id BIGSERIAL UNIQUE NOT NULL," if q.postgres else ""
    for sql in content.replace("__AUTO_ID__", auto_id).replace("__LINK_ID__", link_id).split(";"):
        if sql.strip():
            q.run(sql)


def init_counters(q):
    for table in ("clientes", "encuestas"):
        last = q.one(f"SELECT COALESCE(MAX(CAST(SUBSTR(id,2) AS BIGINT)),0) AS n FROM {table}")["n"]
        q.run("INSERT INTO contadores (entidad,ultimo) VALUES (?,?) ON CONFLICT (entidad) DO NOTHING", (table, last))


def initialize(q, seed_demo=False):
    schema(q)
    seed = json.loads(SEED.read_text(encoding="utf-8"))
    q.run("INSERT INTO config (clave,valor) VALUES ('plantillaInvitacion',?) ON CONFLICT (clave) DO NOTHING", (seed["template"],))
    if not q.one("SELECT id FROM catalogo LIMIT 1"):
        for row in seed["cat"]:
            q.run(f"INSERT INTO catalogo ({TABLES['catalogo']}) VALUES (?,?,?,?,?,?,?,?,1)", row)
        if seed_demo:
            insert_demo(q, seed)
    init_counters(q)


def insert_demo(q, seed):
    def excel_date(value):
        return datetime.fromtimestamp((value - 25569) * 86400, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    for name in ("Ana Demo", "Luis Demo"):
        q.run("INSERT INTO usuarios (nombre,rol,creado) VALUES (?,'estandar',?)", (name, now()))
    for i, row in enumerate(seed["cli"], start=1):
        cid, name, *fields = row
        q.run(
            f"INSERT INTO clientes ({TABLES['clientes']}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (cid, name, "Demo", f"+34 600 000 0{i:02d}", f"{name.lower()}.demo@example.com", *fields, excel_date(46327)),
        )
    for cid, date, *fields in seed["ints"]:
        q.run(
            "INSERT INTO interacciones (cliente_id,fecha,canal,evento,resultado,responsable,accion) VALUES (?,?,?,?,?,?,?)",
            (cid, excel_date(date), *fields),
        )
