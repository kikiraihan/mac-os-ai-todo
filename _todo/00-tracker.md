# Tracker — AI Todo

Rancangan: [`../docs/PRD.md`](../docs/PRD.md). Perbarui setiap tugas selesai.

## v0.1.0 — server + PWA ✅

- [x] PRD v1 → v2 (stack Go + Vue + SQLite, peran admin/user, katalog model, ingatan, manual)
- [x] SQLite: pengguna, sesi, todo, pengingat, katalog model, chat (+FTS5), batch aksi, ingatan, push
- [x] Jadwal pengingat (sekali/harian/mingguan/bulanan/tahunan/interval, until/count) + tes
- [x] Client AI kenari / Agnes / OpenRouter: fallback, allowlist host, toleran balasan aneh + tes
- [x] Asisten: rencana aksi JSON, whitelist, konfirmasi, undo, putaran data, shortcut tanpa AI + tes
- [x] Ingatan ala Hermes: profil/catatan berbatas, pemindai rahasia & injeksi, persona, pencarian chat + tes
- [x] Penjadwal: pengingat, tenggat, ringkasan pagi, dorongan terlambat; Web Push per pengguna
- [x] HTTP API + keamanan (CSRF, sesi hash, batas login, isolasi, penjaga admin) + tes
- [x] PWA Vue: Asisten, Todo, Pengingat, Ingatan, Pengaturan; admin: Ringkasan, Pengguna, Model AI, Asisten
- [x] E2E Chromium terhadap server asli (desktop & HP)
- [x] Dockerfile, docker-compose, .env.example, Makefile (`backup` aman saat berjalan), CI

## v0.2.0 — aplikasi Mac

- [x] Server: `POST /api/login/device` (login password → token perangkat) + tes
- [x] `Client.swift` (Foundation): API, long-poll, pengelompokan todo, rencana notifikasi; diuji di Linux terhadap server asli
- [x] Menu bar + badge, centang cepat (⌥ = buka web), tambah todo manual, pengingat berikutnya
- [x] Panel chat (hotkey ⌥⌘T) dengan konfirmasi / batal / undo kartu aksi
- [x] Notifikasi lokal (pengingat + tenggat) dengan tombol Selesai / Tunda 10 mnt
- [x] Token di Keychain, buka saat login, cek pembaruan (Ed25519, pola PasteLAN)
- [x] Workflow macOS: tes klien, build universal, rilis otomatis
- [ ] Pemilik: buat kunci tanda tangan (`swift scripts/sign-release.swift keygen`), isi `Updater.publicKey`
      dan secret `AITODO_SIGNING_KEY` supaya update otomatis aktif
- [ ] Uji manual di Mac sungguhan

## v0.3.0 — log admin (pola Racik)

- [x] AI Call Log: setiap request keluar ke provider AI dicatat (metadata saja, tanpa isi prompt/jawaban)
      lewat `ai.Registry.Recorder` → antrean asinkron → tabel `ai_calls`; retensi `AI_CALL_LOG_RETENTION_DAYS`
- [x] System Log: ring buffer 3000 baris log server di memori, password & key disembunyikan
- [x] Endpoint admin + halaman Admin → AI Call Log & System Log + tes
- [x] Daftar model Agnes: coba ulang sekali saat 5xx, pesan error gaya new-api/HTML terbaca, model gambar/video
      dibuang, model Agnes ditandai gratis (sebelumnya daftar kosong karena filter "Gratis saja")

## v0.4.0 — UI Mac baru & pilihan model lebih jelas

- [x] Mac: klik ikon menu bar = popover dengan tab **Chat** (gaya Claude: gelembung pengguna di kanan, jawaban AI
      penuh lebar, kotak input di bawah) dan **Manual** (tambah todo + daftar, klik lingkaran = selesai)
- [x] Mac: tombol buka di browser & Pengaturan di header popover; klik kanan ikon = menu singkat
- [x] Mac: jendela Pengaturan terpisah (Umum, Akun, Tentang — pola PasteLAN)
- [x] Admin → Model AI: tombol **Jadikan utama**, tag **dipakai sekarang**, petunjuk API key; Admin → Asisten
      mengarahkan ke halaman Model AI
- [ ] Uji manual popover & Pengaturan di Mac sungguhan

## Berikutnya

- [x] Deploy otomatis ke VPS (backup, health check, rollback) — `CICD.md`, diuji dengan docker tiruan
- [ ] Pemilik: isi secret SSH_* (CICD.md B1) setelah server pertama kali dipasang
- [ ] Uji dengan API key asli & pilih model default terbaik
- [ ] Todo berulang, sub-tugas, rangkuman otomatis ingatan
