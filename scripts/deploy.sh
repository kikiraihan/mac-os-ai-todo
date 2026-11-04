#!/usr/bin/env bash
#
# Deploy script yang dijalankan DI VPS (lewat `make deploy`, SSH manual, atau
# GitHub Actions). Alurnya:
#
#   1. pastikan .env ada & repo bersih
#   2. backup SQLite dulu (kalau container sedang jalan) — `aitodo backup`
#      memakai VACUUM INTO, jadi salinannya konsisten walau server sedang menulis
#   3. git fetch + reset --hard ke origin/<branch>
#      (dari GitHub Actions: kode dikirim sebagai git bundle lewat SSH, jadi VPS
#      tidak butuh kredensial GitHub walau repo-nya private)
#   4. docker compose up -d --build
#   5. health check ke 127.0.0.1:$APP_PORT/api/health
#   6. kalau health check gagal -> otomatis rollback ke commit sebelumnya
#
# Variabel yang bisa dioverride lewat environment:
#   DEPLOY_BRANCH   (default: main)
#   HEALTH_RETRIES  (default: 30)   percobaan health check
#   HEALTH_DELAY    (default: 2)    jeda detik antar percobaan
#   SKIP_BACKUP     (default: 0)    set 1 untuk lewati backup DB
#   NO_ROLLBACK     (default: 0)    set 1 untuk biarkan versi gagal tetap jalan
#   DEPLOY_BUNDLE   (default: kosong) path git bundle berisi commit yang di-deploy;
#                   kalau diisi, kode diambil dari bundle ini, bukan `git fetch origin`
#   DEPLOY_EXPECT_SHA (opsional)    commit yang wajib ada di bundle (pengaman)
#   DEPLOY_APP_DIR  (opsional)      folder repo di VPS; wajib kalau script ini
#                   dijalankan dari luar repo (mis. salinan kiriman GitHub Actions)
#
set -euo pipefail

# --- Jalankan dari salinan sementara -----------------------------------------
# `git reset --hard` di tengah eksekusi bisa mengubah file script yang sedang
# dibaca bash. Jadi begitu masuk, script menyalin dirinya ke /tmp lalu exec dari
# sana supaya isi script stabil selama deploy berlangsung.
if [ "${DEPLOY_SELF_COPY:-0}" != "1" ]; then
	_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	# DEPLOY_APP_DIR boleh diisi dari luar: GitHub Actions menjalankan salinan
	# script versi terbaru dari folder sementara, bukan dari dalam repo.
	_root="${DEPLOY_APP_DIR:-$(cd "$(dirname "$_self")/.." && pwd)}"
	_copy="$(mktemp -t aitodo-deploy.XXXXXX)"
	cp "$_self" "$_copy"
	chmod +x "$_copy"
	DEPLOY_SELF_COPY=1 DEPLOY_APP_DIR="$_root" DEPLOY_SELF_TMP="$_copy" exec "$_copy" "$@"
fi
trap 'rm -f "${DEPLOY_SELF_TMP:-}"' EXIT

APP_DIR="${DEPLOY_APP_DIR:?DEPLOY_APP_DIR tidak terisi}"
cd "$APP_DIR"

BRANCH="${DEPLOY_BRANCH:-main}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_DELAY="${HEALTH_DELAY:-2}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
NO_ROLLBACK="${NO_ROLLBACK:-0}"
PREV_FILE="$APP_DIR/.deploy-previous"
SERVICE=aitodo

log()  { printf '\033[36m[deploy %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[deploy %s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[31m[deploy %s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

compose() { docker compose "$@"; }

# Hanya bilangan bulat: aritmetika bash di bawah gagal diam-diam untuk nilai
# seperti "0.5" dan bisa membuat blok rollback terlewat.
case "$HEALTH_RETRIES$HEALTH_DELAY" in *[!0-9]*|'') die "HEALTH_RETRIES dan HEALTH_DELAY harus bilangan bulat." ;; esac

# Jangan pernah menunggu input user (deploy jalan non-interaktif lewat SSH dari
# GitHub Actions; prompt username/password git akan bikin job menggantung).
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"

# --- 1. Pra-syarat ------------------------------------------------------------
[ -f .env ] || die ".env belum ada di $APP_DIR. Ikuti DEPLOY.md §4 dulu."
command -v git >/dev/null    || die "git tidak terpasang di server."
command -v docker >/dev/null || die "docker tidak terpasang di server."
command -v curl >/dev/null   || die "curl tidak terpasang di server."
docker compose version >/dev/null 2>&1 || die "plugin 'docker compose' tidak tersedia (butuh Compose v2)."

APP_PORT="$(grep -E '^[[:space:]]*(export[[:space:]]+)?APP_PORT[[:space:]]*=' .env | tail -1 | sed -E 's/^[^=]*=//; s/#.*$//' | tr -d '"'\''[:space:]')"
APP_PORT="${APP_PORT:-8095}"

if grep -qE '^ADMIN_PASSWORD=GANTI' .env; then
	die "ADMIN_PASSWORD di .env masih password contoh; server akan menolak start. Lihat DEPLOY.md §4."
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	warn "Ada perubahan lokal yang belum di-commit di server:"
	git status --short --untracked-files=no
	warn "Perubahan ini akan DITIMPA oleh git reset --hard."
fi

# --- 2. Backup database -------------------------------------------------------
if [ "$SKIP_BACKUP" != "1" ] && [ -n "$(compose ps -q "$SERVICE" 2>/dev/null)" ]; then
	mkdir -p backups
	stamp="$(date +%Y%m%d-%H%M%S)"
	tmp="/data/predeploy-$stamp.db"
	if compose exec -T "$SERVICE" aitodo backup "$tmp" >/dev/null 2>&1 \
		&& compose cp "$SERVICE:$tmp" "backups/aitodo-predeploy-$stamp.db" >/dev/null 2>&1; then
		chmod 600 "backups/aitodo-predeploy-$stamp.db" || true
		log "Backup DB -> backups/aitodo-predeploy-$stamp.db"
		# Simpan 10 backup pre-deploy terakhir saja.
		ls -1t backups/aitodo-predeploy-*.db 2>/dev/null | tail -n +11 | xargs -r rm -f
	else
		warn "Backup DB gagal (container mungkin belum sehat / belum punya data). Lanjut deploy."
	fi
	compose exec -T "$SERVICE" rm -f "$tmp" >/dev/null 2>&1 || true
else
	log "Lewati backup DB."
fi

# --- 3. Ambil kode terbaru ----------------------------------------------------
OLD_SHA="$(git rev-parse HEAD)"
log "Commit saat ini : $(git log -1 --format='%h %s' "$OLD_SHA")"

if [ -n "${DEPLOY_BUNDLE:-}" ]; then
	# Kode dikirim GitHub Actions sebagai git bundle (riwayat lengkap, tanpa prasyarat).
	log "Ambil kode dari bundle kiriman GitHub Actions ..."
	[ -f "$DEPLOY_BUNDLE" ] || die "Bundle tidak ditemukan: $DEPLOY_BUNDLE"
	git bundle verify -q "$DEPLOY_BUNDLE" >/dev/null 2>&1 || die "Bundle rusak / tidak valid: $DEPLOY_BUNDLE"
	git fetch -q "$DEPLOY_BUNDLE" "+HEAD:refs/remotes/origin/$BRANCH" \
		|| die "Gagal mengambil commit dari bundle."
	if [ -n "${DEPLOY_EXPECT_SHA:-}" ] && [ "$(git rev-parse "origin/$BRANCH")" != "$DEPLOY_EXPECT_SHA" ]; then
		die "Isi bundle ($(git rev-parse --short "origin/$BRANCH")) tidak sama dengan commit yang diminta ($DEPLOY_EXPECT_SHA)."
	fi
elif ! { log "git fetch origin $BRANCH ..."; git fetch --prune origin "$BRANCH"; }; then
	remote_url="$(git remote get-url origin 2>/dev/null || echo '?')"
	warn "git fetch gagal. Remote saat ini: $remote_url"
	case "$remote_url" in
		https://*)
			warn "Remote memakai HTTPS. Kalau repo-nya dijadikan private, server tidak punya kredensial"
			warn "dan git tidak bisa menanyakannya (deploy jalan non-interaktif)."
			warn "Deploy otomatis dari GitHub Actions tidak butuh ini (kode dikirim sebagai bundle)."
			warn "Untuk 'make deploy' dari VPS: pasang deploy key lalu pindah ke remote SSH — lihat CICD.md langkah A4."
			;;
		git@*|ssh://*)
			ssh_host="${remote_url#git@}"; ssh_host="${ssh_host%%:*}"
			warn "Remote memakai SSH. Cek dari user ini: ssh -T git@${ssh_host}"
			warn "Pastikan deploy key masih aktif di repo GitHub, alias '${ssh_host}' ada di"
			warn "~/.ssh/config, dan host key GitHub ada di ~/.ssh/known_hosts."
			;;
	esac
	die "Tidak bisa mengambil kode terbaru dari origin/$BRANCH."
fi
NEW_SHA="$(git rev-parse "origin/$BRANCH")"

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
	log "Sudah di commit terbaru ($(git rev-parse --short "$NEW_SHA")). Tetap rebuild & restart untuk memastikan container sinkron."
else
	log "Update ke     : $(git log -1 --format='%h %s' "$NEW_SHA")"
fi

echo "$OLD_SHA" > "$PREV_FILE"
git reset --hard "$NEW_SHA"

# --- 4 & 5. Build, jalankan, health check ------------------------------------
health_check() {
	local url="http://127.0.0.1:${APP_PORT}/api/health"
	local i
	for i in $(seq 1 "$HEALTH_RETRIES"); do
		if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
			log "Health check OK ($url) setelah ${i}x percobaan."
			return 0
		fi
		sleep "$HEALTH_DELAY"
	done
	return 1
}

bring_up() {
	export VERSION
	VERSION="$(cat VERSION 2>/dev/null || echo dev)"
	log "docker compose up -d --build (versi $VERSION) ..."
	compose up -d --build
}

rollback() {
	log "Rollback ke $(git rev-parse --short "$OLD_SHA") ..."
	git reset --hard "$OLD_SHA"
	bring_up
}

if ! bring_up; then
	warn "Build/start gagal."
	if [ "$NO_ROLLBACK" = "1" ]; then die "Deploy gagal saat build (rollback dimatikan)."; fi
	rollback || die "Rollback juga gagal. Perlu cek manual di server!"
	die "Deploy gagal saat build; sudah rollback ke commit sebelumnya."
fi

if ! health_check; then
	warn "Health check GAGAL setelah $((HEALTH_RETRIES * HEALTH_DELAY)) detik."
	compose ps
	compose logs --tail=80 "$SERVICE"
	if [ "$NO_ROLLBACK" = "1" ]; then die "Health check gagal (rollback dimatikan)."; fi
	rollback || die "Rollback gagal di-build. Perlu cek manual di server!"
	if health_check; then
		die "Versi baru tidak sehat; sudah rollback dan versi lama jalan normal lagi."
	fi
	die "Versi baru tidak sehat DAN rollback juga tidak sehat. Perlu cek manual di server!"
fi

# --- 6. Bersih-bersih ---------------------------------------------------------
log "Hapus image dangling sisa build ..."
docker image prune -f >/dev/null || warn "docker image prune gagal (abaikan)."

compose ps
log "Deploy selesai: $(git log -1 --format='%h %s') — versi $(curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT}/api/health" 2>/dev/null || echo '?')"
