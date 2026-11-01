<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { get, post, put, del } from '../api'
import { onRemoteChange, toast, errorText } from '../store'
import { timeAgo } from '../dates'
import Icon from '../components/Icon.vue'

const data = ref(null)
const drafts = ref({ profile: '', notes: '' })
const editId = ref(0)
const editText = ref('')

const sections = [
  { key: 'profile', title: 'Profil saya', desc: 'Siapa kamu: kebiasaan, preferensi, gaya komunikasi. Contoh: “Biasanya belanja Sabtu pagi”.' },
  { key: 'notes', title: 'Catatan asisten', desc: 'Konteks & kesepakatan yang perlu diingat. Contoh: “List Kantor = pekerjaan kantor”.' },
]

async function load() {
  data.value = await get('/memory')
}
const items = (k) => computed(() => (data.value?.memories || []).filter((m) => m.target === k)).value
const pct = (k) => (data.value ? Math.round((data.value.usage[k] * 100) / data.value.limits[k]) : 0)

async function add(k) {
  try {
    await post('/memory', { target: k, content: drafts.value[k] })
    drafts.value[k] = ''
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}
function startEdit(m) {
  editId.value = m.id
  editText.value = m.content
}
async function saveEdit() {
  try {
    await put(`/memory/${editId.value}`, { content: editText.value })
    editId.value = 0
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}
async function remove(m) {
  if (!confirm(`Lupakan “${m.content}”?`)) return
  try {
    await del(`/memory/${m.id}`)
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function exportMd() {
  try {
    const res = await fetch('/api/memory/export', { headers: { 'X-AITodo': '1' }, credentials: 'same-origin' })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const blob = await res.blob()
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `ingatan-ai-${new Date().toISOString().slice(0, 10)}.md`
    a.click()
    URL.revokeObjectURL(a.href)
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

let off
onMounted(() => {
  load().catch((e) => toast(errorText(e), 'error'))
  off = onRemoteChange(() => load().catch(() => {}))
})
onBeforeUnmount(() => off && off())
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Ingatan AI</h1>
      <button class="btn" @click="exportMd"><Icon name="download" :size="18" /> Ekspor .md</button>
    </div>
    <p class="muted small">
      Hal yang diingat asisten tentangmu di setiap percakapan, supaya tidak lupa kebiasaan dan konteksmu. Asisten bisa
      menambahkannya sendiri saat kamu bercerita; di sini kamu bisa memeriksa, mengubah, atau menghapusnya. Hanya kamu yang
      bisa melihat halaman ini. Password, PIN, nomor kartu, dan token otomatis ditolak.
    </p>
    <div v-if="!data" class="empty">Memuat…</div>
    <div v-for="s in sections" v-else :key="s.key" class="card">
      <div class="row head">
        <h3 class="grow">{{ s.title }}</h3>
        <span class="small muted">{{ data.usage[s.key] }}/{{ data.limits[s.key] }} karakter</span>
      </div>
      <div class="meter"><i :class="{ warn: pct(s.key) >= 80 }" :style="{ width: Math.min(100, pct(s.key)) + '%' }"></i></div>
      <p class="hint">{{ s.desc }}</p>
      <div v-if="!items(s.key).length" class="muted small empty-mem">Belum ada.</div>
      <div v-for="m in items(s.key)" :key="m.id" class="mem">
        <template v-if="editId === m.id">
          <input v-model="editText" type="text" :maxlength="data.maxEntry" class="grow" @keydown.enter.prevent="saveEdit" />
          <button class="btn sm primary" @click="saveEdit">Simpan</button>
          <button class="btn sm" @click="editId = 0">Batal</button>
        </template>
        <template v-else>
          <div class="grow">
            {{ m.content }}
            <div class="small muted">{{ m.source === 'chat' ? 'dari chat' : 'manual' }} · {{ timeAgo(m.updatedAt) }}</div>
          </div>
          <button class="icon-btn" aria-label="Ubah" @click="startEdit(m)"><Icon name="edit" :size="18" /></button>
          <button class="icon-btn" aria-label="Hapus" @click="remove(m)"><Icon name="trash" :size="18" /></button>
        </template>
      </div>
      <form class="row add" @submit.prevent="add(s.key)">
        <input v-model="drafts[s.key]" type="text" :maxlength="data.maxEntry" class="grow" placeholder="Tambah satu fakta…" />
        <button class="btn" :disabled="!drafts[s.key].trim()">Tambah</button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.head {
  margin-bottom: 6px;
}
.head h3 {
  margin: 0;
}
.mem {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 0;
  border-top: 1px solid var(--border);
}
.add {
  margin-top: 10px;
}
.empty-mem {
  padding: 8px 0;
}
</style>
