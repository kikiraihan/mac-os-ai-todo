<script setup>
// Admin → System Log: baris log server terakhir dari memori (error API,
// kegagalan model AI, penjadwal, push). Pola "Log server" dari Racik.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { get } from '../../api'
import { toast, errorText } from '../../store'
import { friendlyStamp } from '../../dates'
import Icon from '../../components/Icon.vue'

const level = ref('warn') // bawaan: peringatan + error
const source = ref('')
const q = ref('')
const items = ref([])
const stats = ref(null)
const enabled = ref(true)
const lastSeq = ref(0)
const auto = ref(true)
const loading = ref(false)
let timer = null

const levels = [
  { key: 'error', label: 'Error' },
  { key: 'warn', label: 'Peringatan + error' },
  { key: '', label: 'Semua' },
]
const sources = computed(() => Object.keys(stats.value?.sources || {}).sort())

function params(after) {
  const p = new URLSearchParams({ limit: 300 })
  if (level.value) p.set('level', level.value)
  if (source.value) p.set('source', source.value)
  if (q.value.trim()) p.set('q', q.value.trim())
  if (after) p.set('after', after)
  return p.toString()
}

async function load() {
  loading.value = true
  try {
    const res = await get(`/admin/system-logs?${params(0)}`)
    enabled.value = res.enabled
    items.value = res.items
    lastSeq.value = res.lastSeq
    stats.value = res.stats || null
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    loading.value = false
  }
}

// Auto refresh: hanya ambil baris baru (seq > lastSeq) lalu taruh di atas.
async function poll() {
  if (document.hidden || loading.value) return
  try {
    const res = await get(`/admin/system-logs?${params(lastSeq.value)}`)
    if (res.items.length) items.value = [...res.items, ...items.value].slice(0, 1000)
    lastSeq.value = res.lastSeq
    stats.value = res.stats || stats.value
  } catch {
    /* coba lagi di putaran berikutnya */
  }
}

function setAuto(on) {
  clearInterval(timer)
  timer = on ? setInterval(poll, 5000) : null
}

watch([level, source], load)
watch(auto, setAuto)
onMounted(() => {
  load()
  setAuto(auto.value)
})
onBeforeUnmount(() => clearInterval(timer))

const fmtTime = (t) => {
  const s = friendlyStamp(t)
  const sec = String(new Date(t).getSeconds()).padStart(2, '0')
  return `${s}:${sec}`
}
</script>

<template>
  <div class="page wide">
    <div class="page-head">
      <h1>System Log</h1>
      <div class="row">
        <label class="check small"><input v-model="auto" type="checkbox" /> Auto refresh</label>
        <button class="btn" :disabled="loading" @click="load"><Icon name="refresh" :size="18" /> Muat ulang</button>
      </div>
    </div>

    <p class="muted small">Log server terakhir dari memori ({{ stats ? `${stats.stored}/${stats.capacity}` : '…' }} baris; hilang saat server
      restart). Password dan apa pun yang mirip API key disembunyikan sebelum disimpan.
      <template v-if="stats">Server berjalan sejak {{ friendlyStamp(stats.startedAt) }}.</template></p>

    <div v-if="!enabled" class="error">System log tidak aktif di server ini.</div>

    <div v-if="stats" class="stats">
      <div class="stat"><span class="muted small">Error</span><b :class="{ bad: stats.levels.error }">{{ stats.levels.error }}</b></div>
      <div class="stat"><span class="muted small">Peringatan</span><b :class="{ warn: stats.levels.warn }">{{ stats.levels.warn }}</b></div>
      <div class="stat"><span class="muted small">Info</span><b>{{ stats.levels.info }}</b></div>
      <div class="stat"><span class="muted small">Total sejak start</span><b>{{ stats.total }}</b></div>
    </div>

    <div class="card">
      <div class="pills">
        <button v-for="l in levels" :key="l.key" class="pill" :class="{ active: level === l.key }" @click="level = l.key">{{ l.label }}</button>
      </div>
      <form class="row" @submit.prevent="load">
        <input v-model="q" type="search" class="grow" placeholder="Cari teks…" />
        <select v-model="source" class="narrow" aria-label="Sumber">
          <option value="">Semua sumber</option>
          <option v-for="s in sources" :key="s" :value="s">{{ s }}</option>
        </select>
        <button class="btn primary"><Icon name="search" :size="18" /> Cari</button>
      </form>
    </div>

    <div class="card logs">
      <div v-if="!items.length" class="empty">{{ loading ? 'Memuat…' : 'Tidak ada log yang cocok.' }}</div>
      <div v-for="l in items" :key="l.seq" class="line" :class="`lv-${l.level}`">
        <span class="time small muted">{{ fmtTime(l.time) }}</span>
        <span class="tag" :class="{ danger: l.level === 'error', warn: l.level === 'warn' }">{{ l.level }}</span>
        <span class="src small muted">{{ l.source }}</span>
        <span class="msg">{{ l.msg }}</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.page.wide {
  max-width: 1100px;
}
.narrow {
  width: auto;
}
.stat .bad {
  color: var(--danger);
}
.stat .warn {
  color: var(--warn);
}
.logs {
  padding: 0;
  max-height: 65dvh;
  overflow-y: auto;
}
.line {
  display: flex;
  gap: 10px;
  align-items: baseline;
  padding: 6px 12px;
  border-bottom: 1px solid var(--border);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.82rem;
}
.line.lv-error {
  background: var(--danger-soft);
}
.line .time {
  white-space: nowrap;
  flex: none;
}
.line .src {
  flex: none;
  min-width: 70px;
}
.line .msg {
  white-space: pre-wrap;
  word-break: break-word;
  flex: 1;
}
</style>
