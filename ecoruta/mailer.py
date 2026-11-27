from dataclasses import dataclass
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import formataddr, formatdate, make_msgid
from html import escape
import re
import smtplib
import ssl

from .config import IMAGES, NAME
from .domain import TEC, date_text, euro, valid_email


@dataclass(frozen=True)
class Delivery:
    ok: bool
    detail: str
    uncertain: bool = False


def photo(vehicle):
    if vehicle and re.fullmatch(r"V[0-9]{2}", vehicle["id"]):
        path = IMAGES / f"{vehicle['id']}.jpg"
        return path if path.is_file() else None
    return None


def clean_header(text):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(text)).strip()


def invitation_text(template, client, vehicle, date):
    values = {
        "nombre": client["nombre"], "apellido": client["apellido"], "vehiculo": vehicle["modelo"],
        "tecnologia": TEC.get(vehicle["tec"], vehicle["tec"]), "asesor": client["asesor"],
        "fecha": date_text(date), "precio": euro(vehicle["precio"]),
    }
    return re.sub(r"\{(\w+)\}", lambda match: str(values.get(match[1], match[0])), template)


def message_html(title, body, url=None, action=None, vehicle=None, image=False):
    text = escape(body).replace("\n", "<br>")
    button = (
        '<p><a style="display:inline-block;background:#176047;color:white;padding:14px 22px;text-decoration:none;border-radius:7px"'
        f' href="{escape(url, quote=True)}">{escape(action or "Abrir")}</a></p>'
        if url else ""
    )
    vehicle_html = ""
    if vehicle:
        if image:
            vehicle_html += '<img src="cid:vehiculo" alt="Vehículo" style="width:100%;max-width:560px;border-radius:8px">'
        brand = escape(vehicle["modelo"])
        vehicle_html += f"<p><strong>{brand}</strong> · {escape(vehicle['version'])} · {euro(vehicle['precio'])}</p>"
    return (
        '<!doctype html><html lang="es"><body><main style="font-family:Arial,sans-serif;max-width:600px;'
        'margin:auto;color:#17342a"><header style="background:#176047;color:white;padding:16px">'
        f"{NAME}</header><h1>{escape(title)}</h1>{vehicle_html}<p>{text}</p>{button}"
        f'<p style="font-size:13px;color:#4b5f55">{NAME} · Madrid, España</p></main></body></html>'
    )


class Mailer:
    def __init__(self, settings):
        self.settings = settings

    @property
    def configured(self):
        s = self.settings
        return valid_email(s.gmail_user) and bool(s.gmail_password) and not s.gmail_password.startswith("PEGA_")

    def send(self, to, subject, text, html=None, image=None):
        s = self.settings
        if not self.configured:
            return Delivery(False, "Falta el Gmail remitente o su contraseña de aplicación.")
        if not valid_email(to):
            return Delivery(False, "La dirección de destino no es válida.")
        msg = EmailMessage(policy=SMTP)
        msg["From"] = formataddr((clean_header(s.from_name), s.gmail_user))
        msg["Reply-To"] = s.gmail_user
        msg["To"] = to
        msg["Subject"] = clean_header(subject)[:250]
        msg["Date"] = formatdate(usegmt=True)
        msg["Message-ID"] = make_msgid(domain="ecoruta-crm.local")
        msg.set_content(text)
        if html:
            msg.add_alternative(html, subtype="html")
            if image:
                msg.get_payload()[-1].add_related(
                    image.read_bytes(), maintype="image", subtype="jpeg",
                    cid="<vehiculo>", disposition="inline", filename="vehiculo.jpg",
                )
        sending = False
        try:
            ctx = ssl.create_default_context(cafile=s.smtp_ca or None)
            if s.smtp_ssl:
                connection = smtplib.SMTP_SSL(s.smtp_host, s.smtp_port, timeout=12, context=ctx)
            else:
                connection = smtplib.SMTP(s.smtp_host, s.smtp_port, timeout=12)
            try:
                if not s.smtp_ssl:
                    connection.ehlo()
                    connection.starttls(context=ctx)
                    connection.ehlo()
                connection.login(s.gmail_user, s.gmail_password)
                sending = True
                connection.send_message(msg, from_addr=s.gmail_user, to_addrs=[to])
            finally:
                # Un fallo al cerrar no invalida el 250 de aceptación del mensaje.
                try:
                    connection.quit()
                except (OSError, smtplib.SMTPException):
                    connection.close()
        except smtplib.SMTPAuthenticationError:
            return Delivery(False, "Gmail rechazó el acceso. Comprueba la cuenta y la contraseña de aplicación.")
        except (smtplib.SMTPRecipientsRefused, smtplib.SMTPSenderRefused, smtplib.SMTPDataError):
            return Delivery(False, "Gmail rechazó el mensaje o su destinatario.")
        except ssl.SSLError:
            return Delivery(False, "No se pudo verificar TLS con Gmail.")
        except (smtplib.SMTPServerDisconnected, TimeoutError, OSError):
            if sending:
                return Delivery(False, "Gmail no confirmó el envío. Revisa Enviados antes de repetir.", True)
            return Delivery(False, "No se pudo conectar a Gmail SMTP desde este servidor.")
        except smtplib.SMTPException:
            return Delivery(False, "Gmail no completó la conexión SMTP.")
        return Delivery(True, "Aceptado por Gmail.")
