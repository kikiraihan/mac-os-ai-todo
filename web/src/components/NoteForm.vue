<script setup>
// Form catatan (baru / ubah). Pola sama dengan TodoForm, tanpa tenggat & prioritas.
import { computed, ref } from 'vue'
import { post, put, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import Modal from './Modal.vue'
import Icon from './Icon.vue'
import { copyNote } from '../copy'

const props = defineProps({ note: { type: Object, default: null }, preset: { type: Object, default: () => ({}) } })
const emit = defineEmits(['close', 'saved', 'deleted'])

const n = props.note
const title = ref(n?.title ?? props.preset.title ?? '')
const content = ref(n?.content ?? props.preset.content ?? '')
const list = ref(n?.list ?? props.preset.list ?? '')
const pinned = ref(n?.pinned ?? false)
const busy = ref(false)
const error = ref('')

const lists = computed(() => [...new Set(state.notes.map((x) => x.list).filter(Boolean))].sort())

// Hapus dari lembar ubah (di HP juga bisa lewat geser kiri di daftar).
async function remove() {
  if (!confirm(`Hapus catatan “${n.title}”?`)) return
  busy.value = true
  try {
    await del(`/notes/${n.id}`)
    await refreshData()
    toast('Catatan dihapus')
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
  const body = { title: title.value, content: content.value, list: list.value, pinned: pinned.value }
  try {
    const res = n ? await put(`/notes/${n.id}`, body) : await post('/notes', body)
    await refreshData()
    toast(n ? 'Catatan disimpan' : 'Catatan ditambahkan')
    emit('saved', res.note)
    emit('close')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Modal :title="n ? 'Ubah catatan' : 'Catatan baru'" @close="emit('close')">
    <form id="note-form" @submit.prevent="save">
      <div v-if="error" class="error">{{ error }}</div>
      <label class="field"><span>Judul <em class="muted">(kosong = baris pertama isi)</em></span>
        <input v-model="title" type="text" maxlength="200" autofocus placeholder="mis. Resep sambal" />
      </label>
      <label class="field"><span>Isi</span>
        <textarea v-model="content" maxlength="20000" rows="8" placeholder="Teks, link, atau daftar — satu butir per baris"></textarea>
      </label>
      <label class="field"><span>Kategori <em class="muted">(opsional)</em></span>
        <input v-model="list" type="text" maxlength="40" list="note-lists" placeholder="mis. Link" />
        <datalist id="note-lists"><option v-for="l in lists" :key="l" :value="l" /></datalist>
      </label>
      <label class="check"><input v-model="pinned" type="checkbox" /> Sematkan di atas</label>
    </form>
    <template #footer>
      <button v-if="n" class="btn danger push-left" type="button" :disabled="busy" aria-label="Hapus catatan" @click="remove">
        <Icon name="trash" :size="16" /><span class="btn-label">Hapus</span>
      </button>
      <button v-if="n" class="btn" type="button" :aria-label="content ? 'Salin judul & isi' : 'Salin judul'"
        @click="copyNote({ title, content })">
        <Icon name="copy" :size="16" /><span class="btn-label">Salin</span>
      </button>
      <button class="btn" type="button" @click="emit('close')">Batal</button>
      <button class="btn primary" form="note-form" :disabled="busy">{{ busy ? 'Menyimpan…' : 'Simpan' }}</button>
    </template>
  </Modal>
</template>
