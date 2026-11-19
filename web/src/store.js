import { reactive } from 'vue'
import { get, post, ApiError } from './api'
import { syncPush } from './push'

// Keadaan bersama aplikasi. Perubahan dari perangkat lain (Mac, HP lain)
// datang lewat long-poll /api/changes, lalu daftar dimuat ulang.
export const state = reactive({
  me: null,
  // Akun admin (terpisah dari akun pengguna). null = belum masuk mode admin.
  admin: null,
  prefs: null,
  ai: { enabled: true, defaultModelId: 0, defaultModelLabel: '', models: [] },
  timezone: '',
  todos: [],
  reminders: [],
  rev: 0,
  loaded: false,
  online: true,
  toast: null,
})

const listeners = new Set()
export function onRemoteChange(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

let toastTimer = null
export function toast(message, kind = 'info') {
  state.toast = { message, kind }
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (state.toast = null), 3500)
}

export function errorText(e) {
  return e instanceof ApiError || e instanceof Error ? e.message : String(e)
}

export async function loadMe() {
  try {
    const data = await get('/me')
    state.me = data.user
    state.prefs = data.prefs
    state.ai = data.ai || { enabled: true, defaultModelId: 0, defaultModelLabel: '', models: [] }
    state.timezone = data.timezone
    return true
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) {
      state.me = null
      return false
    }
    throw e
  }
}

// loadAdmin: sesi admin memakai cookie sendiri (Path=/api/admin); 401 = belum masuk.
export async function loadAdmin() {
  try {
    state.admin = (await get('/admin/me')).admin
    return true
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) {
      state.admin = null
      return false
    }
    throw e
  }
}

export async function adminLogout() {
  try {
    await post('/admin/logout')
  } catch {
    /* sesi mungkin sudah habis */
  }
  state.admin = null
}

export async function refreshData() {
  const [t, r] = await Promise.all([get('/todos?status=all'), get('/reminders')])
  state.todos = t.todos
  state.reminders = r.reminders
  state.rev = Math.max(t.rev, r.rev)
  state.loaded = true
}

let syncController = null
export function startSync() {
  stopSync()
  // Sesi aktif: tautkan lagi langganan notifikasi perangkat ini ke server (lihat push.js).
  syncPush().catch(() => {})
  const ctl = new AbortController()
  syncController = ctl
  ;(async () => {
    let delay = 1000
    while (!ctl.signal.aborted) {
      try {
        const res = await get(`/changes?since=${state.rev}&wait=1`, { signal: ctl.signal })
        state.online = true
        delay = 1000
        if (res.rev !== state.rev) {
          await Promise.all([refreshData(), loadMe().catch(() => {})])
          state.rev = res.rev
          listeners.forEach((fn) => fn())
        }
      } catch (e) {
        if (ctl.signal.aborted) return
        if (e instanceof ApiError && e.status === 401) return
        state.online = false
        await new Promise((r) => setTimeout(r, delay))
        delay = Math.min(delay * 2, 30000)
      }
    }
  })()
}

export function stopSync() {
  if (syncController) syncController.abort()
  syncController = null
}

export async function logout() {
  stopSync()
  try {
    await post('/logout')
  } catch {
    /* sesi mungkin sudah habis */
  }
  state.me = null
  state.todos = []
  state.reminders = []
  state.loaded = false
}

// Saat tab kembali aktif, sinkronkan segera (long-poll bisa tertahan saat HP tidur).
if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.me) {
      refreshData().catch(() => {})
      startSync()
    }
  })
}
