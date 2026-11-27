"""Smoke test HTTP para una base nueva y desechable. No usar con datos reales."""
import argparse
import concurrent.futures
import json
import re
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url")
    parser.add_argument("--setup-env", type=Path, help="Archivo con CRM_SETUP_TOKEN")
    parser.add_argument("--secure-cookie", action="store_true")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    token = ""
    if args.setup_env:
        token = next(
            line.partition("=")[2] for line in args.setup_env.read_text().splitlines()
            if line.startswith("CRM_SETUP_TOKEN=")
        )

    def req(method, path, status=200, data=None, cookie=None, form=False, origin=None):
        headers = {}
        if cookie:
            headers["Cookie"] = cookie
        if origin:
            headers["Origin"] = origin
        payload = None
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            payload = (urlencode(data) if form else json.dumps(data)).encode()
        request = Request(base + path, data=payload, headers=headers, method=method)
        try:
            res = urlopen(request, timeout=15)
        except HTTPError as error:
            res = error
        with res:
            body = res.read()
            assert res.code == status, (method, path.split("/r/")[0], res.code, status)
            if res.headers.get_content_type() == "application/json":
                body = json.loads(body)
            elif res.headers.get_content_type() == "text/html":
                body = body.decode()
            return body, res.headers

    def login(email, password):
        _, headers = req("POST", "/api/login", data={"email": email, "password": password})
        return headers["Set-Cookie"].split(";")[0]

    assert req("GET", "/healthz")[0] == {"ok": 1}
    assert req("GET", "/livez")[0] == {"ok": 1}
    assert "EcoRuta CRM" in req("GET", "/")[0]
    assert req("GET", "/img/V01.jpg")[0].startswith(b"\xff\xd8")
    req("GET", "/.env", 404)
    req("GET", "/backend/data/ecoruta.db", 404)
    req("GET", "/api/data", 401)
    estado = req("GET", "/api/estado")[0]
    assert estado["necesitaConfiguracion"], "La base debe ser nueva para evitar tocar datos reales"
    assert estado["requiereTokenConfiguracion"] == bool(token)
    admin = {"nombre": "Ángela QA", "email": "admin@example.com", "password": "clave-admin-ecoruta"}
    if token:
        req("POST", "/api/setup", 403, data={**admin, "token": "erróneo"})
    _, headers = req("POST", "/api/setup", data={**admin, "token": token})
    assert ("; Secure" in headers["Set-Cookie"]) == args.secure_cookie
    assert "HttpOnly" in headers["Set-Cookie"]
    ad = headers["Set-Cookie"].split(";")[0]
    assert not req("GET", "/api/estado")[0]["necesitaConfiguracion"]
    req("POST", "/api/setup", 403, data={**admin, "token": token})
    req("POST", "/api/login", 401, data={**admin, "password": "incorrecta"})
    if args.secure_cookie:
        req("POST", "/api/logout", 403, data={}, cookie=ad, origin="https://example.org")
    assert req("GET", "/api/data", cookie=ad)[0]["me"]["nombre"] == admin["nombre"]

    adviser = {"nombre": "Jesús QA", "email": "asesor@example.com", "password": "clave-asesor-ecoruta"}
    req("POST", "/api/usuarios", data=adviser, cookie=ad)
    est = login(adviser["email"], adviser["password"])
    second = {**adviser, "nombre": "María QA", "email": "otra@example.com"}
    req("POST", "/api/usuarios", data=second, cookie=ad)
    other_adviser = login(second["email"], second["password"])
    data = req("GET", "/api/data", cookie=ad)[0]
    assert len(data["catalogo"]) == 9 and not data["clientes"] and not data["interacciones"]

    req("POST", "/api/catalogo/V06/disponible", 403, data={"disponible": False}, cookie=est)
    reco = {"tecnologia": "BEV", "presupuesto": 40000, "carga": "Si"}
    assert req("POST", "/api/recomendar", data=reco, cookie=est)[0]["vehiculo"]["id"] == "V06"
    req("POST", "/api/catalogo/V06/disponible", data={"disponible": False}, cookie=ad)
    assert req("POST", "/api/recomendar", data=reco, cookie=est)[0]["vehiculo"]["id"] == "V05"

    client = {
        "nombre": "Álex", "apellido": "Muñoz", "telefono": "+34 600 100 100",
        "email": "cliente@example.com", "asesor": adviser["nombre"], "origen": "Visita",
        "permiso": "Si", "canal": "Email", "compraDias": 22, **reco,
    }
    req("POST", "/api/clientes", 403, data=client, cookie=est)

    def add_client(data):
        return req("POST", "/api/clientes", data=data, cookie=ad)[0]["cliente"]

    other = {**client, "telefono": "+34 600 100 101", "email": "cliente2@example.com", "permiso": "No"}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        c, no = list(pool.map(add_client, [client, other]))
    assert c["id"] != no["id"] and c["compraDias"] == 22 and c["vehiculo"] == "V05"
    cid = c["id"]
    nid = no["id"]
    req("POST", "/api/clientes", 400, data=client, cookie=ad)
    edit = req("PUT", f"/api/clientes/{cid}", data={**client, "compraDias": 21}, cookie=ad)[0]
    assert edit["cliente"]["compraDias"] == 21

    req("POST", "/api/interacciones", data={"clienteId": cid, "resultado": "Pidió información"}, cookie=est)
    req("POST", "/api/interacciones", 400, data={"clienteId": nid, "resultado": "No consentido"}, cookie=est)
    req("POST", "/api/interacciones", 403, data={"clienteId": cid, "resultado": "Sin asignar"}, cookie=other_adviser)
    assert not req("GET", "/api/data", cookie=other_adviser)[0]["clientes"]
    scoped = req("GET", "/api/data", cookie=est)[0]
    assert any(i["clienteId"] == cid and i["resultado"] == "Pidió información" for i in scoped["interacciones"])
    assert next(c for c in scoped["clientes"] if c["id"] == nid)["email"] == ""

    req("PUT", "/api/plantilla", data={"plantilla": "Hola {nombre}, prueba el {vehiculo}."}, cookie=ad)
    preview, headers = req("GET", f"/api/correo/vista-previa?cliente={cid}&fecha=2026-12-05T11:00", cookie=ad)
    assert headers["X-Frame-Options"] == "SAMEORIGIN"
    assert "Hola Álex" in preview and "sábado 5 de diciembre a las 11:00" in preview.lower()
    states = req("POST", "/api/invitaciones", data={"ids": [cid, nid]}, cookie=ad)[0]["resultados"]
    assert [r["estado"] for r in states] == ["omitido", "sin_permiso"]
    req("POST", "/api/correo/prueba", 502, data={"to": "qa@example.com"}, cookie=ad)

    surveys = req("POST", "/api/encuestas", data={"ids": [cid, nid]}, cookie=ad)[0]["resultados"]
    assert [r["estado"] for r in surveys] == ["omitido", "sin_permiso"]
    path = urlsplit(re.search(r"https?://\S+", surveys[0]["detalle"])[0]).path
    resp, headers = req("GET", path)
    assert "Álex" in resp and headers["Referrer-Policy"] == "no-referrer"
    req("POST", path, data={"satisfaccion": 5, "nps": 10, "interes": "Sí", "comentario": "Cómodo y fácil"}, form=True)
    assert "Ya recibimos tu respuesta" in req("GET", path)[0]
    visible = req("GET", "/api/data", cookie=est)[0]
    encuesta = visible["encuestas"][0]
    assert encuesta["clienteId"] == cid and encuesta["respuestas"]["comentario"] == "Cómodo y fácil"
    assert len(visible["respuestas"]) == 1 and not visible["respuestas"][0]["leido"]
    assert "token" not in visible["respuestas"][0]
    req("POST", "/api/respuestas/leidas", data={}, cookie=est)
    assert req("GET", "/api/data", cookie=est)[0]["respuestas"][0]["leido"]

    req("DELETE", f"/api/clientes/{cid}", cookie=ad)
    req("GET", path, 404)
    admin_data = req("GET", "/api/data", cookie=ad)[0]
    assert not admin_data["encuestas"] and not admin_data["respuestas"]
    req("POST", "/api/logout", data={}, cookie=est)
    req("GET", "/api/data", 401, cookie=est)
    print("OK: salud, seguridad básica, roles, catálogo, clientes, concurrencia, invitaciones de demo, encuestas, historial y borrado.")


if __name__ == "__main__":
    main()
