<script setup>
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { get, post, put, del } from '../../api'
import { state, toast, errorText, adminLogout } from '../../store'
import Modal from '../../components/Modal.vue'
import Icon from '../../components/Icon.vue'

// Akun admin: terpisah dari akun pengguna. Admin baru hanya bisa dibuat di sini
// (oleh admin yang sudah masuk) atau dari server: `aitodo admin <username>`.
const router = useRouter()
const admins = ref([])
const form = ref(null) // { id?, username, displayName, password, disabled }
const error = ref('')
const pw = ref({ current: '', new: '' })

async function load() {
  admins.value = (await get('/admin/admins')).admins
}
const isMe = (a) => state.admin && a.id === state.admin.id

function openNew() {
  error.value = ''
  form.value = { username: '', displayName: '', password: '', disabled: false }
}
function openEdit(a) {
  error.value = ''
  form.value = { id: a.id, username: a.username, displayName: a.displayName, password: '', disabled: a.disabled }
}

async function save() {
  error.value = ''
  const f = form.value
  try {
    if (f.id) {
      const body = { displayName: f.displayName, disabled: f.disabled }
      if (f.password) body.password = f.password
      await put(`/admin/admins/${f.id}`, body)
    } else {
      await post('/admin/admins', { username: f.username, displayName: f.displayName, password: f.password })
    }
    form.value = null
    await load()
    toast('Akun admin disimpan')
  } catch (e) {
    error.value = errorText(e)
  }
}

async function remove(a) {
  if (!confirm(`Hapus akun admin “${a.username}”? Akun pengguna dengan username yang sama (kalau ada) tidak ikut terhapus.`)) return
  try {
    await del(`/admin/admins/${a.id}`)
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function changePassword() {
  try {
    await put('/admin/me/password', pw.value)
    pw.value = { current: '', new: '' }
    toast('Password admin diganti. Sesi admin di browser lain dikeluarkan.')
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function doLogout() {
  await adminLogout()
  router.replace(state.me ? '/' : '/admin/masuk')
}

onMounted(() => load().catch((e) => toast(errorText(e), 'error')))
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Akun admin</h1>
      <button class="btn" @click="doLogout"><Icon name="logout" :size="18" /> Keluar dari mode admin</button>
    </div>

    <nav class="card more-menu" aria-label="Menu lain">
      <RouterLink v-if="state.me" to="/" class="more-link"><Icon name="swap" :size="18" /> Ke mode pengguna ({{ state.me.username }})</RouterLink>
      <RouterLink v-else to="/masuk" class="more-link"><Icon name="swap" :size="18" /> Masuk sebagai pengguna</RouterLink>
      <RouterLink to="/admin/asisten" class="more-link"><Icon name="spark" :size="18" /> Asisten</RouterLink>
      <RouterLink to="/admin/ai-call-log" class="more-link"><Icon name="list" :size="18" /> AI Call Log</RouterLink>
      <RouterLink to="/admin/system-log" class="more-link"><Icon name="alert" :size="18" /> System Log</RouterLink>
    </nav>

    <section class="card">
      <div class="row head">
        <h3 class="grow">Daftar admin</h3>
        <button class="btn primary sm" @click="openNew"><Icon name="plus" :size="16" /> Admin baru</button>
      </div>
      <p class="muted small">
        Akun admin hanya mengelola server (pengguna, model AI, log) dan tidak punya todo. Akun pengguna tidak bisa diubah
        menjadi admin. Admin baru hanya dibuat di sini atau dari server dengan perintah <code>aitodo admin &lt;username&gt;</code>.
      </p>
      <div class="scroll-x">
        <table class="table">
          <thead><tr><th>Username</th><th>Nama</th><th>Status</th><th></th></tr></thead>
          <tbody>
            <tr v-for="a in admins" :key="a.id">
              <td>{{ a.username }} <span v-if="isMe(a)" class="tag accent">kamu</span></td>
              <td>{{ a.displayName }}</td>
              <td><span class="tag" :class="a.disabled ? 'danger' : 'ok'">{{ a.disabled ? 'nonaktif' : 'aktif' }}</span></td>
              <td class="row">
                <button class="icon-btn" aria-label="Ubah" @click="openEdit(a)"><Icon name="edit" :size="18" /></button>
                <button v-if="!isMe(a)" class="icon-btn" aria-label="Hapus" @click="remove(a)"><Icon name="trash" :size="18" /></button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h3>Ganti password admin</h3>
      <form @submit.prevent="changePassword">
        <div class="row">
          <label class="field grow"><span>Password lama</span><input v-model="pw.current" type="password" autocomplete="current-password" required /></label>
          <label class="field grow"><span>Password baru (min. 10)</span><input v-model="pw.new" type="password" minlength="10" autocomplete="new-password" required /></label>
        </div>
        <p class="hint">Hanya mengganti password akun admin; password akun pengguna dengan username sama tidak berubah.</p>
        <div class="actions"><button class="btn primary sm">Ganti password</button></div>
      </form>
    </section>

    <Modal v-if="form" :title="form.id ? `Ubah admin ${form.username}` : 'Admin baru'" @close="form = null">
      <form id="admin-form" @submit.prevent="save">
        <div v-if="error" class="error">{{ error }}</div>
        <label v-if="!form.id" class="field"><span>Username</span>
          <input v-model="form.username" type="text" pattern="[a-zA-Z0-9._\-]{3,32}" required autocapitalize="off" />
        </label>
        <label class="field"><span>Nama tampilan</span><input v-model="form.displayName" type="text" maxlength="60" /></label>
        <label v-if="!form.id || !isMe(form)" class="field">
          <span>{{ form.id ? 'Reset password (kosongkan bila tidak diganti)' : 'Password (min. 10 karakter)' }}</span>
          <input v-model="form.password" type="password" minlength="10" autocomplete="new-password" :required="!form.id" />
        </label>
        <label v-if="form.id && !isMe(form)" class="check"><input v-model="form.disabled" type="checkbox" /> Nonaktifkan (langsung keluar dari mode admin)</label>
      </form>
      <template #footer>
        <button class="btn" type="button" @click="form = null">Batal</button>
        <button class="btn primary" form="admin-form">Simpan</button>
      </template>
    </Modal>
  </div>
</template>

<style scoped>
/* Di layar lebar menu ini ada di sidebar; di HP tampil sebagai daftar tautan. */
.more-menu {
  display: none;
  padding: 6px;
}
.more-link {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px;
  color: var(--text);
  text-decoration: none;
  border-radius: 8px;
}
.more-link + .more-link {
  border-top: 1px solid var(--border);
}
@media (max-width: 760px) {
  .more-menu {
    display: block;
  }
}
.head {
  margin-bottom: 6px;
}
.head h3 {
  margin: 0;
}
.actions {
  margin-top: 10px;
}
</style>
