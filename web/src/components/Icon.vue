<script setup>
// Ikon garis sederhana (tanpa library/CDN, aman untuk CSP).
defineProps({ name: { type: String, required: true }, size: { type: Number, default: 20 } })
const paths = {
  chat: 'M4 5h16v10H8l-4 4z',
  check: 'M5 12l4 4 10-10',
  bell: 'M6 16V11a6 6 0 1112 0v5l2 2H4zM10 20a2 2 0 004 0',
  brain: 'M9 4a3 3 0 00-3 3 3 3 0 00-2 5 3 3 0 002 5 3 3 0 006 0V4zM15 4a3 3 0 013 3 3 3 0 012 5 3 3 0 01-2 5 3 3 0 01-6 0',
  gear: 'M12 9a3 3 0 100 6 3 3 0 000-6zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2',
  chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  users: 'M9 11a4 4 0 100-8 4 4 0 000 8zM2 21a7 7 0 0114 0M17 3a4 4 0 010 8M22 21a7 7 0 00-4-6',
  cpu: 'M7 7h10v10H7zM10 2v3M14 2v3M10 19v3M14 19v3M2 10h3M2 14h3M19 10h3M19 14h3',
  spark: 'M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z',
  plus: 'M12 5v14M5 12h14',
  send: 'M4 12l16-8-6 16-2-6z',
  trash: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13',
  edit: 'M4 20h4L19 9l-4-4L4 16zM14 6l4 4',
  undo: 'M9 14L4 9l5-5M4 9h11a5 5 0 010 10h-3',
  pause: 'M8 5v14M16 5v14',
  play: 'M7 5l12 7-12 7z',
  clock: 'M12 7v5l3 3M12 21a9 9 0 110-18 9 9 0 010 18z',
  x: 'M6 6l12 12M18 6L6 18',
  up: 'M12 19V5M5 12l7-7 7 7',
  down: 'M12 5v14M19 12l-7 7-7-7',
  download: 'M12 4v11M7 10l5 5 5-5M5 20h14',
  logout: 'M15 4h4v16h-4M10 8l-4 4 4 4M6 12h11',
  search: 'M11 18a7 7 0 110-14 7 7 0 010 14zM21 21l-5-5',
  flag: 'M5 21V4M5 4h11l-2 4 2 4H5',
  refresh: 'M20 12a8 8 0 11-3-6.2M20 4v5h-5',
}
</script>

<template>
  <svg :width="size" :height="size" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"
    stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" class="icon">
    <path :d="paths[name] || paths.spark" />
  </svg>
</template>
