from collections import defaultdict
import hmac
import json
import re
import secrets
from time import sleep, time

from .config import NAME
from .db import Database
from .domain import (
    CANALES, CLIENT_FIELDS, EVENTOS, ID_TOKEN, INTERES, RESPUESTAS_INV, TIPOS_ENCUESTA,
    RuleError, date_iso, date_text, euro, normalize_client, now, pass_hash, pass_matches,
    phone_digits, recommendation, segment, valid_email, validate_password,
)
from .mailer import Delivery, Mailer, invitation_text, message_html, photo

SESSION_TTL = 12 * 3600
DEMO_EMAIL = re.compile(r"@example\.(com|org|net)$", re.I)


def make_actor(row):
    return {key: row[key] for key in ("id", "nombre", "email", "rol")}


def read_json(value):
    if not value:
        return {}
    try:
        decoded = json.loads(value)
    except (ValueError, TypeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


class CRM:
    def __init__(self, settings, mailer=None):
        self.settings = settings
        self.db = Database(settings)
        self.mailer = mailer if mailer is not None else Mailer(settings)

    @staticmethod
    def _required(q, token, admin=False):
        row = CRM._session(q, token)
        if not row:
            raise RuleError("Inicia sesión para continuar.")
        if admin and row["rol"] != "admin":
            raise RuleError("Solo un administrador puede realizar esta operación.")
        return row

    @staticmethod
    def _session(q, token):
        if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{64}", token):
            return None
        return q.one(
            "SELECT u.id,u.nombre,u.email,u.rol FROM sesiones s JOIN usuarios u ON u.id=s.usuario_id "
            "WHERE s.token=? AND s.expira>?", (token, int(time())),
        )

    def actor(self, token):
        if not token:
            return None
        with self.db.transaction() as q:
            return self._session(q, token)

    @staticmethod
    def _has_admin(q):
        return bool(q.one("SELECT id FROM usuarios WHERE rol='admin' AND pass_hash IS NOT NULL LIMIT 1"))

    def needs_setup(self):
        with self.db.transaction() as q:
            return not self._has_admin(q)

    @staticmethod
    def _new_session(q, user_id):
        token = secrets.token_hex(32)
        instant = int(time())
        q.run("DELETE FROM sesiones WHERE expira<=?", (instant,))
        q.run("INSERT INTO sesiones (token,usuario_id,expira) VALUES (?,?,?)", (token, user_id, instant + SESSION_TTL))
        return token

    def setup(self, name, email, password, setup_token=""):
        expected = self.settings.setup_token
        if self.settings.production and not expected:
            raise RuleError("Configura CRM_SETUP_TOKEN para habilitar la primera cuenta.")
        if expected and not hmac.compare_digest(str(setup_token).encode(), expected.encode()):
            raise RuleError("El token de configuración es incorrecto.")
        with self.db.transaction(write=True) as q:
            if self._has_admin(q):
                raise RuleError("Ya existe una cuenta de administrador.")
            user_id = self._create_user(q, name, email, password, "admin")
            return self._new_session(q, user_id)

    def login(self, email, password):
        email = str(email).strip().lower()
        if len(email) > 254:
            raise RuleError("Correo o contraseña incorrectos.")
        with self.db.transaction() as q:
            user = q.one("SELECT id,pass_hash FROM usuarios WHERE lower(email)=?", (email,))
        if not user or not pass_matches(password, user["pass_hash"]):
            sleep(0.35)
            raise RuleError("Correo o contraseña incorrectos.")
        with self.db.transaction(write=True) as q:
            # Un cambio de contraseña entre la verificación y el alta revoca ese acceso.
            current = q.one("SELECT pass_hash FROM usuarios WHERE id=?", (user["id"],))
            if not current or current["pass_hash"] != user["pass_hash"]:
                raise RuleError("Vuelve a iniciar sesión con tus credenciales vigentes.")
            return self._new_session(q, user["id"])

    def logout(self, token):
        if token:
            with self.db.transaction(write=True) as q:
                q.run("DELETE FROM sesiones WHERE token=?", (token,))

    @staticmethod
    def _user_inputs(name, email, password):
        name, email = str(name).strip(), str(email).strip().lower()
        if not 1 <= len(name) <= 150 or not valid_email(email):
            raise RuleError("Indica un nombre y un correo electrónico válidos.")
        validate_password(password)
        return name, email

    def _create_user(self, q, name, email, password, role):
        name, email = self._user_inputs(name, email, password)
        if role not in {"admin", "estandar"}:
            raise RuleError("Rol no válido.")
        if q.one("SELECT 1 FROM usuarios WHERE lower(nombre)=lower(?) OR lower(email)=?", (name, email)):
            raise RuleError("Ya existe un usuario con ese nombre o correo.")
        row = q.one("INSERT INTO usuarios (nombre,email,rol,pass_hash,creado) VALUES (?,?,?,?,?) RETURNING id",
                    (name, email, role, pass_hash(password), now()))
        return row["id"]

    def add_user(self, token, name, email, password, role):
        with self.db.transaction(write=True) as q:
            self._required(q, token, admin=True)
            return self._create_user(q, name, email, password, role)

    def change_access(self, token, user_id, email, password):
        email = str(email).strip().lower()
        if not valid_email(email):
            raise RuleError("Indica un correo electrónico válido.")
        validate_password(password)
        with self.db.transaction(write=True) as q:
            self._required(q, token, admin=True)
            if q.one("SELECT 1 FROM usuarios WHERE lower(email)=? AND id<>?", (email, user_id)):
                raise RuleError("Ese correo ya lo usa otro usuario.")
            n = q.run("UPDATE usuarios SET email=?,pass_hash=? WHERE id=?", (email, pass_hash(password), user_id)).rowcount
            if not n:
                raise RuleError("Usuario no encontrado.")
            q.run("DELETE FROM sesiones WHERE usuario_id=? AND token<>?", (user_id, token))

    @staticmethod
    def _catalog(q):
        return q.all("SELECT id,modelo,version,tec,precio,recarga,uso,base,disponible FROM catalogo ORDER BY id")

    @staticmethod
    def _client(q, client_id, actor=None):
        row = q.one("SELECT * FROM clientes WHERE id=?", (client_id,))
        if not row:
            raise RuleError("Cliente no encontrado.")
        if actor and actor["rol"] != "admin" and row["asesor"] != actor["nombre"]:
            raise RuleError("Cliente no asignado a este asesor.")
        return row

    @staticmethod
    def _template(q):
        row = q.one("SELECT valor FROM config WHERE clave='plantillaInvitacion'")
        return row["valor"] if row else ""

    def snapshot(self, token):
        with self.db.transaction() as q:
            actor = self._required(q, token)
            admin = actor["rol"] == "admin"
            filter_client = "" if admin else " WHERE asesor=?"
            filter_other = "" if admin else " AND cliente_id IN (SELECT id FROM clientes WHERE asesor=?)"
            bind = () if admin else (actor["nombre"],)
            clients = q.all("SELECT * FROM clientes" + filter_client + " ORDER BY id", bind)
            histories = q.all("SELECT * FROM interacciones WHERE 1=1" + filter_other + " ORDER BY fecha,id", bind)
            surveys = q.all("SELECT * FROM encuestas WHERE 1=1" + filter_other + " ORDER BY enviada DESC,id DESC", bind)
            responses = q.all(
                "SELECT tipo,cliente_id,resumen,respondido,leido FROM enlaces WHERE respondido IS NOT NULL"
                + filter_other + " ORDER BY respondido DESC LIMIT 200", bind,
            )
            catalog = self._catalog(q)
            users = (
                q.all("SELECT id,nombre,email,rol,pass_hash IS NOT NULL AS acceso FROM usuarios ORDER BY rol,nombre")
                if admin else []
            )
            template = self._template(q) if admin else ""
        if not admin:
            for client in clients:
                if client["permiso"] != "Si":
                    client["telefono"] = client["email"] = ""
        events = defaultdict(set)
        for interaction in histories:
            events[interaction["cliente_id"]].add(interaction["evento"])
        segments = {c["id"]: segment(c, catalog, events[c["id"]]) for c in clients}
        for survey in surveys:
            survey["respuestas"] = read_json(survey["respuestas"])
        return dict(actor=actor, clientes=clients, interacciones=histories, encuestas=surveys, respuestas=responses,
                    catalogo=catalog, usuarios=users, plantilla=template, segmentos=segments, eventos=events)

    @staticmethod
    def _event(q, cid, channel, event, result, who, action=""):
        q.run("INSERT INTO interacciones (cliente_id,fecha,canal,evento,resultado,responsable,accion) VALUES (?,?,?,?,?,?,?)",
              (cid, now(), channel, event, result, who, action))

    def save_client(self, token, values, client_id=None):
        fields = normalize_client(values)
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token, admin=True)
            original = self._client(q, client_id) if client_id else None
            if not q.one("SELECT id FROM usuarios WHERE rol='estandar' AND nombre=?", (fields["asesor"],)):
                raise RuleError("Selecciona un asesor válido.")
            catalog = self._catalog(q)
            if fields["vehiculo"] and not any(v["id"] == fields["vehiculo"] for v in catalog):
                raise RuleError("El vehículo elegido no existe.")
            for row in q.all("SELECT id,email,telefono FROM clientes"):
                if row["id"] != client_id and (
                    (row["email"] or "").lower() == fields["email"]
                    or phone_digits(row["telefono"]) == phone_digits(fields["telefono"])
                ):
                    raise RuleError(f"Posible duplicado. El cliente {row['id']} ya usa ese correo o teléfono.")
            reco = recommendation(catalog, fields["tecnologia"], fields["presupuesto"], fields["carga"])
            vehicle = reco["vehiculo"]
            if not fields["vehiculo"] and vehicle:
                fields["vehiculo"] = vehicle["id"]
            params = tuple(fields[f] for f in CLIENT_FIELDS)
            if original:
                q.run("UPDATE clientes SET " + ",".join(f"{field}=?" for field in CLIENT_FIELDS) + " WHERE id=?", (*params, client_id))
                changed = [field for field in CLIENT_FIELDS if original[field] != fields[field]]
                if changed:
                    self._event(q, client_id, "Otro", "Otro", "Perfil actualizado: " + ", ".join(changed), actor["nombre"])
            else:
                client_id = q.next_id("clientes")
                marks = ",".join("?" for _ in range(len(CLIENT_FIELDS) + 2))
                q.run(f"INSERT INTO clientes (id,{','.join(CLIENT_FIELDS)},creado) VALUES ({marks})", (client_id, *params, now()))
                self._event(q, client_id, fields["origen"], "Consulta", "Alta de cliente en CRM", actor["nombre"])
                if vehicle:
                    self._event(q, client_id, "Otro", "Otro",
                                f"Recomendación automática: {vehicle['modelo']} · {euro(vehicle['precio'])} · {reco['motivo']}",
                                "Motor de recomendación")
        return client_id, reco

    def delete_client(self, token, client_id):
        with self.db.transaction(write=True) as q:
            self._required(q, token, admin=True)
            self._client(q, client_id)
            q.run("DELETE FROM envios WHERE cliente_id=?", (client_id,))
            q.run("DELETE FROM clientes WHERE id=?", (client_id,))

    def interaction(self, token, client_id, channel, event, result, action=""):
        result, action = str(result).strip(), str(action).strip()
        if channel not in CANALES or event not in EVENTOS or not 1 <= len(result) <= 2000 or len(action) > 1000:
            raise RuleError("Revisa el evento, el canal y el resultado de la interacción.")
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token)
            client = self._client(q, client_id, actor)
            if client["permiso"] != "Si":
                raise RuleError("El cliente no autoriza el contacto comercial.")
            self._event(q, client_id, channel, event, result, actor["nombre"], action)

    def mark_read(self, token):
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token)
            if actor["rol"] == "admin":
                q.run("UPDATE enlaces SET leido=1 WHERE respondido IS NOT NULL AND leido=0")
            else:
                q.run("UPDATE enlaces SET leido=1 WHERE respondido IS NOT NULL AND leido=0 "
                      "AND cliente_id IN (SELECT id FROM clientes WHERE asesor=?)", (actor["nombre"],))

    def set_available(self, token, vid, value):
        with self.db.transaction(write=True) as q:
            self._required(q, token, admin=True)
            if not q.run("UPDATE catalogo SET disponible=? WHERE id=?", (int(bool(value)), vid)).rowcount:
                raise RuleError("Vehículo no encontrado.")

    def set_template(self, token, text):
        text = str(text).strip()
        if not 1 <= len(text) <= 12000:
            raise RuleError("La plantilla debe contener entre 1 y 12.000 caracteres.")
        with self.db.transaction(write=True) as q:
            self._required(q, token, admin=True)
            q.run("INSERT INTO config (clave,valor) VALUES ('plantillaInvitacion',?) "
                  "ON CONFLICT (clave) DO UPDATE SET valor=excluded.valor", (text,))

    @staticmethod
    def _vehicle(client, catalog):
        return next((v for v in catalog if v["id"] == client["vehiculo"]), None) or recommendation(
            catalog, client["tecnologia"], int(client["presupuesto"] or 0), client["carga"],
        )["vehiculo"]

    def _url(self, public_token):
        return self.settings.public_url + "/?r=" + public_token

    def preview_invitation(self, token, cid, date=None):
        date = date_iso(date)
        with self.db.transaction() as q:
            self._required(q, token, admin=True)
            client = self._client(q, cid)
            vehicle = self._vehicle(client, self._catalog(q))
            if not vehicle:
                raise RuleError("No hay vehículo para este cliente.")
            text = invitation_text(self._template(q), client, vehicle, date)
        return dict(texto=text, vehiculo=vehicle, fecha=date_text(date))

    @staticmethod
    def _link(q, cid, kind, survey=None, vehicle=None, date=None):
        token = secrets.token_hex(16)
        q.run("INSERT INTO enlaces (token,tipo,cliente_id,encuesta_id,vehiculo,fecha_propuesta,creado) VALUES (?,?,?,?,?,?,?)",
              (token, kind, cid, survey, vehicle, date, now()))
        return token

    @staticmethod
    def _log(q, cid, kind, to, subject, delivery, user):
        q.run("INSERT INTO envios (cliente_id,tipo,destinatario,asunto,estado,detalle,fecha,usuario) VALUES (?,?,?,?,?,?,?,?)",
              (cid, kind, to, subject, "enviado" if delivery.ok else "error", delivery.detail, now(), user))

    def test_mail(self, token, to):
        to = str(to).strip()
        if not valid_email(to):
            raise RuleError("Correo de destino no válido.")
        with self.db.transaction() as q:
            actor = self._required(q, token, admin=True)
        subject = f"Prueba de correo · {NAME} CRM"
        body = f"Este es un correo de prueba enviado desde {NAME}."
        delivered = self.mailer.send(to, subject, body, message_html(subject, body))
        with self.db.transaction(write=True) as q:
            self._log(q, None, "prueba", to, subject, delivered, actor["nombre"])
        return delivered

    def send_invitation(self, token, cid, date=None):
        date = date_iso(date, future=True)
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token, admin=True)
            client = self._client(q, cid)
            email = client["email"]
            if client["permiso"] != "Si":
                return "sin_permiso", "El cliente no autoriza el contacto comercial."
            if q.one("SELECT 1 FROM interacciones WHERE cliente_id=? AND evento='Cita confirmada'", (cid,)):
                return "omitido", "El cliente ya tiene una cita confirmada."
            if DEMO_EMAIL.search(email):
                return "omitido", "No se envía a correos de demostración."
            if not self.mailer.configured:
                return "error", "Configura el correo antes de enviar."
            vehicle = self._vehicle(client, self._catalog(q))
            if not vehicle:
                raise RuleError("No hay vehículo para la tecnología solicitada.")
            public = self._link(q, cid, "invitacion", vehicle=vehicle["id"], date=date)
            text = invitation_text(self._template(q), client, vehicle, date)
        url = self._url(public)
        body = f"{text}\n\nFecha propuesta: {date_text(date)}\nAsesor/a: {client['asesor']}"
        subject = f"{client['nombre']}, te invitamos a probar el {vehicle['modelo']}"
        image = photo(vehicle)
        html = message_html(subject, body, url, "Responder a la invitación", vehicle, bool(image))
        delivery = self.mailer.send(email, subject, f"{body}\n\nResponde aquí: {url}", html, image)
        with self.db.transaction(write=True) as q:
            if q.one("SELECT id FROM clientes WHERE id=?", (cid,)):
                self._log(q, cid, "invitacion", email, subject, delivery, actor["nombre"])
                if delivery.ok:
                    self._event(q, cid, "Email", "Invitación test drive",
                                f"Invitación enviada para probar {vehicle['modelo']} · {date_text(date)}",
                                actor["nombre"], f"Invitar a prueba {vehicle['tec']}")
                elif not delivery.uncertain:
                    q.run("DELETE FROM enlaces WHERE token=? AND respondido IS NULL", (public,))
        return ("enviado" if delivery.ok else "error"), delivery.detail

    def send_survey(self, token, cid, kind):
        if kind not in TIPOS_ENCUESTA:
            raise RuleError("Tipo de encuesta no válido.")
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token, admin=True)
            c = self._client(q, cid)
            if c["permiso"] != "Si":
                return "sin_permiso", "El cliente no autoriza el contacto comercial."
            demo = bool(DEMO_EMAIL.search(c["email"]))
            if not demo and not self.mailer.configured:
                return "error", "Configura el correo antes de enviar."
            eid = q.next_id("encuestas")
            q.run("INSERT INTO encuestas (id,cliente_id,tipo,canal,enviada,estado) VALUES (?,?,?,'Email',?,'Enviada')",
                  (eid, cid, kind, now()))
            public = self._link(q, cid, "encuesta", survey=eid)
        url = self._url(public)
        subject = f"{c['nombre']}, ¿nos cuentas qué tal fue? · {NAME}"
        body = f"Hola {c['nombre']},\n\n{kind}. Cuéntanos qué tal fue tu experiencia y si te gustaría realizar un test drive. Solo te llevará un minuto."
        delivery = (
            Delivery(True, "Encuesta registrada sin enviar a la dirección de demostración. Enlace: " + url)
            if demo else self.mailer.send(c["email"], subject, f"{body}\n\nResponde aquí: {url}", message_html(subject, body, url, "Responder a la encuesta"))
        )
        with self.db.transaction(write=True) as q:
            if q.one("SELECT id FROM clientes WHERE id=?", (cid,)):
                if not demo:
                    self._log(q, cid, "encuesta", c["email"], subject, delivery, actor["nombre"])
                if delivery.ok:
                    self._event(q, cid, "Email", "Encuesta enviada", kind, actor["nombre"], "Disparar encuesta")
                elif delivery.uncertain:
                    q.run("UPDATE encuestas SET estado='Envío incierto' WHERE id=? AND estado='Enviada'", (eid,))
                elif q.one("SELECT token FROM enlaces WHERE token=? AND respondido IS NULL", (public,)):
                    q.run("DELETE FROM enlaces WHERE token=?", (public,))
                    q.run("DELETE FROM encuestas WHERE id=?", (eid,))
        return ("omitido" if demo else "enviado" if delivery.ok else "error"), delivery.detail

    def public_details(self, public):
        if not isinstance(public, str) or not ID_TOKEN.fullmatch(public):
            return None
        with self.db.transaction() as q:
            link = q.one("SELECT * FROM enlaces WHERE token=?", (public,))
            if not link or link["tipo"] not in {"invitacion", "encuesta"}:
                return None
            c = self._client(q, link["cliente_id"])
            car = q.one("SELECT id,modelo,version,precio FROM catalogo WHERE id=?", (link["vehiculo"],)) if link["vehiculo"] else None
        return dict(tipo=link["tipo"], fecha=link["fecha_propuesta"], respondido=bool(link["respondido"]),
                    resumen=link["resumen"], nombre=c["nombre"], asesor=c["asesor"], vehiculo=car)

    def answer_survey(self, token, eid, satisfaction, nps, interest, comment=""):
        with self.db.transaction(write=True) as q:
            actor = self._required(q, token, admin=True)
            survey = q.one("SELECT * FROM encuestas WHERE id=?", (eid,))
            if not survey:
                raise RuleError("Encuesta no encontrada.")
            return self._answer_survey(q, survey, satisfaction, nps, interest, comment, actor["nombre"], True)

    def _answer_survey(self, q, e, sat, nps, interest, comment, who, read):
        if not isinstance(sat, int) or not isinstance(nps, int) or not 1 <= sat <= 5 or not 0 <= nps <= 10 or interest not in INTERES:
            raise RuleError("Responde las tres primeras preguntas.")
        comment = str(comment).strip()[:1000]
        raw = json.dumps(dict(satisfaccion=sat, nps=nps, interes=interest, comentario=comment), ensure_ascii=False)
        summary = f"Encuesta: satisfacción {sat}/5 · recomendaría {nps}/10 · test drive: {interest}"
        if comment:
            summary += f' · "{comment}"'
        at = now()
        if not q.run("UPDATE encuestas SET estado='Respondida',respuestas=?,respondida=? WHERE id=? AND estado<>'Respondida'",
                     (raw, at, e["id"])).rowcount:
            raise RuleError("Esta encuesta ya fue respondida.")
        q.run("UPDATE enlaces SET respondido=?,respuesta=?,resumen=?,leido=? WHERE encuesta_id=? AND respondido IS NULL",
              (at, raw, summary, int(read), e["id"]))
        self._event(q, e["cliente_id"], "Web", "Encuesta respondida", summary, who)
        if interest == "Sí":
            self._event(q, e["cliente_id"], "Web", "Solicitud prueba", "Solicita prueba en la encuesta", who)
        return summary

    def answer_public(self, token, values):
        if not isinstance(token, str) or not ID_TOKEN.fullmatch(token):
            raise RuleError("Este enlace no es válido.")
        with self.db.transaction(write=True) as q:
            e = q.one("SELECT * FROM enlaces WHERE token=?", (token,))
            if not e:
                raise RuleError("Este enlace no es válido.")
            if e["respondido"]:
                raise RuleError("Ya recibimos tu respuesta.")
            c = self._client(q, e["cliente_id"])
            if e["tipo"] == "encuesta":
                survey = q.one("SELECT * FROM encuestas WHERE id=?", (e["encuesta_id"],))
                if not survey:
                    raise RuleError("Encuesta no encontrada.")
                summary = self._answer_survey(q, survey, values.get("satisfaccion"), values.get("nps"),
                                              values.get("interes"), values.get("comentario", ""), "Cliente (respuesta web)", False)
            elif e["tipo"] == "invitacion":
                summary = self._answer_invitation(q, e, c, values)
            else:
                raise RuleError("Este enlace no es válido.")
        self._notify(c, summary)
        return summary

    def _answer_invitation(self, q, e, c, values):
        choice = values.get("opcion")
        if choice not in RESPUESTAS_INV or choice == "confirmo" and not e["fecha_propuesta"]:
            raise RuleError("Elige una de las opciones.")
        vehicle = q.one("SELECT modelo FROM catalogo WHERE id=?", (e["vehiculo"],)) if e["vehiculo"] else None
        model = vehicle["modelo"] if vehicle else "vehículo"
        date = None
        if choice == "confirmo":
            date = date_iso(e["fecha_propuesta"], future=True)
            event, result = "Cita confirmada", f"Confirma el test drive del {model} el {date_text(date)}"
        elif choice == "otra_fecha":
            date = date_iso(values.get("fecha"), future=True)
            if not date:
                raise RuleError("Indica la fecha y la hora que te vienen bien.")
            event, result = "Solicitud prueba", f"Quiere probar el {model} y propone el {date_text(date)}"
        elif choice == "llamada":
            event, result = "Otro", f"Le interesa el {model} y pide que le llamen antes de agendar"
        else:
            event, result = "Otro", f"No quiere hacer la prueba del {model} por ahora"
        comment = str(values.get("comentario") or "").strip()[:1000]
        summary = result + (f' · "{comment}"' if comment else "")
        raw = json.dumps(dict(opcion=choice, fecha=date, comentario=comment), ensure_ascii=False)
        q.run("UPDATE enlaces SET respondido=?,respuesta=?,resumen=?,leido=0 WHERE token=? AND respondido IS NULL",
              (now(), raw, summary, e["token"]))
        self._event(q, c["id"], "Web", event, summary, "Cliente (respuesta web)")
        return summary

    def _notify(self, c, summary):
        to = self.settings.notify_email
        if not self.mailer.configured or not valid_email(to):
            return
        subject = f"Respuesta de {c['nombre']} {c['apellido']} · {NAME}"
        body = f"{summary}\n\nAsesor/a: {c['asesor']}\nAbre el CRM: {self.settings.public_url}"
        delivery = self.mailer.send(to, subject, body, message_html(subject, body, self.settings.public_url, "Abrir el CRM"))
        with self.db.transaction(write=True) as q:
            if q.one("SELECT id FROM clientes WHERE id=?", (c["id"],)):
                self._log(q, c["id"], "aviso", to, subject, delivery, "Sistema")
