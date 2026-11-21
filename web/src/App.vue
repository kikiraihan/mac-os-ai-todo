<script setup>
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { state } from './store'
import Icon from './components/Icon.vue'
import { today } from './dates'

const route = useRoute()
// Dua mode terpisah: /admin/... = mode admin (akun admin), selain itu = mode pengguna.
const adminMode = computed(() => !!route.meta.admin)
const showShell = computed(() => (adminMode.value ? !!state.admin : !!state.me) && !route.meta.public && !route.meta.adminPublic)
const who = computed(() => (adminMode.value ? state.admin?.displayName || state.admin?.username : state.me?.displayName || state.me?.username))
const openCount = computed(() => {
  const t = today()
  return state.todos.filter((x) => x.status === 'open' && x.dueDate && x.dueDate <= t).length
})

const userNav = [
  { to: '/', icon: 'chat', label: 'Asisten' },
  { to: '/todo', icon: 'check', label: 'Todo' },
  { to: '/pengingat', icon: 'bell', label: 'Pengingat' },
  { to: '/catatan', icon: 'doc', label: 'Catatan' },
  { to: '/ingatan', icon: 'brain', label: 'Ingatan' },
  { to: '/pengaturan', icon: 'gear', label: 'Pengaturan' },
]
const adminNav = [
  { to: '/admin', icon: 'chart', label: 'Ringkasan' },
  { to: '/admin/pengguna', icon: 'users', label: 'Pengguna' },
  { to: '/admin/model', icon: 'cpu', label: 'Model AI' },
  { to: '/admin/asisten', icon: 'spark', label: 'Asisten' },
  { to: '/admin/ai-call-log', icon: 'list', label: 'AI Call Log' },
  { to: '/admin/system-log', icon: 'alert', label: 'System Log' },
  { to: '/admin/akun', icon: 'shield', label: 'Akun admin' },
]
const mobileUserNav = userNav.filter((n) => n.to !== '/ingatan')
// Di HP: log & asisten dibuka dari halaman Akun admin.
const mobileAdminNav = adminNav.filter((n) => !['/admin/asisten', '/admin/ai-call-log', '/admin/system-log'].includes(n.to))
const nav = computed(() => (adminMode.value ? adminNav : userNav))
const mobileNav = computed(() => (adminMode.value ? mobileAdminNav : mobileUserNav))
</script>

<template>
  <div v-if="showShell" class="shell" :class="{ 'admin-mode': adminMode }">
    <aside class="sidebar">
      <div class="brand">
        <img src="/favicon.svg" alt="" width="28" height="28" /> AI Todo
        <span v-if="adminMode" class="tag accent">Admin</span>
      </div>
      <nav>
        <RouterLink v-for="n in nav" :key="n.to" :to="n.to" class="nav-item" :exact-active-class="'active'">
          <Icon :name="n.icon" /> <span>{{ n.label }}</span>
          <span v-if="n.to === '/todo' && openCount" class="badge">{{ openCount }}</span>
        </RouterLink>
        <!-- Pindah mode hanya tampil kalau akun mode lain juga sudah masuk (login terpisah). -->
        <template v-if="adminMode ? state.me : state.admin">
          <div class="nav-section">Mode</div>
          <RouterLink :to="adminMode ? '/' : '/admin'" class="nav-item">
            <Icon name="swap" /> <span>{{ adminMode ? 'Ke mode pengguna' : 'Ke mode admin' }}</span>
          </RouterLink>
        </template>
      </nav>
      <div class="sidebar-foot">
        <span class="dot" :class="{ off: !state.online }"></span>
        {{ who }}
      </div>
    </aside>
    <!-- HP: menu di atas (segmented control), bukan tab bar bawah -->
    <header class="topbar">
      <nav :aria-label="adminMode ? 'Menu admin' : 'Menu'">
        <RouterLink v-for="n in mobileNav" :key="n.to" :to="n.to" class="tab" :exact-active-class="'active'">
          <Icon :name="n.icon" :size="18" />
          <span>{{ n.label }}</span>
          <span v-if="n.to === '/todo' && openCount" class="badge">{{ openCount }}</span>
        </RouterLink>
      </nav>
    </header>
    <main class="main">
      <div v-if="!state.online" class="offline">Offline — perubahan akan tersinkron saat koneksi kembali.</div>
      <RouterView />
    </main>
  </div>
  <RouterView v-else />
  <Transition name="fade">
    <div v-if="state.toast" class="toast" :class="state.toast.kind" role="status">{{ state.toast.message }}</div>
  </Transition>
</template>
