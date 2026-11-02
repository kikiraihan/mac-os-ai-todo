// Date / time / datetime picker untuk semua input tanggal & jam di web.
//
// Input tetap native (<input type="date|time|datetime-local">) supaya rapi, mendukung keyboard,
// dan di iPhone/iPad memakai roda bawaan sistem. Di desktop, Chrome hanya membuka picker kalau
// ikon kecil di ujung kolom diklik; di sini klik di mana saja pada kolom langsung membuka picker
// (showPicker). Satu listener global → berlaku juga untuk form yang ditambahkan nanti.

const TYPES = new Set(['date', 'time', 'datetime-local'])

export function isPickerInput(el) {
  return el instanceof HTMLInputElement && TYPES.has(el.type) && !el.disabled && !el.readOnly
}

export function installPickers(doc = document) {
  // Layar sentuh: sistem sudah membuka picker sendiri saat kolom diketuk.
  const finePointer = typeof matchMedia === 'function' && matchMedia('(pointer: fine)').matches
  if (!finePointer) return
  doc.addEventListener('click', (e) => {
    const el = e.target
    if (!isPickerInput(el) || typeof el.showPicker !== 'function') return
    try {
      el.showPicker()
    } catch {
      /* browser menolak (mis. bukan gesture pengguna): biarkan perilaku bawaan */
    }
  })
}
