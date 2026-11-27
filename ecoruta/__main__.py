import argparse
import logging
import os
from pathlib import Path
import sys

from .config import ConfigError, ROOT, Settings
from .crm import CRM
from .domain import RuleError


def main():
    parser = argparse.ArgumentParser(description="EcoRuta CRM")
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--init-db", action="store_true", help="Inicializar esquema de una base administrada por el CRM")
    operation.add_argument("--migrar-sqlite", type=Path, metavar="ARCHIVO", help="Importar una copia de SQLite a PostgreSQL vacío")
    args = parser.parse_args()
    try:
        settings = Settings.load()
        if args.init_db:
            if not settings.manage_schema:
                raise ConfigError("La administración del esquema está desactivada.")
            CRM(settings).db.prepare()
            print("Base de datos inicializada.")
        elif args.migrar_sqlite:
            counts = CRM(settings).db.import_sqlite(args.migrar_sqlite)
            for table, count in counts.items():
                print(f"{table}: {count}")
        else:
            os.chdir(ROOT)
            os.execv(sys.executable, [sys.executable, "-m", "streamlit", "run", str(ROOT / "streamlit_app.py"),
                                      "--server.address", settings.bind, "--server.port", str(settings.port)])
    except (ConfigError, RuleError) as error:
        print(error, file=sys.stderr)
        return 1
    except Exception as error:
        logging.error("No se completó la operación (%s). Revisa la conexión y los permisos.", type(error).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
