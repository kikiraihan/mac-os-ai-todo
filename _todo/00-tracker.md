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

## v0.4.1 — perbaikan popover & input kaca

- [x] Klik kiri ikon tidak membuka apa-apa: `UI.scroll` mem-pin isi ke dokumen scroll tanpa `addSubview` →
      exception constraint ditelan AppKit, popover batal. `UI.pin` kini selalu memasukkan view ke induknya
- [x] Input chat & bar aksi = kaca gaya Apple (Liquid Glass di macOS 26, NSVisualEffectView di versi lama),
      melayang di atas chat sehingga teks yang lewat di belakangnya buram
- [x] Update: alasan update otomatis tidak bisa jalan ditampilkan (bukan diam-diam membuka GitHub)
- [x] Update otomatis memakai kunci tanda tangan yang sama dengan PasteLAN (`Updater.publicKey`)
- [ ] Pemilik: buat secret `AITODO_SIGNING_KEY` di repo ini = isi `~/.pastelan-signing-key` (sama dengan
      `PASTELAN_SIGNING_KEY`). Versi 0.4.0 yang sudah terpasang masih tanpa kunci → pasang 0.4.1 manual sekali

## v0.5.0 — akun admin terpisah & Ingatan di Mac

- [x] Akun admin terpisah dari akun pengguna: tabel `admins` + `admin_sessions`, cookie `aitodo_admin`
      (`Path=/api/admin`), token `aia_`, tanpa Bearer. Endpoint pengguna menolak sesi admin & sebaliknya
- [x] Admin hanya dibuat dari server (`ADMIN_*` saat belum ada admin, `aitodo admin <username>`) atau oleh
      admin lain (Admin → Akun admin); peran tidak bisa diubah dari akun pengguna; minimal satu admin aktif
- [x] Migrasi otomatis: `users.role = admin` → akun admin (username & password sama); akun lama tetap
      pengguna biasa beserta todo, chat, ingatan, dan token Mac
- [x] Web: mode admin (`/admin`, login `/admin/masuk`) & mode pengguna (`/`), tombol pindah mode kalau
      kedua akun sudah masuk; halaman Akun admin
- [x] Mac: tab **Ingatan** di Pengaturan (lihat, tambah, ubah, hapus, ekspor .md) + menu klik kanan
      "Ingatan AI…"; endpoint ingatan di `Client.swift` + tes klien
- [x] OpenUI dicatat sebagai tech debt (`_tech_deb/01-openui-chat-mac.md`)
- [ ] Uji manual tab Ingatan di Mac sungguhan
- [ ] Pemilik: setelah deploy, masuk lagi di `/admin` (password sama dengan sebelumnya)

## v0.5.1 — hapus riwayat chat di Mac

- [x] Popover: tombol ikon tempat sampah "Hapus riwayat chat" di header (aktif hanya di tab Chat, saat
      terhubung, tidak busy) + konfirmasi; menu klik kanan "Hapus riwayat chat…"
- [x] `Client.swift`: `clearChat()` → `DELETE /api/chat` (endpoint lama, server tidak diubah) + tes klien
- [x] Catatan: server ikut menghapus semua kartu aksi — aksi pending batal tanpa dijalankan, aksi yang
      sudah jalan tidak bisa di-undo lagi; disebut di teks konfirmasi Mac
- [ ] Uji manual tombol & menu di Mac sungguhan

## v0.6.0 — daftar todo Hari ini | Semua di tab Manual

- [x] Tab Manual: filter kecil **Hari ini | Semua** (`NSSegmentedControl` kecil di bawah kartu tambah, dengan
      jumlah). Hari ini (bawaan) = terlambat + hari ini + 3 pengingat berikutnya; Semua = semua todo terbuka
      per tanggal (Besok, Rab 5 Nov, …) + tanpa tenggat, maks. 200 baris lalu tautan ke browser
- [x] Pilihan filter diingat (`LocalPrefs.showAllTodos`); saat hari ini kosong ada tautan "Lihat N todo lainnya"
- [x] `TodoBuckets.upcomingByDay` & `total` di `Client.swift` + tes klien
- [x] AGENTS.md: prinsip desain gaya Apple (simpel, intuitif, rapi)
- [x] Input chat Mac: ↩ kirim, ⇧↩ (atau ⌥↩) baris baru; kapsul input tumbuh sampai 6 baris lalu menggulir,
      ikon & tombol kirim menempel di baris terakhir
- [x] Mode ubah todo di tab Manual Mac: tahan ⌥ → ○ jadi ✎ (klik = ubah), klik dua kali judul, atau klik
      kanan → Ubah… / Tandai selesai. Kartu ubah menggantikan barisnya: judul, kategori (combo box daftar
      yang ada), prioritas, ☑ Tanggal (NSDatePicker + kalender), ☑ Jam (NSDatePicker 24 jam); ↩ simpan, esc batal.
      Selama mengubah, sinkron tidak membangun ulang daftar. `Client.swift`: `updateTodo` (PUT) + tes klien
- [x] Web: klik di mana saja pada kolom tanggal/jam membuka picker (`pickers.js`, desktop); pengingat
      "Sekali" memakai satu datetime picker (`datetime-local`)
- [x] AGENTS.md: aturan picker tanggal/jam & pola ⌥
- [x] Web HP: menu pindah ke atas (segmented control kaca), gestur geser ala iOS (`SwipeRow`: kanan =
      selesai/jeda, kiri = ubah·tunda·hapus, geser penuh = langsung), filter todo = carousel chip, tambah cepat
      dengan segmented tanggal, kotak centang bulat, tombol Hapus di lembar ubah todo & pengingat, toast di atas,
      input 16px, theme-color ikut mode terang/gelap. Diperiksa dengan Playwright (iPhone 13, terang & gelap)
- [x] Mac: tab **Todo** di Pengaturan — kelola lengkap (filter Hari ini/Akan datang/Tanpa tenggat/Semua/Selesai,
      cari, kategori, ⌘N tambah, klik dua kali/↩ ubah lewat lembar, spasi selesai/buka lagi, ⌫ hapus, klik kanan,
      arsipkan yang selesai); menu klik kanan "Kelola semua todo…". `Client.swift`: todos(status:), createTodo
      lengkap, reopen, deleteTodo, archiveDone + tes klien
- [ ] Uji manual filter, input multi-baris, mode ubah, & tab Todo di Mac sungguhan
- [ ] Uji gestur geser di iPhone & Android sungguhan

## Berikutnya

- [x] Deploy otomatis ke VPS (backup, health check, rollback) — `CICD.md`, diuji dengan docker tiruan
- [ ] Pemilik: isi secret SSH_* (CICD.md B1) setelah server pertama kali dipasang
- [ ] Uji dengan API key asli & pilih model default terbaik
- [ ] Todo berulang, sub-tugas, rangkuman otomatis ingatan
