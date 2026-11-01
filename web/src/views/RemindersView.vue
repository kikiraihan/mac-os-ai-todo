<script setup>
import { computed, ref } from 'vue'
import { post, put, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { friendlyStamp } from '../dates'
import ReminderForm from '../components/ReminderForm.vue'
import Icon from '../components/Icon.vue'

const editing = ref(null)
const creating = ref(false)
const active = computed(() => state.reminders.filter((r) => r.active))
const inactive = computed(() => state.reminders.filter((r) => !r.active))
const todoTitle = (id) => state.todos.find((x) => x.id === id)?.title

async function run(fn, ok) {
  try {
    await fn()
    await refreshData()
    if (ok) toast(ok)
  } catch (e) {
    toast(errorText(e), 'error')
  }
}

const pause = (r) => run(() => put(`/reminders/${r.id}`, { active: false }), 'Pengingat dijeda')
const resume = (r) => run(() => put(`/reminders/${r.id}`, { active: true }), 'Pengingat aktif lagi')
const snooze = (r) => run(() => post(`/reminders/${r.id}/snooze`, { minutes: 10 }), 'Ditunda 10 menit')
function remove(r) {
  if (!confirm(`Hapus pengingat “${r.title}”?`)) return
  run(() => del(`/reminders/${r.id}`), 'Pengingat dihapus')
}
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Pengingat</h1>
      <button class="btn primary" @click="creating = true"><Icon name="plus" :size="18" /> Pengingat baru</button>
    </div>
    <p class="muted small">Notifikasi dikirim ke semua perangkat yang menyalakan notifikasi di <RouterLink to="/pengaturan">Pengaturan</RouterLink>.</p>

    <div class="card list">
      <h3>Aktif ({{ active.length }})</h3>
      <div v-if="!active.length" class="empty">Belum ada pengingat aktif. Buat di sini atau minta asisten: “tiap hari jam 8 ingetin minum vitamin”.</div>
      <div v-for="r in active" :key="r.id" class="rem">
        <div class="grow" @click="editing = r">
          <div class="title">{{ r.title }}</div>
          <div class="meta">
            <span class="tag accent">{{ r.scheduleText }}</span>
            <span v-if="r.nextFireAt" class="small muted">berikutnya {{ friendlyStamp(r.nextFireAt) }}</span>
          </div>
          <div v-if="r.todoId && todoTitle(r.todoId)" class="small muted">Todo: {{ todoTitle(r.todoId) }}</div>
        </div>
        <button class="icon-btn" title="Tunda 10 menit" aria-label="Tunda 10 menit" @click="snooze(r)"><Icon name="clock" :size="18" /></button>
        <button class="icon-btn" title="Jeda" aria-label="Jeda" @click="pause(r)"><Icon name="pause" :size="18" /></button>
        <button class="icon-btn" title="Ubah" aria-label="Ubah" @click="editing = r"><Icon name="edit" :size="18" /></button>
        <button class="icon-btn" title="Hapus" aria-label="Hapus" @click="remove(r)"><Icon name="trash" :size="18" /></button>
      </div>
    </div>

    <div v-if="inactive.length" class="card list">
      <h3>Dijeda / selesai ({{ inactive.length }})</h3>
      <div v-for="r in inactive" :key="r.id" class="rem off">
        <div class="grow" @click="editing = r">
          <div class="title">{{ r.title }}</div>
          <div class="meta"><span class="tag">{{ r.scheduleText }}</span>
            <span v-if="r.lastFiredAt" class="small muted">terakhir {{ friendlyStamp(r.lastFiredAt) }}</span></div>
        </div>
        <button class="icon-btn" title="Aktifkan" aria-label="Aktifkan" @click="resume(r)"><Icon name="play" :size="18" /></button>
        <button class="icon-btn" title="Hapus" aria-label="Hapus" @click="remove(r)"><Icon name="trash" :size="18" /></button>
      </div>
    </div>

    <ReminderForm v-if="creating" @close="creating = false" />
    <ReminderForm v-if="editing" :reminder="editing" @close="editing = null" />
  </div>
</template>

<style scoped>
.list {
  padding: 12px;
}
.rem {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 10px 4px;
  border-top: 1px solid var(--border);
}
.rem .grow {
  cursor: pointer;
}
.rem.off .title {
  color: var(--muted);
}
.title {
  font-weight: 500;
}
.meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  align-items: center;
  margin-top: 3px;
}
</style>
