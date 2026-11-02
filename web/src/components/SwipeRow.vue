<script setup>
// Baris yang bisa digeser (gaya daftar iOS / Pengingat Apple), khusus layar sentuh.
//
//   geser ke kanan  → aksi depan (mis. Selesai); geser jauh = langsung jalan
//   geser ke kiri   → tombol belakang terbuka (mis. Ubah · Hapus); geser jauh = aksi paling kanan
//
// Semua aksi tetap bisa dicapai tanpa gestur (ketuk baris = ubah, kotak centang, tombol Hapus di
// lembar ubah), jadi gestur hanya jalan pintas. Mouse tidak memicu geser: di desktop baris
// menampilkan tombol ikon biasa. Posisi diatur lewat CSSOM (:style), aman untuk CSP.
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import Icon from './Icon.vue'
import { openSwipe, swipeUsed } from '../swipe'

const props = defineProps({
  // { label, icon, tone: 'ok'|'accent'|'warn'|'danger', run: () => void }
  leading: { type: Object, default: null },
  trailing: { type: Array, default: () => [] },
})

const ACTION_W = 76
const FULL = 90 // jarak ekstra di atas lebar tombol untuk geser penuh
const uid = Symbol('swipe')
const dx = ref(0)
const dragging = ref(false)
const armed = ref(false) // melewati batas geser penuh (untuk umpan balik)
const trailW = computed(() => props.trailing.length * ACTION_W)

let start = null
let suppressClick = false

function setDx(v) {
  const max = props.leading ? Infinity : 0
  const min = props.trailing.length ? -Infinity : 0
  dx.value = Math.max(min, Math.min(max, v))
}

function haptic() {
  try {
    navigator.vibrate?.(8)
  } catch {
    /* tidak didukung */
  }
}

function onDown(e) {
  if (e.pointerType === 'mouse' || !e.isPrimary) return
  start = { x: e.clientX, y: e.clientY, dx: dx.value, axis: null, id: e.pointerId }
}

function onMove(e) {
  if (!start || e.pointerId !== start.id) return
  const mx = e.clientX - start.x
  const my = e.clientY - start.y
  if (!start.axis) {
    if (Math.abs(mx) > 8 && Math.abs(mx) > Math.abs(my) * 1.2) {
      start.axis = 'x'
      dragging.value = true
      openSwipe.value = uid
      e.currentTarget.setPointerCapture?.(e.pointerId)
    } else if (Math.abs(my) > 8) {
      start = null // gulir vertikal: biarkan browser
      return
    } else return
  }
  let v = start.dx + mx
  // Tahanan karet setelah melewati tombol
  const limit = v < 0 ? trailW.value : 0
  if (v < -limit) v = -limit + (v + limit) * 0.8
  setDx(v)
  const nowArmed = (v > 0 && v > FULL) || (v < 0 && props.trailing.length > 0 && v < -(trailW.value + FULL))
  if (nowArmed !== armed.value) {
    armed.value = nowArmed
    if (nowArmed) haptic()
  }
}

function onUp(e) {
  if (!start || e.pointerId !== start.id) return
  const wasDrag = start.axis === 'x'
  start = null
  dragging.value = false
  if (!wasDrag) return
  suppressClick = true
  setTimeout(() => (suppressClick = false), 0)
  const v = dx.value
  const fire = armed.value
  armed.value = false
  if (v > 0) {
    close()
    if (fire || v > 72) run(props.leading)
  } else if (v < 0) {
    if (fire) {
      close()
      run(props.trailing[props.trailing.length - 1])
    } else if (v < -trailW.value / 2) {
      dx.value = -trailW.value
    } else close()
  }
}

function onClickCapture(e) {
  // Ketukan sesudah geser, atau ketukan saat tombol terbuka = tutup saja (bukan buka lembar ubah).
  if (suppressClick || dx.value !== 0) {
    e.stopPropagation()
    e.preventDefault()
    close()
  }
}

function close() {
  dx.value = 0
  if (openSwipe.value === uid) openSwipe.value = null
}

function run(a) {
  if (!a) return
  close()
  swipeUsed()
  a.run()
}

// Hanya satu baris terbuka pada satu waktu.
const stop = watch(openSwipe, (v) => {
  if (v !== uid && dx.value !== 0 && !dragging.value) dx.value = 0
})
onBeforeUnmount(stop)
</script>

<template>
  <div class="swipe" :class="{ dragging, armed, open: dx !== 0 }">
    <div v-if="leading && dx > 0" class="under lead" :class="leading.tone || 'ok'">
      <button type="button" tabindex="-1" @click="run(leading)"><Icon :name="leading.icon" :size="20" /><span>{{ leading.label }}</span></button>
    </div>
    <div v-if="trailing.length && dx < 0" class="under trail">
      <button v-for="a in trailing" :key="a.label" type="button" :class="a.tone || 'accent'"
        :tabindex="dx === -trailW ? 0 : -1" @click="run(a)">
        <Icon :name="a.icon" :size="20" /><span>{{ a.label }}</span>
      </button>
    </div>
    <div class="front" :style="{ transform: dx ? `translateX(${dx}px)` : '' }" @pointerdown="onDown" @pointermove="onMove"
      @pointerup="onUp" @pointercancel="onUp" @click.capture="onClickCapture">
      <slot />
    </div>
  </div>
</template>

<style scoped>
.swipe {
  position: relative;
  overflow: hidden;
}
.front {
  position: relative;
  background: var(--surface);
  touch-action: pan-y;
  transition: transform 0.28s cubic-bezier(0.2, 0.8, 0.2, 1);
  z-index: 1;
}
.dragging .front {
  transition: none;
}
.under {
  position: absolute;
  inset: 0;
  display: flex;
}
.under button {
  border: none;
  font: inherit;
  font-size: 0.78rem;
  font-weight: 600;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 3px;
  width: 76px;
  color: #fff;
  cursor: pointer;
}
.lead {
  justify-content: flex-start;
}
.lead button {
  width: 100%;
  align-items: flex-start;
  padding-left: 22px;
}
.trail {
  justify-content: flex-end;
}
/* Geser penuh ke kiri: tombol paling kanan melebar memenuhi baris (seperti iOS) */
.armed .trail button:last-child {
  width: 100%;
  align-items: flex-end;
  padding-right: 22px;
}
.armed .trail button:not(:last-child) {
  display: none;
}
.ok,
.lead.ok {
  background: var(--ok-solid);
}
.accent {
  background: var(--accent-solid);
}
.warn {
  background: var(--warn-solid);
}
.danger {
  background: var(--danger-solid);
}
.lead.ok button,
.lead.accent button,
.lead.warn button {
  background: transparent;
}
</style>
