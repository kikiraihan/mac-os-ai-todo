<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { get, post, del } from '../api'
import { onRemoteChange, refreshData, toast, errorText } from '../store'
import { timeAgo } from '../dates'
import BatchCard from '../components/BatchCard.vue'
import Icon from '../components/Icon.vue'

const messages = ref([])
const batches = ref({})
const text = ref('')
const sending = ref(false)
const loading = ref(true)
const hasMore = ref(false)
const list = ref(null)
const input = ref(null)

const suggestions = ['Apa saja todo hari ini?', 'Yang terlambat apa?', 'Ringkas minggu ini', '/bantuan']

async function load(before = 0) {
  const res = await get(`/chat${before ? `?before=${before}` : ''}`)
  batches.value = { ...batches.value, ...res.batches }
  hasMore.value = res.messages.length === 50
  if (before) messages.value = [...res.messages, ...messages.value]
  else messages.value = res.messages
}

function scrollDown() {
  nextTick(() => {
    if (list.value) list.value.scrollTop = list.value.scrollHeight
  })
}

async function send(msg) {
  const body = (msg ?? text.value).trim()
  if (!body || sending.value) return
  sending.value = true
  text.value = ''
  const tempId = `tmp-${Date.now()}`
  messages.value.push({ id: tempId, role: 'user', content: body, createdAt: new Date().toISOString() })
  scrollDown()
  try {
    const res = await post('/chat', { message: body })
    messages.value = messages.value.filter((m) => m.id !== tempId)
    messages.value.push(res.user, res.assistant)
    if (res.batch) batches.value[res.batch.id] = res.batch
    if (res.batch) refreshData().catch(() => {})
  } catch (e) {
    messages.value = messages.value.filter((m) => m.id !== tempId)
    text.value = body
    toast(errorText(e), 'error')
  } finally {
    sending.value = false
    scrollDown()
    nextTick(() => input.value?.focus())
  }
}

function onKey(e) {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
    e.preventDefault()
    send()
  }
}

function onBatchUpdate(b) {
  batches.value[b.id] = b
  refreshData().catch(() => {})
}

async function clearAll() {
  if (!confirm('Hapus seluruh riwayat chat? Todo, pengingat, dan ingatan tidak ikut terhapus.')) return
  try {
    await del('/chat')
    messages.value = []
    batches.value = {}
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

let off
onMounted(async () => {
  try {
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    loading.value = false
    scrollDown()
  }
  off = onRemoteChange(async () => {
    if (sending.value) return
    const atBottom = list.value && list.value.scrollHeight - list.value.scrollTop - list.value.clientHeight < 80
    await load().catch(() => {})
    if (atBottom) scrollDown()
  })
})
onBeforeUnmount(() => off && off())

async function older() {
  const first = messages.value.find((m) => typeof m.id === 'number')
  if (first) await load(first.id).catch((e) => toast(errorText(e), 'error'))
}
</script>

<template>
  <div class="page chat">
    <div class="page-head">
      <h1>Asisten</h1>
      <button v-if="messages.length" class="btn sm" @click="clearAll"><Icon name="trash" :size="16" /> Hapus riwayat</button>
    </div>

    <div ref="list" class="messages">
      <button v-if="hasMore" class="btn sm older" @click="older">Muat pesan lama</button>
      <div v-if="!loading && !messages.length" class="welcome">
        <p><b>Halo! 👋</b> Ceritakan saja apa yang perlu kamu kerjakan.</p>
        <p class="muted small">Contoh: “besok jam 9 ingetin telpon bengkel”, “beli galon, bayar wifi, servis motor sabtu”,
          “tiap tanggal 25 ingetin bayar kos”, atau “aku biasanya belanja sabtu pagi, ingat ya”.</p>
      </div>
      <div v-for="m in messages" :key="m.id" class="msg" :class="m.role">
        <div class="bubble">
          <div class="content">{{ m.content }}</div>
          <BatchCard v-if="m.batchId && batches[m.batchId]" :batch="batches[m.batchId]" @update="onBatchUpdate" />
        </div>
        <div class="meta">
          {{ timeAgo(m.createdAt) }}<span v-if="m.model"> · {{ m.model }}</span>
        </div>
      </div>
      <div v-if="sending" class="msg assistant"><div class="bubble typing"><span></span><span></span><span></span></div></div>
    </div>

    <div class="composer">
      <div class="pills suggest">
        <button v-for="s in suggestions" :key="s" class="pill" type="button" :disabled="sending" @click="send(s)">{{ s }}</button>
      </div>
      <form class="input-row" @submit.prevent="send()">
        <textarea ref="input" v-model="text" rows="1" maxlength="2000" placeholder="Ketik pesan… (Enter kirim, Shift+Enter baris baru)"
          :disabled="sending" @keydown="onKey"></textarea>
        <button class="btn primary" :disabled="sending || !text.trim()" aria-label="Kirim"><Icon name="send" /></button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.chat {
  display: flex;
  flex-direction: column;
  height: calc(100dvh - 64px);
}
.messages {
  flex: 1;
  overflow-y: auto;
  padding: 4px 2px 12px;
}
.older {
  display: block;
  margin: 0 auto 12px;
}
.welcome {
  background: var(--surface);
  border: 1px dashed var(--border);
  border-radius: var(--radius);
  padding: 16px;
}
.welcome p {
  margin: 0 0 6px;
}
.msg {
  margin-bottom: 12px;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}
.msg.user {
  align-items: flex-end;
}
.bubble {
  max-width: min(86%, 640px);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 14px 14px 14px 4px;
  padding: 9px 12px;
}
.msg.user .bubble {
  background: var(--accent);
  color: var(--accent-text);
  border-color: var(--accent);
  border-radius: 14px 14px 4px 14px;
}
.content {
  white-space: pre-wrap;
  word-break: break-word;
}
.meta {
  font-size: 0.72rem;
  color: var(--muted);
  margin-top: 3px;
  padding: 0 4px;
}
.typing {
  display: flex;
  gap: 4px;
  padding: 12px 14px;
}
.typing span {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--muted);
  animation: blink 1.2s infinite;
}
.typing span:nth-child(2) {
  animation-delay: 0.2s;
}
.typing span:nth-child(3) {
  animation-delay: 0.4s;
}
@keyframes blink {
  0%, 80%, 100% { opacity: 0.25; }
  40% { opacity: 1; }
}
.composer {
  border-top: 1px solid var(--border);
  padding-top: 10px;
}
.suggest {
  margin-bottom: 8px;
  flex-wrap: nowrap;
  overflow-x: auto;
}
.suggest .pill {
  flex-shrink: 0;
}
.input-row {
  display: flex;
  gap: 8px;
  align-items: flex-end;
}
.input-row textarea {
  min-height: 42px;
  max-height: 160px;
  resize: none;
}
@media (max-width: 760px) {
  .chat {
    height: calc(100dvh - 16px - 84px - env(safe-area-inset-bottom));
  }
}
</style>
