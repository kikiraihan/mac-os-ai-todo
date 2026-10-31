<script setup>
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { state } from './store'
import Icon from './components/Icon.vue'
import { today } from './dates'

const route = useRoute()
const isAdmin = computed(() => state.me?.role === 'admin')
const showShell = computed(() => state.me && !route.meta.public)
const openCount = computed(() => {
  const t = today()
  return state.todos.filter((x) => x.status === 'open' && x.dueDate && x.dueDate <= t).length
})

const userNav = [
  { to: '/', icon: 'chat', label: 'Asisten' },
  { to: '/todo', icon: 'check', label: 'Todo' },
  { to: '/pengingat', icon: 'bell', label: 'Pengingat' },
  { to: '/ingatan', icon: 'brain', label: 'Ingatan' },
  { to: '/pengaturan', icon: 'gear', label: 'Pengaturan' },
]
const adminNav = [
  { to: '/admin', icon: 'chart', label: 'Ringkasan' },
  { to: '/admin/pengguna', icon: 'users', label: 'Pengguna' },
  { to: '/admin/model', icon: 'cpu', label: 'Model AI' },
  { to: '/admin/asisten', icon: 'spark', label: 'Asisten' },
]
const mobileNav = userNav.filter((n) => n.to !== '/ingatan')
</script>

<template>
  <div v-if="showShell" class="shell">
    <aside class="sidebar">
      <div class="brand"><img src="/favicon.svg" alt="" width="28" height="28" /> AI Todo</div>
      <nav>
        <RouterLink v-for="n in userNav" :key="n.to" :to="n.to" class="nav-item" :exact-active-class="'active'">
          <Icon :name="n.icon" /> <span>{{ n.label }}</span>
          <span v-if="n.to === '/todo' && openCount" class="badge">{{ openCount }}</span>
        </RouterLink>
        <template v-if="isAdmin">
          <div class="nav-section">Admin</div>
          <RouterLink v-for="n in adminNav" :key="n.to" :to="n.to" class="nav-item" :exact-active-class="'active'">
            <Icon :name="n.icon" /> <span>{{ n.label }}</span>
          </RouterLink>
        </template>
      </nav>
      <div class="sidebar-foot">
        <span class="dot" :class="{ off: !state.online }"></span>
        {{ state.me.displayName || state.me.username }}
      </div>
    </aside>
    <main class="main">
      <div v-if="!state.online" class="offline">Offline — perubahan akan tersinkron saat koneksi kembali.</div>
      <RouterView />
    </main>
    <nav class="tabbar">
      <RouterLink v-for="n in mobileNav" :key="n.to" :to="n.to" class="tab" :exact-active-class="'active'">
        <Icon :name="n.icon" />
        <span>{{ n.label }}</span>
        <span v-if="n.to === '/todo' && openCount" class="badge">{{ openCount }}</span>
      </RouterLink>
    </nav>
  </div>
  <RouterView v-else />
  <Transition name="fade">
    <div v-if="state.toast" class="toast" :class="state.toast.kind" role="status">{{ state.toast.message }}</div>
  </Transition>
</template>
