.PHONY: help dev-server dev-web build web test ci up down logs backup version

VERSION := $(shell cat VERSION)
COMPOSE ?= docker compose
BACKUP_DIR ?= backups
TS := $(shell date +%Y%m%d-%H%M%S)

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

backup: ## Salin database (aman saat berjalan) ke ./backups/
	@mkdir -p $(BACKUP_DIR)
	$(COMPOSE) exec -T aitodo aitodo backup /data/backup-$(TS).db
	$(COMPOSE) cp aitodo:/data/backup-$(TS).db $(BACKUP_DIR)/aitodo-$(TS).db
	$(COMPOSE) exec -T aitodo rm /data/backup-$(TS).db
	@echo "Backup: $(BACKUP_DIR)/aitodo-$(TS).db"

version: ## Tampilkan versi
	@echo $(VERSION)
