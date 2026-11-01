// Tanggal ditangani sebagai string lokal YYYY-MM-DD / HH:MM di zona waktu
// PENGGUNA (dari server), bukan zona browser — supaya "08:00" di HP yang
// sedang di luar negeri atau di PC ber-UTC tetap berarti 08:00 di rumah.
import { state } from './store'

const days = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab']
const months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des']

const fmtCache = new Map()
function partsIn(date) {
  const tz = state.timezone || undefined
  let f = fmtCache.get(tz)
  if (!f) {
    try {
      f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    } catch {
      f = new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    }
    fmtCache.set(tz, f)
  }
  const p = Object.fromEntries(f.formatToParts(date).map((x) => [x.type, x.value]))
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}` }
}

export function ymd(d) {
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

/** Tanggal hari ini di zona pengguna. */
export function today() {
  return partsIn(new Date()).date
}

export function addDays(date, n) {
  const [y, m, d] = date.split('-').map(Number)
  return ymd(new Date(y, m - 1, d + n))
}

export function parseYmd(s) {
  const [y, m, d] = s.split('-').map(Number)
  return new Date(y, m - 1, d)
}

export function friendlyDate(s) {
  if (!s) return ''
  const t = today()
  if (s === t) return 'Hari ini'
  if (s === addDays(t, 1)) return 'Besok'
  if (s === addDays(t, -1)) return 'Kemarin'
  const d = parseYmd(s)
  let out = `${days[d.getDay()]}, ${d.getDate()} ${months[d.getMonth()]}`
  if (d.getFullYear() !== parseYmd(t).getFullYear()) out += ` ${d.getFullYear()}`
  return out
}

/** Stempel waktu server (RFC3339) → "Besok 08:00" di zona pengguna. */
export function friendlyStamp(iso) {
  if (!iso) return ''
  const p = partsIn(new Date(iso))
  return `${friendlyDate(p.date)} ${p.time}`
}

export function timeAgo(iso) {
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000)
  if (s < 60) return 'baru saja'
  if (s < 3600) return `${Math.floor(s / 60)} menit lalu`
  if (s < 86400) return `${Math.floor(s / 3600)} jam lalu`
  return friendlyStamp(iso)
}

export const weekdayNames = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu']
export const monthNames = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember']
