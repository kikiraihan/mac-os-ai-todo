# DEPLOY.md — panduan setup server AI Todo

Ditulis untuk **agen AI (Claude Code, dsb.) yang memasang server di VPS**, dan tetap bisa diikuti
manusia. Kerjakan berurutan. Bagian bertanda **🛑 TANYA PEMILIK** berarti berhenti dan minta
jawaban — jangan mengarang nilainya.

Hasil akhirnya: AI Todo berjalan di Docker, hanya mendengar `127.0.0.1:<APP_PORT>`, dan dibuka ke
internet lewat nginx host + HTTPS di sebuah subdomain (mis. `https://todo.katili.dev`).

```
internet ──HTTPS──▶ (Cloudflare, opsional) ──▶ nginx host :443 ──▶ 127.0.0.1:APP_PORT ──▶ container aitodo (:8080)
                                                                                         └─ volume aitodo_data (/data/aitodo.db)
```

---

## 0. Aturan keamanan (wajib, jangan dilonggarkan)

1. **Jangan pernah** memakai password contoh `GANTI-dengan-password-acak` dari `.env.example`, atau
   password apa pun yang pernah tertulis di repo, issue, chat, atau log. Server menolak berjalan
   dengan password contoh. Buat password baru dengan `openssl rand -base64 24` **di server**.
2. **API key AI hanya di `.env` di server** (`chmod 600`). Jangan menulisnya ke repo, commit, issue,
   secret GitHub, berkas lain, atau output yang dikirim ke pemilik. Jangan pernah `cat .env` ke
   chat; kalau perlu memeriksa, cukup cek apakah variabelnya terisi (lihat §4).
3. **Jangan membuka port aplikasi ke publik.** Port hanya di-bind ke `127.0.0.1` (sudah begitu di
   `docker-compose.yml`). Jangan menambah aturan firewall untuk `APP_PORT`, jangan mengganti bind
   ke `0.0.0.0`.
4. `TRUST_PROXY=true` **hanya** boleh selama aplikasi hanya bisa dijangkau lewat nginx host (poin 3).
5. HTTPS wajib (Web Push, install PWA di iPhone, dan cookie `Secure` butuh HTTPS). Jangan
   mematikan verifikasi TLS di mana pun.
6. Agen **tidak perlu** login ke aplikasi atau membuat akun pengguna; itu tugas pemilik setelah
   setup selesai.
7. Sebelum mengubah apa pun di nginx host yang sudah melayani situs lain, **baca dulu** konfigurasi
   yang ada dan jangan menyentuh server block situs lain.

## 1. 🛑 TANYA PEMILIK sebelum mulai

| Nilai | Contoh | Catatan |
|---|---|---|
| Domain / subdomain | `todo.katili.dev` | DNS-nya harus mengarah ke IP VPS ini |
| Lewat Cloudflare (awan oranye)? | ya / tidak | menentukan pengaturan IP asli di nginx & mode SSL |
| API key provider AI | kenari / Agnes / OpenRouter | minimal satu; minta pemilik **menempelnya sendiri** ke `.env` bila memungkinkan |
| Zona waktu bawaan | `Asia/Jakarta` | tiap pengguna bisa mengganti sendiri |
| Username admin | `admin` | password dibuat acak oleh agen (§4) |
| Email kontak Web Push | `mailto:nama@domain` | dikirim ke layanan push browser |
| Lokasi repo di VPS | `/var/www/ai-todo` | ikuti kebiasaan VPS tersebut |

Kalau pemilik belum punya API key: setup tetap bisa dilanjutkan tanpa key — semua fitur manual
jalan, asisten AI menjawab "belum siap" sampai key diisi (§8).

## 2. Cek prasyarat di VPS

```bash
uname -a && cat /etc/os-release | head -3
docker --version && docker compose version     # wajib: Docker + plugin compose v2
git --version && make --version | head -1
nginx -v 2>&1; systemctl is-active nginx       # nginx host (atau Caddy, lihat §6b)
free -h && df -h /                             # build image butuh ±1,5 GB RAM bebas & ±2 GB disk
```

Kalau Docker belum ada, pasang dari dokumentasi resmi Docker untuk distro tersebut
(`docs.docker.com/engine/install/`), lalu tambahkan user deploy ke grup `docker` bila perlu.
Kalau `make` belum ada: `sudo apt-get install -y make` (Debian/Ubuntu).

Pilih **port lokal yang belum dipakai** (default `8095`):

```bash
ss -tlnp | grep -E ':8095\b' || echo "8095 bebas"
```

Kalau terpakai, pilih port lain dan pakai nilai itu sebagai `APP_PORT`.

## 3. Ambil kode

```bash
sudo mkdir -p /var/www/ai-todo && sudo chown "$USER": /var/www/ai-todo
git clone https://github.com/kikiraihan/mac-os-ai-todo.git /var/www/ai-todo
cd /var/www/ai-todo
git checkout main
cat VERSION
```

> Selama pekerjaan awal belum di-merge ke `main`, branch-nya `claude/peaceful-babbage-a47jeg`.
> Pakai `main` kalau sudah ada isinya; kalau `main` masih kosong, 🛑 tanya pemilik branch mana.

Repo ini public, jadi clone tidak butuh kredensial.

## 4. Buat `.env`

```bash
cd /var/www/ai-todo
cp .env.example .env
chmod 600 .env
# password admin acak, langsung ditulis ke .env (tidak pernah ditampilkan di layar):
PW="$(openssl rand -base64 24)"
sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${PW}|" .env
unset PW
```

Lalu sunting `.env` (`nano .env`) dan isi nilai dari §1:

| Variabel | Isi |
|---|---|
| `APP_PORT` | port dari §2, mis. `8095` |
| `PUBLIC_URL` | `https://DOMAIN` |
| `ADMIN_USERNAME` | username admin dari pemilik |
| `TIMEZONE` | mis. `Asia/Jakarta` |
| `SECURE_COOKIES` | `true` (biarkan) |
| `TRUST_PROXY` | `true` (biarkan; aplikasi hanya di belakang nginx host) |
| `VAPID_SUBSCRIBER` | `mailto:...` dari pemilik |
| `KENARI_API_KEY` / `AGNES_API_KEY` / `OPENROUTER_API_KEY` | dari pemilik; kosongkan yang tidak dipakai |

Jangan isi `*_BASE_URL` kecuali pemilik memintanya — host di luar allowlist akan ditolak server.

Periksa tanpa membocorkan isi:

```bash
grep -cE '^ADMIN_PASSWORD=GANTI' .env            # harus 0
for k in KENARI_API_KEY AGNES_API_KEY OPENROUTER_API_KEY; do
  grep -qE "^${k}=.+" .env && echo "$k: terisi" || echo "$k: kosong"
done
stat -c '%a %U' .env                              # harus 600
```

## 5. Jalankan container

```bash
make up            # = VERSION=$(cat VERSION) docker compose up -d --build
docker compose ps  # status harus "healthy" setelah ±30 detik
curl -fsS http://127.0.0.1:8095/api/health    # ganti 8095 dengan APP_PORT → {"status":"ok","version":"0.1.0"}
docker compose logs --tail=30 aitodo
```

Di log harus ada:

- `Akun admin awal "admin" dibuat dari ADMIN_USERNAME/ADMIN_PASSWORD`
- `AI provider ...: key terpasang` untuk provider yang diisi
- `AI Todo server 0.1.0 di 0.0.0.0:8080`

Kalau log berisi `ADMIN_PASSWORD masih password contoh` → kembali ke §4.

> Akun admin hanya dibuat **sekali**, saat database masih kosong. Setelah itu mengganti
> `ADMIN_PASSWORD` di `.env` tidak berpengaruh — password diganti dari aplikasi (Pengaturan).

## 6a. nginx host + HTTPS (pola VPS yang sudah punya nginx)

```bash
sudo cp deploy/nginx-aitodo.conf.example /etc/nginx/sites-available/aitodo
sudo nano /etc/nginx/sites-available/aitodo     # ganti DOMAIN dan PORT
sudo ln -s /etc/nginx/sites-available/aitodo /etc/nginx/sites-enabled/aitodo
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d DOMAIN                  # pilih redirect HTTP → HTTPS
```

Hal penting dari contoh konfigurasi (jangan dihapus):

- `proxy_read_timeout 120s` dan `proxy_buffering off` — sinkron real-time memakai long-poll 25
  detik dan jawaban AI bisa sampai ±75 detik; tanpa ini muncul error 504/putus.
- `proxy_set_header X-Real-IP $remote_addr` — dipakai batas percobaan login.

**Kalau domain lewat Cloudflare (awan oranye):**

- nginx harus memulihkan IP asli: pasang `set_real_ip_from` untuk semua rentang IP Cloudflare
  (`https://www.cloudflare.com/ips/`) + `real_ip_header CF-Connecting-IP;` di konteks `http {}`.
  Cek dulu apakah VPS sudah punya berkas seperti ini dari situs lain (`grep -r real_ip_header /etc/nginx`).
  Tanpa ini semua pengunjung tampak ber-IP Cloudflare, dan 5 salah password dari siapa pun bisa
  mengunci login orang lain selama 15 menit.
- SSL/TLS mode di Cloudflare: **Full (strict)**. Bila certbot gagal karena proxy Cloudflare,
  🛑 tanya pemilik: pakai Cloudflare Origin Certificate, atau matikan awan oranye sementara saat
  menerbitkan sertifikat.

## 6b. Alternatif: Caddy (VPS tanpa nginx)

```caddy
DOMAIN {
	encode gzip
	reverse_proxy 127.0.0.1:PORT {
		flush_interval -1
		transport http {
			read_timeout 120s
		}
	}
}
```

Caddy otomatis menerbitkan HTTPS dan mengirim `X-Forwarded-For`; server memakai entri terakhirnya.

## 7. Verifikasi dari luar

```bash
curl -sSI https://DOMAIN | head -20
# harus 200 dan memuat: content-security-policy, strict-transport-security, x-frame-options: DENY
curl -fsS https://DOMAIN/api/health
curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/api/todos -H 'X-AITodo: 1'   # 401 (belum login) = benar
curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/api/todos                     # 403 (tanpa header CSRF) = benar
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://VPS_IP:APP_PORT/api/health   # dari LUAR VPS: harus gagal/timeout
```

## 8. Serah terima ke pemilik

Laporkan (tanpa menampilkan password maupun key):

1. URL aplikasi: `https://DOMAIN`.
2. Username admin, dan bahwa password admin awal ada di server:
   `sudo grep '^ADMIN_PASSWORD=' /var/www/ai-todo/.env` — pemilik membacanya sendiri, lalu
   **segera mengganti password** di aplikasi (Pengaturan → Ganti password).
3. Setelah pemilik berhasil login dan mengganti password, `ADMIN_PASSWORD` di `.env` boleh
   dikosongkan (tidak dipakai lagi) — tanyakan dulu ke pemilik.
4. Provider AI yang key-nya terpasang. Langkah pemilik berikutnya:
   **Admin → Model AI → Tes** tiap model; matikan yang gagal; atur urutan fallback; bila model
   bawaan sudah tidak ada, pakai **Tambah dari daftar API**.
5. Langkah pemilik untuk notifikasi: buka situs di HP → install (Android: tombol install browser;
   iPhone: Bagikan → Tambahkan ke Layar Utama, lalu buka dari ikon) → Pengaturan → Nyalakan
   notifikasi → Kirim tes.
6. Pengguna lain dibuat pemilik lewat **Admin → Pengguna**.

## 9. Backup

Database adalah satu berkas SQLite di volume `aitodo_data`. `make backup` membuat salinan konsisten
walau server berjalan (`VACUUM INTO`), lalu menyalinnya ke `./backups/`.

Pasang backup harian + simpan 14 hari (crontab user deploy, `crontab -e`):

```cron
17 3 * * * cd /var/www/ai-todo && make backup >> backups/cron.log 2>&1 && find backups -name 'aitodo-*.db' -mtime +14 -delete
```

`backups/` sudah di-`.gitignore`. Berkas backup berisi data pribadi semua pengguna — jangan
dipindahkan ke tempat publik.

**Restore** (🛑 hanya atas permintaan pemilik, menimpa data sekarang):

```bash
make backup                                   # amankan data saat ini dulu
docker compose stop aitodo
docker compose cp backups/aitodo-YYYYMMDD-HHMMSS.db aitodo:/data/aitodo.db
docker compose run --rm --user root --entrypoint sh aitodo -c \
  'rm -f /data/aitodo.db-wal /data/aitodo.db-shm && chown 1000:1000 /data/aitodo.db && chmod 600 /data/aitodo.db'
docker compose start aitodo
```

## 10. Memperbarui

```bash
cd /var/www/ai-todo
make backup
git pull --ff-only
make up
curl -fsS http://127.0.0.1:8095/api/health    # ganti 8095 dengan APP_PORT
docker compose logs --tail=20 aitodo
```

Skema database bermigrasi otomatis saat start. Kalau health check gagal setelah update:
`git checkout <commit-sebelumnya> && make up`, lalu laporkan ke pemilik dengan potongan log
(tanpa isi `.env`).

## 11. Masalah umum

| Gejala | Penyebab & solusi |
|---|---|
| `502 Bad Gateway` | container mati / port salah: `docker compose ps`, `logs`, cocokkan `APP_PORT` dengan `proxy_pass` |
| `504` atau chat AI terputus | `proxy_read_timeout` < 120s di nginx / Cloudflare (Cloudflare memutus di 100 detik; jawaban AI normalnya < 75 detik) |
| Login berhasil tapi langsung keluar lagi | situs dibuka lewat HTTP biasa sementara `SECURE_COOKIES=true` → pastikan HTTPS |
| "terlalu banyak percobaan gagal" untuk semua orang | IP asli tidak sampai: periksa `X-Real-IP` / pengaturan Cloudflare real IP (§6a) |
| Asisten: "belum siap" | belum ada key, atau semua model nonaktif: isi key di `.env` → `make up` → Admin → Model AI → Tes |
| Asisten: "semua model AI sedang tidak bisa dipakai" | kuota gratis habis / provider bermasalah: tunggu, tambah model lain, atau isi key provider kedua |
| Tes model: `401` | key salah / tidak aktif → pemilik membuat key baru |
| Notifikasi tidak muncul | bukan HTTPS; di iPhone PWA belum di-install dari Layar Utama; izin notifikasi ditolak di browser |
| Jam pengingat meleset | atur zona waktu di Pengaturan pengguna atau `TIMEZONE` di `.env` |
| Build image gagal karena memori | VPS < 1,5 GB RAM bebas: tambah swap sementara, atau build di mesin lain dan kirim image-nya |

## 12. Ringkasan perintah

```bash
make up        # build & jalankan / perbarui
make down      # hentikan (data tetap di volume)
make logs      # ikuti log
make backup    # backup database ke ./backups/
make version   # versi di repo
```
