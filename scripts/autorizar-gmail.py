#!/usr/bin/env python3
"""Autoriza una cuenta Gmail para EcoRuta y escribe variables privadas para Render."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sys
from time import monotonic
from urllib.error import URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import webbrowser

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/gmail.send"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


class Callback(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # La ruta de retorno contiene un código OAuth.

    def reply(self, status, message):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(message.encode())

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path != "/oauth2callback" or self.headers.get("Host") != self.server.host:
            return self.reply(404, "Ruta no encontrada.")
        params = parse_qs(url.query)
        state = params.get("state", [""])
        if len(state) != 1 or not state[0].isascii() or not secrets.compare_digest(state[0], self.server.state):
            return self.reply(400, "Solicitud OAuth inesperada.")
        code = params.get("code", [])
        if "error" in params or len(code) != 1:
            self.server.result = (None, "La cuenta no concedió el acceso a Gmail.")
            return self.reply(400, "No se concedió la autorización. Puedes cerrar esta pestaña.")
        self.server.result = (code[0], None)
        self.reply(200, "Permiso recibido. Revisa la terminal para confirmar que se guardó la autorización.")


def exchange(client, code, redirect, verifier):
    form = urlencode({
        "client_id": client["client_id"], "client_secret": client["client_secret"],
        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
        "code_verifier": verifier,
    }).encode()
    req = Request(TOKEN_URL, data=form, headers={"Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"})
    try:
        with build_opener(NoRedirect()).open(req, timeout=15) as res:
            payload = json.loads(res.read(128 * 1024))
    except (URLError, ValueError):
        raise SystemExit("Google no pudo completar la autorización. Revisa el cliente OAuth y vuelve a intentar.")
    if not isinstance(payload, dict) or not isinstance(payload.get("scope", ""), str):
        raise SystemExit("Google devolvió una respuesta OAuth no válida.")
    scopes = payload.get("scope", "").split()
    refresh = payload.get("refresh_token", "")
    if not isinstance(refresh, str) or not re.fullmatch(r"[A-Za-z0-9_~.+/=-]+", refresh) or (scopes and SCOPE not in scopes):
        raise SystemExit("Google no entregó un token de renovación con permiso gmail.send.")
    return refresh


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cliente", type=Path, help="JSON del cliente OAuth de tipo Aplicación de escritorio")
    parser.add_argument("--correo", required=True, help="Dirección Gmail que autorizas como remitente")
    parser.add_argument("--salida", type=Path, default=Path(".env.gmail"), help="Archivo nuevo. Por defecto .env.gmail")
    args = parser.parse_args()
    args.salida = args.salida.expanduser()
    if not re.fullmatch(r"[^\s@=]+@[^\s@=]+\.[^\s@=]+", args.correo, flags=re.ASCII):
        parser.error("Indica una dirección de correo válida.")
    if args.salida.is_symlink() or args.salida.exists():
        parser.error("El archivo de salida ya existe. Elige otro nombre.")
    try:
        client = json.loads(args.cliente.expanduser().read_text())["installed"]
        if not re.fullmatch(r"[A-Za-z0-9-]+\.apps\.googleusercontent\.com", client["client_id"]):
            raise ValueError
        if not re.fullmatch(r"[A-Za-z0-9_~-]+", client["client_secret"]):
            raise ValueError
    except (OSError, TypeError, KeyError, ValueError):
        parser.error("Elige el JSON de un cliente OAuth de Google de tipo Aplicación de escritorio.")
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    with HTTPServer(("127.0.0.1", 0), Callback) as server:
        server.host = f"127.0.0.1:{server.server_port}"
        server.state = secrets.token_urlsafe(32)
        server.result = None
        server.timeout = 1
        redirect = f"http://{server.host}/oauth2callback"
        url = AUTH_URL + "?" + urlencode({
            "client_id": client["client_id"], "redirect_uri": redirect,
            "response_type": "code", "scope": SCOPE, "access_type": "offline",
            "prompt": "consent", "login_hint": args.correo, "state": server.state,
            "code_challenge": challenge, "code_challenge_method": "S256",
        })
        print("Autoriza el permiso de envío en tu navegador con la cuenta indicada. No se enviará ningún correo.", flush=True)
        if not webbrowser.open(url):
            print(url, flush=True)
        end = monotonic() + 300
        while server.result is None and monotonic() < end:
            server.handle_request()
        if server.result is None:
            raise SystemExit("La autorización no se recibió en cinco minutos.")
        code, error = server.result
        if error:
            raise SystemExit(error)
    refresh = exchange(client, code, redirect, verifier)
    content = {
        "MAIL_TRANSPORT": "gmail_api",
        "GMAIL_USER": args.correo,
        "GMAIL_OAUTH_CLIENT_ID": client["client_id"],
        "GMAIL_OAUTH_CLIENT_SECRET": client["client_secret"],
        "GMAIL_OAUTH_REFRESH_TOKEN": refresh,
    }
    fd = os.open(args.salida, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        for key, value in content.items():
            out.write(f"{key}={value}\n")
    print(f"Autorización guardada en {args.salida}. Importa este archivo como variables privadas de Render.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
