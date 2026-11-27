#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
read -r sim_port app_port < <(python3 -c 'import socket; s=[socket.socket() for _ in range(2)]; [x.bind(("127.0.0.1", 0)) for x in s]; print(*(x.getsockname()[1] for x in s))')
sim=
app=
cleanup() {
  for pid in "$sim" "$app"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
postman simulation run postman/simulations/gmail.sim.yaml --no-history --port "$sim_port" --output ndjson > "$tmp/sim.ndjson" 2> "$tmp/sim.err" &
sim=$!
sim_url="http://127.0.0.1:$sim_port/gmail"
app_url="http://127.0.0.1:$app_port"
env DB_PATH="$tmp/gmail.sqlite3" PORT="$app_port" BIND_HOST=127.0.0.1 PUBLIC_URL="$app_url" SEED_DEMO=0 APP_ENV=local \
  OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES MAIL_TRANSPORT=gmail_api GMAIL_USER=qa@example.test NOTIFY_EMAIL=qa@example.test \
  GMAIL_OAUTH_CLIENT_ID=fixture-client GMAIL_OAUTH_CLIENT_SECRET=fixture-secret GMAIL_OAUTH_REFRESH_TOKEN=fixture-refresh \
  GMAIL_TEST_SIM_URL="$sim_url" \
  perl -Ibackend/lib -Itests/lib -MEcoRuta::TestGmailHTTP backend/server.pl > "$tmp/gmail.log" 2>&1 &
app=$!
for attempt in {1..30}; do
  if curl -fsS "$sim_url/__test/results" > /dev/null 2>&1 && curl -fsS "$app_url/healthz" > /dev/null 2>&1; then break; fi
  sleep 0.25
done
if ! python3 tests/gmail_integration.py "$app_url" "$sim_url"; then
  cat "$tmp/sim.err" "$tmp/gmail.log"
  tail -16 "$tmp/sim.ndjson"
  exit 1
fi
python3 - "$tmp/sim.ndjson" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    requests = [json.loads(l) for l in f if l.startswith('{')]
sent = [r for r in requests if r.get('event') == 'request' and r.get('method') == 'POST' and r.get('path') == '/gmail/v1/users/me/messages/send']
assert sorted(r['statusCode'] for r in sent) == [200, 200, 200, 200, 401, 429, 503, 503, 503]
print(f"Simulación verificada: {len(sent)} llamadas de envío, sin tráfico a Google.")
PY
