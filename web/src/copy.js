// Salin isi todo sebagai teks polos: "Judul" + baris kosong + detail (bila ada) — sama dengan aplikasi Mac.
import { toast } from './store'

export const todoText = (x, titleOnly = false) => (titleOnly || !x.notes ? x.title : `${x.title}\n\n${x.notes}`)

// Catatan: format yang sama ({ title, content } → "Judul" + baris kosong + isi).
export const copyNote = (n, titleOnly = false) => copyTodo({ title: n.title, notes: n.content || '' }, titleOnly, 'isi')

export async function copyTodo(x, titleOnly = false, what = 'detail') {
  if (await copyText(todoText(x, titleOnly))) toast(titleOnly || !x.notes ? 'Judul disalin' : `Judul & ${what} disalin`)
}

// Salin teks apa adanya (mis. kiriman). Mengembalikan true kalau berhasil; gagal = toast error.
export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    // Cadangan (mis. HTTP lokal / izin clipboard ditolak): textarea sementara + execCommand.
    const ta = document.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    ta.className = 'offscreen'
    document.body.appendChild(ta)
    ta.select()
    const ok = document.execCommand('copy')
    ta.remove()
    if (!ok) {
      toast('Gagal menyalin', 'error')
      return false
    }
  }
  return true
}
