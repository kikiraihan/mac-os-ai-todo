<script setup>
// Catatan: hal umum tanpa waktu (teks, kumpulan link). Pola sama dengan halaman Todo:
// tambah cepat, filter chip, cari, geser di HP, salin, ubah lewat lembar.
import { computed, nextTick, ref, watch } from 'vue'
import { post, put, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { friendlyStamp } from '../dates'
import NoteForm from '../components/NoteForm.vue'
import Icon from '../components/Icon.vue'
import SwipeRow from '../components/SwipeRow.vue'
import DetailText from '../components/DetailText.vue'
import { copyNote } from '../copy'
import { touch, showSwipeHint, swipeUsed } from '../swipe'

// Filter: '' = Semua, '*' = Disematkan, selain itu nama kategori. Pilihan diingat (per browser).
const FILTER_KEY = 'aitodo.notesFilter'
const readFilter = () => {
  try {
    return localStorage.getItem(FILTER_KEY) || ''
  } catch {
    return ''
  }
}
const filter = ref(readFilter())
watch(filter, (v) => {
  try {
    localStorage.setItem(FILTER_KEY, v)
  } catch {
    /* penyimpanan diblokir: tidak apa-apa */
  }
})

const search = ref('')
const quick = ref('')
const editing = ref(null)
const creating = ref(false)
const busyId = ref(0)
// Isi yang sedang dibuka (id catatan); bawaan tertutup supaya daftar tetap ringkas.
const openDetail = ref(new Set())
function toggleDetail(x) {
  const s = new Set(openDetail.value)
  if (s.has(x.id)) s.delete(x.id)
  else s.add(x.id)
  openDetail.value = s
}

const lists = computed(() => [...new Set(state.notes.map((x) => x.list).filter(Boolean))].sort())
// Kategori yang dipilih sudah tidak ada lagi → kembali ke Semua.
watch(lists, (ls) => {
  if (filter.value && filter.value !== '*' && !ls.includes(filter.value)) filter.value = ''
})

const matches = (x) => {
  if (!search.value) return true
  const words = search.value.toLowerCase().split(/\s+/).filter(Boolean)
  const text = `${x.title}\n${x.content}\n${x.list}`.toLowerCase()
  return words.every((w) => text.includes(w))
}
const inFilter = (x, f) => (f === '' ? true : f === '*' ? x.pinned : x.list === f)
const shown = computed(() => state.notes.filter((x) => inFilter(x, filter.value) && matches(x)))

const chips = computed(() => [
  { key: '', label: 'Semua' },
  { key: '*', label: 'Disematkan' },
  ...lists.value.map((l) => ({ key: l, label: l })),
])
const count = (key) => state.notes.filter((x) => inFilter(x, key) && matches(x)).length

// Pratinjau satu baris isi (saat isi tertutup).
const preview = (x) => (x.content || '').split('\n').map((l) => l.replace(/^\s*[-*]\s+/, '').trim()).find((l) => l && l !== x.title) || ''

// Tambah cepat: teks berisi link → masuk ke isi (bisa diklik), judul otomatis dari baris pertama.
async function addQuick() {
  const text = quick.value.trim()
  if (!text) return
  const hasLink = /https?:\/\/|www\./i.test(text)
  const list = filter.value && filter.value !== '*' ? filter.value : ''
  try {
    await post('/notes', hasLink ? { content: text, list, pinned: filter.value === '*' } : { title: text, list, pinned: filter.value === '*' })
    quick.value = ''
    await refreshData()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function togglePin(x) {
  busyId.value = x.id
  try {
    await put(`/notes/${x.id}`, { pinned: !x.pinned })
    await refreshData()
    toast(x.pinned ? 'Sematan dilepas' : 'Catatan disematkan')
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    busyId.value = 0
  }
}

async function remove(x) {
  if (!confirm(`Hapus catatan “${x.title}”?`)) return
  try {
    await del(`/notes/${x.id}`)
    await refreshData()
    toast('Catatan dihapus')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

// Aksi geser (layar sentuh): kanan = sematkan / lepas, kiri = ubah · hapus.
const leadingFor = (x) =>
  x.pinned
    ? { label: 'Lepas', icon: 'pin', tone: 'accent', run: () => togglePin(x) }
    : { label: 'Sematkan', icon: 'pin', tone: 'ok', run: () => togglePin(x) }
const trailingFor = (x) => [
  { label: 'Ubah', icon: 'edit', tone: 'accent', run: () => (editing.value = x) },
  { label: 'Hapus', icon: 'trash', tone: 'danger', run: () => remove(x) },
]

// Carousel filter: chip aktif digeser ke tengah; ←/→ pindah (pola tablist, sama dengan Todo).
const strip = ref(null)
function selectChip(key) {
  filter.value = key
  nextTick(() => strip.value?.querySelector('[aria-selected="true"]')?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' }))
}
function chipKey(e) {
  const i = chips.value.findIndex((x) => x.key === filter.value)
  const n = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : -1
  if (n < 0 || n >= chips.value.length) return
  e.preventDefault()
  selectChip(chips.value[n].key)
  nextTick(() => strip.value?.querySelector('[aria-selected="true"]')?.focus())
}
const emptyText = computed(() =>
  search.value
    ? `Tidak ada catatan yang cocok dengan “${search.value.trim()}”.`
    : filter.value === '*'
      ? 'Belum ada catatan yang disematkan.'
      : 'Belum ada catatan. Simpan teks atau link di atas, atau minta asisten: “catat link …”.',
)
const presetFor = computed(() => ({ list: filter.value && filter.value !== '*' ? filter.value : '' }))
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Catatan</h1>
      <button class="btn primary compact" aria-label="Catatan baru" @click="creating = true">
        <Icon name="plus" :size="18" /><span class="btn-label">Catatan baru</span>
      </button>
    </div>

    <form class="card quick" @submit.prevent="addQuick">
      <input v-model="quick" type="text" maxlength="2000" placeholder="Simpan teks atau link…" aria-label="Catatan baru"
        enterkeyhint="done" />
      <button class="send" :disabled="!quick.trim()" aria-label="Simpan"><Icon name="up" :size="18" /></button>
    </form>

    <div ref="strip" class="carousel tabs" role="tablist" aria-label="Filter catatan" @keydown="chipKey">
      <button v-for="c in chips" :key="c.key || 'all'" class="chip" role="tab" :aria-selected="filter === c.key"
        :tabindex="filter === c.key ? 0 : -1" :class="{ active: filter === c.key }" @click="selectChip(c.key)">
        {{ c.label }}<span class="n">{{ count(c.key) }}</span>
      </button>
    </div>

    <div class="filters">
      <label class="search grow">
        <Icon name="search" :size="16" />
        <input v-model="search" type="search" placeholder="Cari" aria-label="Cari catatan" />
      </label>
    </div>

    <div v-if="touch && showSwipeHint && shown.length" class="hint-bar">
      <span>Geser ke kanan untuk menyematkan, ke kiri untuk ubah atau hapus.</span>
      <button class="icon-btn" aria-label="Tutup petunjuk" @click="swipeUsed"><Icon name="x" :size="16" /></button>
    </div>

    <div class="card list" role="tabpanel">
      <div v-if="!state.loaded" class="empty">Memuat…</div>
      <div v-else-if="!shown.length" class="empty">{{ emptyText }}</div>
      <SwipeRow v-for="x in shown" :key="x.id" :leading="leadingFor(x)" :trailing="trailingFor(x)">
        <div class="note">
          <button class="pin-hit" type="button" :class="{ on: x.pinned }" :disabled="busyId === x.id"
            :aria-label="x.pinned ? `Lepas sematan ${x.title}` : `Sematkan ${x.title}`"
            :title="x.pinned ? 'Lepas sematan' : 'Sematkan di atas'" @click="togglePin(x)">
            <Icon name="pin" :size="16" />
          </button>
          <div class="grow body" @click="editing = x">
            <div class="title">{{ x.title }}</div>
            <div v-if="x.content && !openDetail.has(x.id) && preview(x)" class="preview">{{ preview(x) }}</div>
            <div class="meta">
              <span v-if="x.list">{{ x.list }}</span>
              <span>{{ friendlyStamp(x.updatedAt) }}</span>
              <button v-if="x.content" type="button" class="detail-tag" :aria-expanded="openDetail.has(x.id)"
                :title="openDetail.has(x.id) ? 'Tutup isi' : 'Lihat isi'" @click.stop="toggleDetail(x)">
                <Icon name="note" :size="14" />Isi
              </button>
              <span v-if="x.source === 'chat'" title="Dibuat lewat chat">AI</span>
              <span class="id">#{{ x.id }}</span>
            </div>
            <div v-if="x.content && openDetail.has(x.id)" class="detail" @click.stop>
              <DetailText :text="x.content" />
              <button type="button" class="btn sm" @click="copyNote(x)"><Icon name="copy" :size="14" />Salin</button>
            </div>
          </div>
          <div class="row-actions">
            <button class="icon-btn" :aria-label="`Salin ${x.title}`" title="Salin judul & isi · ⌥-klik: judul saja"
              @click="copyNote(x, $event.altKey)"><Icon name="copy" :size="18" /></button>
            <button class="icon-btn" :aria-label="`Ubah ${x.title}`" @click="editing = x"><Icon name="edit" :size="18" /></button>
            <button class="icon-btn" :aria-label="`Hapus ${x.title}`" @click="remove(x)"><Icon name="trash" :size="18" /></button>
          </div>
        </div>
      </SwipeRow>
    </div>

    <NoteForm v-if="creating" :preset="presetFor" @close="creating = false" />
    <NoteForm v-if="editing" :note="editing" @close="editing = null" @deleted="editing = null" />
  </div>
</template>

<style scoped>
.quick {
  padding: 10px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.quick input {
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
.list :deep(.swipe) + :deep(.swipe) .note {
  border-top: 1px solid var(--border);
}
.note {
  display: flex;
  align-items: flex-start;
  gap: 4px;
  padding: 8px 8px 8px 4px;
}
.pin-hit {
  display: grid;
  place-items: center;
  width: 40px;
  min-height: 40px;
  flex-shrink: 0;
  border: none;
  background: none;
  color: var(--muted);
  opacity: 0.45;
  cursor: pointer;
}
.pin-hit.on {
  color: var(--accent);
  opacity: 1;
}
.body {
  cursor: pointer;
  padding: 8px 0;
  min-height: 40px;
  min-width: 0;
}
.title {
  font-weight: 500;
  word-break: break-word;
}
.preview {
  font-size: 0.88rem;
  color: var(--muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
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
.id {
  margin-left: auto;
  opacity: 0.7;
}
.detail-tag {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  border: none;
  background: var(--accent-soft);
  color: var(--accent);
  font: inherit;
  font-weight: 500;
  border-radius: 999px;
  padding: 1px 8px 1px 6px;
  cursor: pointer;
}
.detail-tag[aria-expanded='true'] {
  background: var(--accent);
  color: var(--accent-text);
}
.detail {
  margin-top: 8px;
  padding: 10px 12px;
  border-radius: 10px;
  background: var(--surface-2);
  font-size: 0.9rem;
  cursor: text;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 8px;
}
.detail .btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.row-actions {
  display: flex;
  align-self: center;
}
@media (pointer: coarse) {
  .detail-tag {
    position: relative;
    padding: 2px 10px 2px 8px;
  }
  .detail-tag::after {
    content: '';
    position: absolute;
    inset: -10px -4px;
  }
  /* HP: aksi lewat geser & ketuk; tombol ikon kecil & nomor id disembunyikan */
  .row-actions,
  .id {
    display: none;
  }
}
</style>
