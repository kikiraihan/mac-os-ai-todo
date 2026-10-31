# PRD — AI Todo (server + PWA + menu bar Mac)

| | |
|---|---|
| Status | **v2** — server & PWA (v0.1.0) dan aplikasi menu bar Mac (v0.2.0) sudah diimplementasikan |
| Tanggal | 31 Oktober 2026 |
| Repo | `kikiraihan/mac-os-ai-todo` |
| Acuan arsitektur | PasteLAN (server sendiri + PWA + menu bar Mac), our-life-planner (Go + Vue + SQLite) |
| Acuan AI | katilidev (`KenariClient`, `AgnesClient`, `OpenRouterClient`), Hermes Agent (ingatan) |

Perubahan dari v1: stack web jadi **Go + Vue 3 + SQLite** (sama dengan our-life-planner, bukan
JS polos + JSON), **banyak akun** dengan peran admin/user, **katalog model AI** yang dikelola admin,
**ingatan AI** ala Hermes Agent, dan **input manual** penuh untuk semua data.

---

## 1. Ringkasan

Todo list yang bisa dikelola **lewat chat dengan AI** maupun **secara manual**. Ketik
*"besok jam 9 ingetin telpon bengkel, terus tandai beli galon udah"* dan asisten menambah todo,
membuat pengingat, dan menandai selesai. Pengingat bisa sekali atau berulang dan muncul sebagai
notifikasi di HP (PWA) dan Mac. Asisten **mengingat** kebiasaan dan konteks pengguna antar
percakapan.

```
 ┌──── Mac (menu bar) ────┐           ┌──── Server (Go, satu binary) ───┐           ┌──── HP / tablet / PC ────┐
 │ todo hari ini + badge   │── HTTPS ─▶│ SQLite: todo, pengingat, chat,  │── HTTPS ─▶│ PWA Vue: chat, todo,      │
 │ chat cepat (hotkey)     │◀──────────┤ ingatan, katalog model          │◀──────────┤ pengingat, ingatan, admin │
 │ notifikasi lokal        │           │ penjadwal notifikasi, Web Push  │           │ notifikasi Web Push       │
 └─────────────────────────┘           └───────────────┬─────────────────┘           └───────────────────────────┘
                                                       │ HTTPS, key hanya di server, allowlist host
                                                       ▼
                                       kenari (:free) · Agnes AI · OpenRouter (:free, mis. Qwen)
```

## 2. Tujuan & non-tujuan

**Tujuan**

- **G1 — Chat sebagai jalan pintas**: tambah, ubah, selesai, hapus, cari, ringkas todo & pengingat
  dari satu kotak chat.
- **G2 — Manual tetap lengkap**: semua yang bisa lewat chat juga bisa lewat form/tombol, tanpa AI.
- **G3 — Pengingat fleksibel**: sekali, harian, mingguan, bulanan, tahunan, tiap N menit dalam
  rentang jam; batas tanggal/jumlah; tunda.
- **G4 — Notifikasi** di semua perangkat (Web Push di PWA, notifikasi lokal di Mac) + ringkasan pagi
  dan dorongan todo terlambat.
- **G5 — Tidak lupa**: asisten membawa identitasnya (persona), profil & catatan tentang pengguna
  (ingatan), dan seluruh daftar tugas di setiap pesan; percakapan lama bisa dicari.
- **G6 — Aman**: AI tidak pernah menyentuh database langsung; aksi berisiko butuh konfirmasi
  manusia; semua aksi bisa di-undo; key AI hanya di server; data antar pengguna terisolasi.
- **G7 — Gratis & ringan**: model gratis dengan fallback antar provider; satu binary + satu berkas
  SQLite.

**Non-tujuan (v1)**: berbagi todo antar pengguna, sinkron Apple Reminders/Google Tasks, pesan suara,
lampiran, pengingat via WhatsApp/Telegram/email, aplikasi native iOS/Android.

## 3. Pengguna & peran

| Peran | Bisa |
|---|---|
| **user** | menu pengguna: Asisten (chat), Todo, Pengingat, Ingatan AI, Pengaturan (profil, password, notifikasi, perangkat & token Mac) |
| **admin** | semua menu pengguna + menu admin: Ringkasan, Pengguna, Model AI, Asisten |

Setiap pengguna punya todo, pengingat, chat, dan ingatan **sendiri**. Admin mengelola akun dan AI,
tapi **tidak** punya endpoint untuk membaca todo/chat/ingatan pengguna lain.

## 4. Skenario

| # | Skenario | Lewat chat | Lewat manual |
|---|---|---|---|
| S1 | Tangkap cepat | "beli galon, bayar wifi, servis motor sabtu" | baris *Tambah cepat* di Todo |
| S2 | Todo + pengingat | "besok jam 9 ingetin telpon bengkel" | form Todo → tenggat + jam → ☑ *Buat pengingat di jam tenggat* |
| S3 | Pengingat berulang | "tiap hari jam 8 ingetin minum vitamin" | Pengingat → *Harian* 08:00 |
| S4 | Interval | "tiap 2 jam dari jam 9–17 hari kerja ingetin minum air" | Pengingat → *Tiap beberapa menit/jam* |
| S5 | Selesai | "galon udah dibeli" | centang di daftar / tombol **Selesai** di notifikasi |
| S6 | Tanya | "apa aja yang belum selesai minggu ini?" | tab *Hari ini / Akan datang / Tanpa tenggat* + cari |
| S7 | Hapus | "hapus semua yang belanja" → **kartu konfirmasi** | ikon hapus + konfirmasi |
| S8 | Undo | "/undo" atau tombol ↶ di kartu aksi | — |
| S9 | Ingatan | "aku biasanya belanja sabtu pagi" → asisten menyimpannya | Ingatan AI → tambah/ubah/hapus |
| S10 | Ingat masa lalu | "bengkel yang dulu itu siapa?" → pencarian chat | — |
| S11 | AI mati | /todo, /selesai, /hari-ini, /undo tetap jalan | semua halaman tetap jalan |

## 5. Fitur

### 5.1 Todo

Field: judul (≤ 200), catatan (≤ 2000), status `open/done/archived`, prioritas `low/normal/high`,
daftar (label ≤ 40), tenggat tanggal + jam opsional, sumber `manual/chat`, waktu selesai.
Menandai selesai mematikan pengingat **sekali** milik todo itu; pengingat berulang dibiarkan.
Menghapus todo ikut menghapus pengingatnya.

### 5.2 Pengingat

Entitas sendiri, boleh terikat todo. Jadwal berupa JSON terstruktur — server yang menghitung
kemunculan berikutnya (deterministik, di zona pengguna), AI tidak pernah menghitung waktu sendiri:

```json
{ "kind": "once",     "at": "2026-10-31T09:00" }
{ "kind": "daily",    "time": "08:00", "every": 1 }
{ "kind": "weekly",   "time": "19:00", "weekdays": [1,3,5], "every": 1 }
{ "kind": "monthly",  "time": "08:00", "monthDay": 25 }
{ "kind": "yearly",   "time": "07:00", "month": 3, "monthDay": 14 }
{ "kind": "interval", "everyMinutes": 120, "window": {"from":"09:00","to":"17:00"}, "weekdays": [1,2,3,4,5] }
```

Opsional: `startDate`, `until`, `count`. Tanggal 29–31 di bulan pendek → hari terakhir.
Batas: interval ≥ 15 menit, ≤ 100 pengingat aktif per pengguna.

### 5.3 Input manual (tanpa AI)

| Halaman | Yang bisa dilakukan |
|---|---|
| **Todo** | tambah cepat (judul + Hari ini/Besok), form lengkap (tenggat, jam, daftar, prioritas, catatan, opsi buat pengingat), centang, ubah, hapus, tab Hari ini / Akan datang / Tanpa tenggat / Semua aktif / Selesai, cari, filter daftar, arsipkan yang selesai |
| **Pengingat** | pembuat jadwal (sekali/harian/mingguan/bulanan/tahunan/interval + hari + berakhir), kaitkan ke todo, tunda 10 menit, jeda/aktifkan, ubah, hapus |
| **Ingatan AI** | lihat kapasitas, tambah/ubah/hapus entri profil & catatan, ekspor `.md` |
| **Chat** | perintah tanpa AI: `/todo`, `/selesai <no>`, `/hari-ini`, `/undo`, `/bantuan` |

Form manual dan asisten memakai **fungsi validasi yang sama** di server (`internal/core`), jadi
aturannya tidak bisa berbeda.

### 5.4 Asisten (chat)

- Riwayat per pengguna, kartu aksi di bawah balasan ("➕ Ditambahkan: Telpon bengkel · besok 09:00
  [↶ Batalkan]"), kartu konfirmasi kuning untuk aksi berisiko (berlaku 10 menit), chip saran.
- Balasan dalam Bahasa Indonesia santai; gaya diatur persona (§5.6).

### 5.5 Ingatan AI (konsep dari Hermes Agent)

Hermes Agent menjaga agar agen "tidak lupa dirinya dan tugasnya" dengan: `SOUL.md` (identitas),
`MEMORY.md` + `USER.md` (catatan berbatas karakter yang selalu masuk prompt), alat `memory`
(add/patch/remove) dengan **pemindai prompt injection**, **persetujuan** untuk penghapusan tanpa
pengawasan, dan **pencarian sesi lama** (FTS5). AI Todo menerapkan hal yang sama di SQLite:

| Hermes | AI Todo |
|---|---|
| `SOUL.md` | **Persona** (Admin → Asisten), ≤ 1500 karakter, paling atas di prompt |
| `USER.md` (1375 karakter) | ingatan **profile** per pengguna, ≤ 1200 karakter |
| `MEMORY.md` (2200 karakter) | ingatan **notes** per pengguna, ≤ 2000 karakter |
| alat `memory` add/patch/remove (pencocokan substring) | aksi `memory.add` / `memory.update` / `memory.remove`, dirujuk dengan **id** `[mN]` (lebih tahan salah ketik model) |
| tulisan ditolak bila penuh → agen merangkum dulu | sama; prompt menampilkan pemakaian `[x% — a/b karakter]` |
| pemindai ancaman (injeksi/exfil) | pemindai: instruksi abaikan aturan, ganti identitas, lewati konfirmasi, **password/PIN, API key, token, nomor kartu** |
| hapus tanpa pengawasan → ditahan untuk disetujui | `memory.remove` selalu lewat **kartu konfirmasi** |
| `session_search` (FTS5) | aksi `chat.search` (FTS5 di riwayat chat milik pengguna itu saja) |
| snapshot beku per sesi | dibaca ulang **setiap pesan** (tidak ada prefix cache yang perlu dijaga di model gratis) |
| berkas `.md` di disk | baris SQLite per pengguna (terisolasi, transaksional, ikut backup) + **ekspor `.md`** |

Pengguna bisa melihat, mengubah, dan menghapus semua ingatannya sendiri; admin tidak bisa membacanya.

### 5.6 Menu admin

- **Ringkasan**: jumlah pengguna/todo/pengingat/chat, status API key per provider (ada/tidak —
  nilainya tidak pernah ditampilkan), jumlah model siap.
- **Pengguna**: buat, ubah nama/peran, nonaktifkan (langsung keluar dari semua perangkat), reset
  password, hapus. Tidak bisa menonaktifkan/menurunkan/menghapus diri sendiri atau admin aktif terakhir.
- **Model AI (katalog)**:
  - daftar model per provider (kenari, Agnes AI, OpenRouter) dengan label, id, *extra body* JSON,
    tanda gratis, status `aktif / nonaktif / tidak tersedia`, hasil & latensi tes terakhir;
  - **urutan = urutan fallback** (naik/turun);
  - **Tes**: satu permintaan nyata; ditolak provider (400/404/410/422) → *tidak tersedia*;
    gangguan sementara (429/5xx/timeout) tidak mengubah status; sukses memulihkan *tidak tersedia*;
  - **Tambah manual** (id persis dari provider) dan **Tambah dari daftar API** (`GET /models`
    provider, filter gratis, centang beberapa) — seperti fitur yang sama di katilidev;
  - *extra body* tidak boleh menimpa `model`, `messages`, `stream`.
- **Asisten**: aktif/mati, persona, kirim catatan todo ke AI (default mati), batas token, batas pesan
  per menit/hari per pengguna.

### 5.7 Notifikasi

| Jenis | Pemicu |
|---|---|
| Pengingat | waktunya tiba (dedupe atomik di database; restart tidak mengirim ganda; terlewat > 30 menit dilewati) |
| Tenggat | 10 menit sebelum jam tenggat todo |
| Ringkasan pagi | jam per pengguna (default 06:30) — dari template, bukan AI |
| Dorongan terlambat | jam per pengguna (default 19:00) bila ada todo lewat tenggat |

Tombol di notifikasi: **Selesai** (todo) dan **Tunda 10 mnt** (pengingat). Opsi *sembunyikan isi*
untuk layar kunci. Web Push hanya dikirim ke perangkat milik pengguna itu.

### 5.8 Aplikasi Mac (v0.2.0)

Menu bar dengan badge todo hari ini + terlambat, daftar centang cepat, panel chat (hotkey ⌥⌘T),
notifikasi lokal dari `GET /api/reminders/upcoming?hours=48` + tenggat todo berjam (10 menit
sebelumnya), login dengan username & password lewat `POST /api/login/device` → **token perangkat**
di Keychain (password tidak disimpan; alternatif tempel token dari web), sinkron real-time lewat
long-poll, update bertanda tangan Ed25519 seperti PasteLAN. Ringkasan pagi & dorongan terlambat tetap
hanya lewat Web Push (dibuat server).

## 6. Desain AI

### 6.1 Provider

Client Go `internal/ai` untuk tiga provider OpenAI-compatible (`POST {base}/chat/completions`):

| Provider | Base URL | Catatan dari katilidev |
|---|---|---|
| kenari | `https://kenari.id/v1` | `:free` jalan saat saldo nol; `response_format: json_object`; balasan lama = 200 + spasi lalu JSON; error bisa 200 berisi `error` |
| Agnes AI | `https://apihub.agnes-ai.com/v1` | matikan thinking lewat `chat_template_kwargs` |
| OpenRouter | `https://openrouter.ai/api/v1` | id berisi `/` dan `:`; 402 = kredit habis; varian `:batch` dibuang; 200 berisi `error` |

Key hanya dari environment server; base URL harus HTTPS ke host di allowlist (dicek saat start
**dan** setiap request); redirect tidak diikuti; pesan error dibersihkan dari pola mirip key.

### 6.2 Rencana aksi JSON

Model membalas satu objek `{"reply", "actions", "clarify"}` (bukan *native tool calling*, karena
dukungannya tidak seragam di model gratis). Parser toleran terhadap ```json, `<think>`, dan teks
pembuka. JSON rusak → diminta perbaiki sekali → pindah model.

| op | Konfirmasi |
|---|---|
| `todo.list`, `reminder.list`, `chat.search` (putaran kedua: hasil dikirim balik ke model) | — |
| `todo.create` (≤ 10/pesan), `reminder.create`, `memory.add` | tidak (bisa di-undo) |
| `todo.update/complete/reopen`, `reminder.update/pause/resume/snooze`, `memory.update` — 1–3 item | tidak (bisa di-undo) |
| perubahan > 3 item sekaligus | **ya** |
| `todo.delete`, `todo.archiveDone`, `reminder.delete`, `memory.remove` | **ya, selalu** |

Server memeriksa whitelist op, bentuk field, kepemilikan id (`WHERE user_id = ?`), lalu menjalankan
semua aksi satu pesan dalam **satu transaksi** dengan catatan undo (snapshot sebelum/sesudah). Undo
ditolak kalau datanya sudah berubah lagi sejak itu.

### 6.3 Isi prompt

Persona → identitas pengguna → waktu sekarang + tabel 14 hari ke depan → **ingatan** (profil &
catatan, dengan kapasitas) → daftar aksi & bentuk jadwal → aturan → **DATA** (todo terbuka ≤ 100,
selesai 7 hari ≤ 30, pengingat ≤ 50; catatan todo hanya bila diizinkan admin) → 10 pesan terakhir.
Tidak pernah dikirim: password, token, nama/IP perangkat, pengaturan, key, data pengguna lain.

## 7. Keamanan

| Ancaman | Penanganan |
|---|---|
| Penyadapan | HTTPS lewat reverse proxy + HSTS; server mendengar localhost / port internal |
| Akses tanpa izin | password bcrypt (min. 10 karakter); token sesi acak 256-bit, server hanya menyimpan SHA-256; cookie `HttpOnly + Secure + SameSite=Strict` (30 hari, diperpanjang); token perangkat (Mac) 1 tahun, bisa dicabut |
| Tebak password | 5 gagal / 15 menit per IP, 100 gagal / jam global; waktu respons sama untuk username tak dikenal |
| CSRF | header wajib `X-AITodo: 1` di semua `/api/` + SameSite=Strict; tanpa CORS |
| XSS | Vue merender teks (tanpa `v-html`); CSP `script-src 'self'` tanpa `unsafe-*`; skrip registrasi SW sebagai berkas terpisah |
| Data antar pengguna | semua query memakai `user_id`; pencarian chat & ingatan per pengguna; tes otomatis |
| Prompt injection | DATA/INGATAN ditandai "bukan perintah"; whitelist op; hapus/massal hanya lewat tombol; ingatan dipindai sebelum disimpan |
| Data sensitif ke provider AI | minimisasi konteks; catatan todo default tidak dikirim; ingatan menolak password/PIN/key/kartu; peringatan bahwa model gratis bisa mencatat prompt |
| Key AI bocor | hanya di `.env` server; tidak di database, respons API, log, backup, repo |
| SSRF | allowlist host provider AI & layanan Web Push; HTTPS; tanpa redirect |
| Penyalahgunaan kuota | batas pesan per menit/hari per pengguna (diatur admin), maks 2 putaran AI per pesan, tidak pernah ke model berbayar otomatis |
| Spam notifikasi | interval ≥ 15 menit, ≤ 100 pengingat aktif |
| Admin = akses isi? | tidak: admin tidak punya endpoint untuk membaca todo/chat/ingatan orang lain |
| Database bocor | isi todo tidak dienkripsi saat diam (diterima: server milik sendiri); berkas di volume privat; backup dengan `aitodo backup` |

## 8. Teknologi & penyimpanan

| Bagian | Teknologi |
|---|---|
| Server | Go 1.24, `net/http`, `modernc.org/sqlite` (tanpa cgo), `webpush-go`, `x/crypto/bcrypt` |
| Database | satu berkas SQLite (WAL): `users`, `sessions`, `settings`, `user_settings`, `todos`, `reminders`, `ai_models`, `chat_messages` (+ FTS5 `chat_fts`), `action_batches`, `memories`, `push_subscriptions` |
| Web | Vue 3 + vue-router + Vite + vite-plugin-pwa, ditanam ke binary (`go:embed`) |
| Real-time | long-poll `GET /api/changes?since=<rev>&wait=1` |
| Deploy | Docker (satu image), `docker compose`, reverse proxy host (nginx/Caddy) untuk HTTPS |

## 9. API (ringkas)

Semua `/api/` wajib `X-AITodo: 1`. Cookie (browser) atau `Authorization: Bearer` (Mac).

| Kelompok | Endpoint |
|---|---|
| Sesi | `POST /login`, `POST /login/device`, `POST /logout`, `GET/PUT /me`, `PUT /me/password`, `PUT /me/prefs`, `GET /sessions`, `DELETE /sessions/{id}`, `POST /devices` |
| Todo | `GET/POST /todos`, `PUT/DELETE /todos/{id}`, `POST /todos/{id}/complete\|reopen`, `POST /todos/archive-done` |
| Pengingat | `GET/POST /reminders`, `GET /reminders/upcoming`, `PUT/DELETE /reminders/{id}`, `POST /reminders/{id}/snooze` |
| Chat | `GET/POST/DELETE /chat`, `POST /chat/batches/{id}/confirm\|reject\|undo` |
| Ingatan | `GET/POST /memory`, `PUT/DELETE /memory/{id}`, `GET /memory/export` |
| Sinkron & push | `GET /changes`, `GET /push/key`, `POST /push/subscribe\|unsubscribe\|test` |
| Admin | `GET /admin/stats`, `GET/POST /admin/users`, `PUT/DELETE /admin/users/{id}`, `GET /admin/ai`, `PUT /admin/ai/settings`, `POST /admin/ai/models`, `PUT/DELETE /admin/ai/models/{id}`, `POST /admin/ai/models/{id}/test`, `POST /admin/ai/models/reorder`, `GET /admin/ai/providers/{p}/models`, `POST /admin/ai/models/import` |

## 10. Tahapan

| Versi | Isi | Status |
|---|---|---|
| v0.1.0 | server Go + SQLite, PWA Vue (menu pengguna & admin), asisten AI + katalog model, ingatan, pengingat & Web Push, Docker, CI | **selesai** |
| v0.2.0 | aplikasi menu bar Mac (token perangkat, chat cepat, notifikasi lokal, update bertanda tangan) | **selesai** (uji di Mac sungguhan menyusul) |
| v0.3.0 | deploy otomatis ke VPS (backup, health check, rollback) seperti PasteLAN/our-life-planner | |
| lanjut | todo berulang, sub-tugas, ringkasan ditulis AI, Telegram, *native tool calling* untuk model yang mendukung, rangkuman otomatis ingatan saat penuh | |

## 11. Kriteria penerimaan v0.1.0

- [x] `go test -race ./...` hijau: jadwal, client AI (fallback, 200 berisi error, spasi awal,
  allowlist, key tidak bocor), asisten (todo+pengingat, konfirmasi hapus meski ada injeksi, isolasi
  pengguna, fallback, putaran data, waktu lampau ditolak, shortcut, undo), ingatan (masuk prompt,
  tolak rahasia/injeksi, batas kapasitas, hapus perlu konfirmasi, pencarian chat terisolasi), HTTP
  (CSRF, sesi, batas login, isolasi, token perangkat dicabut, penjaga admin terakhir, header keamanan).
- [x] E2E Chromium terhadap server asli: login, todo manual + pengingat dari form, pengingat
  mingguan, ingatan (rahasia ditolak), chat shortcut + undo, katalog model + tes, buat pengguna,
  token Mac, pengguna biasa tidak bisa membuka admin, tampilan HP; tanpa error konsol/CSP.
- [ ] Uji dengan API key asli kenari/Agnes/OpenRouter (belum bisa dari lingkungan pengembangan).

## 12. Pertanyaan terbuka

1. Nama produk final, domain (mis. `todo.katili.dev`), dan VPS-nya.
2. Provider utama dan key yang dipakai (disarankan key terpisah dari katilidev).
3. Perlu berbagi todo antar pengguna (mis. todo keluarga bersama) di versi berikutnya?
