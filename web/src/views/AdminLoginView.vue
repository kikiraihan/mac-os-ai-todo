<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { post } from '../api'
import { state, loadAdmin, errorText } from '../store'

// Masuk mode admin: akun admin terpisah dari akun pengguna (sesi & cookie sendiri).
// Username diisi dari akun pengguna yang sedang aktif, kalau ada; password tetap wajib.
const route = useRoute()
const router = useRouter()
const username = ref(state.me?.username || '')
const password = ref('')
const error = ref('')
const busy = ref(false)

async function submit() {
  error.value = ''
  busy.value = true
  try {
    await post('/admin/login', { username: username.value, password: password.value })
    await loadAdmin()
    const n = route.query.next
    router.replace(typeof n === 'string' && n.startsWith('/admin') && !n.startsWith('//') ? n : '/admin')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="login">
    <form class="card login-card" @submit.prevent="submit">
      <div class="login-brand"><img src="/favicon.svg" alt="" width="40" height="40" /><h1>AI Todo</h1><span class="tag accent">Admin</span></div>
      <p class="muted">Masuk ke mode admin: pengguna, model AI, dan log server. Akun admin terpisah dari akun pengguna.</p>
      <div v-if="error" class="error">{{ error }}</div>
      <label class="field"><span>Username admin</span>
        <input v-model="username" type="text" autocomplete="username" autocapitalize="off" required />
      </label>
      <label class="field"><span>Password admin</span>
        <input v-model="password" type="password" autocomplete="current-password" required />
      </label>
      <button class="btn primary login-btn" :disabled="busy">{{ busy ? 'Masuk…' : 'Masuk sebagai admin' }}</button>
      <p class="hint">
        <RouterLink to="/">{{ state.me ? '← Kembali ke mode pengguna' : '← Masuk sebagai pengguna' }}</RouterLink>
      </p>
    </form>
  </div>
</template>

<style scoped>
.login {
  min-height: 100dvh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
}
.login-card {
  width: 100%;
  max-width: 380px;
  padding: 24px;
}
.login-brand {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 4px;
}
.login-btn {
  width: 100%;
  justify-content: center;
  margin-top: 4px;
}
</style>
