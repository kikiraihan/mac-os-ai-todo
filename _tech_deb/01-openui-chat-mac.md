# Tech debt 01 — OpenUI (UI generatif) di chat

Status: **ditunda** (dicatat 2026-11-02). Belum ada kode yang diubah.

## Tujuan

Asisten bisa menjawab dengan UI interaktif (kartu, tabel, form, grafik) memakai
[OpenUI](https://www.openui.com/) (repo `thesysdev/openui`, MIT): model menulis *OpenUI Lang*
(satu komponen per baris, bisa di-stream), lalu renderer menggambarnya dari komponen milik kita.

## Hasil pengecekan

- Renderer resmi hanya untuk web: React, **Vue (`@openuidev/vue-lang`)**, Svelte, Angular.
  Parser `@openuidev/lang-core` tidak bergantung framework.
- **Tidak ada dukungan Swift / AppKit / macOS native.** Chat menu bar sekarang AppKit murni
  (`NSPopover` + `NSStackView` di `Sources/AITodo/main.swift`), jadi tidak bisa dipasang langsung.

## Rencana yang direkomendasikan (jalan B)

Tab Chat di popover diganti `WKWebView` yang memuat `ChatView.vue` dari PWA; `@openuidev/vue-lang`
dipasang di `web/`. Wadah tetap `NSPopover` (dropdown dari ikon, ⌥⌘T tetap). Tab Manual, Pengaturan,
notifikasi, Keychain, long-poll tetap native. Satu kode UI generatif untuk PWA & Mac.

Alternatif (jalan A, tidak disarankan): tulis parser OpenUI Lang + renderer NSView sendiri di Swift —
berat, tanpa dukungan resmi, komponen dibuat dua kali.

## Pekerjaan yang harus dibereskan

1. **Login WebView** — Mac memakai Bearer token (Keychain), WebView butuh cookie `aitodo_session`.
   Perlu endpoint tukar token perangkat → cookie sekali pakai. Token tidak boleh lewat URL / JS.
2. **CSP ketat** (`script-src 'self'; style-src 'self'`, tanpa `unsafe-*`, tanpa CDN):
   - jangan pakai `@openuidev/browser-bundle` / CDN; bundel lewat Vite;
   - cek apakah `vue-lang` menyuntik `<style>` atau memakai `eval`. Kalau ya: pakai `lang-core` saja
     + renderer Vue buatan sendiri.
3. **AI tidak menulis DB** — OpenUI hanya tampilan. Tombol/form dari AI tidak mengeksekusi apa pun
   langsung; harus menjadi op lewat `allowedOps`/`toOps`/`execute` + kartu konfirmasi/undo (`BatchCard`).
   Komponen di-whitelist. Server: field `ui` di jawaban asisten, prompt di `internal/ai`, validasi.
4. **Mac**:
   - kaca blur native pada input diganti CSS;
   - fokus keyboard WebView di dalam popover perlu diuji di Mac sungguhan.

## Perkiraan RAM

| Kondisi | Perkiraan |
|---|---|
| Sekarang (AppKit murni) | ±20–40 MB |
| Dengan WKWebView di tab Chat | +40–100 MB (total ±60–140 MB) |

Penyebab: proses WebKit terpisah (Web Content, Networking, GPU). Pembanding: tab Safari 50–150 MB,
aplikasi Electron 300–600 MB.

Mitigasi:
- **lazy load**: WebView baru dibuat saat tab Chat pertama dibuka;
- **lepas saat idle**: buang WebView setelah popover tertutup 5–10 menit (buka lagi ±0,3–1 dtk);
- render maks. 30 pesan terakhir; matikan service worker PWA di dalam WebView.

Ukur setelah dibangun: Activity Monitor → Memory → jumlahkan "AITodo" + "AITodo Web Content".

## Versi

Fitur baru → naik `b`.
