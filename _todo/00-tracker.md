# Tracker — AI Todo

Rancangan: [`../docs/PRD.md`](../docs/PRD.md). Perbarui tracker ini setiap kali tugas selesai.

## Keputusan yang masih terbuka

Lihat PRD §15 (nama produk, satu pemilik vs multi-akun, provider utama, domain, jam notifikasi,
repo public/private). Implementasi v0.1.0 menunggu jawaban nomor 1, 2, dan 4.

## Tahapan

- [x] PRD draft v1
- [ ] v0.1.0 — server Go + PWA: login & link setup, token per perangkat, admin, CRUD todo & pengingat,
      long-poll, penyimpanan `data.json` atomik, deploy (systemd + Caddy + CI/CD)
- [ ] v0.2.0 — penjadwal pengingat, Web Push + aksi Selesai/Tunda, ringkasan pagi, dorongan terlambat
- [ ] v0.3.0 — asisten AI: client kenari/Agnes/OpenRouter + fallback + allowlist, rencana aksi JSON,
      konfirmasi, undo, rate limit, tes model di admin
- [ ] v0.4.0 — aplikasi Mac: menu bar + badge, chat cepat, notifikasi lokal, QR, Keychain, update bertanda tangan
- [ ] v1.0.0 — stabil setelah dipakai harian
