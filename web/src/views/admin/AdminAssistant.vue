<script setup>
import { onMounted, ref } from 'vue'
import { get, put } from '../../api'
import { toast, errorText } from '../../store'

const s = ref(null)
const busy = ref(false)
const defaultPersona = `Kamu adalah "Tody", asisten todo list pribadi yang hangat, rapi, dan to the point.`

onMounted(async () => {
  try {
    s.value = (await get('/admin/ai')).settings
  } catch (e) {
    toast(errorText(e), 'error')
  }
})

async function save() {
  busy.value = true
  try {
    s.value = (await put('/admin/ai/settings', s.value)).settings
    toast('Pengaturan asisten disimpan')
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="page">
    <div class="page-head"><h1>Asisten</h1></div>
    <div v-if="!s" class="empty">Memuat…</div>
    <form v-else @submit.prevent="save">
      <section class="card">
        <label class="check"><input v-model="s.enabled" type="checkbox" /> Asisten AI aktif</label>
        <p class="hint">Kalau dimatikan, chat hanya menerima perintah tanpa AI (/todo, /selesai, /hari-ini, /undo). Halaman Todo & Pengingat tetap bisa dipakai.</p>
      </section>
      <section class="card">
        <h3>Persona (identitas asisten)</h3>
        <p class="muted small">Siapa asisten ini dan bagaimana gaya bicaranya — setara SOUL.md di Hermes Agent. Selalu diletakkan paling atas di
          prompt, untuk semua pengguna. Aturan keamanan & format tetap dari server dan tidak bisa ditimpa di sini.</p>
        <textarea v-model="s.persona" rows="7" maxlength="1500" :placeholder="defaultPersona + ' (kosong = persona bawaan)'"></textarea>
        <p class="hint">{{ (s.persona || '').length }}/1500 karakter</p>
      </section>
      <section class="card">
        <h3>Privasi & batas</h3>
        <label class="check"><input v-model="s.sendNotes" type="checkbox" /> Kirim catatan todo ke AI</label>
        <p class="hint">Mati = hanya judul, tanggal, daftar, dan prioritas yang dikirim. Model gratis bisa mencatat prompt untuk pelatihan, pilih dengan sadar.</p>
        <div class="row">
          <label class="field grow"><span>Maks token jawaban</span><input v-model.number="s.maxTokens" type="number" min="300" max="8000" /></label>
          <label class="field grow"><span>Pesan per menit / pengguna</span><input v-model.number="s.perMinute" type="number" min="1" max="120" /></label>
          <label class="field grow"><span>Pesan per hari / pengguna</span><input v-model.number="s.perDay" type="number" min="1" max="5000" /></label>
        </div>
      </section>
      <button class="btn primary" :disabled="busy">Simpan</button>
    </form>
  </div>
</template>
