#!/bin/bash
# Doble clic para arrancar el CRM EcoRuta (backend + frontend). Cierra esta ventana para detenerlo.
cd "$(dirname "$0")" || exit 1
PORT=$(grep -E '^PORT=' .env 2>/dev/null | cut -d= -f2)
PORT=${PORT:-8080}
(sleep 1.5; open "http://localhost:$PORT") &
/usr/bin/perl backend/server.pl
