// Pembaruan PWA (service worker).
//
// Kenapa sebelumnya "telat": service worker menyajikan index.html & aset dari cache supaya cepat
// dan bisa offline. Versi baru baru diunduh SETELAH halaman lama tampil, dan di HP (terutama iPhone)
// aplikasi yang dibuka lagi dari latar belakang tidak memeriksa pembaruan sama sekali — jadi perubahan
// baru terlihat setelah aplikasi ditutup-buka satu-dua kali.
//
// Sekarang:
// - Pembaruan dicek saat aplikasi dibuka, setiap kembali dari latar belakang, dan tiap jam.
// - Versi baru yang ditemukan sesaat setelah aplikasi dibuka langsung dipasang (muat ulang otomatis),
//   kecuali sedang mengetik. Selain itu: pesan singkat + tombol "Perbarui sekarang" di Pengaturan.
// - Versi server (/api/health) dibandingkan dengan versi aplikasi ini, jadi Pengaturan tahu kalau
//   tampilan masih versi lama walau service worker belum menemukan pembaruannya.
import { reactive } from 'vue'
import { registerSW } from 'virtual:pwa-register'
import { get } from './api'
import { toast } from './store'

/* global __APP_VERSION__ */
export const appVersion = __APP_VERSION__

export const update = reactive({
  supported: 'serviceWorker' in navigator,
  checking: false,
  applying: false,
  // Service worker versi baru sudah terunduh & menunggu dipasang.
  available: false,
  serverVersion: '',
  lastCheck: null,
})

// Pembaruan yang ditemukan dalam jendela ini setelah aplikasi dibuka / kembali dibuka langsung dipasang.
const FRESH_MS = 15000
const HOURLY = 60 * 60 * 1000
let openedAt = Date.now()
let registration = null
let applySW = null
let started = false

/** Versi a.b.c → angka yang bisa dibandingkan. */
function cmp(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0)
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0)
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0)
  return 0
}

/** Server sudah lebih baru daripada tampilan yang sedang berjalan. */
export function serverNewer() {
  return !!update.serverVersion && cmp(update.serverVersion, appVersion) > 0
}

// Sedang mengetik (mis. pesan chat)? Jangan muat ulang otomatis supaya isian tidak hilang.
function typing() {
  const el = document.activeElement
  return !!el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') && !!el.value
}

export function initUpdates() {
  if (started) return
  started = true
  if (update.supported) {
    applySW = registerSW({
      immediate: true,
      onNeedRefresh() {
        update.available = true
        if (Date.now() - openedAt < FRESH_MS && !typing()) applyUpdate()
        else toast('Versi baru tersedia — Pengaturan → Perbarui sekarang')
      },
      onRegisteredSW(_url, reg) {
        registration = reg || null
        setInterval(() => checkUpdate(), HOURLY)
      },
    })
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return
    openedAt = Date.now()
    checkUpdate()
  })
  checkUpdate()
}

/** Cek versi server & minta service worker memeriksa sw.js baru. */
export async function checkUpdate() {
  if (update.checking) return
  update.checking = true
  try {
    try {
      const h = await get('/health')
      update.serverVersion = h.version || ''
    } catch {
      // offline: cukup lewati
    }
    try {
      await registration?.update()
    } catch {
      // gagal mengunduh sw.js (offline) — coba lagi nanti
    }
    if (registration?.waiting) update.available = true
    update.lastCheck = new Date()
  } finally {
    update.checking = false
  }
}

/** Pasang versi baru: aktifkan service worker yang menunggu lalu muat ulang. */
export async function applyUpdate() {
  if (update.applying) return
  update.applying = true
  if (applySW && registration?.waiting) {
    await applySW(true) // kirim SKIP_WAITING; halaman dimuat ulang saat versi baru mengambil alih
    // Jaga-jaga kalau event 'controlling' tidak datang (beberapa versi Safari).
    setTimeout(() => location.reload(), 3000)
    return
  }
  await forceReload()
}

/**
 * Muat ulang paksa: hapus cache aplikasi (bukan data, login, atau langganan notifikasi) lalu muat ulang,
 * sehingga semua berkas diambil lagi dari server. Service worker tidak di-unregister supaya
 * notifikasi push tetap aktif.
 */
export async function forceReload() {
  update.applying = true
  try {
    if ('caches' in window) {
      const keys = await caches.keys()
      await Promise.all(keys.map((k) => caches.delete(k)))
    }
    await registration?.update()
    registration?.waiting?.postMessage({ type: 'SKIP_WAITING' })
  } catch {
    // tetap muat ulang
  }
  location.reload()
}
