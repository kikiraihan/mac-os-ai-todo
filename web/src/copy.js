// Salin isi todo sebagai teks polos: "Judul" + baris kosong + detail (bila ada) — sama dengan aplikasi Mac.
import { toast } from './store'

export const todoText = (x, titleOnly = false) => (titleOnly || !x.notes ? x.title : `${x.title}\n\n${x.notes}`)

export async function copyTodo(x, titleOnly = false) {
  const text = todoText(x, titleOnly)
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
    if (!ok) return toast('Gagal menyalin', 'error')
  }
  toast(titleOnly || !x.notes ? 'Judul disalin' : 'Judul & detail disalin')
}
