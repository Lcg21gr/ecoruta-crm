"""Transporta PostgreSQL por el WebSocket TLS oficial de Neon."""

from contextlib import contextmanager, suppress
import logging
from pathlib import Path
import re
import socket
import ssl
from tempfile import TemporaryDirectory
from threading import Event, Thread

from .config import ConfigError

LOCAL_PORT = 5432
OPEN_TIMEOUT = 7
CLOSE_TIMEOUT = 1
CHUNK = 16384
NEON_HOST = re.compile(r"ep-[a-z0-9-]+(?:\.[a-z0-9-]+)+\.neon\.tech", re.ASCII)
LOG = logging.getLogger(__name__)


def is_neon_host(host):
    return bool(host and NEON_HOST.fullmatch(host))


def _forward(stream, ws):
    from websockets.exceptions import ConnectionClosed

    def outgoing():
        try:
            while chunk := stream.recv(CHUNK):
                ws.send(chunk)
        except (OSError, ConnectionClosed):
            pass
        finally:
            # 1000 is the normal close when libpq ends the session.
            with suppress(OSError, ConnectionClosed):
                ws.close()

    sender = Thread(target=outgoing, name="ecoruta-pg-to-neon", daemon=True)
    sender.start()
    try:
        for packet in ws:
            if not isinstance(packet, bytes):
                raise ValueError("Neon devolvió una trama inesperada.")
            stream.sendall(packet)
    finally:
        with suppress(OSError):
            stream.shutdown(socket.SHUT_RDWR)
        sender.join(timeout=CLOSE_TIMEOUT + 1)


def _serve(listener, endpoint, stop):
    from websockets.sync.client import connect

    try:
        while not stop.is_set():
            try:
                stream, _ = listener.accept()
                break
            except TimeoutError:
                continue
        else:
            return
        with stream, connect(
            endpoint, ssl=ssl.create_default_context(), proxy=None,
            open_timeout=OPEN_TIMEOUT, close_timeout=CLOSE_TIMEOUT,
        ) as ws:
            _forward(stream, ws)
    except Exception as error:
        # No registrar la URL de PostgreSQL ni cargas del protocolo.
        LOG.warning("Falló el transporte WebSocket de Neon (%s).", type(error).__name__)


@contextmanager
def postgres_socket(host):
    if not is_neon_host(host):
        raise ConfigError("El transporte WebSocket requiere un endpoint oficial de Neon.")
    if not hasattr(socket, "AF_UNIX"):
        raise ConfigError("Este equipo no admite el socket local del transporte Neon. Usa CRM_DB_TRANSPORT=tcp.")
    # El directorio es privado y único por conexión. No se abre ningún puerto TCP local.
    with TemporaryDirectory(prefix="eco-neon-", dir="/tmp") as directory:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(Path(directory) / f".s.PGSQL.{LOCAL_PORT}"))
            listener.listen(1)
            listener.settimeout(0.2)
            stop = Event()
            worker = Thread(target=_serve, name="ecoruta-neon", args=(listener, f"wss://{host}/v2", stop), daemon=True)
            worker.start()
            try:
                yield directory
            finally:
                stop.set()
                worker.join(timeout=OPEN_TIMEOUT + CLOSE_TIMEOUT + 2)
