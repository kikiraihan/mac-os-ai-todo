// Keadaan bersama untuk baris yang bisa digeser (components/SwipeRow.vue).
import { ref } from 'vue'

// Baris yang sedang terbuka (hanya satu pada satu waktu).
export const openSwipe = ref(null)

// Seperti iOS: saat ada baris terbuka, ketukan di tempat lain hanya menutupnya
// (tidak ikut membuka lembar ubah / menekan tombol di bawah jari).
if (typeof document !== 'undefined') {
  let swallow = false
  document.addEventListener(
    'pointerdown',
    (e) => {
      if (openSwipe.value && !e.target.closest?.('.swipe.open')) {
        openSwipe.value = null
        swallow = true
      }
    },
    true,
  )
  document.addEventListener(
    'click',
    (e) => {
      if (!swallow) return
      swallow = false
      e.stopPropagation()
      e.preventDefault()
    },
    true,
  )
  document.addEventListener('pointerup', () => setTimeout(() => (swallow = false), 350), true)
}

// Petunjuk gestur ditampilkan sampai pengguna pernah memakai geser atau menutupnya.
const KEY = 'aitodo.swipeHint'
function read() {
  try {
    return localStorage.getItem(KEY) !== 'done'
  } catch {
    return true
  }
}
export const showSwipeHint = ref(read())
export function swipeUsed() {
  showSwipeHint.value = false
  try {
    localStorage.setItem(KEY, 'done')
  } catch {
    /* penyimpanan diblokir: petunjuk muncul lagi lain kali */
  }
}

// Layar sentuh (HP/tablet): gestur aktif, tombol ikon kecil disembunyikan.
export const touch = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches
