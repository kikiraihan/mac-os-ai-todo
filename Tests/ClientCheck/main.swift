// Uji klien Mac (Client.swift) terhadap server Go asli — jalan di Linux & macOS.
//   AITODO_URL=http://127.0.0.1:8099 AITODO_USER=admin AITODO_PASS=... [AITODO_ADMIN_PASS=...] ./client-check
// Dipakai oleh scripts/test-client.sh.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let env = ProcessInfo.processInfo.environment
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "✅ " : "❌ ") + what)
    if !ok { failures += 1 }
}

/// Jalankan panggilan async dan tunggu hasilnya.
func wait<T>(_ f: (@escaping (Result<T, APIError>) -> Void) -> Void) -> Result<T, APIError> {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<T, APIError>!
    f { out = $0; sem.signal() }
    sem.wait()
    return out
}

// URL: https wajib kecuali localhost
check(ServerURL.normalize("todo.katili.dev")?.absoluteString == "https://todo.katili.dev", "normalisasi tanpa skema → https")
check(ServerURL.normalize("http://todo.katili.dev") == nil, "http ke host publik ditolak")
check(ServerURL.normalize("https://user:pw@todo.katili.dev") == nil, "URL dengan kredensial ditolak")
check(ServerURL.normalize("http://127.0.0.1:8080/")?.absoluteString == "http://127.0.0.1:8080", "http localhost boleh")

// Urutan manual (tahan ⌃ lalu seret di popover): item tanpa urutan tetap di posisi bawaannya
check(ManualOrder.apply([1, 2, 3, 4] as [Int64], order: [], id: { $0 }) == [1, 2, 3, 4], "urutan manual kosong → urutan bawaan")
check(ManualOrder.apply([1, 2, 3, 4] as [Int64], order: [4, 3, 2, 1], id: { $0 }) == [4, 3, 2, 1], "urutan manual dipakai")
check(ManualOrder.apply([1, 5, 2, 3] as [Int64], order: [3, 1, 2], id: { $0 }) == [3, 5, 1, 2],
      "item baru (tanpa urutan) tetap di posisi bawaannya")
let placed = ManualOrder.place([3, 1], in: [9, 1, 7, 3, 8], keep: [1, 3, 7, 9])
check(placed == [9, 7, 3, 1], "simpan urutan kelompok: kelompok lain tetap, id yang hilang dibuang (\(placed))")
check(ManualOrder.reset([3, 1], in: [9, 3, 1]) == [9], "kembalikan kelompok ke urutan bawaan")

// Pintasan papan ketik (Pengaturan → Pintasan): bawaan, simpan, validasi, pencocokan
let defKeys = Shortcuts.resolve([:])
check(defKeys[.toggleChat]?.display == "⌥⌘T" && defKeys[.newItem]?.display == "⌘N" && defKeys[.nextTab]?.display == "⌃⇥",
      "pintasan bawaan sama dengan sebelumnya (⌥⌘T, ⌘N, ⌃⇥)")
check(Shortcuts.resolve([:], chatHotkeyOff: true)[.toggleChat] == nil, "sakelar lama ⌥⌘T mati → pintasan asisten kosong")
check(Shortcuts.resolve(["toggleChat": ""])[.toggleChat] == nil, "\"\" = pintasan dimatikan")
let kc = KeyCombo(keyCode: 0x29, chars: ";", mods: KeyCombo.command | KeyCombo.shift)
check(KeyCombo(stored: kc.stored) == kc && kc.display == "⇧⌘;", "simpan & baca ulang pintasan (\(kc.stored))")
check(Shortcuts.resolve(["search": kc.stored])[.search] == kc, "pintasan tersimpan dipakai")
check(Shortcuts.validate(KeyCombo(keyCode: 0x2D, chars: "n", mods: 0), for: .search, in: defKeys) != nil, "tanpa ⌘/⌃ ditolak")
check(Shortcuts.validate(KeyCombo(keyCode: 0x08, chars: "c", mods: KeyCombo.command), for: .search, in: defKeys) != nil, "⌘C (Salin) ditolak")
check(Shortcuts.validate(KeyCombo(keyCode: 0x2D, chars: "n", mods: KeyCombo.command), for: .search, in: defKeys) != nil,
      "bentrok dengan pintasan lain ditolak")
check(Shortcuts.validate(KeyCombo(keyCode: 0x2D, chars: "n", mods: KeyCombo.command), for: .newItem, in: defKeys) == nil,
      "pintasan yang sama untuk aksinya sendiri boleh")
check(Shortcuts.validate(KeyCombo(keyCode: 0x60, chars: "x", mods: 0), for: .search, in: defKeys) == nil, "F5 tanpa modifier boleh")
check(Shortcuts.action(keyCode: 0x13, mods: KeyCombo.command, in: defKeys) == .tabTodo, "⌘2 → tab Todo")
check(Shortcuts.action(keyCode: 0x11, mods: KeyCombo.command | KeyCombo.option, in: defKeys) == nil, "pintasan global tidak dicocokkan lokal")

// Cari di popover: semua kata harus ada (urutan bebas), abaikan huruf besar/kecil & aksen
let sTodo = Todo(id: 1, title: "Meeting Singapay dengan Irish", notes: "bahas split payment", status: "open",
                 priority: "", list: "Kerja", dueDate: "", dueTime: "")
check(TextSearch.matches(sTodo, query: ""), "cari kosong → semua cocok")
check(TextSearch.matches(sTodo, query: "  singapay  "), "cari judul, abaikan huruf besar & spasi")
check(TextSearch.matches(sTodo, query: "payment split"), "cari di detail, urutan kata bebas")
check(TextSearch.matches(sTodo, query: "kerja irish"), "cari kategori + judul")
check(!TextSearch.matches(sTodo, query: "singapay biller"), "satu kata tidak ada → tidak cocok")
check(TextSearch.matches(["Café Kopi"], query: "cafe"), "aksen diabaikan")
let sRem = Reminder(id: 2, todoId: 1, title: "Siapkan bahan", message: "slide demo", nextFireAt: "", active: true, scheduleText: "Tiap hari 08:00")
check(TextSearch.matches(sRem, todoTitle: sTodo.title, query: "singapay"), "pengingat cocok lewat judul todo terkait")
check(TextSearch.matches(sRem, query: "demo tiap"), "pengingat: cari pesan & jadwal")
check(!TextSearch.matches(sRem, query: "singapay"), "tanpa judul todo terkait → tidak cocok")

guard let base = ServerURL.normalize(env["AITODO_URL"] ?? ""), let user = env["AITODO_USER"], let pass = env["AITODO_PASS"] else {
    print("set AITODO_URL, AITODO_USER, AITODO_PASS"); exit(2)
}

let api = APIClient()
// Password akun admin (terpisah) tidak boleh membuka akun pengguna dengan username sama.
if let adminPass = env["AITODO_ADMIN_PASS"] {
    let r = wait { api.loginDevice(base: base, username: user, password: adminPass, device: "Tes", completion: $0) }
    if case .failure(.server(401, _)) = r { check(true, "password admin → ditolak di login pengguna") }
    else { check(false, "password admin → ditolak di login pengguna (\(r))") }
}
let bad = wait { api.loginDevice(base: base, username: user, password: "salah-sekali-ya", device: "Tes", completion: $0) }
if case .failure(.server(401, _)) = bad { check(true, "password salah → 401") } else { check(false, "password salah → 401 (\(bad))") }

guard case .success(let login) = wait({ api.loginDevice(base: base, username: user, password: pass, device: "MacBook Tes", completion: $0) }) else {
    print("login gagal"); exit(1)
}
check(login.token.hasPrefix("ait_"), "login perangkat mengembalikan token")
api.configure(base: base, token: login.token)

guard case .success(let me) = wait(api.me) else { print("me gagal"); exit(1) }
check(me.user.username == user, "GET /me (zona \(me.timezone))")
check(me.ai != nil, "GET /me menyertakan info model AI")
guard case .success(let prefRes) = wait({ api.setDefaultModel(0, $0) }) else { print("setDefaultModel gagal"); exit(1) }
check((prefRes.prefs.defaultModelId ?? 0) == 0, "PUT /me/prefs defaultModelId=0")
let badModel = wait { api.setDefaultModel(999_999, $0) }
if case .failure(.server(400, _)) = badModel { check(true, "PUT /me/prefs model tidak ada → 400") }
else { check(false, "PUT /me/prefs model tidak ada → 400 (\(badModel))") }
let tz = Clock.zone(me.timezone)

let now = Date()
var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
let today = Clock.ymd(now, tz)
let tomorrow = Clock.ymd(cal.date(byAdding: .day, value: 1, to: now)!, tz)
let yesterday = Clock.ymd(cal.date(byAdding: .day, value: -1, to: now)!, tz)

guard case .success(let r0) = wait(api.openTodos) else { print("todos gagal"); exit(1) }
let rev0 = r0.rev

// long-poll harus bangun saat ada perubahan dari "perangkat lain"
let sem = DispatchSemaphore(value: 0)
var pollRev: Int64 = 0
let pollStart = Date()
api.changes(since: rev0) { r in if case .success(let v) = r { pollRev = v.rev }; sem.signal() }
Thread.sleep(forTimeInterval: 0.5)

guard case .success(let t1) = wait({ api.createTodo(title: "Telpon bengkel (tes Mac)", dueDate: tomorrow, dueTime: "09:00", $0) }) else { print("create gagal"); exit(1) }
_ = sem.wait(timeout: .now() + 10)
check(pollRev > rev0 && Date().timeIntervalSince(pollStart) < 8, "long-poll bangun saat todo dibuat")

_ = wait { api.createTodo(title: "Bayar listrik (tes Mac)", dueDate: yesterday, dueTime: "", $0) }
_ = wait { api.createTodo(title: "Beli galon (tes Mac)", dueDate: today, dueTime: "", $0) }

guard case .success(let r1) = wait(api.openTodos) else { exit(1) }
let buckets = TodoBuckets(r1.todos, now: now, tz: tz)
check(buckets.overdue.contains { $0.title.hasPrefix("Bayar listrik") }, "kelompok terlambat")
check(buckets.today.contains { $0.title.hasPrefix("Beli galon") }, "kelompok hari ini")
check(buckets.upcoming.contains { $0.id == t1.todo.id }, "kelompok akan datang")
check(buckets.badge >= 2, "badge = hari ini + terlambat (\(buckets.badge))")
check(buckets.upcomingByDay.first?.date == tomorrow && buckets.upcomingByDay.first?.todos.contains { $0.id == t1.todo.id } == true,
      "tampilan Semua: todo mendatang dikelompokkan per tanggal")
check(buckets.total == buckets.badge + buckets.upcoming.count + buckets.noDate.count, "jumlah semua todo terbuka")

// asisten tanpa AI: shortcut membuat pengingat lewat chat tidak mungkin, jadi pakai /todo + undo
guard case .success(let rep) = wait({ api.chat("/todo tes dari Mac", $0) }) else { print("chat gagal"); exit(1) }
check(rep.batch?.status == "applied" && rep.batch?.undoable == true, "chat /todo → kartu aksi bisa di-undo")
if let b = rep.batch, case .success(let u) = wait({ api.batch(b.id, "undo", $0) }) {
    check(u.batch.status == "undone", "undo dari Mac")
} else { check(false, "undo dari Mac") }
guard case .success(let hist) = wait(api.chatHistory) else { exit(1) }
check(hist.messages.count >= 2 && !hist.batches.isEmpty, "riwayat chat + kartu aksi")

// hapus riwayat chat (tombol tempat sampah di popover)
if case .success = wait(api.clearChat), case .success(let empty) = wait(api.chatHistory) {
    check(empty.messages.count == 0 && empty.batches.isEmpty, "hapus riwayat chat → riwayat & kartu aksi kosong")
} else { check(false, "hapus riwayat chat") }

// rencana notifikasi: tenggat todo besok 09:00 → 08:50
guard case .success(let up) = wait({ api.upcoming(hours: 48, $0) }) else { exit(1) }
let plan = NotificationPlan.build(occurrences: up.occurrences, todos: r1.todos, prefs: me.prefs, tz: tz, now: now)
let due = plan.first { $0.todoId == t1.todo.id }
check(due.map { Clock.hm($0.fireAt, tz) == "08:50" } ?? false, "notifikasi tenggat dijadwalkan 10 menit sebelumnya")

// pengingat: yang terkait todo (ikon 🔔 di baris todo) vs pengingat lepas (tab Pengingat)
let onceAt = Clock.ymd(now.addingTimeInterval(86400), tz) + "T07:30"
for (title, todo) in [("Minum obat", nil), ("Ingat telpon bengkel", t1.todo.id)] as [(String, Int64?)] {
    var body: [String: Any] = ["title": title, "schedule": ["kind": "once", "at": onceAt]]
    if let todo { body["todoId"] = todo }
    if case .failure(let e) = wait({ api.raw("POST", "/reminders", body: body, completion: $0) }) { check(false, "buat pengingat: \(e)") }
}
if case .success(let rs) = wait(api.reminders) {
    let loose = rs.reminders.first { $0.title == "Minum obat" }
    let linked = rs.reminders.first { $0.title == "Ingat telpon bengkel" }
    check(loose?.todoId == nil && loose?.active == true && !(loose?.nextFireAt.isEmpty ?? true)
          && !(loose?.scheduleText.isEmpty ?? true), "pengingat lepas: tanpa todo, aktif, ada jadwal")
    check(linked?.todoId == t1.todo.id, "pengingat terkait todo membawa todoId")
    check(loose?.schedule?.kind == "once" && loose?.schedule?.at == onceAt && loose?.ended == false, "jadwal pengingat terbaca")
    // kelola pengingat dari Pengaturan → Pengingat / tab Pengingat popover
    if let loose {
        if case .success(let p) = wait({ api.updateReminder(loose.id, ["active": false], $0) }) {
            check(!p.reminder.active && p.reminder.nextFireAt.isEmpty, "tandai selesai (nonaktif)")
        } else { check(false, "tandai selesai pengingat") }
        if case .success(let p) = wait({ api.updateReminder(loose.id, ["active": true], $0) }) {
            check(p.reminder.active && !p.reminder.nextFireAt.isEmpty, "aktifkan lagi")
        } else { check(false, "aktifkan lagi pengingat") }
        let daily = ReminderSchedule(kind: "daily", time: "07:15", every: 1)
        if case .success(let p) = wait({ api.updateReminder(loose.id, ["title": "Minum obat pagi", "todoId": t1.todo.id,
                                                                        "schedule": daily.body], $0) }) {
            check(p.reminder.title == "Minum obat pagi" && p.reminder.todoId == t1.todo.id && p.reminder.schedule?.kind == "daily"
                  && p.reminder.schedule?.time == "07:15", "ubah judul, kaitkan ke todo, jadwal harian")
        } else { check(false, "ubah pengingat") }
        let past = ReminderSchedule(kind: "once", at: Clock.ymd(now.addingTimeInterval(-86400), tz) + "T07:00")
        if case .failure = wait({ api.updateReminder(loose.id, ["schedule": past.body], $0) }) {
            check(true, "jadwal yang sudah lewat ditolak server")
        } else { check(false, "jadwal yang sudah lewat ditolak server") }
        if case .success = wait({ api.deleteReminder(loose.id, $0) }), case .success(let rs2) = wait(api.reminders) {
            check(!rs2.reminders.contains { $0.id == loose.id }, "hapus pengingat")
        } else { check(false, "hapus pengingat") }
    }
    let weekly = ReminderSchedule(kind: "weekly", time: "18:00", every: 1, weekdays: [1, 3, 5])
    if case .success(let c) = wait({ api.createReminder(["title": "Olahraga", "schedule": weekly.body], $0) }) {
        check(c.reminder.active && c.reminder.todoId == nil && c.reminder.schedule?.weekdays == [1, 3, 5], "buat pengingat mingguan")
        _ = wait({ api.deleteReminder(c.reminder.id, $0) })
    } else { check(false, "buat pengingat mingguan") }
} else { check(false, "daftar pengingat") }

// ubah todo dari tab Manual (mode ubah ⌥)
if case .success(let ed) = wait({ api.updateTodo(t1.todo.id, ["title": "Telpon bengkel (diubah)", "list": "Rumah",
                                                             "dueDate": today, "dueTime": "14:30", "priority": "high"], $0) }) {
    check(ed.todo.title == "Telpon bengkel (diubah)" && ed.todo.list == "Rumah" && ed.todo.dueDate == today
          && ed.todo.dueTime == "14:30" && ed.todo.priority == "high", "ubah judul, kategori, tanggal, jam, prioritas")
} else { check(false, "ubah todo") }
if case .success(let ed) = wait({ api.updateTodo(t1.todo.id, ["dueDate": "", "dueTime": ""], $0) }) {
    check(ed.todo.dueDate.isEmpty && ed.todo.dueTime.isEmpty && ed.todo.list == "Rumah", "hapus tenggat, kolom lain tetap")
} else { check(false, "hapus tenggat") }
if case .failure = wait({ api.updateTodo(t1.todo.id, ["title": "  "], $0) }) {
    check(true, "judul kosong ditolak server")
} else { check(false, "judul kosong ditolak server") }

// selesaikan todo
if case .success(let done) = wait({ api.complete(todo: t1.todo.id, $0) }) {
    check(done.todo.status == "done", "tandai selesai")
} else { check(false, "tandai selesai") }
if case .success(let d) = wait({ api.todos(status: "done", $0) }) {
    check(d.todos.first { $0.id == t1.todo.id }.map { !($0.completedAt ?? "").isEmpty } ?? false, "daftar Selesai membawa completedAt")
} else { check(false, "daftar todo selesai") }

// kelola todo lengkap (tab Todo di Pengaturan Mac)
if case .success(let d) = wait({ api.todos(status: "done", $0) }) {
    check(d.todos.contains { $0.id == t1.todo.id }, "daftar todo selesai")
} else { check(false, "daftar todo selesai") }
if case .success(let ro) = wait({ api.reopen(todo: t1.todo.id, $0) }) {
    check(ro.todo.status == "open", "buka lagi todo selesai")
} else { check(false, "buka lagi todo selesai") }
if case .success(let full) = wait({ api.createTodo(["title": "Tes lengkap Mac", "notes": "catatan", "list": "Kantor",
                                                     "priority": "low", "dueDate": tomorrow, "dueTime": "07:15"], $0) }) {
    let t = full.todo
    check(t.notes == "catatan" && t.list == "Kantor" && t.priority == "low" && t.dueTime == "07:15", "buat todo dengan kolom lengkap")
    if case .success = wait({ api.deleteTodo(t.id, $0) }), case .success(let open) = wait(api.openTodos) {
        check(!open.todos.contains { $0.id == t.id }, "hapus todo")
    } else { check(false, "hapus todo") }
} else { check(false, "buat todo dengan kolom lengkap") }
_ = wait { api.complete(todo: t1.todo.id, $0) }
if case .success(let a) = wait(api.archiveDone), case .success(let d2) = wait({ api.todos(status: "done", $0) }) {
    check(a.archived >= 1 && d2.todos.isEmpty, "arsipkan semua yang selesai (\(a.archived))")
} else { check(false, "arsipkan yang selesai") }

// ingatan AI (tab Ingatan di Pengaturan Mac)
guard case .success(let m0) = wait(api.memories) else { print("ingatan gagal"); exit(1) }
check(m0.limits["profile"] ?? 0 > 0 && m0.maxEntry > 0, "GET /memory: batas & pemakaian")
if case .success(let added) = wait({ api.addMemory(target: "profile", content: "Suka kopi tanpa gula", $0) }) {
    check(added.memory.target == "profile" && added.memory.source == "manual", "tambah ingatan")
    if case .success(let upd) = wait({ api.updateMemory(added.memory.id, content: "Suka kopi susu", $0) }) {
        check(upd.memory.content == "Suka kopi susu", "ubah ingatan")
    } else { check(false, "ubah ingatan") }
    if case .success(let md) = wait(api.exportMemory) { check(md.contains("Suka kopi susu"), "ekspor ingatan .md") }
    else { check(false, "ekspor ingatan .md") }
    guard case .success(let m1) = wait(api.memories) else { exit(1) }
    check(m1.items("profile").count == m0.items("profile").count + 1 && (m1.usage["profile"] ?? 0) > 0, "daftar ingatan per bagian")
    if case .success = wait({ api.deleteMemory(added.memory.id, $0) }) {
        guard case .success(let m2) = wait(api.memories) else { exit(1) }
        check(!m2.memories.contains { $0.id == added.memory.id }, "hapus ingatan")
    } else { check(false, "hapus ingatan") }
} else { check(false, "tambah ingatan") }
if case .failure(.server(400, let msg)) = wait({ api.addMemory(target: "notes", content: "password wifi: rahasia123", $0) }) {
    check(!msg.isEmpty, "ingatan berisi rahasia ditolak (\(msg))")
} else { check(false, "ingatan berisi rahasia ditolak") }

// catatan (tab Catatan): tambah (judul otomatis dari link), sematkan, cari, hapus
if case .success(let created) = wait({ api.createNote(["content": "https://contoh.id/resep\n- cabai", "list": "Link"], $0) }) {
    check(created.note.title == "https://contoh.id/resep" && !created.note.pinned, "tambah catatan (judul otomatis)")
    if case .success(let upd) = wait({ api.updateNote(created.note.id, ["pinned": true, "title": "Resep sambal"], $0) }) {
        check(upd.note.pinned && upd.note.title == "Resep sambal" && upd.note.content.contains("cabai"), "ubah & sematkan catatan")
    } else { check(false, "ubah & sematkan catatan") }
    guard case .success(let ns) = wait(api.notes) else { exit(1) }
    check(ns.notes.first?.id == created.note.id, "GET /notes: yang disematkan paling atas")
    check(ns.notes.first.map { TextSearch.matches($0, query: "SAMBAL link") } == true, "cari catatan (judul + kategori)")
    if case .success = wait({ api.deleteNote(created.note.id, $0) }),
       case .success(let after) = wait(api.notes) {
        check(!after.notes.contains { $0.id == created.note.id }, "hapus catatan")
    } else { check(false, "hapus catatan") }
} else { check(false, "tambah catatan (judul otomatis)") }
if case .failure(.server(400, _)) = wait({ api.createNote(["title": " "], $0) }) { check(true, "catatan kosong ditolak") }
else { check(false, "catatan kosong ditolak") }
check(defKeys[.tabNotes]?.display == "⌘4", "pintasan tab Catatan bawaan ⌘4")

// kiriman: Mac mengirim → perangkat lain (HP) mendapat notifikasi kotak masuk dengan teks Salin; pengirim tidak
let phone = APIClient()
if case .success(let pl) = wait({ phone.loginDevice(base: base, username: user, password: pass, device: "Pixel Tes", completion: $0) }) {
    phone.configure(base: base, token: pl.token)
    guard case .success(let start) = wait({ phone.inbox(after: nil, $0) }),
          case .success(let mine0) = wait({ api.inbox(after: nil, $0) }) else { exit(1) }
    check(start.items.isEmpty, "kotak masuk awal tanpa isi lama")
    if case .success(let sent) = wait({ api.sendClip("git pull --rebase\n", $0) }) {
        check(sent.clip.device == "MacBook Tes" && sent.clip.content == "git pull --rebase\n", "kirim kiriman dari Mac")
        if case .success(let got) = wait({ phone.inbox(after: start.last, $0) }) {
            let c = ClipInbox.clips(got.items)
            check(c.count == 1 && c[0].text == "git pull --rebase\n" && c[0].clipId == sent.clip.id, "HP menerima kiriman + teks Salin")
            check(ClipInbox.next(after: start.last, inbox: got) == c[0].id, "posisi baca kotak masuk maju")
        } else { check(false, "HP menerima kiriman + teks Salin") }
        if case .success(let mine) = wait({ api.inbox(after: mine0.last, $0) }) {
            check(ClipInbox.clips(mine.items).isEmpty, "pengirim tidak menerima kirimannya sendiri")
        } else { check(false, "pengirim tidak menerima kirimannya sendiri") }
        if case .success(let one) = wait({ phone.clip(sent.clip.id, $0) }) { check(one.clip.id == sent.clip.id, "ambil kiriman (teks panjang)") }
        else { check(false, "ambil kiriman (teks panjang)") }
    } else { check(false, "kirim kiriman dari Mac") }
    if case .failure(.server(400, _)) = wait({ api.sendClip("   ", $0) }) { check(true, "kiriman kosong ditolak") }
    else { check(false, "kiriman kosong ditolak") }
} else { check(false, "login perangkat kedua") }

// pembaruan aplikasi lewat server: server tes tidak diatur (GITHUB_RELEASE_REPO kosong) → 501 berpesan
if case .failure(.server(501, let msg)) = wait(api.macRelease) {
    check(msg.contains("GITHUB_RELEASE_REPO"), "pembaruan lewat server belum diatur → 501")
} else { check(false, "pembaruan lewat server belum diatur → 501") }
if case .failure(.server(404, _)) = wait({ api.macDownload("lain.txt", $0) }) { check(true, "unduh file rilis asing ditolak") }
else { check(false, "unduh file rilis asing ditolak") }

// token dicabut → unauthorized
_ = wait(api.logout)
if case .failure(.unauthorized) = wait(api.me) { check(true, "setelah logout token tidak berlaku") } else { check(false, "setelah logout token tidak berlaku") }

print(failures == 0 ? "\nSEMUA LULUS" : "\n\(failures) GAGAL")
exit(failures == 0 ? 0 : 1)
