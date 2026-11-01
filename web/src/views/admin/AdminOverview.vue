<script setup>
import { onMounted, ref } from 'vue'
import { get } from '../../api'
import { toast, errorText } from '../../store'

const s = ref(null)
onMounted(async () => {
  try {
    s.value = await get('/admin/stats')
  } catch (e) {
    toast(errorText(e), 'error')
  }
})
</script>

<template>
  <div class="page">
    <div class="page-head"><h1>Ringkasan</h1><span v-if="s" class="muted small">versi {{ s.version }}</span></div>
    <div v-if="!s" class="empty">Memuat…</div>
    <template v-else>
      <div class="stats">
        <div class="stat"><span class="muted small">Pengguna</span><b>{{ s.users }}</b></div>
        <div class="stat"><span class="muted small">Todo aktif</span><b>{{ s.openTodos }}</b></div>
        <div class="stat"><span class="muted small">Pengingat aktif</span><b>{{ s.activeReminders }}</b></div>
        <div class="stat"><span class="muted small">Chat 24 jam</span><b>{{ s.chats24h }}</b></div>
        <div class="stat"><span class="muted small">Model siap</span><b>{{ s.modelsReady }}</b></div>
      </div>
      <div class="card">
        <h3>Provider AI</h3>
        <p class="muted small">API key hanya diisi di file environment server (<code>KENARI_API_KEY</code>, <code>AGNES_API_KEY</code>,
          <code>OPENROUTER_API_KEY</code>) dan tidak pernah ditampilkan di sini.</p>
        <table class="table">
          <thead><tr><th>Provider</th><th>Base URL</th><th>API key</th></tr></thead>
          <tbody>
            <tr v-for="p in s.providers" :key="p.key">
              <td>{{ p.name }}</td><td class="small muted">{{ p.baseUrl }}</td>
              <td><span class="tag" :class="p.hasKey ? 'ok' : 'warn'">{{ p.hasKey ? 'terpasang' : 'belum ada' }}</span></td>
            </tr>
          </tbody>
        </table>
        <p v-if="!s.modelsReady" class="error">Asisten belum bisa menjawab: belum ada model aktif yang provider-nya punya API key.
          Pasang key di server, lalu cek <RouterLink to="/admin/model">Model AI</RouterLink>.</p>
      </div>
    </template>
  </div>
</template>
