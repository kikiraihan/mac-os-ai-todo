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
DATA_DIR="$WORK/data" ADDR=127.0.0.1:8099 SECURE_COOKIES=false ADMIN_USERNAME=admin \
  ADMIN_PASSWORD=password-tes-klien-123 "$WORK/aitodo" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1 && break; sleep 0.2; done

"$SWIFTC" -O Sources/AITodo/Client.swift Tests/ClientCheck/main.swift -o "$WORK/client-check"
AITODO_URL=http://127.0.0.1:8099 AITODO_USER=admin AITODO_PASS=password-tes-klien-123 "$WORK/client-check"
