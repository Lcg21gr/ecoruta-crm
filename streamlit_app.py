from collections import Counter
from datetime import datetime, timedelta
import logging
import sqlite3

from psycopg import Error as PostgreSQLError
import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

from ecoruta.config import ConfigError, Settings
from ecoruta.crm import CRM
from ecoruta.domain import (
    CANALES, CARGAS, CONTACTO, EVENTOS, INTERES, ORIGENES, RESPUESTAS_INV, SEGMENTOS, TEC,
    TIPOS_ENCUESTA, ZONA, RuleError, csv_clients, date_text, euro, recommendation,
)
from ecoruta.mailer import photo

MENU = ("Panel", "Clientes", "Invitaciones test drive", "Encuestas", "Catálogo", "Equipo y correo")
PRIORITY = {"Alta": 0, "Media": 1, "Baja": 2}


@st.cache_resource
def open_crm(settings):
    crm = CRM(settings)
    crm.db.prepare()
    return crm


def label(client):
    return f"{client['nombre']} {client['apellido']} · {client['id']}"


def table(rows):
    if rows:
        st.dataframe(rows, hide_index=True, width="stretch")
    else:
        st.caption("No hay registros.")


def choose(title, options, value=None, **kwargs):
    values = list(options)
    default = values.index(value) if value in values else 0
    return st.selectbox(title, values, index=default if values else None, **kwargs)


def datetime_inputs(prefix, title, optional=False):
    if optional and not st.checkbox(title, key=f"{prefix}_date_enabled"):
        return None
    st.caption(title if not optional else "Fecha y hora de Madrid")
    left, right = st.columns(2)
    tomorrow = datetime.now(ZONA).date() + timedelta(days=1)
    day = left.date_input("Fecha", tomorrow, key=f"{prefix}_day")
    hour = right.time_input("Hora", datetime.strptime("10:00", "%H:%M").time(), key=f"{prefix}_hour")
    return f"{day:%Y-%m-%d}T{hour:%H:%M}" if day and hour else None


def flash(message):
    st.session_state["_flash"] = message
    st.rerun()


def visit(view, client_id=None):
    st.session_state["_menu"] = view
    if client_id:
        st.session_state["_open_client"] = client_id


def car_card(car, compact=False):
    if not car:
        return
    image = photo(car)
    if image:
        st.image(str(image), width=270 if compact else "stretch")
    st.text(f"{car['modelo']} · {car['version']}")
    st.caption(" · ".join(x for x in [car["id"], car.get("tec"), euro(car["precio"])] if x))


def login(crm):
    st.title("EcoRuta CRM")
    if crm.needs_setup():
        st.subheader("Crear cuenta de administrador")
        if crm.settings.production and not crm.settings.setup_token:
            st.warning("La primera cuenta necesita un token CRM_SETUP_TOKEN configurado por el administrador.")
            return
        with st.form("setup", clear_on_submit=True):
            setup = st.text_input("Token de configuración", type="password", max_chars=256) if crm.settings.setup_token else ""
            name = st.text_input("Nombre", max_chars=150)
            email = st.text_input("Correo electrónico", max_chars=254)
            password = st.text_input("Contraseña", type="password", max_chars=256)
            submitted = st.form_submit_button("Crear y entrar", type="primary")
        if submitted:
            st.session_state["_token"] = crm.setup(name, email, password, setup)
            st.rerun()
        return
    st.caption("Inicia sesión con tu cuenta de EcoRuta Madrid.")
    with st.form("login", clear_on_submit=True):
        email = st.text_input("Correo electrónico", max_chars=254)
        password = st.text_input("Contraseña", type="password", max_chars=256)
        submitted = st.form_submit_button("Entrar", type="primary")
    if submitted:
        st.session_state["_token"] = crm.login(email, password)
        st.rerun()


def panel(crm, token, data, admin):
    st.title("Panel comercial" if admin else "Mi panel")
    clients, events, segments = data["clientes"], data["eventos"], data["segmentos"]
    if admin and not crm.mailer.configured:
        st.warning("Gmail no está configurado. Revisa las variables en Equipo y correo.")
    invited = {c["id"] for c in clients if "Invitación test drive" in events[c["id"]]}
    confirmed = {c["id"] for c in clients if "Cita confirmada" in events[c["id"]]}
    counts = Counter(s["segmento"] for s in segments.values())
    ratings = [s["respuestas"]["satisfaccion"] for s in data["encuestas"] if isinstance(s["respuestas"].get("satisfaccion"), int)]
    metrics = st.columns(5)
    for col, title, value in zip(metrics, ["Clientes", "Listos para prueba", "Citas confirmadas", "Conversión", "Satisfacción media"],
                                  [len(clients), counts["Listo para prueba"], len(confirmed),
                                   f"{len(invited & confirmed) / len(invited):.0%}" if invited else "—",
                                   f"{sum(ratings) / len(ratings):.1f}/5" if ratings else "—"]):
        col.metric(title, value)
    st.subheader("Respuestas de clientes")
    responses = data["respuestas"]
    n = sum(not response["leido"] for response in responses)
    if n and st.button(f"Marcar como leídas ({n})"):
        crm.mark_read(token)
        flash("Respuestas marcadas como leídas.")
    names = {c["id"]: label(c) for c in clients}
    for i, reply in enumerate(responses[:8]):
        left, right = st.columns([4, 1], vertical_alignment="center")
        left.text(f"{names.get(reply['cliente_id'], reply['cliente_id'])} · "
                  f"{'Encuesta' if reply['tipo'] == 'encuesta' else 'Invitación'}"
                  f"{' · Nueva' if not reply['leido'] else ''}")
        left.text(reply["resumen"] or "")
        if right.button("Ver cliente", key=f"reply_{i}"):
            visit("Clientes", reply["cliente_id"])
            st.rerun()
    if not responses:
        st.caption("Todavía no hay respuestas a los enlaces de correo.")
    st.subheader("Segmentos")
    st.bar_chart([{"Segmento": name, "Clientes": counts[name]} for name in SEGMENTOS], x="Segmento", y="Clientes", sort=False)
    st.subheader("Seguimientos sugeridos")
    pending = sorted((c for c in clients if segments[c["id"]]["segmento"] != "Sin permiso"),
                     key=lambda c: (PRIORITY[segments[c["id"]]["prioridad"]], c["compra_dias"] or 0))
    table([{"Cliente": label(c), "Prioridad": segments[c["id"]]["prioridad"], "Siguiente acción": segments[c["id"]]["accion"],
            "Plazo": segments[c["id"]]["plazo"]} for c in pending])


def client_form(crm, token, data, client=None):
    c = client or {}
    cid = c.get("id")
    key = cid or "new"
    advisers = [u["nombre"] for u in data["usuarios"] if u["rol"] == "estandar"]
    if not advisers:
        st.warning("Crea un asesor estándar en Equipo y correo antes de registrar un cliente.")
        return
    catalog = data["catalogo"]
    cars = {v["id"]: f"{v['modelo']} · {v['version']} · {euro(v['precio'])}" for v in catalog}
    left, right = st.columns(2)
    with left:
        name = st.text_input("Nombre", c.get("nombre") or "", max_chars=150, key=f"name_{key}")
        email = st.text_input("Correo", c.get("email") or "", max_chars=254, key=f"email_{key}")
        source = choose("Origen", ORIGENES, c.get("origen"), key=f"origin_{key}")
        channel = choose("Canal preferido", CONTACTO, c.get("canal"), format_func=CONTACTO.get, key=f"channel_{key}")
        budget = st.number_input("Presupuesto (€)", 1, 10**9, value=max(1, c.get("presupuesto") or 30000), key=f"budget_{key}")
        adviser = choose("Asesor", advisers, c.get("asesor"), key=f"adviser_{key}")
    with right:
        surname = st.text_input("Apellido", c.get("apellido") or "", max_chars=150, key=f"surname_{key}")
        phone = st.text_input("Teléfono", c.get("telefono") or "", max_chars=32, key=f"phone_{key}")
        consent = choose("Autoriza contacto comercial", ("No", "Si"), c.get("permiso"),
                         format_func=lambda v: "Sí" if v == "Si" else v, key=f"consent_{key}")
        tech = choose("Tecnología", TEC, c.get("tecnologia"), key=f"tech_{key}")
        days = st.number_input("Días previstos de compra", 0, 36500, value=(c.get("compra_dias") if c.get("compra_dias") is not None else 30), key=f"days_{key}")
        charging = choose("Carga habitual", CARGAS, c.get("carga") or "Por confirmar", key=f"charging_{key}")
    reco = recommendation(catalog, tech, budget, charging)
    vehicle = choose("Vehículo", [None, *cars], c.get("vehiculo"),
                     format_func=lambda v: cars[v] if v else "Usar la recomendación", key=f"vehicle_{key}")
    with st.expander("Ver recomendación"):
        car_card(reco["vehiculo"], compact=True)
        st.text(reco["motivo"])
        if reco["aviso"]:
            st.warning(reco["aviso"])
        alternatives = reco["alternativas"]
        if alternatives:
            st.caption("Opciones de la misma tecnología dentro del presupuesto")
            table([{"Modelo": v["modelo"], "Precio": euro(v["precio"]), "Disponible": bool(v["disponible"])} for v in alternatives])
        if reco["otra_tecnologia"]:
            st.caption(f"Alternativa de otra tecnología · {reco['otra_tecnologia']['modelo']}")
    if st.button("Guardar cambios" if cid else "Crear cliente", key=f"save_{key}", type="primary"):
        saved, _ = crm.save_client(token, dict(nombre=name, apellido=surname, email=email, telefono=phone, origen=source,
                                              permiso=consent, canal=channel, tecnologia=tech, presupuesto=budget,
                                              compra_dias=days, carga=charging, asesor=adviser, vehiculo=vehicle), cid)
        st.session_state.pop("_new_client", None)
        visit("Clientes", saved)
        flash("Cliente actualizado." if cid else f"Cliente {saved} registrado.")


def client_detail(crm, token, data, c, admin):
    cid = c["id"]
    seg = data["segmentos"][cid]
    st.subheader(label(c))
    profile, history, surveys = st.tabs(["Perfil", "Historial", "Encuestas"])
    with profile:
        left, right = st.columns(2)
        left.text(f"Asesor · {c['asesor']}")
        left.text(f"Origen · {c['origen']}  |  Canal · {CONTACTO.get(c['canal'], c['canal'])}")
        left.text(f"Presupuesto · {euro(c['presupuesto'])}  |  Compra · {c['compra_dias']} días")
        left.text(f"Tecnología · {c['tecnologia']}  |  Carga · {c['carga']}")
        left.text(f"{seg['segmento']} · Prioridad {seg['prioridad']}")
        left.text(f"{seg['accion']} · {seg['plazo']}")
        if c["permiso"] != "Si":
            left.warning("No autoriza contacto comercial.")
        if c["email"] or c["telefono"]:
            left.text(f"{c['email']}  |  {c['telefono']}")
        with right:
            car_card(seg["vehiculo"], compact=True)
        if admin and c["permiso"] == "Si":
            with st.expander("Enviar correo al cliente"):
                if seg["segmento"] != "Cita confirmada":
                    date = datetime_inputs(f"quick_inv_{cid}", "Proponer fecha y hora (opcional)", optional=True)
                    if st.button("Enviar invitación", key=f"quick_inv_{cid}", disabled=not crm.mailer.configured):
                        batch([cid], lambda client_id: crm.send_invitation(token, client_id, date), {cid: label(c)})
                kind = choose("Tipo de encuesta", TIPOS_ENCUESTA, key=f"quick_survey_type_{cid}")
                if st.button("Enviar encuesta", key=f"quick_survey_{cid}"):
                    batch([cid], lambda client_id: crm.send_survey(token, client_id, kind), {cid: label(c)})
        if admin:
            with st.expander("Editar perfil"):
                client_form(crm, token, data, c)
            with st.expander("Eliminar cliente"):
                confirmed = st.checkbox("Confirmo que quiero eliminar este cliente y su historial", key=f"confirm_delete_{cid}")
                if st.button("Eliminar cliente", disabled=not confirmed, key=f"delete_{cid}"):
                    crm.delete_client(token, cid)
                    flash("Cliente eliminado.")
    with history:
        entries = (row for row in reversed(data["interacciones"]) if row["cliente_id"] == cid)
        table([{"Fecha": row["fecha"], "Evento": row["evento"], "Canal": CONTACTO.get(row["canal"], row["canal"]),
                "Resultado": row["resultado"], "Acción": row["accion"], "Responsable": row["responsable"]} for row in entries])
        if c["permiso"] == "Si":
            with st.form(f"inter_{cid}", clear_on_submit=True):
                channel = choose("Canal", CANALES, c["canal"], format_func=lambda x: CONTACTO.get(x, x))
                event = choose("Evento", EVENTOS)
                result = st.text_area("Resultado", max_chars=2000)
                action = st.text_input("Siguiente acción", max_chars=1000)
                submitted = st.form_submit_button("Registrar interacción")
            if submitted:
                crm.interaction(token, cid, channel, event, result, action)
                visit("Clientes", cid)
                flash("Interacción registrada.")
    with surveys:
        survey_table(s for s in data["encuestas"] if s["cliente_id"] == cid)


def clients_view(crm, token, data, admin):
    st.title("Clientes" if admin else "Mis clientes")
    if admin and st.button("Nuevo cliente" if not st.session_state.get("_new_client") else "Cerrar alta de cliente"):
        st.session_state["_new_client"] = not st.session_state.get("_new_client")
    if admin and st.session_state.get("_new_client"):
        with st.container(border=True):
            st.subheader("Nuevo cliente")
            client_form(crm, token, data)
    opening = st.session_state.pop("_open_client", None)
    if opening:
        st.session_state["client_selected"] = opening
        st.session_state["client_search"] = ""
        st.session_state["client_segment"] = "Todos"
    left, right = st.columns(2)
    query = left.text_input("Buscar cliente", placeholder="Nombre, correo, teléfono, asesor o ID", key="client_search").strip().casefold()
    segment = right.selectbox("Segmento", ["Todos", *SEGMENTOS], key="client_segment")
    segments = data["segmentos"]
    filtered = [c for c in data["clientes"]
                if (not query or query in " ".join(str(c.get(k) or "") for k in ("id", "nombre", "apellido", "email", "telefono", "asesor")).casefold())
                and (segment == "Todos" or segments[c["id"]]["segmento"] == segment)]
    table([{"Cliente": label(c), "Asesor": c["asesor"], "Tecnología": c["tecnologia"], "Presupuesto": euro(c["presupuesto"]),
            "Segmento": segments[c["id"]]["segmento"], "Prioridad": segments[c["id"]]["prioridad"]} for c in filtered])
    if admin and filtered:
        st.download_button("Descargar CSV", csv_clients(filtered, segments), "ecoruta-clientes.csv", "text/csv")
    labels = {c["id"]: label(c) for c in filtered}
    cid = choose("Abrir ficha de cliente", [None, *labels], key="client_selected",
                 format_func=lambda x: labels[x] if x else "Selecciona un cliente")
    if cid in labels:
        client_detail(crm, token, data, next(c for c in filtered if c["id"] == cid), admin)


def batch(items, operation, labels):
    results = []
    for cid in items:
        try:
            status, detail = operation(cid)
        except RuleError as error:
            status, detail = "error", str(error)
        results.append({"Cliente": labels[cid], "Estado": status, "Detalle": detail})
    table(results)


def invitations(crm, token, data):
    st.title("Invitaciones test drive")
    with st.expander("Plantilla del correo"):
        st.caption("Variables disponibles en la plantilla")
        st.code("{nombre} {apellido} {vehiculo} {tecnologia} {precio} {fecha} {asesor}")
        with st.form("template_form"):
            template = st.text_area("Texto de la invitación", value=data["plantilla"], height=220, max_chars=12000)
            saved = st.form_submit_button("Guardar plantilla")
        if saved:
            crm.set_template(token, template)
            flash("Plantilla actualizada.")
    visits = {i["cliente_id"] for i in data["interacciones"]
              if i["canal"] == "Visita" or i["evento"] == "Visita concesionario"}
    scope = choose("Mostrar clientes", ("Visitaron el concesionario", "Listos para prueba", "Todos los clientes"))
    eligible = {
        c["id"]: label(c) for c in data["clientes"]
        if c["permiso"] == "Si" and "Cita confirmada" not in data["eventos"][c["id"]]
        and (scope == "Todos los clientes"
             or scope == "Visitaron el concesionario" and (c["id"] in visits or c["origen"] == "Visita")
             or scope == "Listos para prueba" and data["segmentos"][c["id"]]["segmento"] == "Listo para prueba")
    }
    st.caption("Solo se pueden invitar clientes con permiso que no tengan cita confirmada.")
    if not crm.settings.production:
        st.info("En modo local, el enlace del correo solo abre desde este equipo si PUBLIC_URL apunta a localhost.")
    if not eligible:
        st.info("No hay clientes elegibles para una invitación.")
        return
    selected = st.multiselect("Clientes destinatarios", list(eligible), format_func=eligible.get)
    date = datetime_inputs("invite", "Proponer fecha y hora (opcional)", optional=True)
    sample = choose("Cliente para la vista previa", eligible, selected[0] if selected else None, format_func=eligible.get)
    with st.expander("Vista previa"):
        preview = crm.preview_invitation(token, sample, date)
        car_card(preview["vehiculo"], compact=True)
        st.text(preview["texto"])
        st.text(f"Fecha propuesta · {preview['fecha']}")
    if st.button("Enviar invitaciones", disabled=not selected or not crm.mailer.configured, type="primary"):
        with st.spinner("Enviando invitaciones…"):
            batch(selected, lambda cid: crm.send_invitation(token, cid, date), eligible)
    if not crm.mailer.configured:
        st.warning("Configura Gmail en Equipo y correo antes de enviar.")


def survey_answers(key):
    sat = st.radio("Satisfacción con la experiencia", (1, 2, 3, 4, 5), index=None, horizontal=True, key=f"{key}_sat")
    nps = st.selectbox("¿Qué probabilidad hay de que nos recomiendes? (0 a 10)", list(range(11)), index=None, key=f"{key}_nps")
    interest = st.radio("¿Te interesa realizar un test drive?", INTERES, index=None, horizontal=True, key=f"{key}_interest")
    comment = st.text_area("Comentario (opcional)", max_chars=1000, key=f"{key}_comment")
    return dict(satisfaccion=sat, nps=nps, interes=interest, comentario=comment)


def survey_table(items, labels=None):
    table([{"Encuesta": e["id"], **({"Cliente": labels.get(e["cliente_id"], e["cliente_id"])} if labels else {}),
            "Tipo": e["tipo"], "Canal": e["canal"], "Enviada": e["enviada"], "Estado": e["estado"],
            "Satisfacción": e["respuestas"].get("satisfaccion"), "Recomendación": e["respuestas"].get("nps"),
            "Interés": e["respuestas"].get("interes"), "Comentario": e["respuestas"].get("comentario")} for e in items])


def surveys_view(crm, token, data):
    st.title("Encuestas")
    all_surveys = data["encuestas"]
    answers = [e["respuestas"] for e in all_surveys if e["estado"] == "Respondida"]
    scores = [a["nps"] for a in answers if isinstance(a.get("nps"), int)]
    ratings = [a["satisfaccion"] for a in answers if isinstance(a.get("satisfaccion"), int)]
    nps = 100 * (sum(x >= 9 for x in scores) - sum(x <= 6 for x in scores)) / len(scores) if scores else None
    for col, title, value in zip(st.columns(5), ("Encuestas", "Respondidas", "Satisfacción media", "NPS", "Quieren test drive"),
                                 (len(all_surveys), len(answers), f"{sum(ratings)/len(ratings):.1f}/5" if ratings else "—",
                                  f"{nps:.0f}" if nps is not None else "—", sum(a.get("interes") == "Sí" for a in answers))):
        col.metric(title, value)
    labels = {c["id"]: label(c) for c in data["clientes"]}
    eligible = {c["id"]: labels[c["id"]] for c in data["clientes"] if c["permiso"] == "Si"}
    with st.form("send_surveys"):
        kind = choose("Tipo de encuesta", TIPOS_ENCUESTA)
        selected = st.multiselect("Clientes destinatarios", list(eligible), format_func=eligible.get)
        sent = st.form_submit_button("Enviar encuestas", disabled=not eligible, type="primary")
    if sent:
        if not selected:
            st.warning("Selecciona al menos un cliente.")
        else:
            with st.spinner("Enviando encuestas…"):
                batch(selected, lambda cid: crm.send_survey(token, cid, kind), labels)
            all_surveys = crm.snapshot(token)["encuestas"]
    survey_table(all_surveys, labels)
    pending = {e["id"]: f"{e['id']} · {labels.get(e['cliente_id'], e['cliente_id'])} · {e['tipo']}"
               for e in all_surveys if e["estado"] != "Respondida"}
    if pending:
        with st.expander("Registrar respuesta manual"):
            eid = choose("Encuesta pendiente", pending, format_func=pending.get)
            with st.form(f"manual_survey_{eid}", clear_on_submit=True):
                values = survey_answers("manual")
                submitted = st.form_submit_button("Guardar respuesta")
            if submitted:
                crm.answer_survey(token, eid, values["satisfaccion"], values["nps"], values["interes"], values["comentario"])
                flash("Respuesta registrada.")


def catalog_view(crm, token, data, admin):
    st.title("Catálogo")
    st.caption("Precios de referencia. Confirma el precio y el stock antes de ofrecer una unidad.")
    filter_tech = choose("Tecnología", ["Todas", *TEC])
    cars = [c for c in data["catalogo"] if filter_tech == "Todas" or c["tec"] == filter_tech]
    for offset in range(0, len(cars), 3):
        for col, car in zip(st.columns(3), cars[offset:offset + 3]):
            with col.container(border=True):
                car_card(car)
                st.caption(TEC.get(car["tec"], car["tec"]))
                st.text(f"Carga · {car['recarga']}  |  Uso · {car['uso']}  |  Base · {car['base']}")
                st.caption("Disponible para prueba" if car["disponible"] else "No disponible para prueba")
                if admin and st.button("Marcar no disponible" if car["disponible"] else "Marcar disponible", key=f"stock_{car['id']}"):
                    crm.set_available(token, car["id"], not car["disponible"])
                    flash("Disponibilidad actualizada.")


def team(crm, token, data):
    st.title("Equipo y correo")
    users = data["usuarios"]
    roles = {"admin": "Administrador", "estandar": "Estándar"}
    table([{"Nombre": u["nombre"], "Correo": u["email"], "Rol": roles[u["rol"]], "Con acceso": bool(u["acceso"])} for u in users])
    with st.expander("Añadir usuario"):
        with st.form("add_user", clear_on_submit=True):
            name = st.text_input("Nombre", max_chars=150)
            email = st.text_input("Correo", max_chars=254)
            password = st.text_input("Contraseña", type="password", max_chars=256)
            role = choose("Rol", roles, "estandar", format_func=roles.get)
            submitted = st.form_submit_button("Crear usuario")
        if submitted:
            crm.add_user(token, name, email, password, role)
            flash("Usuario creado.")
    with st.expander("Activar acceso o cambiar contraseña"):
        mapping = {u["id"]: u for u in users}
        target = choose("Usuario", mapping, format_func=lambda uid: mapping[uid]["nombre"])
        if target:
            with st.form(f"change_access_{target}", clear_on_submit=True):
                email = st.text_input("Correo de acceso", mapping[target]["email"] or "", max_chars=254)
                password = st.text_input("Contraseña nueva", type="password", max_chars=256)
                submitted = st.form_submit_button("Guardar acceso")
            if submitted:
                crm.change_access(token, target, email, password)
                flash("Acceso actualizado. Las otras sesiones del usuario se cerraron.")
    st.subheader("Correo saliente")
    st.write("Gmail SMTP con contraseña de aplicación.")
    if crm.mailer.configured:
        st.caption("Hay credenciales configuradas. El estado se comprueba al enviar.")
        with st.form("test_mail"):
            to = st.text_input("Enviar prueba a", value=crm.settings.gmail_user, max_chars=254)
            submitted = st.form_submit_button("Enviar correo de prueba")
        if submitted:
            delivery = crm.test_mail(token, to)
            (st.success if delivery.ok else st.error)(delivery.detail)
    else:
        st.warning("Configura GMAIL_USER y GMAIL_APP_PASSWORD en los secretos del despliegue o en el .env local.")


def public_page(crm, token):
    details = crm.public_details(token)
    st.title("EcoRuta Madrid")
    if not details:
        st.error("Este enlace no es válido o ya no está disponible.")
        return
    is_survey = details["tipo"] == "encuesta"
    st.subheader("Encuesta de satisfacción" if is_survey else "Invitación a un test drive")
    st.text(f"Hola, {details['nombre']}.")
    if details["respondido"]:
        st.success("Ya recibimos tu respuesta. Gracias.")
        st.text(details["resumen"] or "")
        return
    if is_survey:
        with st.form("public_survey", clear_on_submit=True):
            values = survey_answers("public")
            submitted = st.form_submit_button("Enviar respuesta", type="primary")
        if submitted:
            crm.answer_public(token, values)
            st.rerun()
        return
    car_card(details["vehiculo"], compact=True)
    st.text(f"Tu asesor o asesora · {details['asesor']}")
    date = details["fecha"]
    if date:
        st.text(f"Fecha propuesta · {date_text(date)} (Madrid)")
    choices = [key for key in RESPUESTAS_INV if key != "confirmo" or date]
    choice = st.radio("¿Qué prefieres?", choices, format_func=RESPUESTAS_INV.get, index=None)
    alternative = datetime_inputs("public_inv", "Proponer fecha y hora en Madrid") if choice == "otra_fecha" else None
    comment = st.text_area("Comentario (opcional)", max_chars=1000)
    if st.button("Enviar respuesta", type="primary", disabled=not choice):
        crm.answer_public(token, dict(opcion=choice, fecha=alternative, comentario=comment))
        st.rerun()


def main():
    st.set_page_config(page_title="EcoRuta CRM", page_icon="🌱", layout="wide")
    try:
        extra = st.secrets.to_dict()
    except (FileNotFoundError, StreamlitSecretNotFoundError):
        extra = {}
    crm = open_crm(Settings.load(extra))
    if "r" in st.query_params:
        public_page(crm, st.query_params["r"])
        return
    token = st.session_state.get("_token")
    actor = crm.actor(token)
    if not actor:
        st.session_state.pop("_token", None)
        login(crm)
        return
    admin = actor["rol"] == "admin"
    messages = st.session_state.pop("_flash", None)
    if messages:
        st.success(messages)
    data = crm.snapshot(token)
    st.sidebar.title("EcoRuta CRM")
    st.sidebar.text(actor["nombre"])
    st.sidebar.caption("Administrador" if admin else "Asesor")
    if st.sidebar.button("Cerrar sesión"):
        crm.logout(token)
        st.session_state.clear()
        st.rerun()
    scope = MENU if admin else (MENU[0], MENU[1], MENU[4])
    view = st.session_state.get("_menu", scope[0])
    # El botón de una respuesta puede cambiar la página en el siguiente rerun.
    if view not in scope:
        view = scope[0]
    if st.session_state.get("_nav") != view:
        st.session_state["_nav"] = view
    st.sidebar.radio("Navegación", scope, key="_nav", on_change=lambda: visit(st.session_state["_nav"]))
    if view == MENU[0]:
        panel(crm, token, data, admin)
    elif view == MENU[1]:
        clients_view(crm, token, data, admin)
    elif view == MENU[2]:
        invitations(crm, token, data)
    elif view == MENU[3]:
        surveys_view(crm, token, data)
    elif view == MENU[4]:
        catalog_view(crm, token, data, admin)
    else:
        team(crm, token, data)


try:
    main()
except (ConfigError, RuleError) as error:
    st.error(str(error))
except (PostgreSQLError, sqlite3.Error, OSError) as error:
    logging.error("No se pudo completar una operación del CRM (%s).", type(error).__name__)
    st.error("No se pudo completar la operación. Revisa la conexión con la base de datos, su esquema y sus permisos.")
