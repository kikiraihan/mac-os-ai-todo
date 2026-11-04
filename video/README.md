# Video teaser

`ai-todo-teaser.mp4` — teaser 31 detik, 1920×1080, 30 fps, tanpa suara.

| Detik | Adegan |
|---|---|
| 0–4 | Ikon + "AI Todo — Cukup ketik. Asisten yang mencatat." |
| 4–11 | Chat: "besok jam 9 ingetin telpon bengkel, terus tandai beli galon udah" → 3 aksi + Batalkan |
| 11–16 | Popover menu bar Mac |
| 16–20 | Mac + web berdampingan |
| 20–24 | Tampilan HP (PWA) |
| 24–28 | Fitur: pengingat berulang, ingatan AI, undo, notifikasi, manual, server sendiri |
| 28–31 | Penutup: logo + "Todo yang bisa diajak ngobrol." |

## Render ulang

Sumber animasi ada di `src/teaser.html` (memakai screenshot dari `docs/screenshots/`). Buka langsung
di browser untuk pratinjau. Untuk membuat MP4 (butuh Node + Playwright/Chromium + ffmpeg):

```bash
node video/src/render.js
```
