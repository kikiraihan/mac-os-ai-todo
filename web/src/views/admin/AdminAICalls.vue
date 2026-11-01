<script setup>
// Admin → AI Call Log: setiap request keluar ke provider AI (metadata saja,
// tanpa isi prompt/jawaban pengguna). Pola dari Racik.
import { computed, onMounted, ref } from 'vue'
import { get, post } from '../../api'
import { toast, errorText } from '../../store'
import { friendlyStamp } from '../../dates'
import Icon from '../../components/Icon.vue'

const days = ref(7)
const summary = ref(null)
const list = ref(null) // { items, total, page, size, features, providers, retentionDays }
const loading = ref(false)
const selected = ref(new Set())
const f = ref({ q: '', provider: '', feature: '', status: '', from: '', to: '' })
const page = ref(1)

const pages = computed(() => (list.value ? Math.max(1, Math.ceil(list.value.total / list.value.size)) : 1))
const providerName = (k) => list.value?.providers?.find((p) => p.key === k)?.name || k
const errRate = computed(() => {
  const t = summary.value?.total
  return t && t.calls ? Math.round((t.errors / t.calls) * 100) : 0
})
const allChecked = computed(() => list.value?.items.length > 0 && list.value.items.every((x) => selected.value.has(x.id)))

function query() {
  const p = new URLSearchParams({ page: page.value, size: 50 })
  for (const [k, v] of Object.entries(f.value)) if (v) p.set(k, v)
  return p.toString()
}

async function loadSummary() {
  summary.value = await get(`/admin/ai-calls/summary?days=${days.value}`)
}
async function loadList() {
  loading.value = true
  try {
    list.value = await get(`/admin/ai-calls?${query()}`)
    selected.value = new Set()
  } finally {
    loading.value = false
  }
}
async function refresh() {
  try {
    await Promise.all([loadSummary(), loadList()])
  } catch (e) {
    toast(errorText(e), 'error')
  }
}
function search() {
  page.value = 1
  loadList().catch((e) => toast(errorText(e), 'error'))
}
function reset() {
  f.value = { q: '', provider: '', feature: '', status: '', from: '', to: '' }
  search()
}
function go(p) {
  page.value = p
  loadList().catch((e) => toast(errorText(e), 'error'))
}
function changeDays() {
  loadSummary().catch((e) => toast(errorText(e), 'error'))
}

function toggle(id) {
  const s = new Set(selected.value)
  s.has(id) ? s.delete(id) : s.add(id)
  selected.value = s
}
function toggleAll() {
  selected.value = allChecked.value ? new Set() : new Set(list.value.items.map((x) => x.id))
}
async function remove(all) {
  const msg = all ? 'Kosongkan SEMUA AI call log?' : `Hapus ${selected.value.size} log terpilih?`
  if (!confirm(msg)) return
  try {
    const res = await post('/admin/ai-calls/delete', all ? { all: true } : { ids: [...selected.value] })
    toast(res.message)
    await refresh()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

const fmtMs = (ms) => (ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms)} ms`)
const fmtNum = (n) => (n || 0).toLocaleString('id-ID')

onMounted(refresh)
</script>

<template>
  <div class="page wide">
    <div class="page-head">
      <h1>AI Call Log</h1>
      <div class="row">
        <select v-model.number="days" class="narrow" aria-label="Rentang ringkasan" @change="changeDays">
          <option :value="1">24 jam</option>
          <option :value="7">7 hari</option>
          <option :value="30">30 hari</option>
          <option :value="90">90 hari</option>
        </select>
        <button class="btn" :disabled="loading" @click="refresh"><Icon name="refresh" :size="18" /> Muat ulang</button>
      </div>
    </div>

    <p class="muted small">Setiap request keluar ke provider AI (kenari, Agnes AI, OpenRouter): model, status HTTP, latensi, token, dan pesan
      error. Isi prompt & jawaban <b>tidak</b> disimpan karena berisi data pengguna.
      <template v-if="list">Log disimpan {{ list.retentionDays ? `${list.retentionDays} hari` : 'selamanya' }}
        (<code>AI_CALL_LOG_RETENTION_DAYS</code>).</template></p>

    <template v-if="summary">
      <div class="stats">
        <div class="stat"><span class="muted small">Panggilan</span><b>{{ fmtNum(summary.total.calls) }}</b></div>
        <div class="stat"><span class="muted small">Gagal</span><b :class="{ bad: summary.total.errors }">{{ fmtNum(summary.total.errors) }}
          <span class="small muted">({{ errRate }}%)</span></b></div>
        <div class="stat"><span class="muted small">Rata-rata latensi</span><b>{{ fmtMs(summary.total.avgMs) }}</b></div>
        <div class="stat"><span class="muted small">Token masuk / keluar</span>
          <b>{{ fmtNum(summary.total.promptTokens) }} / {{ fmtNum(summary.total.completionTokens) }}</b></div>
      </div>
      <div v-if="summary.items.length" class="card scroll-x">
        <h3>Per model</h3>
        <table class="table">
          <thead><tr><th>Provider</th><th>Model</th><th>Panggilan</th><th>Gagal</th><th>Rata-rata</th><th>Maks</th><th>Token</th><th>Terakhir</th></tr></thead>
          <tbody>
            <tr v-for="x in summary.items" :key="x.provider + x.model">
              <td>{{ providerName(x.provider) }}</td>
              <td class="mono small">{{ x.model || '—' }}</td>
              <td>{{ fmtNum(x.calls) }}</td>
              <td><span :class="{ bad: x.errors }">{{ fmtNum(x.errors) }}</span></td>
              <td>{{ fmtMs(x.avgMs) }}</td>
              <td>{{ fmtMs(x.maxMs) }}</td>
              <td class="small">{{ fmtNum(x.promptTokens) }} / {{ fmtNum(x.completionTokens) }}</td>
              <td class="small muted nowrap">{{ friendlyStamp(x.lastCall) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>

    <div class="card">
      <form class="filters" @submit.prevent="search">
        <input v-model="f.q" type="search" class="grow" placeholder="Cari model / fitur / error / username…" />
        <select v-model="f.provider" aria-label="Provider">
          <option value="">Semua provider</option>
          <option v-for="p in list?.providers || []" :key="p.key" :value="p.key">{{ p.name }}</option>
        </select>
        <select v-model="f.feature" aria-label="Fitur">
          <option value="">Semua fitur</option>
          <option v-for="x in list?.features || []" :key="x" :value="x">{{ x }}</option>
        </select>
        <select v-model="f.status" aria-label="Status">
          <option value="">Semua status</option>
          <option value="ok">Berhasil</option>
          <option value="error">Gagal</option>
        </select>
        <label class="small muted date">Dari <input v-model="f.from" type="date" /></label>
        <label class="small muted date">Sampai <input v-model="f.to" type="date" /></label>
        <button class="btn primary"><Icon name="search" :size="18" /> Cari</button>
        <button class="btn" type="button" @click="reset">Reset</button>
      </form>
    </div>

    <div class="card scroll-x">
      <div class="row head">
        <span class="small muted grow">{{ list ? `${fmtNum(list.total)} log` : 'Memuat…' }}</span>
        <button class="btn sm" :disabled="!selected.size" @click="remove(false)"><Icon name="trash" :size="16" /> Hapus terpilih</button>
        <button class="btn sm danger-text" :disabled="!list?.total" @click="remove(true)">Kosongkan</button>
      </div>
      <div v-if="list && !list.items.length" class="empty">Belum ada log yang cocok.</div>
      <table v-else-if="list" class="table">
        <thead>
          <tr>
            <th><input type="checkbox" aria-label="Pilih semua" :checked="allChecked" @change="toggleAll" /></th>
            <th>Waktu</th><th>Status</th><th>Provider · model</th><th>Fitur</th><th>Pengguna</th><th>Latensi</th><th>Token</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="x in list.items" :key="x.id" :class="{ failed: !x.ok }">
            <td><input type="checkbox" :aria-label="`Pilih log ${x.id}`" :checked="selected.has(x.id)" @change="toggle(x.id)" /></td>
            <td class="small nowrap">{{ friendlyStamp(x.createdAt) }}</td>
            <td>
              <span class="tag" :class="x.ok ? 'ok' : 'danger'">{{ x.httpStatus || 'gagal' }}</span>
            </td>
            <td>
              {{ providerName(x.provider) }} <span class="small muted">{{ x.operation }}</span>
              <div class="small muted mono">{{ x.model || x.endpoint }}</div>
              <div v-if="x.error" class="small err-msg">{{ x.error }}</div>
            </td>
            <td class="small">{{ x.feature || '—' }}</td>
            <td class="small">{{ x.username || (x.userId ? `#${x.userId}` : '—') }}</td>
            <td class="small nowrap">{{ fmtMs(x.latencyMs) }}</td>
            <td class="small nowrap">{{ x.promptTokens || x.completionTokens ? `${fmtNum(x.promptTokens)} / ${fmtNum(x.completionTokens)}` : '—' }}</td>
          </tr>
        </tbody>
      </table>
      <div v-if="list && pages > 1" class="row pager">
        <button class="btn sm" :disabled="page <= 1" @click="go(page - 1)">‹ Sebelumnya</button>
        <span class="small muted">Halaman {{ page }} / {{ pages }}</span>
        <button class="btn sm" :disabled="page >= pages" @click="go(page + 1)">Berikutnya ›</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.page.wide {
  max-width: 1100px;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  word-break: break-all;
}
.nowrap {
  white-space: nowrap;
}
.narrow {
  width: auto;
}
.filters {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
}
.filters select {
  width: auto;
}
.filters .grow {
  min-width: 220px;
}
.filters .date {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.filters .date input {
  width: auto;
}
.head {
  margin-bottom: 8px;
}
.pager {
  justify-content: center;
  margin-top: 12px;
}
.bad {
  color: var(--danger);
}
.err-msg {
  color: var(--danger);
  max-width: 420px;
  word-break: break-word;
}
.danger-text {
  color: var(--danger);
}
</style>
