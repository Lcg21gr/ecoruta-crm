"""Integración HTTP con una base vacía y la simulación local de Gmail."""
import argparse
from email import message_from_string, policy
import json
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import re
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("crm_url")
    parser.add_argument("simulation_url")
    args = parser.parse_args()
    base = args.crm_url.rstrip("/")
    mock = args.simulation_url.rstrip("/")
    if any(urlsplit(u).hostname != "127.0.0.1" for u in (base, mock)):
        parser.error("La prueba solo admite CRM y Gmail de prueba en loopback")
    cookie = ""

    def req(path, data=None, status=200, form=False, auth=True, base_url=base):
        headers = {"Cookie": cookie} if cookie and auth else {}
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            data = (urlencode(data) if form else json.dumps(data)).encode()
        try:
            res = urlopen(Request(base_url + path, data=data, headers=headers), timeout=12)
        except HTTPError as ex:
            res = ex
        with res:
            assert res.status == status, (path.split("/r/")[0], res.status, status)
            return (json.load(res) if res.headers.get_content_type() == "application/json" else res.read().decode(), res.headers)

    assert req("/api/estado")[0]["necesitaConfiguracion"], "Usa solo una base desechable."
    _, headers = req("/api/setup", dict(nombre="QA Admin", email="admin@example.com", password="clave-qa-ecoruta"))
    cookie = headers["Set-Cookie"].split(";")[0]
    mail = req("/api/data")[0]["correo"]
    assert mail == {"configurado": True, "remitente": "qa@example.test", "transporte": "gmail_api"}
    req("/api/usuarios", dict(nombre="QA Asesor", email="asesor@example.com", password="clave-qa-asesor"))
    _, headers = req("/api/login", dict(email="asesor@example.com", password="clave-qa-asesor"), auth=False)
    admin_cookie, cookie = cookie, headers["Set-Cookie"].split(";")[0]
    req("/api/correo/prueba", {"to":"prueba@example.test"}, status=403)
    cookie = admin_cookie

    req("/api/correo/prueba", {"to":"prueba@example.test"})
    failure, _ = req("/api/correo/prueba", {"to":"temporal@example.test"}, status=502)
    assert "carpeta Enviados" in failure["error"] and "fixture" not in failure["error"]
    limited, _ = req("/api/correo/prueba", {"to":"limite@example.test"}, status=502)
    assert "límite temporal" in limited["error"]

    client = {
        "nombre":"Álex","apellido":"Prueba","telefono":"+34 600 123 987","email":"cliente@example.test",
        "asesor":"QA Asesor","origen":"Visita","permiso":"Si","canal":"Email","tecnologia":"BEV",
        "presupuesto":33000,"compraDias":10,"carga":"Si",
    }
    cid = req("/api/clientes", client)[0]["cliente"]["id"]
    result = req("/api/invitaciones", {"ids":[cid], "fecha":"2099-12-05T11:00"})[0]
    assert result["resultados"][0]["estado"] == "enviado"

    def results():
        return req("/__test/results", auth=False, base_url=mock)[0]

    inv = message_from_string(results()["messages"][-1], policy=policy.default)
    assert "Álex" in str(inv["Subject"])
    assert any(p.get_content_type() == "image/jpeg" and p["Content-ID"] == "<vehiculo>" for p in inv.walk())
    plain = inv.get_body(preferencelist=("plain",)).get_content()
    path = re.search(r"/r/[0-9a-f]{32}", plain)[0]
    req(path, dict(opcion="confirmo"), form=True, auth=False)
    for _ in range(30):
        if results()["accepted"] >= 3:
            break
        time.sleep(.1)
    assert results()["accepted"] == 3, "Falta el correo de aviso al asesor"
    assert any(i["clienteId"] == cid and i["evento"] == "Cita confirmada" for i in req("/api/data")[0]["interacciones"])
    result = req("/api/encuestas", {"ids":[cid]})[0]
    assert result["resultados"][0]["estado"] == "enviado"
    assert base + "/r/" in message_from_string(results()["messages"][-1], policy=policy.default).get_body(preferencelist=("plain",)).get_content()
    other = req("/api/clientes", {**client, "nombre":"Otro", "telefono":"+34 600 123 986", "email":"temporal@example.test"})[0]["cliente"]["id"]
    for route in ("/api/invitaciones", "/api/encuestas"):
        result = req(route, {"ids":[other]})[0]["resultados"][0]
        assert result["estado"] == "error" and "carpeta Enviados" in result["detalle"]
        uncertain_mail = message_from_string(results()["uncertain"][-1], policy=policy.default)
        private_path = re.search(r"/r/[0-9a-f]{32}", uncertain_mail.get_body(preferencelist=("plain",)).get_content())[0]
        req(private_path, auth=False)
    assert any(e["clienteId"] == other and e["estado"] == "Envío incierto" for e in req("/api/data")[0]["encuestas"])
    summary = results()
    assert summary["accepted"] == 4 and len(summary["uncertain"]) == 3 and summary["unauthorized"] == 1
    print("OK: OAuth, 401, 429, 503 sin reintento, consentimiento/roles, prueba, invitación con foto, aviso y encuesta por Gmail simulado.")


if __name__ == "__main__":
    main()
