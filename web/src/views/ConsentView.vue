<script setup>
// Halaman izin OAuth: aplikasi AI lain (mis. Claude) minta akses ke todo lewat MCP.
// Selalu perlu persetujuan orangnya sendiri di browser yang sudah login; bisa pilih "hanya baca".
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { get, post } from '../api'
import { state, errorText } from '../store'

const route = useRoute()
const info = ref(null)
const error = ref(typeof route.query.error === 'string' ? route.query.error : '')
const write = ref(true)
const busy = ref(false)
// Query string asli dari /oauth/authorize, dikirim apa adanya ke server untuk dicek ulang.
const query = computed(() => window.location.search.replace(/^\?/, ''))

onMounted(async () => {
  if (error.value) return
  try {
    info.value = await get('/oauth/request?' + query.value)
    write.value = info.value.write
  } catch (e) {
    error.value = errorText(e)
  }
})

async function decide(allow) {
  busy.value = true
  try {
    const res = await post('/oauth/approve', { query: query.value, allow, write: write.value })
    window.location.assign(res.redirect)
  } catch (e) {
    error.value = errorText(e)
    busy.value = false
  }
}
</script>

<template>
  <div class="consent">
    <div class="card box">
      <img src="/favicon.svg" alt="" width="40" height="40" />
      <template v-if="error">
        <h1>Tidak bisa menghubungkan</h1>
        <p class="muted">{{ error }}</p>
        <RouterLink to="/" class="btn">Kembali ke AI Todo</RouterLink>
      </template>
      <template v-else-if="info">
        <h1>Izinkan <b>{{ info.clientName }}</b> mengakses AI Todo?</h1>
        <p class="muted small">Masuk sebagai <b>{{ state.me?.username }}</b> · kembali ke <b>{{ info.redirectHost }}</b></p>
        <ul class="perms">
          <li>Melihat todo, pengingat, dan catatan kamu</li>
          <li v-if="write">Menambah & mengubah todo, pengingat, dan catatan; mengirim teks ke HP kamu</li>
          <li class="muted">Tidak bisa menghapus apa pun, membaca chat, Ingatan AI, atau pengaturan</li>
        </ul>
        <label v-if="info.write" class="check"><input v-model="write" type="checkbox" /> Boleh menambah & mengubah (bukan hanya membaca)</label>
        <div class="row actions">
          <button class="btn" :disabled="busy" @click="decide(false)">Tolak</button>
          <button class="btn primary" :disabled="busy" @click="decide(true)">Izinkan</button>
        </div>
        <p class="hint">Akses bisa dicabut kapan saja di Pengaturan → Perangkat.</p>
      </template>
      <p v-else class="muted">Memuat…</p>
    </div>
  </div>
</template>

<style scoped>
.consent {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 16px;
}
.box {
  max-width: 440px;
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
h1 {
  font-size: 1.25rem;
  margin: 4px 0 0;
}
.perms {
  margin: 4px 0;
  padding-left: 20px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.actions {
  justify-content: flex-end;
  gap: 8px;
  margin-top: 6px;
}
</style>
