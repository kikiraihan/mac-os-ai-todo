<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { get, post, put, del } from '../api'
import { state, toast, errorText, logout, loadMe } from '../store'
import { timeAgo } from '../dates'
import { copyText } from '../copy'
import Icon from '../components/Icon.vue'
import { pushState as readPushState, enablePush as turnOnPush, disablePush as turnOffPush, syncPush } from '../push'
import { appVersion, update, checkUpdate, applyUpdate, forceReload, serverNewer } from '../update'

const router = useRouter()
const displayName = ref(state.me.displayName)
const timezone = ref(state.me.timezone || '')
const prefs = ref({ defaultModelId: 0, ...state.prefs })
const pw = ref({ current: '', new: '' })
const sessions = ref([])
const currentId = ref(0)
const deviceName = ref('MacBook')
const newToken = ref('')
// Integrasi AI lain lewat MCP (server/internal/httpapi/mcp.go).
const mcpURL = `${window.location.origin}/mcp`
const mcpName = ref('Claude Code')
const mcpWrite = ref(true)
const mcpToken = ref('')
const mcpCommand = computed(() => `claude mcp add --transport http aitodo ${mcpURL} --header "Authorization: Bearer ${mcpToken.value}"`)
const pushState = ref('unknown') // unsupported | denied | off | on
const zones = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : ['Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura']
const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent)
const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone

// Pembaruan aplikasi (logika di ../update.js)
const hasUpdate = computed(() => update.available || serverNewer())
const updateText = computed(() => {
  if (update.applying) return 'Memperbarui…'
  if (update.checking) return 'Memeriksa…'
  if (hasUpdate.value) return 'Versi baru tersedia'
  return update.lastCheck ? 'Terbaru' : 'Belum diperiksa'
})

async function checkNow() {
  await checkUpdate()
  if (!hasUpdate.value) toast('Aplikasi sudah versi terbaru')
}

async function loadSessions() {
  const res = await get('/sessions')
  sessions.value = res.sessions
  currentId.value = res.currentId
}

// Logika langganan ada di ../push.js (dipakai juga saat aplikasi dibuka untuk sinkron ulang).
async function detectPush() {
  pushState.value = await readPushState()
}

async function enablePush() {
  try {
    pushState.value = await turnOnPush()
    if (pushState.value === 'on') toast('Notifikasi aktif di perangkat ini')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function disablePush() {
  try {
    await turnOffPush()
    pushState.value = 'off'
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function testPush() {
  try {
    await syncPush() // pastikan server masih punya langganan perangkat ini
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

async function saveDefaultModel() {
  try {
    const res = await put('/me/prefs', { defaultModelId: Number(prefs.value.defaultModelId) || 0 })
    state.prefs = res.prefs
    prefs.value = { defaultModelId: 0, ...res.prefs }
    toast('Model AI bawaan disimpan')
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

async function createMCPToken() {
  try {
    const res = await post('/mcp/tokens', { name: mcpName.value, write: mcpWrite.value })
    mcpToken.value = res.token
    await loadSessions()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function copyPlain(text, what) {
  if (await copyText(text)) toast(`${what} disalin`)
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
  if (s.kind === 'device' || s.kind === 'mcp') return s.name
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
      <button class="btn compact" aria-label="Keluar" @click="doLogout"><Icon name="logout" :size="18" /><span class="btn-label">Keluar</span></button>
    </div>

    <nav class="card more-menu" aria-label="Menu lain">
      <RouterLink to="/kiriman" class="more-link"><Icon name="send" :size="18" /> Kiriman</RouterLink>
      <RouterLink to="/ingatan" class="more-link"><Icon name="brain" :size="18" /> Ingatan AI</RouterLink>
      <!-- Mode admin = akun terpisah; tautan hanya tampil kalau sudah masuk sebagai admin di browser ini. -->
      <RouterLink v-if="state.admin" to="/admin" class="more-link"><Icon name="swap" :size="18" /> Ke mode admin</RouterLink>
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

    <section v-if="state.ai?.models?.length" class="card">
      <h3>Asisten AI</h3>
      <label class="field"><span>Model bawaan</span>
        <select v-model.number="prefs.defaultModelId" @change="saveDefaultModel">
          <option :value="0">Bawaan server{{ state.ai.defaultModelLabel ? ` (${state.ai.defaultModelLabel})` : '' }}</option>
          <option v-for="m in state.ai.models" :key="m.id" :value="m.id">{{ m.label }}</option>
        </select>
      </label>
      <p class="hint">Dipakai otomatis di web dan aplikasi Mac saat mulai chat. Tetap bisa diganti langsung di kotak chat.</p>
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
      <p class="hint">Username: <b>{{ state.me.username }}</b></p>
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
                <span v-if="s.kind === 'device'" class="tag">token</span>
                <span v-if="s.kind === 'mcp'" class="tag" :title="s.clientId ? 'Terhubung lewat OAuth' : 'Token MCP manual'">
                  AI · {{ (s.scope || '').includes('write') ? 'baca & tulis' : 'baca' }}</span></td>
              <td class="small muted">{{ timeAgo(s.lastSeenAt) }}</td>
              <td><button class="btn sm danger" @click="revoke(s)">Keluarkan</button></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h3>Integrasi AI lain (MCP)</h3>
      <p class="muted small">Hubungkan AI Todo ke Claude atau AI lain yang mendukung MCP, misalnya supaya Claude bisa
        menambah todo atau <b>mengingatkanmu</b> (pengingat dikirim server ke HP & Mac seperti biasa). AI lain tidak bisa
        menghapus apa pun, membaca chat, maupun Ingatan AI.</p>
      <div class="token plain">
        <code>{{ mcpURL }}</code>
        <button class="btn sm" @click="copyPlain(mcpURL, 'URL MCP')">Salin URL</button>
      </div>
      <p class="hint"><b>claude.ai / aplikasi Claude:</b> Settings → Connectors → Add custom connector → tempel URL di atas,
        lalu setujui di halaman izin yang muncul. <b>Claude Code / klien lain dengan header:</b> buat token di bawah.</p>
      <form class="row mcp-form" @submit.prevent="createMCPToken">
        <input v-model="mcpName" type="text" maxlength="60" class="grow" aria-label="Nama klien MCP" />
        <label class="check"><input v-model="mcpWrite" type="checkbox" /> Boleh menambah & mengubah</label>
        <button class="btn">Buat token MCP</button>
      </form>
      <div v-if="mcpToken" class="token">
        <code>{{ mcpCommand }}</code>
        <button class="btn sm" @click="copyPlain(mcpCommand, 'Perintah')">Salin perintah</button>
        <button class="btn sm" @click="copyPlain(mcpToken, 'Token')">Salin token</button>
        <button class="btn sm" @click="mcpToken = ''">Sudah kusimpan</button>
      </div>
      <p class="hint">Akses AI yang terhubung tampil di daftar Perangkat di atas (tanda “AI”) — cabut dengan Keluarkan.</p>
    </section>

    <section class="card">
      <h3>Pembaruan aplikasi</h3>
      <p class="muted small">
        Versi {{ appVersion }}<template v-if="serverNewer()"> · server sudah {{ update.serverVersion }}</template>
      </p>
      <div class="row">
        <span class="tag" :class="hasUpdate ? 'accent' : (update.lastCheck ? 'ok' : '')">{{ updateText }}</span>
        <button v-if="hasUpdate" class="btn primary sm" :disabled="update.applying" @click="applyUpdate">Perbarui sekarang</button>
        <button v-else class="btn sm" :disabled="update.checking || update.applying" @click="checkNow">Periksa pembaruan</button>
        <button class="btn sm" :disabled="update.applying" @click="forceReload">Muat ulang paksa</button>
      </div>
      <p class="hint">Pembaruan diperiksa otomatis setiap aplikasi dibuka. Kalau tampilan masih terasa versi lama,
        pakai <b>Muat ulang paksa</b>: cache aplikasi dihapus, login, data, dan notifikasi tetap.</p>
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
.mcp-form {
  flex-wrap: wrap;
}
.mcp-form input[type='text'] {
  flex: 1 1 220px;
}
.token.plain {
  background: var(--surface-2);
}
</style>
