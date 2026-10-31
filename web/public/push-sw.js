// Handler Web Push untuk service worker hasil Workbox (lihat vite.config.js).
// Notifikasi pengingat punya tombol "Tunda 10 mnt", notifikasi todo punya
// tombol "Selesai" — keduanya memanggil API dengan cookie sesi yang sama.

self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    data = { body: event.data ? event.data.text() : '' }
  }
  const actions = []
  if (data.todoId) actions.push({ action: 'done', title: 'Selesai' })
  if (data.reminderId) actions.push({ action: 'snooze', title: 'Tunda 10 mnt' })
  event.waitUntil(
    self.registration.showNotification(data.title || 'AI Todo', {
      body: data.body || '',
      icon: '/pwa-192.png',
      badge: '/pwa-192.png',
      tag: data.tag || 'aitodo',
      renotify: true,
      actions,
      data: { url: data.url || '/', todoId: data.todoId || 0, reminderId: data.reminderId || 0 },
    }),
  )
})

function callApi(path, body) {
  return fetch('/api' + path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'X-AITodo': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  })
}

function openApp(url) {
  return self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
    for (const client of windows) {
      if ('focus' in client) {
        if ('navigate' in client) client.navigate(url).catch(() => {})
        return client.focus()
      }
    }
    return self.clients.openWindow(url)
  })
}

self.addEventListener('notificationclick', (event) => {
  const d = event.notification.data || {}
  event.notification.close()
  if (event.action === 'done' && d.todoId) {
    event.waitUntil(callApi(`/todos/${Number(d.todoId)}/complete`).catch(() => openApp('/todo')))
    return
  }
  if (event.action === 'snooze' && d.reminderId) {
    event.waitUntil(callApi(`/reminders/${Number(d.reminderId)}/snooze`, { minutes: 10 }).catch(() => openApp('/pengingat')))
    return
  }
  // Hanya buka rute di situs ini sendiri.
  const url = typeof d.url === 'string' && d.url.startsWith('/') && !d.url.startsWith('//') ? d.url : '/'
  event.waitUntil(openApp(url))
})
