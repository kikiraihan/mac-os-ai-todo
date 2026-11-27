# MCP — hubungkan AI Todo ke Claude & AI lain

AI Todo punya server **MCP** (Model Context Protocol) bawaan di `https://DOMAIN/mcp`. AI lain yang
mendukung MCP (Claude di web/HP/desktop, Claude Code, Cursor, dsb.) bisa membaca dan menambah todo,
pengingat, dan catatan — misalnya *"ingatkan saya jam 3 sore untuk telepon klien"* dari Claude akan
membuat pengingat di AI Todo, lalu **server AI Todo** yang mengirim notifikasinya ke HP Android, Mac,
dan PWA seperti pengingat biasa.

## Tool yang tersedia

| Tool | Butuh | Isi |
|---|---|---|
| `get_context` | baca | waktu & zona pengguna, jumlah todo terbuka / hari ini / terlambat |
| `list_todos` | baca | daftar todo (status, rentang tenggat, cari, kategori) |
| `create_todo`, `update_todo`, `complete_todo`, `reopen_todo` | tulis | kelola todo |
| `list_reminders` | baca | pengingat + bunyi berikutnya (waktu lokal) |
| `create_reminder`, `snooze_reminder` | tulis | pengingat sekali (`at`) atau berulang (`schedule`) |
| `list_notes` | baca | catatan (cari, disematkan) |
| `create_note`, `append_to_note` | tulis | simpan catatan / tambah isi |
| `send_to_devices` | tulis | kirim teks ke HP & perangkat lain sebagai **Kiriman** (notifikasi dengan tombol Salin) |

Sengaja **tidak ada**: tool hapus, akses chat asisten, Ingatan AI, pengaturan, atau data pengguna lain.

## Cara menyambungkan

### claude.ai / aplikasi Claude (OAuth)

1. Claude → **Settings → Connectors → Add custom connector**.
2. URL: `https://DOMAIN/mcp` (salin dari web AI Todo → Pengaturan → Integrasi AI lain).
3. Claude membuka halaman izin AI Todo → masuk bila perlu → pilih **Izinkan** (boleh hilangkan centang
   "Boleh menambah & mengubah" untuk akses baca saja).

### Claude Code / klien dengan header (token manual)

Web AI Todo → Pengaturan → **Integrasi AI lain (MCP)** → *Buat token MCP* → salin perintahnya, mis.:

```bash
claude mcp add --transport http aitodo https://DOMAIN/mcp --header "Authorization: Bearer ait_…"
```

Token hanya tampil sekali; server menyimpan hash-nya saja.

### Mencabut akses

Web → Pengaturan → **Perangkat**: baris bertanda **AI · baca / baca & tulis** → *Keluarkan*. Token OAuth
dan refresh token-nya langsung tidak berlaku. Ganti password juga mengeluarkan semua AI yang terhubung.

## Keamanan (untuk pengembang)

- Kode: `server/internal/httpapi/mcp.go` (JSON-RPC Streamable HTTP tanpa SSE, stateless) dan `oauth.go`.
- `/mcp` **hanya** menerima `Authorization: Bearer` sesi jenis `mcp` — cookie tidak dibaca (tidak ada
  CSRF), dan token MCP ditolak di `/api/` (tidak bisa membaca chat / ingatan / pengaturan).
- Header `Origin` asing ditolak (DNS rebinding). Batas: 120 request/menit, 30 perubahan/menit per token.
- Semua aksi lewat `internal/core` (validasi sama dengan form manual), `Source = "mcp"`, selalu `user_id`
  pemilik token. Argumen dengan kolom tak dikenal ditolak. Log hanya metadata (nama tool, berhasil/gagal).
- OAuth 2.1: pendaftaran klien dinamis (klien publik; redirect https atau http loopback), PKCE S256 wajib,
  kode sekali pakai 10 menit, persetujuan hanya dari sesi **browser** (bukan token perangkat), refresh
  token dirotasi dan terikat ke sesi (cabut sesi = refresh mati). `redirect_uri` yang tidak terdaftar
  tidak pernah dipakai sebagai tujuan redirect.
- Isi `PUBLIC_URL` di `.env` dengan alamat publik server: dipakai sebagai issuer OAuth & URL resource.
- Tool baru: tambahkan definisi ke `mcpTools` (tandai `writeTool` bila mengubah data), eksekusi di
  `mcpCall.run` lewat `internal/core`, tes di `mcp_test.go`. Jangan menambah tool hapus tanpa
  mekanisme konfirmasi pengguna.
