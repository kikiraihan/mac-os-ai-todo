# AGENTS.md

Panduan untuk agen AI (Claude Code, dsb.) di repo ini.

## Proyek

AI Todo: server Go + SQLite (`server/`), PWA Vue 3 (`web/`, hasil build ditanam ke
`server/internal/webui/dist`), aplikasi menu bar Mac (`Sources/AITodo/`). Rancangan: `docs/PRD.md`.
Perbarui `_todo/00-tracker.md` setiap tahapan selesai.

**Agen yang memasang / memperbarui server di VPS: ikuti [`DEPLOY.md`](DEPLOY.md)** (termasuk aturan
keamanannya di §0 dan titik "tanya pemilik"). Auto deploy dari GitHub Actions: [`CICD.md`](CICD.md)
(`scripts/deploy.sh` — backup, health check, rollback otomatis; jangan hapus langkah-langkah itu).

## Cek sebelum commit

```bash
cd server && gofmt -l . && go vet ./... && go test -race ./...
cd web && npm run build
./scripts/test-client.sh          # klien Swift ⇄ server Go (butuh swiftc; jalan di Linux juga)
swiftc -parse Sources/AITodo/*.swift   # di Linux: cek sintaks bagian AppKit
```

Tidak ada Mac di lingkungan agen cloud: bagian AppKit (`main.swift`) baru benar-benar dikompilasi
oleh workflow `.github/workflows/mac.yml` (macOS). `Client.swift` wajib tetap **hanya Foundation**
supaya bisa diuji di Linux.

## Prinsip desain: gaya Apple

Semua tampilan (aplikasi Mac & web) mengikuti gaya desain Apple (Human Interface Guidelines):
**simpel, intuitif, rapi**.

- **Simpel**: satu layar = satu tujuan utama. Tampilan bawaan menampilkan yang paling sering dipakai
  (mis. todo hari ini); detail lain ada satu klik di belakang (filter, tab, menu), bukan ditumpuk.
- **Intuitif**: pakai kontrol bawaan sistem (`NSSegmentedControl`, `NSPopUpButton`, `NSSwitch`, SF
  Symbols, `NSAlert`) dan pola yang sudah dikenal pengguna macOS / Pengingat (Reminders). Label pendek
  berbahasa Indonesia, tooltip & label aksesibilitas untuk tombol ikon. Aksi yang menghapus selalu
  dikonfirmasi.
- **Rapi**: jarak & margin konsisten (`PopoverController.inset`, kelipatan 4), warna sistem
  (`labelColor`, `secondaryLabelColor`, `separatorColor`) + satu aksen (`Theme.accent`), mendukung
  mode gelap. Jangan menambah warna, ukuran huruf, atau gaya tombol baru tanpa alasan.
- **Tanggal & jam selalu lewat picker**: web memakai input native `date` / `time` / `datetime-local`
  (klik di mana saja membuka picker — `web/src/pickers.js`), Mac memakai `NSDatePicker` (kalender
  `presentsCalendarOverlay`, jam `.hourMinute`). Pengecualian yang disengaja: kartu tambah cepat di tab
  Manual Mac (dropdown Hari ini/Besok/Lusa + kolom jam) — jangan diubah tanpa izin pemilik.
- Aksi alternatif mengikuti pola macOS: tahan ⌥ untuk menampilkan aksi kedua (mis. ○ selesai → ✎
  ubah, menu Salin → Salin judul saja), selalu dengan jalan lain yang mudah ditemukan (klik dua kali, klik kanan).
- Salin todo = teks polos "Judul" + baris kosong + detail (`TodoCopy` di Mac, `web/src/copy.js`), selalu dengan
  umpan balik singkat ("Judul & detail disalin"). Di popover Mac: klik teks = salin, ikon ○ = selesai, klik dua kali = ubah.
- Popover Mac: tab **Chat | Todo | Pengingat**; filter "Selesai" selalu paling ujung (✓ di sana = batalkan selesai).
  Pengingat milik todo = ikon 🔔 di baris todo; tab Pengingat hanya pengingat tanpa todo; kelola lengkap di
  Pengaturan → Pengingat.
- **HP (web ≤760px / layar sentuh)**: menu di atas (segmented control), judul besar, tombol utama =
  ikon bulat, area ketuk ≥40px, input ≥16px (Safari tidak zoom). Aksi baris lewat **gestur geser**
  (`components/SwipeRow.vue`: kanan = aksi utama, kiri = ubah/hapus, geser penuh = langsung) — tombol
  ikon kecil hanya untuk mouse. Setiap aksi geser wajib punya jalan lain lewat ketukan (lembar ubah).
  Filter banyak opsi = carousel chip (`.carousel` + `.chip`), pilihan 2–4 opsi = `.seg`.
- Fitur baru tidak boleh membuat tampilan yang sudah ada lebih ramai: kalau perlu ruang, sembunyikan
  di balik filter/tab kecil dengan bawaan yang paling ringkas, dan ingat pilihan pengguna.

## Aturan yang tidak boleh dilonggarkan

- **AI tidak pernah menulis database langsung.** Semua aksi lewat `internal/core` (validasi yang
  sama dengan form manual). Op baru di asisten = tambah ke whitelist `allowedOps`, validasi bentuk di
  `toOps`, eksekusi di `execute`, ringkasan di `preview`; aksi yang menghapus masuk `dangerousOps`.
- **Setiap query data pengguna memakai `user_id`.** Admin tidak mendapat endpoint untuk membaca
  todo/chat/ingatan pengguna lain.
- **API key AI hanya dari environment.** Jangan simpan di `settings`, jangan kirim ke klien, jangan
  log. Host provider baru → tambahkan ke `providerDefs` (allowlist) di `internal/ai/client.go`.
- **Ingatan** dipindai `core.ScanMemory` sebelum disimpan; jangan melemahkan pola rahasia/injeksi.
- Semua `/api/` wajib header `X-AITodo: 1`; cookie `HttpOnly + Secure + SameSite=Strict`; CSP
  tanpa `unsafe-*` (jangan pakai `v-html`, script/style inline, atau CDN).
- Jadwal pengingat dihitung server (`internal/schedule`), bukan AI. Waktu di database = RFC3339 UTC;
  tampilan memakai zona pengguna (`web/src/dates.js`).
- Jangan menyalin password contoh dari `.env.example`; server menolak berjalan dengannya.

## Versi

`VERSION` (format `a.b.c`): fitur baru → naik `b`, perbaikan/gaya minor → naik `c`, breaking →
naik `a`. PR yang hanya mengubah dokumentasi/CI tidak menaikkan versi. Satu versi untuk semuanya:
samakan `web/package.json` dan `Resources/Info.plist` (`CFBundleShortVersionString` = VERSION,
`CFBundleVersion` +1). CI menolak kalau Info.plist ≠ VERSION. Merge ke `main` dengan versi yang belum
punya tag → rilis `v<versi>` berisi `AITodo.zip`.
