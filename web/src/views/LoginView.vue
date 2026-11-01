<script setup>
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { post } from '../api'
import { loadMe, refreshData, startSync, errorText } from '../store'

const route = useRoute()
const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)

async function submit() {
  error.value = ''
  busy.value = true
  try {
    await post('/login', { username: username.value, password: password.value })
    await loadMe()
    await refreshData()
    startSync()
    const next = typeof route.query.next === 'string' && route.query.next.startsWith('/') && !route.query.next.startsWith('//') ? route.query.next : '/'
    router.replace(next)
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
      <div class="login-brand"><img src="/favicon.svg" alt="" width="40" height="40" /><h1>AI Todo</h1></div>
      <p class="muted">Todo & pengingat yang kamu kelola cukup lewat chat.</p>
      <div v-if="error" class="error">{{ error }}</div>
      <label class="field"><span>Username</span>
        <input v-model="username" type="text" autocomplete="username" autocapitalize="off" required />
      </label>
      <label class="field"><span>Password</span>
        <input v-model="password" type="password" autocomplete="current-password" required />
      </label>
      <button class="btn primary login-btn" :disabled="busy">{{ busy ? 'Masuk…' : 'Masuk' }}</button>
      <p class="hint">Belum punya akun? Minta admin membuatkannya.</p>
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
