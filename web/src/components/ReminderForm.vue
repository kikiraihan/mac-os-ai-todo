<script setup>
import { computed, ref } from 'vue'
import { post, put } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { today, addDays, weekdayNames, monthNames } from '../dates'
import Modal from './Modal.vue'

const props = defineProps({ reminder: { type: Object, default: null } })
const emit = defineEmits(['close'])

const r = props.reminder
const s = r?.schedule || {}
const title = ref(r?.title || '')
const message = ref(r?.message || '')
const todoId = ref(r?.todoId || 0)
const kind = ref(s.kind || 'once')
const atDate = ref(s.at ? s.at.slice(0, 10) : addDays(today(), 0))
const atTime = ref(s.at ? s.at.slice(11, 16) : '09:00')
const time = ref(s.time || '08:00')
const every = ref(s.every || 1)
const weekdays = ref(s.weekdays ? [...s.weekdays] : [1])
const monthDay = ref(s.monthDay || Number(today().slice(8, 10)))
const month = ref(s.month || Number(today().slice(5, 7)))
const everyMinutes = ref(s.everyMinutes || 120)
const winFrom = ref(s.window?.from || '09:00')
const winTo = ref(s.window?.to || '17:00')
const useWindow = ref(kind.value !== 'interval' || !!s.window && !(s.window.from === '00:00' && s.window.to === '23:59'))
const endMode = ref(s.until ? 'until' : s.count ? 'count' : 'never')
const until = ref(s.until || addDays(today(), 30))
const count = ref(s.count || 10)
const busy = ref(false)
const error = ref('')

const openTodos = computed(() => state.todos.filter((x) => x.status === 'open' || x.id === todoId.value))

function toggleDay(d) {
  const i = weekdays.value.indexOf(d)
  if (i >= 0) weekdays.value.splice(i, 1)
  else weekdays.value.push(d)
}

function buildSchedule() {
  const k = kind.value
  if (k === 'once') return { kind: 'once', at: `${atDate.value}T${atTime.value}` }
  const sch = { kind: k }
  if (k === 'daily') Object.assign(sch, { time: time.value, every: Number(every.value) })
  if (k === 'weekly') Object.assign(sch, { time: time.value, every: Number(every.value), weekdays: [...weekdays.value].sort() })
  if (k === 'monthly') Object.assign(sch, { time: time.value, monthDay: Number(monthDay.value) })
  if (k === 'yearly') Object.assign(sch, { time: time.value, month: Number(month.value), monthDay: Number(monthDay.value) })
  if (k === 'interval') {
    Object.assign(sch, { everyMinutes: Number(everyMinutes.value) })
    if (useWindow.value) sch.window = { from: winFrom.value, to: winTo.value }
    if (weekdays.value.length && weekdays.value.length < 7) sch.weekdays = [...weekdays.value].sort()
  }
  if (r?.schedule?.startDate && r.schedule.kind === k) sch.startDate = r.schedule.startDate
  if (endMode.value === 'until') sch.until = until.value
  if (endMode.value === 'count') sch.count = Number(count.value)
  return sch
}

async function save() {
  error.value = ''
  if (kind.value === 'weekly' && !weekdays.value.length) {
    error.value = 'Pilih minimal satu hari'
    return
  }
  busy.value = true
  const body = { title: title.value, message: message.value, todoId: Number(todoId.value) || 0, schedule: buildSchedule() }
  try {
    if (r) await put(`/reminders/${r.id}`, body)
    else await post('/reminders', body)
    await refreshData()
    toast(r ? 'Pengingat disimpan' : 'Pengingat dibuat')
    emit('close')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}

function onTodoPick() {
  const t = state.todos.find((x) => x.id === Number(todoId.value))
  if (t && !title.value) title.value = t.title
}
</script>

<template>
  <Modal :title="r ? 'Ubah pengingat' : 'Pengingat baru'" @close="emit('close')">
    <form id="rem-form" @submit.prevent="save">
      <div v-if="error" class="error">{{ error }}</div>
      <label class="field"><span>Judul notifikasi</span>
        <input v-model="title" type="text" maxlength="200" required placeholder="mis. Minum vitamin" />
      </label>
      <label class="field"><span>Pesan (opsional)</span>
        <input v-model="message" type="text" maxlength="500" placeholder="Isi notifikasi" />
      </label>
      <label class="field"><span>Terkait todo (opsional)</span>
        <select v-model="todoId" @change="onTodoPick">
          <option :value="0">— tidak ada —</option>
          <option v-for="x in openTodos" :key="x.id" :value="x.id">#{{ x.id }} {{ x.title }}</option>
        </select>
      </label>

      <label class="field"><span>Jadwal</span>
        <select v-model="kind">
          <option value="once">Sekali</option>
          <option value="daily">Harian</option>
          <option value="weekly">Mingguan</option>
          <option value="monthly">Bulanan</option>
          <option value="yearly">Tahunan</option>
          <option value="interval">Tiap beberapa menit/jam</option>
        </select>
      </label>

      <div v-if="kind === 'once'" class="row">
        <label class="field grow"><span>Tanggal</span><input v-model="atDate" type="date" required /></label>
        <label class="field grow"><span>Jam</span><input v-model="atTime" type="time" required /></label>
      </div>

      <template v-else>
        <div v-if="kind !== 'interval'" class="row">
          <label class="field grow"><span>Jam</span><input v-model="time" type="time" required /></label>
          <label v-if="kind === 'daily' || kind === 'weekly'" class="field grow">
            <span>Tiap berapa {{ kind === 'daily' ? 'hari' : 'minggu' }}</span>
            <input v-model="every" type="number" min="1" max="365" />
          </label>
          <label v-if="kind === 'yearly'" class="field grow"><span>Bulan</span>
            <select v-model="month"><option v-for="(m, i) in monthNames" :key="m" :value="i + 1">{{ m }}</option></select>
          </label>
          <label v-if="kind === 'monthly' || kind === 'yearly'" class="field grow"><span>Tanggal</span>
            <input v-model="monthDay" type="number" min="1" max="31" />
          </label>
        </div>
        <p v-if="(kind === 'monthly' || kind === 'yearly') && monthDay > 28" class="hint">Bulan yang lebih pendek memakai hari terakhirnya.</p>

        <template v-if="kind === 'interval'">
          <label class="field"><span>Tiap</span>
            <select v-model="everyMinutes">
              <option :value="15">15 menit</option><option :value="30">30 menit</option><option :value="45">45 menit</option>
              <option :value="60">1 jam</option><option :value="90">1,5 jam</option><option :value="120">2 jam</option>
              <option :value="180">3 jam</option><option :value="240">4 jam</option><option :value="360">6 jam</option>
            </select>
          </label>
          <label class="check"><input v-model="useWindow" type="checkbox" /> Hanya pada jam tertentu</label>
          <div v-if="useWindow" class="row">
            <label class="field grow"><span>Dari</span><input v-model="winFrom" type="time" /></label>
            <label class="field grow"><span>Sampai</span><input v-model="winTo" type="time" /></label>
          </div>
        </template>

        <div v-if="kind === 'weekly' || kind === 'interval'" class="field">
          <span class="lbl">Hari{{ kind === 'interval' ? ' (kosong = setiap hari)' : '' }}</span>
          <div class="pills days">
            <button v-for="(d, i) in weekdayNames" :key="d" type="button" class="pill" :class="{ active: weekdays.includes(i + 1) }"
              @click="toggleDay(i + 1)">{{ d.slice(0, 3) }}</button>
          </div>
        </div>

        <label class="field"><span>Berakhir</span>
          <select v-model="endMode">
            <option value="never">Tidak pernah</option>
            <option value="until">Pada tanggal</option>
            <option value="count">Setelah sekian kali</option>
          </select>
        </label>
        <label v-if="endMode === 'until'" class="field"><span>Sampai tanggal</span><input v-model="until" type="date" /></label>
        <label v-if="endMode === 'count'" class="field"><span>Jumlah</span><input v-model="count" type="number" min="1" max="10000" /></label>
      </template>
    </form>
    <template #footer>
      <button class="btn" type="button" @click="emit('close')">Batal</button>
      <button class="btn primary" form="rem-form" :disabled="busy">{{ busy ? 'Menyimpan…' : 'Simpan' }}</button>
    </template>
  </Modal>
</template>

<style scoped>
.lbl {
  display: block;
  font-size: 0.85rem;
  font-weight: 600;
  margin-bottom: 4px;
}
.days {
  margin-bottom: 0;
}
.check {
  margin-bottom: 10px;
}
</style>
