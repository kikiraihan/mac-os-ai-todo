import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { VitePWA } from 'vite-plugin-pwa'

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
      registerType: 'autoUpdate',
      // Skrip registrasi sebagai berkas terpisah (bukan inline) supaya lolos CSP.
      injectRegister: 'script',
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
      },
    }),
    keepPlaceholder,
  ],
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
