<script setup>
import { computed, ref } from 'vue'
import { post, put, del } from '../api'
import { state, toast, errorText, refreshData } from '../store'
import { friendlyStamp } from '../dates'
import ReminderForm from '../components/ReminderForm.vue'
import Icon from '../components/Icon.vue'
import SwipeRow from '../components/SwipeRow.vue'
import { touch, showSwipeHint, swipeUsed } from '../swipe'

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
// Geser (layar sentuh): kanan = jeda / aktifkan, kiri = tunda 10 menit · hapus.
const leadingFor = (r) =>
  r.active
    ? { label: 'Jeda', icon: 'pause', tone: 'warn', run: () => pause(r) }
    : { label: 'Aktifkan', icon: 'play', tone: 'ok', run: () => resume(r) }
const trailingFor = (r) => [
  ...(r.active ? [{ label: 'Tunda', icon: 'clock', tone: 'accent', run: () => snooze(r) }] : []),
  { label: 'Hapus', icon: 'trash', tone: 'danger', run: () => remove(r) },
]

function remove(r) {
  if (!confirm(`Hapus pengingat “${r.title}”?`)) return
  run(() => del(`/reminders/${r.id}`), 'Pengingat dihapus')
}
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h1>Pengingat</h1>
      <button class="btn primary compact" aria-label="Pengingat baru" @click="creating = true">
        <Icon name="plus" :size="18" /><span class="btn-label">Pengingat baru</span>
      </button>
    </div>
    <p class="muted small intro">Notifikasi dikirim ke semua perangkat yang menyalakan notifikasi di <RouterLink to="/pengaturan">Pengaturan</RouterLink>.</p>

    <div v-if="touch && showSwipeHint && active.length" class="hint-bar">
      <span>Geser ke kanan untuk jeda, ke kiri untuk tunda atau hapus.</span>
      <button class="icon-btn" aria-label="Tutup petunjuk" @click="swipeUsed"><Icon name="x" :size="16" /></button>
    </div>

    <h3 class="group">Aktif · {{ active.length }}</h3>
    <div class="card list">
      <div v-if="!active.length" class="empty">Belum ada pengingat aktif. Buat di sini atau minta asisten: “tiap hari jam 8 ingetin minum vitamin”.</div>
      <SwipeRow v-for="r in active" :key="r.id" :leading="leadingFor(r)" :trailing="trailingFor(r)">
        <div class="rem">
          <div class="grow body" @click="editing = r">
            <div class="title">{{ r.title }}</div>
            <div class="meta">
              <span class="sched">{{ r.scheduleText }}</span>
              <span v-if="r.nextFireAt">berikutnya {{ friendlyStamp(r.nextFireAt) }}</span>
            </div>
            <div v-if="r.todoId && todoTitle(r.todoId)" class="small muted">Todo: {{ todoTitle(r.todoId) }}</div>
          </div>
          <div class="row-actions">
            <button class="icon-btn" title="Tunda 10 menit" aria-label="Tunda 10 menit" @click="snooze(r)"><Icon name="clock" :size="18" /></button>
            <button class="icon-btn" title="Jeda" aria-label="Jeda" @click="pause(r)"><Icon name="pause" :size="18" /></button>
            <button class="icon-btn" title="Ubah" aria-label="Ubah" @click="editing = r"><Icon name="edit" :size="18" /></button>
            <button class="icon-btn" title="Hapus" aria-label="Hapus" @click="remove(r)"><Icon name="trash" :size="18" /></button>
          </div>
        </div>
      </SwipeRow>
    </div>

    <template v-if="inactive.length">
      <h3 class="group">Dijeda / selesai · {{ inactive.length }}</h3>
      <div class="card list">
        <SwipeRow v-for="r in inactive" :key="r.id" :leading="leadingFor(r)" :trailing="trailingFor(r)">
          <div class="rem off">
            <div class="grow body" @click="editing = r">
              <div class="title">{{ r.title }}</div>
              <div class="meta"><span>{{ r.scheduleText }}</span>
                <span v-if="r.lastFiredAt">terakhir {{ friendlyStamp(r.lastFiredAt) }}</span></div>
            </div>
            <div class="row-actions">
              <button class="icon-btn" title="Aktifkan" aria-label="Aktifkan" @click="resume(r)"><Icon name="play" :size="18" /></button>
              <button class="icon-btn" title="Hapus" aria-label="Hapus" @click="remove(r)"><Icon name="trash" :size="18" /></button>
            </div>
          </div>
        </SwipeRow>
      </div>
    </template>

    <ReminderForm v-if="creating" @close="creating = false" />
    <ReminderForm v-if="editing" :reminder="editing" @close="editing = null" />
  </div>
</template>

<style scoped>
.intro {
  margin: 0 0 14px;
}
.group {
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--muted);
  margin: 0 4px 6px;
}
.hint-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.85rem;
  color: var(--muted);
  background: var(--accent-soft);
  border-radius: 10px;
  padding: 4px 4px 4px 12px;
  margin-bottom: 10px;
}
.hint-bar span {
  flex: 1;
}
.list {
  padding: 0;
  overflow: hidden;
}
.list :deep(.swipe) + :deep(.swipe) .rem {
  border-top: 1px solid var(--border);
}
.rem {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 8px 4px 16px;
}
.body {
  cursor: pointer;
  padding: 8px 0;
}
.rem.off .title {
  color: var(--muted);
}
.title {
  font-weight: 500;
}
.meta {
  display: flex;
  gap: 4px 10px;
  flex-wrap: wrap;
  align-items: center;
  margin-top: 2px;
  font-size: 0.82rem;
  color: var(--muted);
}
.sched {
  color: var(--accent);
  font-weight: 500;
}
.row-actions {
  display: flex;
}
@media (pointer: coarse) {
  .row-actions {
    display: none;
  }
}
</style>
