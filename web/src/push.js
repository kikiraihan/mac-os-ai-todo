// Web Push di perangkat ini: nyalakan, matikan, dan sinkronkan langganan dengan server.
// Handler notifikasi ada di public/push-sw.js (diimpor service worker Workbox).
import { get, post } from './api'

export function pushSupported() {
  return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
}

function b64ToBytes(b64) {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4)
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

function sameKey(a, b) {
  if (!a || !b) return false
  const x = new Uint8Array(a)
  return x.length === b.length && x.every((v, i) => v === b[i])
}

async function currentSub() {
  const reg = await navigator.serviceWorker.getRegistration()
  return reg ? reg.pushManager.getSubscription() : null
}

/** unsupported | denied | off | on — dilihat dari browser ini. */
export async function pushState() {
  if (!pushSupported()) return 'unsupported'
  if (Notification.permission === 'denied') return 'denied'
  if (Notification.permission !== 'granted') return 'off'
  return (await currentSub()) ? 'on' : 'off'
}

// Langganan dengan kunci VAPID server saat ini. Langganan lama dengan kunci lain (mis. database
// server dibuat ulang) tidak bisa dipakai lagi, jadi diganti.
async function subscribe() {
  const { publicKey } = await get('/push/key')
  const key = b64ToBytes(publicKey)
  const reg = await navigator.serviceWorker.ready
  let sub = await reg.pushManager.getSubscription()
  if (sub && !sameKey(sub.options && sub.options.applicationServerKey, key)) {
    await sub.unsubscribe().catch(() => {})
    sub = null
  }
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key })
  await post('/push/subscribe', sub.toJSON())
}

export async function enablePush() {
  const perm = await Notification.requestPermission()
  if (perm !== 'granted') return perm === 'denied' ? 'denied' : 'off'
  await subscribe()
  return 'on'
}

export async function disablePush() {
  const sub = await currentSub()
  if (sub) {
    await post('/push/unsubscribe', { endpoint: sub.endpoint })
    await sub.unsubscribe()
  }
}

/**
 * Dipanggil setiap kali sesi aktif (buka aplikasi / masuk). Langganan di server ikut terhapus saat sesi
 * keluar/kedaluwarsa, atau dibuang server kalau layanan push bilang sudah tidak berlaku; tanpa ini browser
 * masih menganggap notifikasi "Aktif" padahal server tidak mengirim apa-apa lagi.
 */
export async function syncPush() {
  if (!pushSupported() || Notification.permission !== 'granted') return
  if (!(await currentSub())) return
  await subscribe()
}
