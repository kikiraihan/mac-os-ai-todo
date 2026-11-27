#!/bin/bash
# Uji klien Android (android/app/.../Api.kt) terhadap server Go asli — pola sama dengan test-client.sh.
# Butuh Android SDK (local.properties: sdk.dir=…) dan JDK 17+.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

(cd server && go build -o "$WORK/aitodo" ./cmd/server)
DATA_DIR="$WORK/data" ADDR=127.0.0.1:8098 SECURE_COOKIES=false ADMIN_USERNAME=admin GITHUB_RELEASE_REPO= \
  ADMIN_PASSWORD=password-tes-android-123 "$WORK/aitodo" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS http://127.0.0.1:8098/api/health >/dev/null 2>&1 && break; sleep 0.2; done

API=http://127.0.0.1:8098/api
curl -fsS -c "$WORK/admin.jar" -H 'X-AITodo: 1' -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"password-tes-android-123"}' "$API/admin/login" >/dev/null
curl -fsS -b "$WORK/admin.jar" -H 'X-AITodo: 1' -H 'Content-Type: application/json' \
  -d '{"username":"budi","password":"password-pengguna-456"}' "$API/admin/users" >/dev/null

cd android
AITODO_URL=http://127.0.0.1:8098 AITODO_USER=budi AITODO_PASS=password-pengguna-456 \
  ./gradlew --no-daemon -q testDebugUnitTest --tests '*ServerIntegrationTest*' --rerun
echo "Tes klien Android ⇄ server: LULUS"
