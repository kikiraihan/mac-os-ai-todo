#!/bin/bash
# Uji klien Mac (Sources/AITodo/Client.swift) terhadap server Go asli.
# Jalan di Linux (toolchain Swift) maupun macOS. Server dijalankan sementara di port 8099
# dengan database baru di folder sementara.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
WORK="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

(cd server && go build -o "$WORK/aitodo" ./cmd/server)
DATA_DIR="$WORK/data" ADDR=127.0.0.1:8099 SECURE_COOKIES=false ADMIN_USERNAME=admin GITHUB_RELEASE_REPO= \
  ADMIN_PASSWORD=password-tes-klien-123 "$WORK/aitodo" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1 && break; sleep 0.2; done

# Akun admin terpisah dari akun pengguna: admin awal membuat akun pengguna (username sama) untuk aplikasi Mac.
API=http://127.0.0.1:8099/api
curl -fsS -c "$WORK/admin.jar" -H 'X-AITodo: 1' -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"password-tes-klien-123"}' "$API/admin/login" >/dev/null
curl -fsS -b "$WORK/admin.jar" -H 'X-AITodo: 1' -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"password-pengguna-456"}' "$API/admin/users" >/dev/null

"$SWIFTC" -O Sources/AITodo/Client.swift Tests/ClientCheck/main.swift -o "$WORK/client-check"
AITODO_URL=http://127.0.0.1:8099 AITODO_USER=admin AITODO_PASS=password-pengguna-456 \
  AITODO_ADMIN_PASS=password-tes-klien-123 "$WORK/client-check"
