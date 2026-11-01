# AGENTS.md

Panduan untuk agen AI (Claude Code, dsb.) di repo ini.

## Proyek

AI Todo: server Go + SQLite (`server/`), PWA Vue 3 (`web/`, hasil build ditanam ke
`server/internal/webui/dist`), aplikasi menu bar Mac (`Sources/AITodo/`). Rancangan: `docs/PRD.md`.
Perbarui `_todo/00-tracker.md` setiap tahapan selesai.

**Agen yang memasang / memperbarui server di VPS: ikuti [`DEPLOY.md`](DEPLOY.md)** (termasuk aturan
keamanannya di §0 dan titik "tanya pemilik").

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
