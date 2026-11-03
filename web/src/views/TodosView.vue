<script setup>
import { computed, nextTick, ref } from 'vue'
import { post, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { today, addDays, friendlyDate } from '../dates'
import TodoForm from '../components/TodoForm.vue'
import Icon from '../components/Icon.vue'
import SwipeRow from '../components/SwipeRow.vue'
import { touch, showSwipeHint, swipeUsed } from '../swipe'

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

// Aksi geser (layar sentuh): kanan = selesai / buka lagi, kiri = ubah · hapus.
const leadingFor = (x) =>
  x.status === 'done'
    ? { label: 'Buka lagi', icon: 'undo', tone: 'accent', run: () => toggle(x) }
    : { label: 'Selesai', icon: 'check', tone: 'ok', run: () => toggle(x) }
const trailingFor = (x) => [
  { label: 'Ubah', icon: 'edit', tone: 'accent', run: () => (editing.value = x) },
  { label: 'Hapus', icon: 'trash', tone: 'danger', run: () => remove(x) },
]

// Carousel filter: tab aktif selalu digeser ke tengah; ←/→ pindah tab (pola tablist).
const strip = ref(null)
function selectTab(key) {
  tab.value = key
  nextTick(() => strip.value?.querySelector('[aria-selected="true"]')?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' }))
}
function tabKey(e) {
  const i = tabs.findIndex((x) => x.key === tab.value)
  const n = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : -1
  if (n < 0 || n >= tabs.length) return
  e.preventDefault()
  selectTab(tabs[n].key)
  nextTick(() => strip.value?.querySelector('[aria-selected="true"]')?.focus())
}
const emptyText = computed(
  () =>
    ({
      today: 'Tidak ada todo untuk hari ini 🎉',
      upcoming: 'Tidak ada todo terjadwal.',
      nodate: 'Semua todo punya tenggat.',
      all: 'Semua todo sudah selesai 🎉',
      done: 'Belum ada todo yang selesai.',
    })[tab.value],
)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Todo</h1>
      <button class="btn primary compact" aria-label="Todo baru" @click="creating = true">
        <Icon name="plus" :size="18" /><span class="btn-label">Todo baru</span>
      </button>
    </div>

    <form class="card quick" @submit.prevent="addQuick">
      <div class="quick-input">
        <input v-model="quick" type="text" maxlength="200" placeholder="Tambah cepat…" aria-label="Judul todo baru" enterkeyhint="done" />
        <button class="send" :disabled="!quick.trim()" aria-label="Tambah"><Icon name="up" :size="18" /></button>
      </div>
      <div class="seg" role="radiogroup" aria-label="Tenggat">
        <button v-for="d in quickDates" :key="d.label" type="button" role="radio" :aria-checked="quickDate === d.v"
          :class="{ on: quickDate === d.v }" @click="quickDate = d.v">{{ d.label }}</button>
      </div>
    </form>

    <div ref="strip" class="carousel tabs" role="tablist" aria-label="Filter todo" @keydown="tabKey">
      <button v-for="tb in tabs" :key="tb.key" class="chip" role="tab" :aria-selected="tab === tb.key"
        :tabindex="tab === tb.key ? 0 : -1" :class="{ active: tab === tb.key }" @click="selectTab(tb.key)">
        {{ tb.label }}<span class="n">{{ groups[tb.key].length }}</span>
      </button>
    </div>

    <div class="filters">
      <label class="search grow">
        <Icon name="search" :size="16" />
        <input v-model="search" type="search" placeholder="Cari" aria-label="Cari todo" />
      </label>
      <select v-if="lists.length" v-model="listFilter" class="list-pick" aria-label="Filter daftar">
        <option value="">Semua daftar</option>
        <option v-for="l in lists" :key="l" :value="l">{{ l }}</option>
      </select>
    </div>

    <div v-if="touch && showSwipeHint && shown.length" class="hint-bar">
      <span>Geser ke kanan untuk selesai, ke kiri untuk ubah atau hapus.</span>
      <button class="icon-btn" aria-label="Tutup petunjuk" @click="swipeUsed"><Icon name="x" :size="16" /></button>
    </div>

    <div class="card list" role="tabpanel">
      <div v-if="!state.loaded" class="empty">Memuat…</div>
      <div v-else-if="!shown.length" class="empty">{{ emptyText }}</div>
      <SwipeRow v-for="x in shown" :key="x.id" :leading="leadingFor(x)" :trailing="trailingFor(x)">
        <div class="todo" :class="{ done: x.status === 'done' }">
          <label class="tick-hit">
            <input type="checkbox" class="tick" :class="{ high: x.priority === 'high' }" :checked="x.status === 'done'"
              :disabled="busyId === x.id" :aria-label="`Tandai ${x.title}`" @change="toggle(x)" />
          </label>
          <div class="grow body" @click="editing = x">
            <div class="title">
              <span v-if="x.priority === 'high'" class="prio" title="Prioritas tinggi">!</span>{{ x.title }}
            </div>
            <div class="meta">
              <span v-if="x.dueDate" :class="isLate(x) ? 'late' : 'due'">{{ dueLabel(x) }}</span>
              <span v-if="x.list">{{ x.list }}</span>
              <span v-if="reminderCount(x)" title="Pengingat">🔔 {{ reminderCount(x) }}</span>
              <span v-if="x.source === 'chat'" title="Dibuat lewat chat">AI</span>
              <span class="id">#{{ x.id }}</span>
            </div>
            <div v-if="x.notes" class="notes muted small">{{ x.notes }}</div>
          </div>
          <div class="row-actions">
            <button class="icon-btn" :aria-label="`Ubah ${x.title}`" @click="editing = x"><Icon name="edit" :size="18" /></button>
            <button class="icon-btn" :aria-label="`Hapus ${x.title}`" @click="remove(x)"><Icon name="trash" :size="18" /></button>
          </div>
        </div>
      </SwipeRow>
    </div>
    <div v-if="tab === 'done' && groups.done.length" class="list-foot">
      <button class="btn sm" @click="archiveDone">Arsipkan semua yang selesai</button>
    </div>

    <TodoForm v-if="creating" :preset-date="tab === 'today' ? t0 : ''" @close="creating = false" />
    <TodoForm v-if="editing" :todo="editing" @close="editing = null" @deleted="editing = null" />
  </div>
</template>

<style scoped>
.quick {
  padding: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.quick-input {
  display: flex;
  align-items: center;
  gap: 8px;
}
.quick-input input {
  flex: 1;
}
.send {
  flex-shrink: 0;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  border: none;
  background: var(--accent);
  color: var(--accent-text);
  display: grid;
  place-items: center;
  cursor: pointer;
  transition: opacity 0.15s;
}
.send:disabled {
  opacity: 0.35;
  cursor: default;
}
.tabs {
  margin-bottom: 10px;
}
.filters {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
}
.list-pick {
  width: auto;
  max-width: 45%;
}
.hint-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.85rem;
  color: var(--muted);
  background: var(--accent-soft);
  border-radius: 10px;
  padding: 4px 4px 4px 12px;
  margin-bottom: 10px;
}
.hint-bar span {
  flex: 1;
}
.list {
  padding: 0;
  overflow: hidden;
}
.list :deep(.swipe) + :deep(.swipe) .todo {
  border-top: 1px solid var(--border);
}
.todo {
  display: flex;
  align-items: flex-start;
  gap: 4px;
  padding: 8px 8px 8px 4px;
  margin-left: 0;
}
.tick-hit {
  display: grid;
  place-items: center;
  width: 40px;
  min-height: 40px;
  flex-shrink: 0;
  cursor: pointer;
}
.body {
  cursor: pointer;
  padding: 8px 0;
  min-height: 40px;
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
  gap: 4px 10px;
  flex-wrap: wrap;
  margin-top: 2px;
  align-items: center;
  font-size: 0.82rem;
  color: var(--muted);
}
.meta .due {
  color: var(--accent);
  font-weight: 500;
}
.meta .late {
  color: var(--danger);
  font-weight: 500;
}
.id {
  margin-left: auto;
  opacity: 0.7;
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
.row-actions {
  display: flex;
  align-self: center;
}
.list-foot {
  display: flex;
  justify-content: center;
  margin: -4px 0 14px;
}
@media (pointer: coarse) {
  /* HP: aksi lewat geser & ketuk; tombol ikon kecil & nomor id disembunyikan */
  .row-actions,
  .id {
    display: none;
  }
}
</style>
