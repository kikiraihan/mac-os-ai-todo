# CI/CD — Auto deploy ke VPS

Setelah setup ini selesai, alur kerjanya jadi:

```
Anda: merge / push ke main (yang mengubah server/, web/, Dockerfile, …)
        │
        ▼
GitHub Actions (CI)  → gofmt, go vet, go test -race, npm run build, docker build
        │  (kalau semuanya hijau)
        ▼
GitHub Actions (Deploy) → git bundle commit ini + deploy.sh → scp ke VPS → jalankan deploy.sh
        │
        ├─ backup SQLite (aitodo backup, aman saat berjalan) → backups/aitodo-predeploy-<timestamp>.db
        ├─ ambil commit dari bundle → git reset --hard (VPS tidak perlu akses ke GitHub)
        ├─ docker compose up -d --build
        ├─ health check http://127.0.0.1:$APP_PORT/api/health
        └─ kalau health check gagal → ROLLBACK otomatis ke commit sebelumnya
```

Kalau CI merah, deploy **tidak** dijalankan sama sekali — VPS tidak tersentuh. Perubahan yang hanya
menyentuh aplikasi Mac (`Sources/`, `Resources/`) atau dokumentasi **tidak** memicu deploy server;
aplikasi Mac punya workflow sendiri (`mac.yml`, rilis GitHub).

Prasyarat: VPS sudah pernah di-setup mengikuti [DEPLOY.md](DEPLOY.md) (repo ter-clone di
`/var/www/ai-todo`, `.env` terisi, nginx host + HTTPS sudah jalan).

| Workflow | File | Kapan |
|---|---|---|
| CI | `.github/workflows/ci.yml` | setiap PR, manual, dan dipanggil oleh Deploy |
| Deploy ke VPS | `.github/workflows/deploy.yml` | push ke `main` yang mengubah server/web/Docker, atau manual |
| Mac app | `.github/workflows/mac.yml` | push yang mengubah aplikasi Mac; rilis `v<versi>` dari `main` |

---

## Bagian A — Setup di sisi VPS

### A1. Buat SSH key khusus deploy

Jangan pakai SSH key pribadi Anda untuk GitHub Actions. Buat key baru khusus untuk ini.

**Di laptop Anda** (bukan di VPS):

```bash
ssh-keygen -t ed25519 -C "github-actions-aitodo" -f ~/.ssh/aitodo_deploy -N ""
```

Menghasilkan dua file:
- `~/.ssh/aitodo_deploy` — private key → nanti ditaruh di GitHub Secrets
- `~/.ssh/aitodo_deploy.pub` — public key → dipasang di VPS

Kirim public key-nya ke VPS (ganti `user` dan `IP_VPS`):

```bash
ssh-copy-id -i ~/.ssh/aitodo_deploy.pub -p 22 user@IP_VPS
```

Kalau `ssh-copy-id` tidak ada, manual:

```bash
cat ~/.ssh/aitodo_deploy.pub | ssh user@IP_VPS "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Tes bahwa key-nya jalan:

```bash
ssh -i ~/.ssh/aitodo_deploy user@IP_VPS "echo koneksi-ok"
```

### A2. Pastikan user VPS bisa jalankan docker tanpa sudo

Login ke VPS, lalu:

```bash
docker ps          # harus jalan tanpa 'permission denied'
```

Kalau kena `permission denied`:

```bash
sudo usermod -aG docker $USER
# logout lalu login lagi, cek ulang: docker ps
```

Ini penting karena `scripts/deploy.sh` memanggil `docker compose` langsung, tanpa `sudo`. User ini
juga harus **pemilik folder repo** (`/var/www/ai-todo`) dan bisa membaca `.env`.

### A3. Siapkan repo di VPS

```bash
cd /var/www/ai-todo   # sesuaikan lokasi Anda

# Pastikan remote-nya benar & branch-nya main
git remote -v
git checkout main
git pull origin main

# Pastikan script-nya executable (bit ini juga tersimpan di git)
chmod +x scripts/deploy.sh scripts/rollback.sh

# Pastikan .env ada dan terisi (file ini TIDAK ikut git, jadi aman dari reset --hard)
ls -la .env
```

### A4. Akses baca ke GitHub (opsional — hanya untuk `make deploy` dari VPS)

**Deploy otomatis tidak butuh langkah ini**, walau repo private: GitHub Actions mengirim commit yang
di-deploy sebagai `git bundle` lewat SSH yang sama (`DEPLOY_BUNDLE`), jadi VPS tidak pernah
`git fetch` ke GitHub. `deploy.sh` juga ikut dikirim dan dijalankan dari salinan itu, jadi perubahan
script langsung berlaku.

Langkah ini hanya perlu kalau Anda ingin `make deploy` / `make deploy-remote` (yang `git fetch`
langsung dari VPS) tetap jalan saat repo private — tanpanya muncul
`fatal: could not read Username for 'https://github.com'`. Pasang **deploy key** (SSH read-only khusus
repo ini), **di VPS sebagai user yang sama dengan `SSH_USER`**:

```bash
# 1. Buat key khusus akses GitHub dari VPS
ssh-keygen -t ed25519 -C "vps-aitodo-readonly" -f ~/.ssh/github_aitodo -N ""

# 2. Tampilkan public key-nya, lalu SALIN seluruh barisnya
cat ~/.ssh/github_aitodo.pub
```

Buka **github.com/kikiraihan/mac-os-ai-todo → Settings → Deploy keys → Add deploy key**, tempel public
key tadi, **jangan** centang "Allow write access", lalu Add key.

Kembali ke VPS. Pakai alias khusus (jangan `Host github.com` kalau blok itu sudah ada — SSH memakai
blok **pertama** yang cocok):

```bash
# 3. Alias 'github-aitodo' yang memakai key tadi
cat >> ~/.ssh/config <<'EOF'

Host github-aitodo
	HostName github.com
	User git
	IdentityFile ~/.ssh/github_aitodo
	IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# 4. Host key github.com supaya fetch non-interaktif tidak nyangkut
ssh-keyscan github.com >> ~/.ssh/known_hosts

# 5. Ganti remote ke SSH — hostnya 'github-aitodo'
cd /var/www/ai-todo
git remote set-url origin git@github-aitodo:kikiraihan/mac-os-ai-todo.git

# 6. Verifikasi — dua-duanya harus sukses tanpa menanyakan apa pun
ssh -T git@github-aitodo
git fetch origin main
```

### A5. Coba deploy manual dulu

Sebelum melibatkan GitHub, pastikan script-nya jalan mulus di server:

```bash
cd /var/www/ai-todo
make deploy
```

Yang seharusnya terlihat: backup DB → git fetch → build → `Health check OK` → `Deploy selesai`.

### A6. Ambil host key VPS (untuk keamanan koneksi)

**Di laptop Anda**:

```bash
ssh-keyscan -p 22 -H IP_VPS
```

Salin **seluruh output**-nya — nanti dipakai sebagai secret `SSH_KNOWN_HOSTS`. Ini yang membuat
GitHub Actions memverifikasi bahwa server yang dihubungi memang VPS Anda, bukan man-in-the-middle.

---

## Bagian B — Setup di sisi GitHub

### B1. Tambahkan Secrets

Buka: **github.com/kikiraihan/mac-os-ai-todo → Settings → Secrets and variables → Actions → New repository secret**

| Nama secret | Isi | Wajib? |
|---|---|---|
| `SSH_HOST` | IP atau hostname VPS, mis. `203.0.113.10` | ✅ |
| `SSH_USER` | user SSH di VPS, mis. `deploy` | ✅ |
| `SSH_PRIVATE_KEY` | **seluruh isi** `~/.ssh/aitodo_deploy` termasuk baris `-----BEGIN...` dan `-----END...` | ✅ |
| `SSH_KNOWN_HOSTS` | output `ssh-keyscan` dari langkah A6 | Sangat disarankan |
| `SSH_PORT` | port SSH kalau bukan 22 | Opsional |
| `APP_DIR` | lokasi repo di VPS kalau bukan `/var/www/ai-todo` | Opsional |

> **Jangan** pernah menaruh isi `.env` (password admin, API key AI) di secret GitHub. Secret di sini
> hanya untuk SSH; semua rahasia aplikasi tetap hanya di `.env` di VPS.

Cara cepat menyalin private key ke clipboard (macOS):

```bash
pbcopy < ~/.ssh/aitodo_deploy
```

### B2. Merge ke main

Workflow sudah ada di repo. Merge PR ke `main` (atau push ke `main`) yang mengubah `server/`, `web/`,
`Dockerfile`, `docker-compose.yml`, `VERSION`, atau skrip deploy akan memicu deploy.

### B3. Lihat hasilnya

Tab **Actions** → workflow **Deploy ke VPS**: job `ci` jalan duluan, lalu `deploy`. Klik job `deploy`
→ step "Jalankan deploy di VPS" untuk melihat log deploy dari server.

---

## Pemakaian sehari-hari

### Deploy otomatis (cara utama)

Merge PR ke `main`. Tunggu ±3–5 menit (build image di VPS), cek tab Actions.

### Deploy manual dari GitHub

Tab **Actions** → **Deploy ke VPS** → **Run workflow** (bisa centang "Lewati backup DB"). Berguna
untuk re-deploy tanpa commit baru, mis. setelah mengubah `.env` di server.

### Deploy manual dari laptop (tanpa lewat GitHub)

```bash
make deploy-remote SSH_TARGET=user@IP_VPS
# kalau lokasinya beda:
make deploy-remote SSH_TARGET=user@IP_VPS REMOTE_DIR=/var/www/ai-todo SSH_PORT=2222
```

### Deploy manual dari dalam VPS

```bash
cd /var/www/ai-todo && make deploy
```

### Rollback

Deploy otomatis sudah rollback sendiri kalau health check gagal. Rollback manual (versi baru jalan
tapi ada bug):

```bash
# di VPS
make rollback                  # kembali ke commit sebelum deploy terakhir
make rollback SHA=abc1234      # kembali ke commit tertentu
```

Setelah rollback, `main` di GitHub masih berisi kode bermasalah — perbaiki dan push lagi, atau
`git revert` commit-nya, supaya deploy berikutnya tidak mengembalikan bug yang sama.

Rollback hanya memundurkan **kode**. Skema database hanya bertambah (`CREATE … IF NOT EXISTS`), jadi
versi lama tetap bisa membaca database yang sudah dipakai versi baru. Untuk mengembalikan **isi
data**, pakai backup di `backups/` (DEPLOY.md §9).

### Cek status

```bash
make version    # VERSION + commit yang sedang jalan di server
make health     # cek /api/health (APP_PORT dibaca dari .env)
make ps         # status container
make logs       # ikuti log
```

### Jalankan cek CI di lokal sebelum push

```bash
make ci    # gofmt + go vet + go test -race + npm build
```

---

## Yang perlu diperhatikan

**`git reset --hard` di server.** Perubahan file yang diedit langsung di VPS akan **hilang** saat
deploy. Ini disengaja supaya server selalu identik dengan GitHub. Yang aman karena di `.gitignore`:
`.env`, `backups/`, dan data SQLite (ada di docker volume `aitodo_data`, bukan di folder repo).

**Data SQLite tidak tersentuh.** Rebuild dan restart container tidak menghapusnya. Yang menghapusnya
cuma `docker volume rm` / `docker compose down -v` — jangan dijalankan.

**Ada downtime singkat** (beberapa detik) saat container di-recreate. Build terjadi sebelum container
lama dimatikan. Klien PWA & Mac otomatis menyambung ulang (long-poll dengan backoff).

**Build memakai resource VPS.** `npm ci` + `vite build` + `go build` cukup berat. Kalau RAM mepet
(≤ 1 GB) dan build sering gagal, tambahkan swap:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

**Backup pre-deploy.** Tiap deploy menyimpan salinan DB di `backups/aitodo-predeploy-<timestamp>.db`
(10 terbaru, `chmod 600`). Ini bukan pengganti backup harian — tetap pasang cron `make backup`
(DEPLOY.md §9) dan simpan salinannya di luar VPS.

**`HEALTH_RETRIES` / `HEALTH_DELAY` harus bilangan bulat.** Skrip menolak nilai seperti `0.5`, karena
aritmetika bash yang gagal bisa membuat blok rollback terlewat.

---

## Troubleshooting

**`Permission denied (publickey)` di step SSH.**
Isi `SSH_PRIVATE_KEY` kemungkinan terpotong — harus lengkap termasuk baris `-----BEGIN OPENSSH PRIVATE KEY-----`
dan `-----END OPENSSH PRIVATE KEY-----`. Cek juga public key-nya ada di `~/.ssh/authorized_keys` milik `SSH_USER`.

**`Host key verification failed`.**
`SSH_KNOWN_HOSTS` tidak cocok (VPS ganti IP / di-reinstall). Jalankan ulang `ssh-keyscan` dan perbarui secret-nya.

**`docker: permission denied while trying to connect to the Docker daemon`.**
User SSH belum masuk grup `docker`. Lihat A2.

**`fatal: could not read Username for 'https://github.com'`.**
Repo private dan deploy dijalankan dengan `git fetch` dari VPS (`make deploy` / `make deploy-remote`,
atau `deploy.yml` versi lama). Deploy dari GitHub Actions versi sekarang tidak terkena ini; untuk
`make deploy` ikuti A4.

**`Isi bundle (...) tidak sama dengan commit yang diminta`.**
Bundle yang dikirim Actions bukan commit yang dipicu. Jalankan ulang workflow; kalau terulang, cek
langkah "Buat git bundle" di log Actions.

**`.env belum ada di ...` atau `ADMIN_PASSWORD di .env masih password contoh`.**
Ikuti DEPLOY.md §4 di server.

**Deploy sukses tapi `Health check GAGAL` lalu rollback.**
Versi baru benar-benar tidak sehat. 80 baris log container ikut dicetak di output Actions. Penyebab
umum: variabel baru yang belum ditambahkan ke `.env` di server.

**`cd: /var/www/ai-todo: No such file or directory`.**
Path repo di VPS beda. Set secret `APP_DIR` sesuai lokasi sebenarnya (`pwd` di dalam folder repo).

**`./scripts/deploy.sh: Permission denied`.**
Jalankan sekali di VPS: `chmod +x scripts/deploy.sh scripts/rollback.sh`.

**Workflow Deploy tidak jalan setelah merge.**
Perubahannya mungkin hanya di aplikasi Mac / dokumentasi (lihat `paths` di `deploy.yml`). Pakai
**Run workflow** kalau tetap ingin deploy.
