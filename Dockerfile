FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl tzdata perl libhttp-daemon-perl liburi-perl \
       libdbi-perl libdbd-pg-perl libdbd-sqlite3-perl libio-socket-ssl-perl \
       libauthen-sasl-perl starman \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 ecoruta \
    && useradd --uid 10001 --gid ecoruta --no-create-home --shell /usr/sbin/nologin ecoruta \
    && install -d -m 0700 -o ecoruta -g ecoruta /app/backend/data

WORKDIR /app
COPY backend/server.pl backend/schema.sql ./backend/
COPY backend/lib/ ./backend/lib/
COPY frontend/index.html ./frontend/
COPY frontend/img/V*.jpg ./frontend/img/
RUN perl -c backend/server.pl

ENV BIND_HOST=0.0.0.0 PORT=8080 HTTP_ENGINE=starman SEED_DEMO=0 TZ=Europe/Madrid
USER ecoruta
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=8s --start-period=20s \
  CMD curl -fsS --max-time 7 "http://127.0.0.1:$PORT/livez" > /dev/null || exit 1
ENTRYPOINT ["perl", "backend/server.pl"]
