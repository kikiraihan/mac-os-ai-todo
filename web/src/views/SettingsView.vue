<script setup>
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { get, post, put, del } from '../api'
import { state, toast, errorText, logout, loadMe } from '../store'
import { timeAgo } from '../dates'
import Icon from '../components/Icon.vue'

const router = useRouter()
const displayName = ref(state.me.displayName)
const timezone = ref(state.me.timezone || '')
const prefs = ref({ ...state.prefs })
const pw = ref({ current: '', new: '' })
const sessions = ref([])
const currentId = ref(0)
const deviceName = ref('MacBook')
const newToken = ref('')
const pushState = ref('unknown') // unsupported | denied | off | on
const zones = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : ['Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura']
const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent)
const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone

async function loadSessions() {
  const res = await get('/sessions')
  sessions.value = res.sessions
  currentId.value = res.currentId
}

async function detectPush() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
    pushState.value = 'unsupported'
    return
  }
  if (Notification.permission === 'denied') {
    pushState.value = 'denied'
    return
  }
  const reg = await navigator.serviceWorker.getRegistration()
  const sub = reg && (await reg.pushManager.getSubscription())
  pushState.value = sub ? 'on' : 'off'
}

function b64ToBytes(b64) {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4)
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

async function enablePush() {
  try {
    const perm = await Notification.requestPermission()
    if (perm !== 'granted') {
      pushState.value = perm === 'denied' ? 'denied' : 'off'
      return
    }
    const { publicKey } = await get('/push/key')
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(publicKey) })
    await post('/push/subscribe', sub.toJSON())
    pushState.value = 'on'
    toast('Notifikasi aktif di perangkat ini')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function disablePush() {
  try {
    const reg = await navigator.serviceWorker.getRegistration()
    const sub = reg && (await reg.pushManager.getSubscription())
    if (sub) {
      await post('/push/unsubscribe', { endpoint: sub.endpoint })
      await sub.unsubscribe()
    }
    pushState.value = 'off'
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function testPush() {
  try {
    const res = await post('/push/test')
    toast(`Terkirim ke ${res.sent} perangkat`)
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function saveProfile() {
  try {
    await put('/me', { displayName: displayName.value, timezone: timezone.value })
    await loadMe()
    toast('Profil disimpan')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function savePrefs() {
  try {
    const res = await put('/me/prefs', prefs.value)
    state.prefs = res.prefs
    toast('Pengaturan notifikasi disimpan')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function changePassword() {
  try {
    await put('/me/password', pw.value)
    pw.value = { current: '', new: '' }
    await loadSessions()
    toast('Password diganti. Perangkat lain sudah dikeluarkan.')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function createDevice() {
  try {
    const res = await post('/devices', { name: deviceName.value })
    newToken.value = res.token
    await loadSessions()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function copyToken() {
  try {
    await navigator.clipboard.writeText(newToken.value)
    toast('Token disalin')
  } catch {
    toast('Salin manual dari kotak di atas', 'error')
  }
}

async function revoke(s) {
  if (!confirm(`Keluarkan “${s.name}”? Perangkat itu harus masuk lagi.`)) return
  try {
    await del(`/sessions/${s.id}`)
    if (s.id === currentId.value) {
      await logout()
      router.replace('/masuk')
      return
    }
    await loadSessions()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function doLogout() {
  await disablePush().catch(() => {})
  await logout()
  router.replace('/masuk')
}

function deviceLabel(s) {
  if (s.kind === 'device') return s.name
  const ua = s.userAgent || ''
  if (/iphone|ipad/i.test(ua)) return 'iPhone/iPad'
  if (/android/i.test(ua)) return 'Android'
  if (/mac os/i.test(ua)) return 'Mac (browser)'
  if (/windows/i.test(ua)) return 'Windows'
  return 'Browser'
}

onMounted(() => {
  loadSessions().catch((e) => toast(errorText(e), 'error'))
  detectPush().catch(() => (pushState.value = 'unsupported'))
})
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Pengaturan</h1>
      <button class="btn" @click="doLogout"><Icon name="logout" :size="18" /> Keluar</button>
    </div>

    <nav class="card more-menu" aria-label="Menu lain">
      <RouterLink to="/ingatan" class="more-link"><Icon name="brain" :size="18" /> Ingatan AI</RouterLink>
      <template v-if="state.me.role === 'admin'">
        <RouterLink to="/admin" class="more-link"><Icon name="chart" :size="18" /> Admin · Ringkasan</RouterLink>
        <RouterLink to="/admin/pengguna" class="more-link"><Icon name="users" :size="18" /> Admin · Pengguna</RouterLink>
        <RouterLink to="/admin/model" class="more-link"><Icon name="cpu" :size="18" /> Admin · Model AI</RouterLink>
        <RouterLink to="/admin/asisten" class="more-link"><Icon name="spark" :size="18" /> Admin · Asisten</RouterLink>
      </template>
    </nav>

    <section class="card">
      <h3>Notifikasi di perangkat ini</h3>
      <p v-if="pushState === 'unsupported'" class="muted small">
        Browser ini belum mendukung notifikasi push.
        <template v-if="isIOS && !standalone"> Di iPhone/iPad: ketuk Bagikan → <b>Tambahkan ke Layar Utama</b>, lalu buka AI Todo dari ikonnya.</template>
      </p>
      <p v-else-if="pushState === 'denied'" class="muted small">Notifikasi diblokir. Izinkan lewat pengaturan situs di browser, lalu muat ulang.</p>
      <div v-else class="row">
        <span class="tag" :class="pushState === 'on' ? 'ok' : ''">{{ pushState === 'on' ? 'Aktif' : 'Mati' }}</span>
        <button v-if="pushState !== 'on'" class="btn primary sm" @click="enablePush">Nyalakan notifikasi</button>
        <template v-else>
          <button class="btn sm" @click="testPush">Kirim tes</button>
          <button class="btn sm" @click="disablePush">Matikan</button>
        </template>
      </div>
      <hr />
      <div class="row">
        <label class="field grow"><span>Ringkasan pagi</span><input v-model="prefs.briefTime" type="time" /></label>
        <label class="field grow"><span>Pengingat yang terlambat</span><input v-model="prefs.nudgeTime" type="time" /></label>
      </div>
      <p class="hint">Kosongkan jam untuk mematikannya.</p>
      <label class="check"><input v-model="prefs.dueNotify" type="checkbox" /> Beri tahu 10 menit sebelum tenggat todo berjam</label><br />
      <label class="check"><input v-model="prefs.hideContent" type="checkbox" /> Sembunyikan isi notifikasi di layar kunci</label>
      <div class="actions"><button class="btn primary sm" @click="savePrefs">Simpan</button></div>
    </section>

    <section class="card">
      <h3>Profil</h3>
      <div class="row">
        <label class="field grow"><span>Nama panggilan</span><input v-model="displayName" type="text" maxlength="60" /></label>
        <label class="field grow"><span>Zona waktu</span>
          <select v-model="timezone">
            <option value="">Bawaan server ({{ state.timezone }})</option>
            <option v-for="z in zones" :key="z" :value="z">{{ z }}</option>
          </select>
        </label>
      </div>
      <p class="hint">Username: <b>{{ state.me.username }}</b> · peran: {{ state.me.role }}</p>
      <div class="actions"><button class="btn primary sm" @click="saveProfile">Simpan profil</button></div>
    </section>

    <section class="card">
      <h3>Ganti password</h3>
      <form @submit.prevent="changePassword">
        <div class="row">
          <label class="field grow"><span>Password lama</span><input v-model="pw.current" type="password" autocomplete="current-password" required /></label>
          <label class="field grow"><span>Password baru (min. 10)</span><input v-model="pw.new" type="password" minlength="10" autocomplete="new-password" required /></label>
        </div>
        <div class="actions"><button class="btn primary sm">Ganti password</button></div>
      </form>
    </section>

    <section class="card">
      <h3>Perangkat & aplikasi Mac</h3>
      <p class="muted small">Untuk aplikasi menu bar Mac: buat token di sini, lalu tempel di aplikasinya (klik ikon → Hubungkan ke server…).
        Token hanya ditampilkan sekali; server hanya menyimpan hash-nya.</p>
      <form class="row" @submit.prevent="createDevice">
        <input v-model="deviceName" type="text" maxlength="60" class="grow" aria-label="Nama perangkat" />
        <button class="btn">Buat token perangkat</button>
      </form>
      <div v-if="newToken" class="token">
        <code>{{ newToken }}</code>
        <button class="btn sm" @click="copyToken">Salin</button>
        <button class="btn sm" @click="newToken = ''">Sudah kusimpan</button>
      </div>
      <div class="scroll-x">
        <table class="table sessions">
          <thead><tr><th>Perangkat</th><th>Terakhir aktif</th><th></th></tr></thead>
          <tbody>
            <tr v-for="s in sessions" :key="s.id">
              <td>{{ deviceLabel(s) }} <span v-if="s.id === currentId" class="tag accent">ini</span>
                <span v-if="s.kind === 'device'" class="tag">token</span></td>
              <td class="small muted">{{ timeAgo(s.lastSeenAt) }}</td>
              <td><button class="btn sm danger" @click="revoke(s)">Keluarkan</button></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

<style scoped>
.more-menu {
  display: none;
  padding: 6px;
}
.more-link {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px;
  color: var(--text);
  text-decoration: none;
  border-radius: 8px;
}
.more-link + .more-link {
  border-top: 1px solid var(--border);
}
@media (max-width: 760px) {
  .more-menu {
    display: block;
  }
}
hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 14px 0;
}
.actions {
  margin-top: 10px;
}
.token {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
  background: var(--warn-soft);
  padding: 10px;
  border-radius: 8px;
  margin: 10px 0;
}
.token code {
  word-break: break-all;
  flex: 1;
  min-width: 200px;
  font-size: 0.85rem;
}
.sessions {
  margin-top: 12px;
}
</style>
