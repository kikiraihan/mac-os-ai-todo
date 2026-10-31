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

## Berikutnya

- [ ] Deploy otomatis ke VPS (backup, health check, rollback)
- [ ] Uji dengan API key asli & pilih model default terbaik
- [ ] Todo berulang, sub-tugas, rangkuman otomatis ingatan
