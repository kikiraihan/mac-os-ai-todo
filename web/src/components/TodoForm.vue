<script setup>
import { computed, ref } from 'vue'
import { post, put, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import Modal from './Modal.vue'
import Icon from './Icon.vue'
import { copyTodo } from '../copy'

const props = defineProps({ todo: { type: Object, default: null }, presetDate: { type: String, default: '' } })
const emit = defineEmits(['close', 'saved', 'deleted'])

const t = props.todo
const title = ref(t?.title || '')
const notes = ref(t?.notes || '')
const list = ref(t?.list || '')
const priority = ref(t?.priority || 'normal')
const dueDate = ref(t?.dueDate || props.presetDate)
const dueTime = ref(t?.dueTime || '')
const remind = ref(false)
const busy = ref(false)
const error = ref('')

const lists = computed(() => [...new Set(state.todos.map((x) => x.list).filter(Boolean))].sort())

// Hapus dari lembar ubah (di HP juga bisa lewat geser kiri di daftar).
async function remove() {
  const n = state.reminders.filter((r) => r.todoId === t.id && r.active).length
  if (!confirm(`Hapus “${t.title}”?${n ? ` ${n} pengingatnya ikut terhapus.` : ''}`)) return
  busy.value = true
  try {
    await del(`/todos/${t.id}`)
    await refreshData()
    toast('Todo dihapus')
    emit('deleted')
    emit('close')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}

async function save() {
  error.value = ''
  busy.value = true
  const body = {
    title: title.value,
    notes: notes.value,
    list: list.value,
    priority: priority.value,
    dueDate: dueDate.value,
    dueTime: dueDate.value ? dueTime.value : '',
  }
  try {
    const res = t ? await put(`/todos/${t.id}`, body) : await post('/todos', body)
    if (remind.value && body.dueDate && body.dueTime) {
      await post('/reminders', {
        title: res.todo.title,
        todoId: res.todo.id,
        schedule: { kind: 'once', at: `${body.dueDate}T${body.dueTime}` },
      })
    }
    await refreshData()
    toast(t ? 'Todo disimpan' : 'Todo ditambahkan')
    emit('saved', res.todo)
    emit('close')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Modal :title="t ? 'Ubah todo' : 'Todo baru'" @close="emit('close')">
    <form id="todo-form" @submit.prevent="save">
      <div v-if="error" class="error">{{ error }}</div>
      <label class="field"><span>Judul</span>
        <input v-model="title" type="text" maxlength="200" required autofocus placeholder="mis. Bayar listrik" />
      </label>
      <div class="row">
        <label class="field grow"><span>Tenggat</span><input v-model="dueDate" type="date" /></label>
        <label class="field grow"><span>Jam</span><input v-model="dueTime" type="time" :disabled="!dueDate" /></label>
      </div>
      <div class="row">
        <label class="field grow"><span>Daftar</span>
          <input v-model="list" type="text" maxlength="40" list="todo-lists" placeholder="mis. Belanja" />
          <datalist id="todo-lists"><option v-for="l in lists" :key="l" :value="l" /></datalist>
        </label>
        <label class="field grow"><span>Prioritas</span>
          <select v-model="priority">
            <option value="low">Rendah</option>
            <option value="normal">Normal</option>
            <option value="high">Tinggi</option>
          </select>
        </label>
      </div>
      <label class="field"><span>Detail <em class="muted">(opsional)</em></span>
        <textarea v-model="notes" maxlength="5000" rows="4" placeholder="Link, rincian, atau daftar catatan — satu butir per baris"></textarea>
      </label>
      <label v-if="dueDate && dueTime" class="check"><input v-model="remind" type="checkbox" /> Buat pengingat di jam tenggat</label>
    </form>
    <template #footer>
      <button v-if="t" class="btn danger push-left" type="button" :disabled="busy" aria-label="Hapus todo" @click="remove">
        <Icon name="trash" :size="16" /><span class="btn-label">Hapus</span>
      </button>
      <button v-if="t" class="btn" type="button" :aria-label="notes ? 'Salin judul & detail' : 'Salin judul'"
        @click="copyTodo({ title, notes })">
        <Icon name="copy" :size="16" /><span class="btn-label">Salin</span>
      </button>
      <button class="btn" type="button" @click="emit('close')">Batal</button>
      <button class="btn primary" form="todo-form" :disabled="busy">{{ busy ? 'Menyimpan…' : 'Simpan' }}</button>
    </template>
  </Modal>
</template>
