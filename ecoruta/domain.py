import csv
import hashlib
import hmac
import io
import re
import secrets
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

ZONA = ZoneInfo("Europe/Madrid")
ORIGENES = ("Web", "Visita", "Evento", "Referido")
TEC = {"BEV": "100% eléctrico", "PHEV": "híbrido enchufable", "HEV": "híbrido"}
CONTACTO = {"Email": "Correo", "Telefono": "Teléfono"}
CARGAS = ("Si", "No", "Por confirmar")
CANALES = (*CONTACTO, "Web", "Visita", "WhatsApp", "Evento", "Otro")
EVENTOS = (
    "Consulta", "Visita concesionario", "Solicitud prueba", "Invitación test drive",
    "Cita confirmada", "Asesoramiento enviado", "Encuesta enviada", "Encuesta respondida", "Llamada", "Otro",
)
TIPOS_ENCUESTA = ("Satisfacción post-visita", "Satisfacción post test drive", "Interés en nuevo modelo")
INTERES = ("Sí", "No", "Más adelante")
RESPUESTAS_INV = {
    "confirmo": "Sí, confirmo la cita", "otra_fecha": "Propongo otra fecha",
    "llamada": "Prefiero que me llaméis primero", "no": "Ahora no me interesa",
}
SEGMENTOS = (
    "Listo para prueba", "Cita confirmada", "Asesorar carga", "Revisar presupuesto",
    "Revisar modelo", "Lista de espera", "En exploración", "Sin permiso",
)
REFERENCIA = {"BEV": "V04", "PHEV": "V07", "HEV": "V01"}
EMAIL_RE = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_{}|~\x60-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z0-9-]{2,}", re.ASCII)
ID_TOKEN = re.compile(r"[0-9a-f]{32}", re.ASCII)
PASSWORD_ITERS = 600_000
CLIENT_FIELDS = (
    "nombre", "apellido", "telefono", "email", "origen", "permiso", "canal",
    "tecnologia", "presupuesto", "compra_dias", "carga", "asesor", "vehiculo",
)


class RuleError(ValueError):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def valid_email(value):
    return isinstance(value, str) and len(value) <= 254 and value.isascii() and EMAIL_RE.fullmatch(value) is not None


def validate_password(value):
    if not isinstance(value, str) or not 8 <= len(value) <= 512:
        raise RuleError("La contraseña debe tener de 8 a 512 caracteres.")


def pass_hash(password, salt=None, iterations=PASSWORD_ITERS):
    salt = salt if salt is not None else secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2${iterations}${salt.hex()}${digest.hex()}"


def pass_matches(password, encoded):
    if not isinstance(password, str) or len(password) > 512:
        return False
    match = re.fullmatch(r"pbkdf2\$([0-9]{1,7})\$([0-9a-f]{32})\$([0-9a-f]{64})", encoded or "")
    if not match or not 1 <= int(match[1]) <= 2_000_000:
        return False
    computed = pass_hash(password, bytes.fromhex(match[2]), int(match[1]))
    return hmac.compare_digest(computed, encoded)


def euro(value):
    return f"{int(value or 0):,}".replace(",", ".") + " €"


def date_iso(value, future=False):
    if not value:
        return None
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M").replace(tzinfo=ZONA)
        if parsed.strftime("%Y-%m-%dT%H:%M") != value:
            raise ValueError()
    except (TypeError, ValueError):
        raise RuleError("Indica una fecha y hora válidas.") from None
    if future and parsed < datetime.now(ZONA).replace(second=0, microsecond=0):
        raise RuleError("La fecha elegida ya pasó. Elige una fecha futura.")
    return value


def date_text(value):
    if not value:
        return "la fecha que tú elijas"
    parsed = datetime.strptime(date_iso(value), "%Y-%m-%dT%H:%M")
    days = ("lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo")
    months = ("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre")
    return f"{days[parsed.weekday()]} {parsed.day} de {months[parsed.month - 1]} a las {parsed:%H:%M}"


def recommendation(catalog, tech, budget, charging):
    same = sorted((v for v in catalog if v["tec"] == tech), key=lambda v: v["precio"])
    within = [v for v in same if v["precio"] <= budget]
    available = [v for v in within if v["disponible"]]
    if available:
        vehicle, state, reason = available[-1], "ok", f"Es el {tech} de mayor gama dentro del presupuesto y con unidad disponible."
    elif within:
        vehicle, state, reason = within[-1], "espera", "Cabe en el presupuesto, pero la unidad no está disponible. Ofrece una fecha alternativa."
    elif same:
        vehicle, state, reason = same[0], "presupuesto", f"Ningún {tech} cabe en el presupuesto. Se propone el más asequible."
    else:
        vehicle, state, reason = None, "sin_catalogo", f"No hay vehículos {tech} en el catálogo."
    others = [v for v in catalog if v["tec"] != tech and v["precio"] <= budget and v["disponible"]]
    return dict(vehiculo=vehicle, estado=state, motivo=reason, margen=budget - vehicle["precio"] if vehicle else None,
                alternativas=within, otra_tecnologia=others[-1] if others else None,
                aviso=f'Carga habitual "{charging}": verifica el punto de carga.' if tech != "HEV" and charging != "Si" else "")


def segment(client, catalog, events):
    tech = client["tecnologia"]
    stock = {v["id"]: v for v in catalog}
    v = stock.get(client["vehiculo"]) or stock.get(REFERENCIA.get(tech))
    budget = int(client["presupuesto"] or 0)
    days = int(client["compra_dias"] or 0)
    priority = "Alta" if days <= 30 else "Media" if days <= 60 else "Baja"
    if client["permiso"] != "Si":
        name, action, deadline = "Sin permiso", "No iniciar seguimiento comercial", "No aplica"
    elif "Cita confirmada" in events:
        name, action, deadline = "Cita confirmada", "Preparar prueba ya acordada", "Según cita registrada"
    elif not v or v["tec"] != tech:
        name, action, deadline = "Revisar modelo", f"Revisar el vehículo para tecnología {tech}", "En 3 días"
    elif tech != "HEV" and client["carga"] != "Si":
        name, action, deadline = "Asesorar carga", "Aclarar carga y comparar opciones con cliente", "En 3 días"
    elif budget < v["precio"]:
        alternatives = sum(x["tec"] == tech and x["precio"] <= budget for x in catalog)
        action = f"Proponer {alternatives} alternativa(s) {tech}" if alternatives else "Proponer financiación o tecnología alternativa"
        name, deadline = "Revisar presupuesto", "En 3 días"
    elif "Solicitud prueba" in events and days <= 30:
        name, action = ("Listo para prueba", f"Invitar a prueba {tech}") if v["disponible"] else ("Lista de espera", f"Unidad {v['id']} no disponible, ofrecer fecha alternativa")
        deadline = "En 24 horas"
    else:
        name, action, deadline = "En exploración", f"Enviar comparativa {tech} y acordar seguimiento", "En 3 días"
    return dict(segmento=name, accion=action, plazo=deadline, prioridad=priority, vehiculo=v)


def normalize_client(values):
    fields = {key: str(values.get(key) or "").strip() for key in CLIENT_FIELDS if key not in {"presupuesto", "compra_dias"}}
    errors = [f"Falta {key}." for key in ("nombre", "apellido", "telefono", "email") if not fields[key]]
    fields["email"] = fields["email"].lower()
    if fields["email"] and not valid_email(fields["email"]):
        errors.append("El correo electrónico no es válido.")
    if fields["telefono"] and (
        not re.fullmatch(r"\+?[0-9 ()-]+", fields["telefono"]) or not 9 <= len(phone_digits(fields["telefono"])) <= 20
    ):
        errors.append("El teléfono debe contener de 9 a 20 dígitos.")
    choices = dict(origen=ORIGENES, permiso=("Si", "No"), canal=CONTACTO, tecnologia=TEC, carga=CARGAS)
    errors.extend(f"El campo {key} no es válido." for key, allowed in choices.items() if fields[key] not in allowed)
    if any(len(fields[key]) > 150 for key in ("nombre", "apellido", "asesor")):
        errors.append("El nombre, el apellido y el asesor pueden tener hasta 150 caracteres.")
    for key, lower, upper, message in (
        ("presupuesto", 1, 10**9, "Indica un presupuesto mayor que cero."),
        ("compra_dias", 0, 36500, "Indica los días previstos de compra."),
    ):
        try:
            amount = Decimal(str(values.get(key, "")))
            if not lower <= amount <= upper or amount != int(amount):
                raise ValueError()
            fields[key] = int(amount)
        except (ValueError, InvalidOperation, OverflowError):
            errors.append(message)
    if errors:
        raise RuleError(" ".join(errors))
    fields["vehiculo"] = fields["vehiculo"] or None
    return fields


def phone_digits(phone):
    return re.sub(r"[^0-9]", "", phone or "")


def csv_clients(clients, segments):
    fields = (*CLIENT_FIELDS[:-1], "vehiculo")
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter=";")
    writer.writerow(("id", *fields, "segmento", "accion", "plazo", "prioridad"))

    def literal(value):
        if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
            return "'" + value
        return value

    for c in clients:
        s = segments[c["id"]]
        writer.writerow([c["id"], *(literal(c[k]) for k in fields), *(literal(s[k]) for k in ("segmento", "accion", "plazo", "prioridad"))])
    return output.getvalue().encode("utf-8-sig")
