import { createRouter, createWebHistory } from 'vue-router'
import { state, loadMe, loadAdmin, refreshData, startSync } from './store'
import { setUnauthorizedHandler } from './api'
import LoginView from './views/LoginView.vue'
import ChatView from './views/ChatView.vue'
import TodosView from './views/TodosView.vue'
import RemindersView from './views/RemindersView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/masuk', name: 'login', component: LoginView, meta: { public: true, title: 'Masuk' } },
    { path: '/', name: 'chat', component: ChatView, meta: { title: 'Asisten' } },
    { path: '/todo', name: 'todos', component: TodosView, meta: { title: 'Todo' } },
    { path: '/pengingat', name: 'reminders', component: RemindersView, meta: { title: 'Pengingat' } },
    { path: '/ingatan', name: 'memory', component: () => import('./views/MemoryView.vue'), meta: { title: 'Ingatan AI' } },
    { path: '/pengaturan', name: 'settings', component: () => import('./views/SettingsView.vue'), meta: { title: 'Pengaturan' } },
    // Mode admin: akun & sesi terpisah dari mode pengguna (lihat server/internal/httpapi/adminauth.go).
    { path: '/admin/masuk', name: 'admin-login', component: () => import('./views/AdminLoginView.vue'), meta: { adminPublic: true, title: 'Masuk admin' } },
    { path: '/admin', name: 'admin', component: () => import('./views/admin/AdminOverview.vue'), meta: { admin: true, title: 'Ringkasan' } },
    { path: '/admin/pengguna', name: 'admin-users', component: () => import('./views/admin/AdminUsers.vue'), meta: { admin: true, title: 'Pengguna' } },
    { path: '/admin/model', name: 'admin-models', component: () => import('./views/admin/AdminModels.vue'), meta: { admin: true, title: 'Model AI' } },
    { path: '/admin/asisten', name: 'admin-assistant', component: () => import('./views/admin/AdminAssistant.vue'), meta: { admin: true, title: 'Asisten' } },
    { path: '/admin/ai-call-log', name: 'admin-ai-calls', component: () => import('./views/admin/AdminAICalls.vue'), meta: { admin: true, title: 'AI Call Log' } },
    { path: '/admin/system-log', name: 'admin-system-log', component: () => import('./views/admin/AdminSystemLogs.vue'), meta: { admin: true, title: 'System Log' } },
    { path: '/admin/akun', name: 'admin-accounts', component: () => import('./views/admin/AdminAccounts.vue'), meta: { admin: true, title: 'Akun admin' } },
    { path: '/admin/:pathMatch(.*)*', redirect: '/admin' },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

let booted = false
router.beforeEach(async (to) => {
  if (!booted) {
    booted = true
    try {
      const [isUser] = await Promise.all([loadMe(), loadAdmin()])
      if (isUser) {
        await refreshData()
        startSync()
      }
    } catch {
      /* server tidak terjangkau: tetap tampilkan halaman, pesan muncul di view */
    }
  }
  // Mode admin (/admin/...) hanya butuh sesi admin; mode pengguna hanya butuh sesi pengguna.
  if (to.meta.adminPublic) return state.admin ? { name: 'admin' } : true
  if (to.meta.admin) return state.admin ? true : { name: 'admin-login', query: to.fullPath !== '/admin' ? { next: to.fullPath } : {} }
  if (to.meta.public) return state.me ? { name: 'chat' } : true
  if (!state.me) return { name: 'login', query: to.fullPath !== '/' ? { next: to.fullPath } : {} }
  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · AI Todo` : 'AI Todo'
})

setUnauthorizedHandler((path) => {
  if (path.startsWith('/admin/')) {
    if (state.admin) {
      state.admin = null
      if (router.currentRoute.value.meta.admin) router.push({ name: 'admin-login' })
    }
    return
  }
  if (state.me) {
    state.me = null
    if (!router.currentRoute.value.meta.admin) router.push({ name: 'login' })
  }
})

export default router
