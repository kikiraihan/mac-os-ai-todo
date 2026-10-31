import { createRouter, createWebHistory } from 'vue-router'
import { state, loadMe, refreshData, startSync } from './store'
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
    { path: '/admin', name: 'admin', component: () => import('./views/admin/AdminOverview.vue'), meta: { admin: true, title: 'Ringkasan' } },
    { path: '/admin/pengguna', name: 'admin-users', component: () => import('./views/admin/AdminUsers.vue'), meta: { admin: true, title: 'Pengguna' } },
    { path: '/admin/model', name: 'admin-models', component: () => import('./views/admin/AdminModels.vue'), meta: { admin: true, title: 'Model AI' } },
    { path: '/admin/asisten', name: 'admin-assistant', component: () => import('./views/admin/AdminAssistant.vue'), meta: { admin: true, title: 'Asisten' } },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

let booted = false
router.beforeEach(async (to) => {
  if (!booted) {
    booted = true
    try {
      if (await loadMe()) {
        await refreshData()
        startSync()
      }
    } catch {
      /* server tidak terjangkau: tetap tampilkan halaman, pesan muncul di view */
    }
  }
  if (to.meta.public) return state.me ? { name: 'chat' } : true
  if (!state.me) return { name: 'login', query: to.fullPath !== '/' ? { next: to.fullPath } : {} }
  if (to.meta.admin && state.me.role !== 'admin') return { name: 'chat' }
  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · AI Todo` : 'AI Todo'
})

setUnauthorizedHandler(() => {
  if (state.me) {
    state.me = null
    router.push({ name: 'login' })
  }
})

export default router
