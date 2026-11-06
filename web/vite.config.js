import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { VitePWA } from 'vite-plugin-pwa'

// Versi aplikasi (sama dengan VERSION) — ditampilkan di Pengaturan → Pembaruan aplikasi.
const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'))

// Hasil build ditanam ke binary server Go (server/internal/webui/dist).
const outDir = fileURLToPath(new URL('../server/internal/webui/dist', import.meta.url))

// go:embed butuh minimal satu berkas di dist/, dan git menyimpan .gitkeep;
// emptyOutDir menghapusnya, jadi tulis ulang setelah build.
const keepPlaceholder = {
  name: 'keep-gitkeep',
  closeBundle() {
    writeFileSync(`${outDir}/.gitkeep`, '')
  },
}

export default defineConfig({
  plugins: [
    vue(),
    VitePWA({
      // 'prompt': versi baru menunggu sampai aplikasi memasangnya (src/update.js) — otomatis saat
      // aplikasi baru dibuka, atau lewat tombol Perbarui di Pengaturan — supaya isian tidak hilang.
      registerType: 'prompt',
      // Registrasi lewat `virtual:pwa-register` di src/update.js (ikut bundle, bukan skrip inline,
      // jadi tetap lolos CSP) supaya bisa cek pembaruan setiap aplikasi kembali dibuka.
      injectRegister: false,
      includeAssets: ['favicon.svg', 'apple-touch-icon.png'],
      manifest: {
        name: 'AI Todo',
        short_name: 'AI Todo',
        description: 'Todo list & pengingat yang dikelola lewat chat dengan AI.',
        lang: 'id',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        background_color: '#f6f7f9',
        theme_color: '#0f766e',
        icons: [
          { src: '/pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/pwa-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
        shortcuts: [
          { name: 'Chat asisten', url: '/', icons: [{ src: '/pwa-192.png', sizes: '192x192', type: 'image/png' }] },
          { name: 'Todo', url: '/todo', icons: [{ src: '/pwa-192.png', sizes: '192x192', type: 'image/png' }] },
        ],
      },
      workbox: {
        // Handler Web Push & tombol notifikasi ditulis sendiri.
        importScripts: ['push-sw.js'],
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api\//],
        // Data pengguna (API) sengaja TIDAK di-cache service worker: isinya
        // pribadi dan berbeda per akun.
        runtimeCaching: [],
        // Hapus cache precache versi lama setelah versi baru aktif.
        cleanupOutdatedCaches: true,
      },
    }),
    keepPlaceholder,
  ],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
  },
  build: {
    outDir,
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: false },
    },
  },
})
