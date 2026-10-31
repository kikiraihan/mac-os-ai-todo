# AI Todo

Todo list & pengingat yang bisa dikelola **lewat chat dengan AI** maupun **secara manual**.
Ketik *"besok jam 9 ingetin telpon bengkel"* dan asisten membuat todo beserta pengingatnya;
notifikasi muncul di HP (PWA) dan nanti juga di menu bar Mac. Asisten mengingat kebiasaan dan
konteksmu antar percakapan (konsep ingatan dari Hermes Agent).

- **Server**: Go + SQLite, satu binary (PWA ikut tertanam)
- **Web/PWA**: Vue 3 + Vite, bisa di-install di HP, tablet, PC
- **AI gratis**: kenari (`:free`), Agnes AI, OpenRouter (`:free`, mis. Qwen) — dengan fallback
- **Mac**: aplikasi menu bar (tahap berikutnya, lihat [PRD](docs/PRD.md) §5.8)

Rancangan lengkap: [`docs/PRD.md`](docs/PRD.md). Tahapan kerja: [`_todo/00-tracker.md`](_todo/00-tracker.md).

## Fitur

| Menu | Isi |
|---|---|
| **Asisten** | chat: tambah/ubah/selesai/hapus todo & pengingat, tanya jadwal, simpan ingatan. Aksi tampil sebagai kartu dengan tombol **↶ Batalkan**; hapus & perubahan massal minta konfirmasi. Tanpa AI: `/todo`, `/selesai <no>`, `/hari-ini`, `/undo`, `/bantuan` |
| **Todo** | tambah cepat, form lengkap (tenggat, jam, daftar, prioritas, catatan, buat pengingat), centang, tab Hari ini / Akan datang / Tanpa tenggat / Selesai, cari, filter |
| **Pengingat** | sekali, harian, mingguan, bulanan, tahunan, tiap N menit/jam dalam rentang jam; berakhir pada tanggal / setelah N kali; tunda, jeda |
| **Ingatan AI** | profil & catatan yang selalu dibawa asisten; lihat/ubah/hapus, ekspor `.md` |
| **Pengaturan** | notifikasi perangkat ini, ringkasan pagi & dorongan terlambat, profil & zona waktu, password, perangkat & token aplikasi Mac |
| **Admin** (peran admin) | ringkasan, pengguna, **katalog Model AI** (tes, aktif/nonaktif, urutan fallback, tambah manual / dari daftar API provider), persona & batas asisten |

## Menjalankan lokal

```bash
# terminal 1 — server (http://127.0.0.1:8080)
cd server && DATA_DIR=../data SECURE_COOKIES=false ADMIN_PASSWORD='password-panjang-sekali' \
  KENARI_API_KEY=kn-... go run ./cmd/server

# terminal 2 — web dev (http://localhost:5173, /api diproksikan ke :8080)
cd web && npm install && npm run dev
```

Tanpa `ADMIN_PASSWORD`, password admin acak dibuat dan dicetak **sekali** di log. Isi minimal satu
`*_API_KEY` supaya asisten AI bisa menjawab; tanpa key, semua fitur manual tetap jalan.

`make build` menghasilkan satu binary `build/aitodo` dengan PWA di dalamnya. `make ci` menjalankan
cek yang sama dengan GitHub Actions.

## Deploy (Docker, di belakang reverse proxy)

```bash
cp .env.example .env && nano .env   # password admin acak, API key, APP_PORT, PUBLIC_URL
make up                             # build image & jalankan di 127.0.0.1:APP_PORT
make backup                         # salin database (aman saat berjalan) ke ./backups/
```

Arahkan subdomain (mis. `todo.katili.dev`) dari nginx/Caddy host ke `127.0.0.1:APP_PORT` dengan
HTTPS dan header `X-Real-IP`. Web Push dan install PWA di iPhone butuh HTTPS.

## Keamanan (ringkas)

- API key AI hanya di `.env` server; tidak pernah dikirim ke browser, tidak masuk database, log,
  atau backup. Server hanya menghubungi host provider yang diizinkan.
- AI hanya **mengusulkan** aksi (JSON); server memvalidasi, menjalankan dalam transaksi, mencatat
  undo. Hapus dan perubahan massal butuh tombol konfirmasi.
- Ingatan menolak password, PIN, token, nomor kartu, dan pola prompt injection.
- Sesi: token acak (server simpan hash), cookie `HttpOnly + Secure + SameSite=Strict`, header CSRF
  wajib, batas percobaan login, CSP ketat. Data tiap pengguna terisolasi; admin tidak bisa membaca
  isi milik pengguna lain.

Detail: [PRD §7](docs/PRD.md#7-keamanan).

## Struktur

```
server/              Go: cmd/server (main), internal/{db,core,schedule,ai,assistant,scheduler,push,httpapi,webui}
web/                 Vue 3 + Vite (PWA) → build ke server/internal/webui/dist
docs/PRD.md          rancangan produk
_todo/               tracker tahapan
Dockerfile, docker-compose.yml, .env.example, Makefile
```
