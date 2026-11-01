// Uji klien Mac (Client.swift) terhadap server Go asli — jalan di Linux & macOS.
//   AITODO_URL=http://127.0.0.1:8099 AITODO_USER=admin AITODO_PASS=... ./client-check
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

guard let base = ServerURL.normalize(env["AITODO_URL"] ?? ""), let user = env["AITODO_USER"], let pass = env["AITODO_PASS"] else {
    print("set AITODO_URL, AITODO_USER, AITODO_PASS"); exit(2)
}

let api = APIClient()
let bad = wait { api.loginDevice(base: base, username: user, password: "salah-sekali-ya", device: "Tes", completion: $0) }
if case .failure(.server(401, _)) = bad { check(true, "password salah → 401") } else { check(false, "password salah → 401 (\(bad))") }

guard case .success(let login) = wait({ api.loginDevice(base: base, username: user, password: pass, device: "MacBook Tes", completion: $0) }) else {
    print("login gagal"); exit(1)
}
check(login.token.hasPrefix("ait_"), "login perangkat mengembalikan token")
api.configure(base: base, token: login.token)

guard case .success(let me) = wait(api.me) else { print("me gagal"); exit(1) }
check(me.user.username == user, "GET /me (zona \(me.timezone))")
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

// asisten tanpa AI: shortcut membuat pengingat lewat chat tidak mungkin, jadi pakai /todo + undo
guard case .success(let rep) = wait({ api.chat("/todo tes dari Mac", $0) }) else { print("chat gagal"); exit(1) }
check(rep.batch?.status == "applied" && rep.batch?.undoable == true, "chat /todo → kartu aksi bisa di-undo")
if let b = rep.batch, case .success(let u) = wait({ api.batch(b.id, "undo", $0) }) {
    check(u.batch.status == "undone", "undo dari Mac")
} else { check(false, "undo dari Mac") }
guard case .success(let hist) = wait(api.chatHistory) else { exit(1) }
check(hist.messages.count >= 2 && !hist.batches.isEmpty, "riwayat chat + kartu aksi")

// rencana notifikasi: tenggat todo besok 09:00 → 08:50
guard case .success(let up) = wait({ api.upcoming(hours: 48, $0) }) else { exit(1) }
let plan = NotificationPlan.build(occurrences: up.occurrences, todos: r1.todos, prefs: me.prefs, tz: tz, now: now)
let due = plan.first { $0.todoId == t1.todo.id }
check(due.map { Clock.hm($0.fireAt, tz) == "08:50" } ?? false, "notifikasi tenggat dijadwalkan 10 menit sebelumnya")

// selesaikan todo
if case .success(let done) = wait({ api.complete(todo: t1.todo.id, $0) }) {
    check(done.todo.status == "done", "tandai selesai")
} else { check(false, "tandai selesai") }

// token dicabut → unauthorized
_ = wait(api.logout)
if case .failure(.unauthorized) = wait(api.me) { check(true, "setelah logout token tidak berlaku") } else { check(false, "setelah logout token tidak berlaku") }

print(failures == 0 ? "\nSEMUA LULUS" : "\n\(failures) GAGAL")
exit(failures == 0 ? 0 : 1)
