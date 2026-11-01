.PHONY: help dev-server dev-web build web test ci up down logs ps backup version deploy deploy-remote rollback health

VERSION := $(shell cat VERSION)
COMPOSE ?= docker compose
BACKUP_DIR ?= backups
TS := $(shell date +%Y%m%d-%H%M%S)

# --- Konfigurasi deploy (lihat CICD.md) --------------------------------------
# DEPLOY_BRANCH : branch yang di-deploy ke produksi
# SSH_TARGET    : user@host VPS, atau alias dari ~/.ssh/config (untuk deploy-remote)
# SSH_PORT      : port SSH VPS
# REMOTE_DIR    : lokasi repo di VPS
DEPLOY_BRANCH ?= main
SSH_TARGET    ?=
SSH_PORT      ?= 22
REMOTE_DIR    ?= /var/www/ai-todo
APP_PORT_ENV   = $(shell [ -f .env ] && grep -E '^[[:space:]]*(export[[:space:]]+)?APP_PORT[[:space:]]*=' .env | tail -1 | sed -E 's/^[^=]*=//; s/\#.*$$//' | tr -d '"'\''[:space:]')
APP_PORT      ?= $(if $(APP_PORT_ENV),$(APP_PORT_ENV),8095)

help: ## Daftar perintah
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "\033[36m%-12s\033[0m %s\n",$$1,$$2}'

dev-server: ## Jalankan server lokal (http://127.0.0.1:8080, cookie tanpa Secure)
	cd server && DATA_DIR=../data SECURE_COOKIES=false go run ./cmd/server

dev-web: ## Jalankan Vite dev server (http://localhost:5173, proxy /api ke :8080)
	cd web && npm run dev

web: ## Build PWA ke server/internal/webui/dist
	cd web && npm ci && npm run build

build: web ## Build satu binary (PWA tertanam) ke build/aitodo
	mkdir -p build && cd server && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o ../build/aitodo ./cmd/server

test: ## Tes server
	cd server && go test -race ./...

ci: ## Cek seperti CI: format, vet, tes, build web
	cd server && test -z "$$(gofmt -l .)" && go vet ./... && go test -race ./...
	cd web && npm ci && npm run build

up: ## Build & jalankan container (butuh .env)
	@test -f .env || (echo "Salin .env.example ke .env dan isi dulu" && exit 1)
	VERSION=$(VERSION) $(COMPOSE) up -d --build

down: ## Hentikan container (data tetap di volume)
	$(COMPOSE) down

logs: ## Ikuti log
	$(COMPOSE) logs -f

ps: ## Status container
	$(COMPOSE) ps

backup: ## Salin database (aman saat berjalan) ke ./backups/
	@mkdir -p $(BACKUP_DIR)
	$(COMPOSE) exec -T aitodo aitodo backup /data/backup-$(TS).db
	$(COMPOSE) cp aitodo:/data/backup-$(TS).db $(BACKUP_DIR)/aitodo-$(TS).db
	$(COMPOSE) exec -T aitodo rm /data/backup-$(TS).db
	@echo "Backup: $(BACKUP_DIR)/aitodo-$(TS).db"

version: ## Versi di repo + commit yang sedang ter-deploy
	@echo "VERSION: $(VERSION)"
	@git log -1 --format='commit : %h %s (%cr)'

deploy: ## [DI VPS] Pull kode terbaru + backup + rebuild + health check + auto-rollback
	DEPLOY_BRANCH=$(DEPLOY_BRANCH) ./scripts/deploy.sh

deploy-remote: ## [DI LOKAL] Trigger deploy di VPS via SSH: make deploy-remote SSH_TARGET=user@ip
	@if [ -z "$(SSH_TARGET)" ]; then \
		echo "Gunakan: make deploy-remote SSH_TARGET=user@ip [SSH_PORT=22] [REMOTE_DIR=/var/www/ai-todo]"; \
		exit 1; \
	fi
	ssh -p $(SSH_PORT) $(SSH_TARGET) "cd $(REMOTE_DIR) && DEPLOY_BRANCH=$(DEPLOY_BRANCH) ./scripts/deploy.sh"

rollback: ## [DI VPS] Kembali ke commit sebelum deploy terakhir (atau: make rollback SHA=abc1234)
	./scripts/rollback.sh $(SHA)

health: ## Cek endpoint health app di localhost VPS
	@curl -fsS --max-time 5 http://127.0.0.1:$(APP_PORT)/api/health && echo "" || \
		(echo "Health check GAGAL di http://127.0.0.1:$(APP_PORT)/api/health"; exit 1)
