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
- [ ] Uji manual filter, input multi-baris, & mode ubah di Mac sungguhan

## v0.7.0 — web HP gaya iOS & tab Todo di Pengaturan Mac

- [x] Web HP: menu pindah ke atas (segmented control kaca), gestur geser ala iOS (`SwipeRow`: kanan =
      selesai/jeda, kiri = ubah·tunda·hapus, geser penuh = langsung), filter todo = carousel chip, tambah cepat
      dengan segmented tanggal, kotak centang bulat, tombol Hapus di lembar ubah todo & pengingat, toast di atas,
      input 16px, theme-color ikut mode terang/gelap. Diperiksa dengan Playwright (iPhone 13, terang & gelap)
- [x] Mac: tab **Todo** di Pengaturan — kelola lengkap (filter Hari ini/Akan datang/Tanpa tenggat/Semua/Selesai,
      cari, kategori, ⌘N tambah, klik dua kali/↩ ubah lewat lembar, spasi selesai/buka lagi, ⌫ hapus, klik kanan,
      arsipkan yang selesai); menu klik kanan "Kelola semua todo…". `Client.swift`: todos(status:), createTodo
      lengkap, reopen, deleteTodo, archiveDone + tes klien
- [ ] Uji manual tab Todo di Mac sungguhan
- [ ] Uji gestur geser di iPhone & Android sungguhan

## v0.7.1 — bar undo Mac bisa ditutup & perbaikan notifikasi PWA

- [x] Mac: tombol ✕ di bar "Aksi terakhir sudah dijalankan" — menutup bar tanpa membatalkan aksi (masih bisa
      `/undo`); id kartu yang ditutup diingat (`LocalPrefs.dismissedUndoBatch`) supaya tidak muncul lagi
- [x] Server push: klaim VAPID `sub` jadi `mailto:mailto:…` (webpush-go menambah awalan sendiri) → Apple
      menolak 403; sekarang awalan dibuang (`subscriberClaim`). Langganan hanya dihapus saat 404/410, bukan
      401/403 (dulu notifikasi diam-diam berhenti). Galat layanan push dicatat + dikembalikan ke "Kirim tes"
- [x] Allowlist endpoint: Chrome baru memberi endpoint `*.google.com/fcm/send/…` (mis. jmt17.google.com) yang
      dulu ditolak 400 → notifikasi di Chrome tidak bisa dinyalakan
- [x] Web: `src/push.js` — langganan disinkron ulang ke server setiap app dibuka/masuk (langganan server ikut
      terhapus saat sesi keluar/kedaluwarsa), ganti langganan kalau kunci VAPID server berubah, "Kirim tes"
      sinkron dulu. Service worker: tombol Selesai/Tunda membuka app kalau API gagal (mis. 401),
      `pushsubscriptionchange` mendaftarkan langganan baru. Tes `internal/push` (layanan push tiruan)
- [x] E2E Chromium terhadap server asli: nyalakan → kirim tes ke FCM sungguhan (`sent: 1`) → push sampai ke
      service worker (judul, isi, tombol Selesai / Tunda 10 mnt) → logout/login → sinkron otomatis → matikan
- [ ] Uji manual di Mac sungguhan
- [ ] Uji notifikasi di iPhone (PWA di Layar Utama) setelah deploy

## v0.8.0 — contoh pertanyaan di chat Mac & filter Pengingat

- [x] Mac: carousel chip kaca **contoh pertanyaan** di atas kotak input chat (`SuggestionBar`), sama dengan
      chip di web + "Todo besok apa?" & "Pengingat apa saja yang aktif?". Klik = langsung kirim; geser ke
      samping (trackpad atau roda mouse), tepi memudar menandakan masih ada chip lain. Sembunyi saat mengetik
      atau saat menunggu konfirmasi; klik kanan → Sembunyikan, nyalakan lagi di Pengaturan → Umum
      (`LocalPrefs.showSuggestions`)
- [x] Mac tab Manual: pengingat yang terkait todo tidak lagi didaftar terpisah — cukup ikon 🔔 + waktu berbunyi
      berikutnya di baris todo-nya (tooltip = jadwal). Pengingat tanpa todo pindah ke filter baru **Pengingat**
      (`Hari ini | Semua | Pengingat`): Akan berbunyi (urut waktu) & Dijeda, tautan "Kelola pengingat di browser";
      kartu tambah todo disembunyikan di filter ini. Pilihan filter diingat (`LocalPrefs.manualScope`).
      `Client.swift`: `Reminder` + `reminders()` (GET /api/reminders), ikut disinkron di `Store.refresh` + tes klien
- [ ] Uji manual carousel di Mac sungguhan (macOS 26 Liquid Glass & versi lama)
- [ ] Uji manual ikon 🔔 & filter Pengingat di Mac sungguhan

## v0.9.0 — detail & salin todo, tab Todo | Pengingat, kelola pengingat di Mac

- [x] **Detail todo** (kolom `notes`, opsional; maks 5000 karakter): link, rincian, daftar catatan.
      AI: `todo.update` + `addNotes` menambah detail di bawah yang lama tanpa menimpa (`core.TodoInput.AppendNotes`,
      juga di API), alias `detail`; aturan prompt no. 10; bila admin tidak mengirim isi catatan ke AI, DATA
      memberi tanda `hasNotes`. Tes `TestTodoDetailAppend` (tambah, ringkasan "Detail ditambahkan", undo)
- [x] Mac: tanda **≡ Detail** di baris todo → klik = pratinjau (NSPopover: judul, info, detail dengan link bisa
      diklik & daftar •, tombol Salin / Ubah…); arahkan mouse = tooltip detail. Kolom Detail juga di kartu ubah
      cepat (↩ = baris baru)
- [x] Salin todo (judul + baris kosong + detail): Mac klik kanan → Salin, tahan ⌥ → Salin judul saja; ⌘C di
      pratinjau (tanpa pilihan = semua) & di Pengaturan → Todo (baris terpilih); umpan balik di baris status.
      Menu Edit tak terlihat (`AppDelegate.editMenu`) supaya ⌘C/⌘V/⌘X/⌘A/⌘Z bekerja di aplikasi menu bar
- [x] Web: tanda **Detail** di baris (klik = buka/tutup detail di tempat, link bisa diklik — `DetailText.vue` tanpa
      v-html, tombol Salin), tombol salin di baris (desktop, ⌥-klik = judul saja), Salin di lembar ubah,
      label "Catatan" → "Detail (opsional)". Dicek Playwright (desktop, iPhone 13, gelap)
- [x] Mac popover jadi tiga tab **Chat | Todo | Pengingat** (dulu Chat | Manual). Satu tujuan per tab; "Selesai"
      selalu filter paling ujung: Todo = `Hari ini | Semua | Selesai`, Pengingat = `Aktif | Selesai`. Di Selesai,
      klik ✓ = batalkan (todo dibuka lagi / pengingat aktif lagi; jadwal yang sudah lewat → tawaran "Ubah jadwal…").
      Pilihan filter per tab diingat (`LocalPrefs.todoScope`, `reminderScope`)
- [x] Klik teks todo / pengingat = **salin** (⌥-klik = judul saja), teks berkedip + "Judul & detail disalin";
      klik dua kali tetap ubah, ikon ○ tetap selesai. Klik pada tombol Detail tidak ikut menyalin
- [x] Pengaturan → tab **Pengingat** (`ReminderPage`): Aktif | Selesai, cari, + baru (⌘N), klik dua kali / ↩ ubah,
      spasi selesai/aktifkan lagi, ⌫ hapus (konfirmasi), ⌘C salin. Lembar `ReminderEditor`: judul, pesan, **todo
      terkait** (supaya 🔔 tampil di todo-nya), jadwal Sekali / Tiap hari / Tiap minggu (pilih hari) / Tiap bulan;
      jenis lain (interval, tahunan) tetap diubah lewat web. Menu ikon: "Kelola pengingat…"
- [x] 🔔 + waktu berikutnya juga di daftar Pengaturan → Todo. `Client.swift`: `ReminderSchedule`, `createReminder`,
      `updateReminder`, `deleteReminder`, `Todo.completedAt` + tes klien (selesai/aktifkan, ubah & kaitkan ke todo,
      jadwal lewat ditolak, mingguan, hapus)
- [ ] Uji manual pratinjau detail, menu Salin (⌥), ⌘C/⌘V di Mac sungguhan
- [x] Pintasan standar di popover & jendela Mac: ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⇧⌘Z / ⌘W lewat monitor lokal
      (`installEditShortcuts`) + menu Edit tak terlihat sebagai cadangan
- [ ] Uji manual tiga tab popover, klik-salin, tab Pengingat di Pengaturan di Mac sungguhan
- [ ] Uji manual ⌘C/⌘V/⌘X/⌘A/⌘Z di input chat, kolom tambah todo, kartu ubah, lembar Pengaturan
- [x] 0.9.1: popover Mac ikut tertutup saat indikator menu bar lain diklik (monitor klik global selama popover
      tampil, dilepas saat tertutup)
- [ ] Uji manual: buka popover → klik indikator lain / Wi-Fi / jam → popover tertutup
- [x] 0.9.2: kartu tambah todo di tab Todo popover Mac **disembunyikan bawaan**; tombol ＋ di header (hanya tab Todo,
      bukan filter Selesai) / ⌘N membuka kartu & fokus ke judul, ＋ lagi atau Esc menutup (isian dikosongkan).
      Kartu tetap terbuka setelah Tambah (bisa menambah beruntun); pindah tab = tertutup
- [ ] Uji manual: ＋ / ⌘N / Esc di tab Todo popover Mac sungguhan
- [x] 0.10.0: daftar tab Todo popover Mac bisa **dikelompokkan menurut Waktu (bawaan) atau Kategori**
      (`LocalPrefs.todoGroup`). Pilih lewat klik kanan filter Hari ini | Semua | Selesai, atau Pengaturan → Umum →
      "Kelompokkan todo". Mode Kategori: kelompok urut abjad, "Tanpa kategori" paling bawah, di dalamnya urut tenggat;
      baris menulis "Terlambat" / "hari ini" karena judul tanggal tidak ada, kategori tidak diulang di baris.
      Filter Selesai tetap urut waktu selesai
- [ ] Uji manual: klik kanan filter → Kategori, Pengaturan → Umum, di Mac sungguhan

- [x] 0.12.0: popover Mac — **tambah cepat di tab Pengingat** (＋ / ⌘N: judul + Kapan Hari ini/Besok/Lusa/Tiap hari
      + time picker), jam di kartu tambah todo kini **time picker** (centang "Jam") bukan ketik HH:MM, dan
      **"Isian lengkap…"** (atau ⌥-klik ＋) di kedua tab: form lengkap di tempat kartu (todo: detail, kategori,
      prioritas, tanggal & jam picker; pengingat: pesan/detail, todo terkait, jadwal sekali/harian/mingguan/bulanan).
      "Pengingat baru…" di daftar kini membuka form ini (bukan lembar Pengaturan)
- [ ] Uji manual di Mac sungguhan: ＋ / ⌘N / ⌥-klik ＋ / Esc di tab Todo & Pengingat, isian lengkap, picker jam
- [x] 0.12.1: perbaikan build Mac (rusak sejak 0.11.0): `.resume()` berlebih setelah `macDownload` di `Updater.install`
- [x] 0.12.2: tab Pengingat popover Mac — tautan "Pengingat baru…" kini membuka **kartu tambah cepat** (sama dengan
      tab Todo / ＋), bukan langsung form lengkap; "Isian lengkap…" tetap di kartu (⌥-klik tautan = langsung form
      lengkap). Dari filter Selesai otomatis pindah ke Aktif (dulu membuka lembar Pengaturan)
- [x] 0.13.0: kartu tambah cepat tab Pengingat (popover Mac) punya pilihan **Todo terkait**. Memilih todo mengisi
      judul yang masih kosong dengan judul todo, dan Kapan + jam dengan tenggat todo (hari ini/besok/lusa, jam belum
      lewat) selama belum diubah pengguna. Todo terkait ikut terbawa ke "Isian lengkap…"; setelah Tambah muncul
      "🔔 di todo …" karena pengingat milik todo tampil di baris todo-nya
- [ ] Uji manual di Mac sungguhan: Todo terkait di kartu cepat Pengingat
- [x] 0.13.0: PWA chat — **Enter tidak langsung mengirim** (Enter = baris baru, kirim lewat tombol Kirim;
      pintasan ⌘/Ctrl+Enter). Kotak pesan tumbuh mengikuti isi sampai batas tinggi
- [x] 0.14.0: PWA — **pembaruan tidak lagi telat**. Service worker mode `prompt` + registrasi lewat
      `virtual:pwa-register` (`web/src/update.js`): cek pembaruan saat dibuka, setiap kembali dari latar belakang
      (iPhone tidak mengecek sendiri), dan tiap jam; versi baru yang ditemukan ≤15 dtk setelah dibuka langsung dipasang
      (kecuali sedang mengetik), selain itu toast. Pengaturan → **Pembaruan aplikasi**: versi, Periksa pembaruan,
      Perbarui sekarang, Muat ulang paksa (hapus cache, SW & langganan push tetap). Diuji Playwright: server 0.14.0 → 0.14.1
- [ ] Uji manual di iPhone (PWA terpasang): update sampai tanpa tutup-buka berkali-kali
- [x] 0.14.1: popover Mac — pratinjau **Detail** kadang membuat popover utama macet (tidak bisa diklik). Penyebab:
      daftar dibangun ulang (sinkron / ganti filter) saat pratinjau terbuka → tombol jangkarnya lepas dari jendela.
      Kini pratinjau dipindah ke tombol Detail baris baru (atau ditutup bila todo berubah/hilang), ikut ditutup saat
      popover utama ditutup, dan fokus dikembalikan ke popover utama setelah pratinjau tertutup
- [ ] Uji manual di Mac sungguhan: buka Detail lalu tunggu sinkron / ubah todo dari web — popover tetap bisa diklik
- [x] 0.14.2: aplikasi menu bar Mac lebih hemat — selama popover tertutup, daftar todo tidak lagi digambar ulang di
      setiap sinkron (ditandai, lalu dibangun sekali sebelum popover tampil); jadwal notifikasi yang isinya sama tidak
      dicocokkan ulang ke Notification Center (tetap dicek ulang paling lambat tiap 15 menit). Long-poll (25 dtk) &
      timer 15 menit sudah hemat, tidak diubah
- [ ] Uji manual di Mac sungguhan: ubah todo dari web saat popover tertutup → buka popover, daftar sudah terbaru
- [x] 0.15.0: popover Mac tab Pengingat — filter **Hari ini | Semua | Selesai** (seperti tab Todo, menggantikan
      Aktif | Selesai). Hari ini = pengingat tanpa todo yang berbunyi hari ini (kosong → tautan "Lihat N pengingat
      lainnya"); Semua = semua pengingat aktif, termasuk milik todo (🔔 judul todo), dikelompokkan per hari lalu
      "Tanpa jadwal". Pilihan lama Selesai tetap diingat (kunci prefs baru `reminderFilter`)
- [ ] Uji manual di Mac sungguhan: tab Pengingat → Semua menampilkan pengingat besok & milik todo
- [x] 0.16.0: popover Mac — **urutan manual** todo & pengingat: tahan ⌃ → lingkaran jadi ≡, seret untuk memindah
      di dalam kelompoknya (Hari ini, Besok, kategori, …); jalan lain klik kanan → Urutkan (Paling atas, Naikkan,
      Turunkan, Paling bawah, Urutan bawaan). Disimpan di Mac ini saja; todo/pengingat baru tetap di posisi
      bawaannya (menurut waktu). Logika `ManualOrder` (Client.swift) diuji di `Tests/ClientCheck`
- [ ] Uji manual di Mac sungguhan: tahan ⌃ lalu seret ≡ (juga ⌃-klik tidak membuka menu di pegangan), urutan
      bertahan setelah sinkron & buka-tutup popover
- [x] 0.17.0: popover Mac — **cari** di tab Todo & Pengingat: tombol 🔍 di header (⌘F) membuka kolom cari di atas
      filter (bawaan tersembunyi). Menyaring daftar yang sedang tampil (Hari ini / Semua / Selesai) — todo: judul,
      detail, kategori; pengingat: judul, pesan, jadwal, judul todo terkait. Semua kata harus ada (urutan bebas, abaikan
      huruf besar & aksen); angka di filter ikut hasil; hasil di luar filter → tautan "… cocok di Semua". Esc = kosongkan,
      Esc lagi = tutup; ganti tab = tutup. Urutan manual nonaktif selama mencari. Tombol 🗑 kini hanya tampil di tab
      Chat (slotnya dipakai 🔍). Logika `TextSearch` (Client.swift) diuji di `Tests/ClientCheck`
- [ ] Uji manual di Mac sungguhan: ⌘F di tab Todo & Pengingat, ketik / ⓧ / Esc, sinkron saat mencari

## Berikutnya

- [x] 0.11.0: pembaruan aplikasi Mac lewat server (`/api/app/mac/*`, token GitHub read-only di `.env`) — repo private tetap bisa update
- [ ] Pemilik: isi `GITHUB_RELEASE_TOKEN` di `.env` VPS, lalu pasang AITodo 0.11.0 manual sekali
- [x] Deploy otomatis tanpa kredensial GitHub di VPS: kode dikirim sebagai git bundle lewat SSH (repo private tetap bisa deploy)
- [x] 0.10.1: pesan gagal cek pembaruan menyebut penyebab sebenarnya (404 repo privat / batas akses / jaringan)
- [x] 0.10.1: halaman Pengaturan (Umum, Akun, Tentang) bisa digulir; switch & tombol rata kanan
- [ ] Pemilik: pembaruan otomatis butuh rilis yang bisa dibaca tanpa login (repo publik, atau rilis di repo publik terpisah)
- [x] Deploy otomatis ke VPS (backup, health check, rollback) — `CICD.md`, diuji dengan docker tiruan
- [ ] Pemilik: isi secret SSH_* (CICD.md B1) setelah server pertama kali dipasang
- [ ] Uji dengan API key asli & pilih model default terbaik
- [ ] Todo berulang, sub-tugas, rangkuman otomatis ingatan
