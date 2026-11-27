# Aplikasi Android

Kode: [`android/`](android/) — Kotlin + Jetpack Compose (Material 3, aksen teal yang sama dengan web & Mac),
minSdk 26 (Android 8), satu APK untuk server mana pun.

## Fitur

- Tab **Asisten | Todo | Pengingat | Catatan | Kiriman** (bawaan: Todo, tab terakhir diingat). Gestur geser
  seperti PWA di HP: kanan = aksi utama (selesai / tunda / sematkan / salin), kiri = hapus (dikonfirmasi);
  setiap aksi juga ada lewat ketuk (lembar ubah) atau tekan lama (menu).
- **Notifikasi dari server** dengan tombol langsung, tanpa membuka aplikasi:
  - Kiriman → **Salin** (teks langsung masuk clipboard; Android 13+ menampilkan konfirmasi sistem)
  - Todo / tenggat → **Selesai** & **Salin** ("Judul" + baris kosong + detail)
  - Pengingat → **Tunda 10 mnt**
- **Kiriman**: kirim teks dari HP ke Mac / web (dan sebaliknya: Mac → klik kanan ikon → *Kirim clipboard ke HP*,
  web → menu Kiriman, AI lain → tool MCP `send_to_devices`). Disimpan 7 hari (maks. 50).
- **Bagikan → AI Todo** dari aplikasi lain: jadi Kiriman, todo hari ini, atau catatan.
- Pembaruan lewat server (Pengaturan → Periksa pembaruan): `AITodo.apk` diunduh lewat `/api/app/android/*`
  (wajib login; repo GitHub boleh private). Android sendiri memastikan tanda tangan APK sama.

## 1. Jalur notifikasi

Server menyimpan setiap notifikasi di **kotak masuk** (`GET /api/notifications?after=<id>`). Aplikasi membacanya lewat:

| Mode | Kapan | Catatan |
|---|---|---|
| **FCM** (disarankan) | server mengisi `FCM_*` di `.env` dan HP punya Google Play | hemat baterai, tetap sampai saat HP tidur. Pesan FCM **hanya berisi nomor notifikasi** — judul, isi, dan teks Salin diambil langsung dari server AI Todo, jadi tidak lewat Google |
| **Koneksi langsung** | tanpa FCM | layanan latar depan long-poll `/api/changes` + notifikasi tetap "Terhubung ke server". Izinkan "berjalan tanpa pembatasan baterai" (tombol di Pengaturan aplikasi) |

Pengenal Firebase (bukan rahasia) dikirim server ke aplikasi yang sudah login (`GET /api/app/android/config`), jadi
tidak ada `google-services.json` di repo.

## 2. Menyalakan FCM (pemilik)

1. [console.firebase.google.com](https://console.firebase.google.com) → buat proyek (Analytics tidak perlu).
2. **Add app → Android**, package `com.kikiraihan.aitodo`. Catat dari *Project settings → General → Your apps*:
   **App ID** (`1:…:android:…`), **Web API key** (`AIza…`), dan **Project number** (= sender ID).
3. *Project settings → Service accounts → Generate new private key* → berkas JSON (**rahasia**).
4. Di `.env` VPS (tempel sendiri, jangan lewat chat):
   ```
   FCM_CREDENTIALS={"type":"service_account",...}   # satu baris; atau base64 JSON-nya
   FCM_ANDROID_APP_ID=1:1234567890:android:abc123
   FCM_API_KEY=AIza...
   FCM_SENDER_ID=1234567890
   ```
5. `make up`. Log server saat start: `FCM proyek <id>: aktif`. Buka aplikasi Android → Pengaturan → Notifikasi
   harus menulis "Lewat Firebase Cloud Messaging".

## 3. Kunci tanda tangan rilis (pemilik, sekali)

APK rilis harus selalu ditandatangani kunci yang sama, kalau tidak Android menolak pembaruan.

```bash
keytool -genkeypair -v -keystore aitodo.jks -alias aitodo -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 aitodo.jks > aitodo.jks.b64
```

GitHub → repo → Settings → Secrets and variables → Actions:
`ANDROID_KEYSTORE_B64` (isi `aitodo.jks.b64`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`aitodo`),
`ANDROID_KEY_PASSWORD`. Simpan `aitodo.jks` + password di tempat aman (hilang = pengguna harus pasang ulang).

Tanpa secret ini workflow tetap membangun & menguji, tapi rilis tidak berisi `AITodo.apk` (hanya artefak
`AITodo-debug.apk` di halaman run Actions).

## 4. Build & tes lokal

```bash
cd android
echo "sdk.dir=$ANDROID_HOME" > local.properties   # sekali
./gradlew testDebugUnitTest assembleDebug          # APK: app/build/outputs/apk/debug/app-debug.apk
```

Build debug memakai package `com.kikiraihan.aitodo.debug` (bisa terpasang berdampingan dengan versi rilis;
FCM hanya untuk package rilis). Versi = `VERSION` di akar repo; `versionCode` = a·10000 + b·100 + c otomatis.
Server lokal: alamat `http://10.0.2.2:8080` (emulator) diizinkan tanpa HTTPS; selain itu wajib HTTPS.
