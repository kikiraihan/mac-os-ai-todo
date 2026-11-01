<script setup>
import { computed, onMounted, ref } from 'vue'
import { get, post, put, del } from '../../api'
import { toast, errorText } from '../../store'
import { timeAgo } from '../../dates'
import Modal from '../../components/Modal.vue'
import Icon from '../../components/Icon.vue'

const models = ref([])
const providers = ref([])
const testing = ref(0)
const lastTest = ref({})
const editForm = ref(null)
const addForm = ref(null)
const importer = ref(null) // { provider, list, loading, error, q, freeOnly, selected:Set }
const error = ref('')

const providerName = (k) => providers.value.find((p) => p.key === k)?.name || k
const hasKey = (k) => providers.value.find((p) => p.key === k)?.hasKey
const chain = computed(() => models.value.filter((m) => m.status === 'active' && hasKey(m.provider)))

async function load() {
  const res = await get('/admin/ai')
  models.value = res.models
  providers.value = res.providers
}

async function test(m) {
  testing.value = m.id
  try {
    const res = await post(`/admin/ai/models/${m.id}/test`)
    lastTest.value[m.id] = res
    toast(res.ok ? `OK · ${res.latencyMs} ms` : `Gagal: ${res.error}`, res.ok ? 'info' : 'error')
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  } finally {
    testing.value = 0
  }
}

async function setStatus(m, status) {
  try {
    await put(`/admin/ai/models/${m.id}`, { status })
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function move(i, dir) {
  const ids = models.value.map((m) => m.id)
  const j = i + dir
  if (j < 0 || j >= ids.length) return
  ;[ids[i], ids[j]] = [ids[j], ids[i]]
  try {
    models.value = (await post('/admin/ai/models/reorder', { ids })).models
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

async function remove(m) {
  if (!confirm(`Hapus ${m.modelId} dari katalog?`)) return
  try {
    await del(`/admin/ai/models/${m.id}`)
    await load()
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

function openEdit(m) {
  error.value = ''
  editForm.value = { id: m.id, modelId: m.modelId, provider: m.provider, label: m.label, extraBody: m.extraBody, free: m.free }
}
async function saveEdit() {
  error.value = ''
  const f = editForm.value
  try {
    await put(`/admin/ai/models/${f.id}`, { label: f.label, extraBody: f.extraBody, free: f.free })
    editForm.value = null
    await load()
  } catch (e) {
    error.value = errorText(e)
  }
}

function openAdd() {
  error.value = ''
  addForm.value = { provider: providers.value[0]?.key || 'kenari', modelId: '', label: '', extraBody: '', free: true }
}
async function saveAdd() {
  error.value = ''
  try {
    await post('/admin/ai/models', addForm.value)
    addForm.value = null
    await load()
    toast('Model ditambahkan — klik Tes untuk memastikan bisa dipakai')
  } catch (e) {
    error.value = errorText(e)
  }
}

async function openImport(provider) {
  importer.value = { provider, list: [], loading: true, error: '', q: '', freeOnly: true, selected: new Set() }
  try {
    importer.value.list = (await get(`/admin/ai/providers/${provider}/models`)).models
  } catch (e) {
    importer.value.error = errorText(e)
  } finally {
    importer.value.loading = false
  }
}
const importList = computed(() => {
  const im = importer.value
  if (!im) return []
  const q = im.q.toLowerCase()
  return im.list.filter((m) => (!im.freeOnly || m.free) && (!q || m.id.toLowerCase().includes(q) || (m.name || '').toLowerCase().includes(q))).slice(0, 300)
})
function toggleSel(m) {
  const s = importer.value.selected
  s.has(m.id) ? s.delete(m.id) : s.add(m.id)
}
async function doImport() {
  const im = importer.value
  const picked = im.list.filter((m) => im.selected.has(m.id))
  try {
    const res = await post('/admin/ai/models/import', { provider: im.provider, models: picked })
    importer.value = null
    await load()
    toast(`${res.added.length} model ditambahkan`)
  } catch (e) {
    im.error = errorText(e)
  }
}

onMounted(() => load().catch((e) => toast(errorText(e), 'error')))
</script>

<template>
  <div class="page wide">
    <div class="page-head">
      <h1>Model AI</h1>
      <div class="row">
        <button class="btn" @click="openAdd"><Icon name="plus" :size="18" /> Tambah manual</button>
      </div>
    </div>

    <div class="card">
      <h3>Urutan fallback</h3>
      <p class="muted small">Asisten mencoba model aktif dari atas ke bawah. Kalau satu penuh (429), error, atau ditolak, ia pindah ke model
        berikutnya — tidak pernah ke model berbayar otomatis karena hanya model di katalog ini yang dipakai.</p>
      <p v-if="chain.length" class="small">Sekarang: <span v-for="(m, i) in chain" :key="m.id">{{ i ? ' → ' : '' }}<b>{{ m.label }}</b></span></p>
      <p v-else class="error">Belum ada model aktif yang provider-nya punya API key.</p>
      <div class="row">
        <span class="small muted">Tambah dari daftar API provider:</span>
        <button v-for="p in providers" :key="p.key" class="btn sm" @click="openImport(p.key)">{{ p.name }}</button>
      </div>
    </div>

    <div class="card scroll-x">
      <table class="table">
        <thead><tr><th>#</th><th>Model</th><th>Provider</th><th>Status</th><th>Tes terakhir</th><th></th></tr></thead>
        <tbody>
          <tr v-for="(m, i) in models" :key="m.id" :class="{ dim: m.status !== 'active' }">
            <td class="order">
              <button class="icon-btn" aria-label="Naik" :disabled="i === 0" @click="move(i, -1)"><Icon name="up" :size="16" /></button>
              <button class="icon-btn" aria-label="Turun" :disabled="i === models.length - 1" @click="move(i, 1)"><Icon name="down" :size="16" /></button>
            </td>
            <td>
              <b>{{ m.label }}</b> <span v-if="m.free" class="tag ok">gratis</span> <span v-if="m.builtin" class="tag">bawaan</span>
              <div class="small muted mono">{{ m.modelId }}</div>
              <div v-if="m.extraBody" class="small muted mono">{{ m.extraBody }}</div>
            </td>
            <td>{{ providerName(m.provider) }} <span v-if="!hasKey(m.provider)" class="tag warn">tanpa key</span></td>
            <td>
              <span class="tag" :class="{ ok: m.status === 'active', danger: m.status === 'unavailable' }">
                {{ { active: 'aktif', disabled: 'nonaktif', unavailable: 'tidak tersedia' }[m.status] }}</span>
              <div v-if="m.statusNote" class="small muted note">{{ m.statusNote }}</div>
            </td>
            <td class="small muted">
              <template v-if="m.lastCheckedAt">{{ timeAgo(m.lastCheckedAt) }}<span v-if="m.lastLatencyMs"> · {{ m.lastLatencyMs }} ms</span></template>
              <template v-else>belum</template>
            </td>
            <td class="actions">
              <button class="btn sm" :disabled="testing === m.id || !hasKey(m.provider)" @click="test(m)">{{ testing === m.id ? 'Menguji…' : 'Tes' }}</button>
              <button v-if="m.status !== 'disabled'" class="btn sm" @click="setStatus(m, 'disabled')">Matikan</button>
              <button v-else class="btn sm" @click="setStatus(m, 'active')">Aktifkan</button>
              <button class="icon-btn" aria-label="Ubah" @click="openEdit(m)"><Icon name="edit" :size="18" /></button>
              <button class="icon-btn" aria-label="Hapus" @click="remove(m)"><Icon name="trash" :size="18" /></button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <Modal v-if="editForm" :title="`Ubah ${editForm.modelId}`" @close="editForm = null">
      <form id="edit-model" @submit.prevent="saveEdit">
        <div v-if="error" class="error">{{ error }}</div>
        <label class="field"><span>Label</span><input v-model="editForm.label" type="text" maxlength="100" /></label>
        <label class="field"><span>Extra body (JSON, opsional)</span>
          <textarea v-model="editForm.extraBody" class="mono" rows="3" placeholder='{"reasoning_effort":"low"}'></textarea>
        </label>
        <p class="hint">Digabung ke body request, mis. mematikan "thinking" supaya token tidak habis. <code>model</code> dan <code>messages</code> tidak bisa ditimpa.</p>
        <label class="check"><input v-model="editForm.free" type="checkbox" /> Model gratis</label>
      </form>
      <template #footer>
        <button class="btn" type="button" @click="editForm = null">Batal</button>
        <button class="btn primary" form="edit-model">Simpan</button>
      </template>
    </Modal>

    <Modal v-if="addForm" title="Tambah model manual" @close="addForm = null">
      <form id="add-model" @submit.prevent="saveAdd">
        <div v-if="error" class="error">{{ error }}</div>
        <label class="field"><span>Provider</span>
          <select v-model="addForm.provider"><option v-for="p in providers" :key="p.key" :value="p.key">{{ p.name }}</option></select>
        </label>
        <label class="field"><span>ID model (persis dari daftar provider)</span>
          <input v-model="addForm.modelId" type="text" class="mono" required placeholder="mis. qwen/qwen3-235b-a22b:free" />
        </label>
        <label class="field"><span>Label</span><input v-model="addForm.label" type="text" maxlength="100" /></label>
        <label class="field"><span>Extra body (JSON, opsional)</span><textarea v-model="addForm.extraBody" class="mono" rows="2"></textarea></label>
        <label class="check"><input v-model="addForm.free" type="checkbox" /> Model gratis</label>
      </form>
      <template #footer>
        <button class="btn" type="button" @click="addForm = null">Batal</button>
        <button class="btn primary" form="add-model">Tambah</button>
      </template>
    </Modal>

    <Modal v-if="importer" wide :title="`Daftar model ${providerName(importer.provider)}`" @close="importer = null">
      <div v-if="importer.error" class="error">{{ importer.error }}</div>
      <div v-if="importer.loading" class="empty">Mengambil daftar dari provider…</div>
      <template v-else-if="importer.list.length">
        <div class="row">
          <input v-model="importer.q" type="search" class="grow" placeholder="Cari id / nama…" />
          <label class="check"><input v-model="importer.freeOnly" type="checkbox" /> Gratis saja</label>
        </div>
        <div class="import-list">
          <label v-for="m in importList" :key="m.id" class="import-row" :class="{ dim: m.inCatalog }">
            <input type="checkbox" :disabled="m.inCatalog" :checked="importer.selected.has(m.id)" @change="toggleSel(m)" />
            <span class="grow"><b>{{ m.name || m.id }}</b> <span v-if="m.free" class="tag ok">gratis</span>
              <span v-if="m.inCatalog" class="tag">sudah ada</span><br /><span class="small muted mono">{{ m.id }}</span></span>
          </label>
          <div v-if="!importList.length" class="empty">Tidak ada yang cocok.</div>
        </div>
      </template>
      <template #footer>
        <span class="small muted grow">{{ importer.selected.size }} dipilih</span>
        <button class="btn" type="button" @click="importer = null">Batal</button>
        <button class="btn primary" :disabled="!importer.selected.size" @click="doImport">Tambahkan</button>
      </template>
    </Modal>
  </div>
</template>

<style scoped>
.page.wide {
  max-width: 1100px;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  word-break: break-all;
}
.order {
  white-space: nowrap;
  width: 70px;
}
.actions {
  white-space: nowrap;
}
.actions .btn {
  margin-right: 4px;
}
tr.dim td {
  opacity: 0.6;
}
.note {
  max-width: 220px;
}
.import-list {
  max-height: 50dvh;
  overflow-y: auto;
  margin-top: 10px;
  border: 1px solid var(--border);
  border-radius: 8px;
}
.import-row {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  padding: 8px 10px;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
}
.import-row.dim {
  opacity: 0.55;
  cursor: default;
}
</style>
