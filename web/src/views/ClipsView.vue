<script setup>
// Kiriman: kirim teks dari perangkat ini ke perangkat lain (HP Android: notifikasi dengan tombol Salin).
// Sementara (7 hari, 50 terbaru), bukan arsip — untuk disimpan, pakai Catatan.
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { get, post, del } from '../api'
import { state, toast, errorText, onRemoteChange } from '../store'
import { friendlyStamp } from '../dates'
import { copyText } from '../copy'
import Icon from '../components/Icon.vue'
import SwipeRow from '../components/SwipeRow.vue'

const route = useRoute()
const router = useRouter()
const clips = ref([])
const loaded = ref(false)
const text = ref('')
const sending = ref(false)
// Kiriman yang dibuka dari notifikasi (?salin=<id>): disorot + tombol Salin besar.
const focusId = ref(Number(route.query.salin) || 0)
const focused = computed(() => clips.value.find((c) => c.id === focusId.value))

async function load() {
  try {
    clips.value = (await get('/clips')).clips
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    loaded.value = true
  }
}

async function send() {
  const content = text.value
  if (!content.trim() || sending.value) return
  sending.value = true
  try {
    const res = await post('/clips', { content })
    text.value = ''
    toast(res.sent ? `Terkirim ke ${res.sent} perangkat` : 'Tersimpan — belum ada perangkat lain dengan notifikasi aktif')
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    sending.value = false
  }
}

async function pasteAndSend() {
  try {
    text.value = await navigator.clipboard.readText()
  } catch {
    toast('Browser tidak mengizinkan membaca clipboard — tempel manual (⌘V / tahan → Tempel)', 'error')
  }
}

async function copy(c) {
  if (await copyText(c.content)) toast('Kiriman disalin')
}

async function remove(c) {
  try {
    await del(`/clips/${c.id}`)
    clips.value = clips.value.filter((x) => x.id !== c.id)
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function clearAll() {
  if (!confirm('Hapus semua kiriman?')) return
  try {
    await del('/clips')
    clips.value = []
    toast('Semua kiriman dihapus')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

function onKey(e) {
  // ⌘/Ctrl+Enter = kirim (Enter biasa = baris baru, kiriman sering berisi banyak baris).
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
    e.preventDefault()
    send()
  }
}

function dismissFocus() {
  focusId.value = 0
  router.replace({ query: {} })
}

watch(() => route.query.salin, (v) => (focusId.value = Number(v) || 0))

const leadingFor = (c) => ({ label: 'Salin', icon: 'copy', tone: 'ok', run: () => copy(c) })
const trailingFor = (c) => [{ label: 'Hapus', icon: 'trash', tone: 'danger', run: () => remove(c) }]

let off = null
onMounted(() => {
  load()
  off = onRemoteChange(load)
})
onUnmounted(() => off && off())
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Kiriman</h1>
      <button v-if="clips.length" class="btn compact" aria-label="Hapus semua kiriman" @click="clearAll">
        <Icon name="trash" :size="18" /><span class="btn-label">Hapus semua</span>
      </button>
    </div>

    <div v-if="focused" class="card focus">
      <div class="muted small">Dari {{ focused.device || 'perangkat lain' }} · {{ friendlyStamp(focused.createdAt) }}</div>
      <pre class="content">{{ focused.content }}</pre>
      <div class="row">
        <button class="btn primary" @click="copy(focused)"><Icon name="copy" :size="16" /> Salin</button>
        <button class="btn" @click="dismissFocus">Tutup</button>
      </div>
    </div>

    <form class="card compose" @submit.prevent="send">
      <textarea v-model="text" rows="3" maxlength="20000" placeholder="Teks untuk dikirim ke HP & perangkat lain…"
        aria-label="Isi kiriman" @keydown="onKey"></textarea>
      <div class="row">
        <button type="button" class="btn sm" @click="pasteAndSend"><Icon name="download" :size="14" /> Tempel</button>
        <span class="grow muted small hint-key">⌘↵ kirim</span>
        <button class="btn primary sm" :disabled="!text.trim() || sending"><Icon name="send" :size="14" /> Kirim</button>
      </div>
    </form>

    <div class="card list">
      <div v-if="!loaded" class="empty">Memuat…</div>
      <div v-else-if="!clips.length" class="empty">
        Belum ada kiriman. Teks yang dikirim muncul sebagai notifikasi di HP (aplikasi Android AI Todo) dengan tombol
        <b>Salin</b>, dan tersimpan di sini selama 7 hari.
      </div>
      <SwipeRow v-for="c in clips" :key="c.id" :leading="leadingFor(c)" :trailing="trailingFor(c)">
        <div class="clip" :class="{ hl: c.id === focusId }">
          <button class="grow body" type="button" :title="'Klik untuk menyalin'" @click="copy(c)">
            <pre class="content clamp">{{ c.content }}</pre>
            <span class="meta">{{ c.device || 'Perangkat' }} · {{ friendlyStamp(c.createdAt) }}</span>
          </button>
          <div class="row-actions">
            <button class="icon-btn" aria-label="Salin kiriman" @click="copy(c)"><Icon name="copy" :size="18" /></button>
            <button class="icon-btn" aria-label="Hapus kiriman" @click="remove(c)"><Icon name="trash" :size="18" /></button>
          </div>
        </div>
      </SwipeRow>
    </div>
    <p v-if="state.me" class="hint">Kiriman otomatis terhapus setelah 7 hari (maks. 50). Untuk disimpan, pakai Catatan.</p>
  </div>
</template>

<style scoped>
.compose {
  padding: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.compose textarea {
  width: 100%;
  resize: vertical;
  min-height: 72px;
  font-family: inherit;
}
.compose .row {
  align-items: center;
  gap: 8px;
}
.hint-key {
  text-align: right;
}
.focus {
  border: 1px solid var(--accent);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.list {
  padding: 0;
  overflow: hidden;
}
.list :deep(.swipe) + :deep(.swipe) .clip {
  border-top: 1px solid var(--border);
}
.clip {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 8px;
}
.clip.hl {
  background: var(--accent-soft);
}
.body {
  min-width: 0;
  text-align: left;
  border: none;
  background: none;
  color: inherit;
  font: inherit;
  cursor: pointer;
  padding: 8px 4px;
  min-height: 40px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.content {
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.88rem;
  white-space: pre-wrap;
  word-break: break-word;
}
.clamp {
  display: -webkit-box;
  -webkit-line-clamp: 4;
  line-clamp: 4;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.meta {
  font-size: 0.82rem;
  color: var(--muted);
}
.row-actions {
  display: flex;
}
@media (pointer: coarse) {
  .row-actions,
  .hint-key {
    display: none;
  }
}
</style>
