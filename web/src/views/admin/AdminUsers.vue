<script setup>
import { onMounted, ref } from 'vue'
import { get, post, put, del } from '../../api'
import { state, toast, errorText } from '../../store'
import Modal from '../../components/Modal.vue'
import Icon from '../../components/Icon.vue'

const users = ref([])
const form = ref(null) // { id?, username, displayName, role, password, disabled }
const error = ref('')

async function load() {
  users.value = (await get('/admin/users')).users
}

function openNew() {
  error.value = ''
  form.value = { username: '', displayName: '', role: 'user', password: '', disabled: false }
}
function openEdit(u) {
  error.value = ''
  form.value = { id: u.id, username: u.username, displayName: u.displayName, role: u.role, password: '', disabled: u.disabled }
}

async function save() {
  error.value = ''
  const f = form.value
  try {
    if (f.id) {
      const body = { displayName: f.displayName, role: f.role, disabled: f.disabled }
      if (f.password) body.password = f.password
      await put(`/admin/users/${f.id}`, body)
    } else {
      await post('/admin/users', f)
    }
    form.value = null
    await load()
    toast('Pengguna disimpan')
  } catch (e) {
    error.value = errorText(e)
  }
}

async function remove(u) {
  if (!confirm(`Hapus akun “${u.username}” beserta semua todo, pengingat, chat, dan ingatannya? Tidak bisa dibatalkan.`)) return
  try {
    await del(`/admin/users/${u.id}`)
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

onMounted(() => load().catch((e) => toast(errorText(e), 'error')))
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Pengguna</h1>
      <button class="btn primary" @click="openNew"><Icon name="plus" :size="18" /> Pengguna baru</button>
    </div>
    <p class="muted small">Setiap pengguna punya todo, pengingat, chat, dan ingatan AI sendiri. Admin tidak bisa membaca isi milik pengguna lain.</p>
    <div class="card scroll-x">
      <table class="table">
        <thead><tr><th>Username</th><th>Nama</th><th>Peran</th><th>Status</th><th></th></tr></thead>
        <tbody>
          <tr v-for="u in users" :key="u.id">
            <td>{{ u.username }} <span v-if="u.id === state.me.id" class="tag accent">kamu</span></td>
            <td>{{ u.displayName }}</td>
            <td><span class="tag" :class="u.role === 'admin' ? 'accent' : ''">{{ u.role }}</span></td>
            <td><span class="tag" :class="u.disabled ? 'danger' : 'ok'">{{ u.disabled ? 'nonaktif' : 'aktif' }}</span></td>
            <td class="row">
              <button class="icon-btn" aria-label="Ubah" @click="openEdit(u)"><Icon name="edit" :size="18" /></button>
              <button v-if="u.id !== state.me.id" class="icon-btn" aria-label="Hapus" @click="remove(u)"><Icon name="trash" :size="18" /></button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <Modal v-if="form" :title="form.id ? `Ubah ${form.username}` : 'Pengguna baru'" @close="form = null">
      <form id="user-form" @submit.prevent="save">
        <div v-if="error" class="error">{{ error }}</div>
        <label v-if="!form.id" class="field"><span>Username</span>
          <input v-model="form.username" type="text" pattern="[a-zA-Z0-9._\-]{3,32}" required autocapitalize="off" />
        </label>
        <label class="field"><span>Nama tampilan</span><input v-model="form.displayName" type="text" maxlength="60" /></label>
        <label class="field"><span>Peran</span>
          <select v-model="form.role" :disabled="form.id === state.me.id">
            <option value="user">user — hanya menu pengguna</option>
            <option value="admin">admin — juga menu admin</option>
          </select>
        </label>
        <label class="field"><span>{{ form.id ? 'Reset password (kosongkan bila tidak diganti)' : 'Password (min. 10 karakter)' }}</span>
          <input v-model="form.password" type="password" minlength="10" autocomplete="new-password" :required="!form.id" />
        </label>
        <label v-if="form.id && form.id !== state.me.id" class="check"><input v-model="form.disabled" type="checkbox" /> Nonaktifkan akun (langsung keluar dari semua perangkat)</label>
      </form>
      <template #footer>
        <button class="btn" type="button" @click="form = null">Batal</button>
        <button class="btn primary" form="user-form">Simpan</button>
      </template>
    </Modal>
  </div>
</template>
