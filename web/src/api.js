// Pembungkus fetch: semua request membawa header X-AITodo (perlindungan CSRF
// yang diwajibkan server) dan cookie sesi HttpOnly.

export class ApiError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

let onUnauthorized = () => {}
export function setUnauthorizedHandler(fn) {
  onUnauthorized = fn
}

export async function api(method, path, body, { signal } = {}) {
  const headers = { 'X-AITodo': '1' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  let res
  try {
    res = await fetch('/api' + path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
    })
  } catch (e) {
    if (e.name === 'AbortError') throw e
    throw new ApiError(0, 'Tidak bisa terhubung ke server. Periksa koneksi internet.')
  }
  let data = null
  try {
    data = await res.json()
  } catch {
    data = null
  }
  if (res.status === 401 && path !== '/login') onUnauthorized()
  if (!res.ok) throw new ApiError(res.status, (data && data.error) || `HTTP ${res.status}`)
  return data
}

export const get = (p, opts) => api('GET', p, undefined, opts)
export const post = (p, b) => api('POST', p, b ?? {})
export const put = (p, b) => api('PUT', p, b ?? {})
export const del = (p) => api('DELETE', p)
