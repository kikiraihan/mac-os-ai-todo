<script setup>
import { computed, ref } from 'vue'
import { post } from '../api'
import { toast, errorText } from '../store'

const props = defineProps({ batch: { type: Object, required: true } })
const emit = defineEmits(['update'])
const busy = ref(false)

const icons = {
  'todo.create': '➕', 'todo.update': '✏️', 'todo.complete': '✅', 'todo.reopen': '↩️', 'todo.delete': '🗑',
  'todo.archiveDone': '📦', 'reminder.create': '🔔', 'reminder.update': '🔔', 'reminder.pause': '⏸',
  'reminder.resume': '▶️', 'reminder.snooze': '⏰', 'reminder.delete': '🗑', 'memory.add': '🧠',
  'memory.update': '🧠', 'memory.remove': '🧠',
}
const statusText = computed(() => ({
  pending: 'Menunggu konfirmasi',
  applied: '',
  rejected: 'Dibatalkan',
  expired: 'Kedaluwarsa — minta ulang lewat chat',
  undone: 'Sudah di-undo',
  failed: 'Gagal',
})[props.batch.status] || '')

async function act(action) {
  busy.value = true
  try {
    const res = await post(`/chat/batches/${props.batch.id}/${action}`)
    emit('update', res.batch)
    if (action === 'undo') toast('Aksi dibatalkan')
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="batch" :class="batch.status">
    <ul>
      <li v-for="(it, i) in batch.items" :key="i"><span class="ic">{{ icons[it.op] || '•' }}</span>{{ it.summary }}</li>
    </ul>
    <div class="batch-foot">
      <span v-if="statusText" class="small muted">{{ statusText }}</span>
      <span class="grow"></span>
      <template v-if="batch.status === 'pending'">
        <button class="btn sm" :disabled="busy" @click="act('reject')">Batal</button>
        <button class="btn sm primary" :disabled="busy" @click="act('confirm')">Ya, lakukan</button>
      </template>
      <button v-else-if="batch.undoable" class="btn sm" :disabled="busy" @click="act('undo')">↶ Batalkan</button>
    </div>
  </div>
</template>

<style scoped>
.batch {
  margin-top: 8px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--surface);
  padding: 8px 10px;
  font-size: 0.9rem;
}
.batch.pending {
  border-color: var(--warn);
  background: var(--warn-soft);
}
.batch.undone,
.batch.rejected,
.batch.expired {
  opacity: 0.65;
}
.batch.undone li,
.batch.rejected li {
  text-decoration: line-through;
}
ul {
  list-style: none;
  margin: 0;
  padding: 0;
}
li {
  padding: 2px 0;
  display: flex;
  gap: 6px;
}
.ic {
  width: 20px;
  flex-shrink: 0;
}
.batch-foot {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 6px;
}
</style>
