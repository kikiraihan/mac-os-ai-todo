// Aplikasi Android: info rilis APK (lewat server, wajib login) & tawaran pasang.
// APK diunduh lewat /unduh/AITodo.apk (navigasi biasa + cookie login; lihat server/internal/httpapi/release.go).
import { reactive } from 'vue'
import { get } from './api'

export const apkUrl = '/unduh/AITodo.apk'
export const isAndroid = /android/i.test(navigator.userAgent)

const DISMISS_KEY = 'aitodo.apkBannerHidden'
const readDismissed = () => {
  try {
    return localStorage.getItem(DISMISS_KEY) === '1'
  } catch {
    return false
  }
}

// status: unknown | loading | ready (apk ada) | none (rilis tanpa APK / fitur rilis belum diatur)
export const apk = reactive({ status: 'unknown', version: '', dismissed: readDismissed() })

export async function loadApk() {
  if (apk.status !== 'unknown') return
  apk.status = 'loading'
  try {
    const r = await get('/app/android/latest')
    apk.version = (r.version || '').replace(/^v/, '')
    apk.status = r.apk ? 'ready' : 'none'
  } catch {
    apk.status = 'none'
  }
}

export function dismissApkBanner() {
  apk.dismissed = true
  try {
    localStorage.setItem(DISMISS_KEY, '1')
  } catch {
    /* penyimpanan diblokir: spanduk muncul lagi lain kali, tidak apa-apa */
  }
}
