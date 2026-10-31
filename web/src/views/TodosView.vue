<script setup>
import { computed, ref } from 'vue'
import { post, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { today, addDays, friendlyDate } from '../dates'
import TodoForm from '../components/TodoForm.vue'
import Icon from '../components/Icon.vue'

const tab = ref('today')
const listFilter = ref('')
const search = ref('')
const quick = ref('')
const quickDate = ref('')
const editing = ref(null)
const creating = ref(false)
const busyId = ref(0)

const t0 = computed(() => today())
const lists = computed(() => [...new Set(state.todos.map((x) => x.list).filter(Boolean))].sort())

const base = computed(() =>
  state.todos.filter((x) => {
    if (x.status === 'archived') return false
    if (listFilter.value && x.list !== listFilter.value) return false
    if (search.value) {
      const q = search.value.toLowerCase()
      if (!x.title.toLowerCase().includes(q) && !x.notes.toLowerCase().includes(q)) return false
    }
    return true
  }),
)
const groups = computed(() => {
  const open = base.value.filter((x) => x.status === 'open')
  return {
    today: open.filter((x) => x.dueDate && x.dueDate <= t0.value),
    upcoming: open.filter((x) => x.dueDate && x.dueDate > t0.value),
    nodate: open.filter((x) => !x.dueDate),
    done: base.value.filter((x) => x.status === 'done'),
    all: open,
  }
})
const tabs = [
  { key: 'today', label: 'Hari ini' },
  { key: 'upcoming', label: 'Akan datang' },
  { key: 'nodate', label: 'Tanpa tenggat' },
  { key: 'all', label: 'Semua aktif' },
  { key: 'done', label: 'Selesai' },
]
const shown = computed(() => groups.value[tab.value])

function dueLabel(x) {
  if (!x.dueDate) return ''
  return friendlyDate(x.dueDate) + (x.dueTime ? ` ${x.dueTime}` : '')
}
const isLate = (x) => x.status === 'open' && x.dueDate && (x.dueDate < t0.value)
const reminderCount = (x) => state.reminders.filter((r) => r.todoId === x.id && r.active).length

async function addQuick() {
  const title = quick.value.trim()
  if (!title) return
  try {
    await post('/todos', { title, dueDate: quickDate.value })
    quick.value = ''
    await refreshData()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function toggle(x) {
  busyId.value = x.id
  try {
    await post(`/todos/${x.id}/${x.status === 'done' ? 'reopen' : 'complete'}`)
    await refreshData()
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    busyId.value = 0
  }
}

async function remove(x) {
  const n = reminderCount(x)
  if (!confirm(`Hapus “${x.title}”?${n ? ` ${n} pengingatnya ikut terhapus.` : ''}`)) return
  try {
    await del(`/todos/${x.id}`)
    await refreshData()
    toast('Todo dihapus')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function archiveDone() {
  if (!confirm(`Arsipkan ${groups.value.done.length} todo yang sudah selesai?`)) return
  try {
    const res = await post('/todos/archive-done')
    await refreshData()
    toast(`${res.archived} todo diarsipkan`)
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

const quickDates = computed(() => [
  { v: '', label: 'Tanpa tanggal' },
  { v: t0.value, label: 'Hari ini' },
  { v: addDays(t0.value, 1), label: 'Besok' },
])
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Todo</h1>
      <button class="btn primary" @click="creating = true"><Icon name="plus" :size="18" /> Todo baru</button>
    </div>

    <form class="card quick" @submit.prevent="addQuick">
      <input v-model="quick" type="text" maxlength="200" placeholder="Tambah cepat… (Enter)" aria-label="Judul todo baru" />
      <select v-model="quickDate" aria-label="Tanggal">
        <option v-for="d in quickDates" :key="d.label" :value="d.v">{{ d.label }}</option>
      </select>
      <button class="btn" :disabled="!quick.trim()">Tambah</button>
    </form>

    <div class="pills">
      <button v-for="tb in tabs" :key="tb.key" class="pill" :class="{ active: tab === tb.key }" @click="tab = tb.key">
        {{ tb.label }}<span class="n">{{ groups[tb.key].length }}</span>
      </button>
    </div>

    <div class="row filters">
      <input v-model="search" type="search" class="grow" placeholder="Cari…" aria-label="Cari todo" />
      <select v-if="lists.length" v-model="listFilter" aria-label="Filter daftar">
        <option value="">Semua daftar</option>
        <option v-for="l in lists" :key="l" :value="l">{{ l }}</option>
      </select>
      <button v-if="tab === 'done' && groups.done.length" class="btn sm" @click="archiveDone">Arsipkan semua</button>
    </div>

    <div class="card list">
      <div v-if="!state.loaded" class="empty">Memuat…</div>
      <div v-else-if="!shown.length" class="empty">
        {{ tab === 'today' ? 'Tidak ada todo untuk hari ini 🎉' : 'Kosong.' }}
      </div>
      <div v-for="x in shown" :key="x.id" class="todo" :class="{ done: x.status === 'done' }">
        <input type="checkbox" class="tick" :checked="x.status === 'done'" :disabled="busyId === x.id"
          :aria-label="`Tandai ${x.title}`" @change="toggle(x)" />
        <div class="grow body" @click="editing = x">
          <div class="title">
            <span v-if="x.priority === 'high'" class="prio" title="Prioritas tinggi">!</span>{{ x.title }}
          </div>
          <div class="meta">
            <span v-if="x.dueDate" class="tag" :class="{ danger: isLate(x), accent: !isLate(x) }">{{ dueLabel(x) }}</span>
            <span v-if="x.list" class="tag">{{ x.list }}</span>
            <span v-if="reminderCount(x)" class="tag">🔔 {{ reminderCount(x) }}</span>
            <span v-if="x.source === 'chat'" class="tag" title="Dibuat lewat chat">AI</span>
            <span class="muted small id">#{{ x.id }}</span>
          </div>
          <div v-if="x.notes" class="notes muted small">{{ x.notes }}</div>
        </div>
        <button class="icon-btn" :aria-label="`Ubah ${x.title}`" @click="editing = x"><Icon name="edit" :size="18" /></button>
        <button class="icon-btn" :aria-label="`Hapus ${x.title}`" @click="remove(x)"><Icon name="trash" :size="18" /></button>
      </div>
    </div>

    <TodoForm v-if="creating" :preset-date="tab === 'today' ? t0 : ''" @close="creating = false" />
    <TodoForm v-if="editing" :todo="editing" @close="editing = null" />
  </div>
</template>

<style scoped>
.quick {
  display: flex;
  gap: 8px;
  padding: 10px;
}
.quick select {
  width: auto;
}
@media (max-width: 760px) {
  .quick {
    flex-wrap: wrap;
  }
  .quick input {
    flex: 1 1 100%;
  }
  .quick select {
    flex: 1;
  }
}
.filters {
  margin-bottom: 12px;
}
.filters select {
  width: auto;
}
.list {
  padding: 4px 8px;
}
.todo {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 10px 4px;
  border-bottom: 1px solid var(--border);
}
.todo:last-child {
  border-bottom: none;
}
.tick {
  width: 20px;
  height: 20px;
  margin-top: 2px;
  accent-color: var(--accent);
  cursor: pointer;
}
.body {
  cursor: pointer;
}
.title {
  font-weight: 500;
  word-break: break-word;
}
.done .title {
  text-decoration: line-through;
  color: var(--muted);
}
.prio {
  color: var(--danger);
  font-weight: 800;
  margin-right: 6px;
}
.meta {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-top: 4px;
  align-items: center;
}
.id {
  margin-left: auto;
}
.notes {
  margin-top: 4px;
  white-space: pre-wrap;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>
