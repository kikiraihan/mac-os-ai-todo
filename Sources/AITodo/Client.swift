// Klien server AI Todo — hanya Foundation (tanpa AppKit), jadi bisa dikompilasi
// & diuji di Linux terhadap server Go asli (lihat scripts/test-client.sh).
//
// Keamanan: token perangkat dikirim sebagai "Authorization: Bearer", tidak
// pernah ditulis ke log; server wajib HTTPS kecuali localhost (pengembangan);
// redirect tidak diikuti supaya token tidak terkirim ke host lain.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Model

struct User: Codable {
    let id: Int64
    let username: String
    let displayName: String
    let role: String
}

struct Prefs: Codable {
    var briefTime: String
    var nudgeTime: String
    var hideContent: Bool
    var dueNotify: Bool
}

struct Me: Codable {
    let user: User
    let timezone: String
    let prefs: Prefs
    let version: String?
}

struct Todo: Codable, Equatable {
    let id: Int64
    var title: String
    var notes: String
    var status: String
    var priority: String
    var list: String
    var dueDate: String
    var dueTime: String
}

struct Occurrence: Codable, Equatable {
    let reminderId: Int64
    let todoId: Int64?
    let title: String
    let body: String
    let at: String
}

struct ChatMessage: Codable {
    let id: Int64
    let role: String
    let content: String
    let batchId: Int64?
    let model: String?
    let createdAt: String
}

struct BatchItem: Codable {
    let op: String
    let summary: String
}

struct BatchView: Codable {
    let id: Int64
    let status: String
    let items: [BatchItem]
    let undoable: Bool
    let expiresAt: String?
}

struct ChatReply: Codable {
    let user: ChatMessage
    let assistant: ChatMessage
    let batch: BatchView?
}

struct ChatPage: Codable {
    let messages: [ChatMessage]
    let batches: [String: BatchView]
}

// MARK: - Error

enum APIError: Error, CustomStringConvertible {
    case notConnected
    case insecureURL
    case network(String)
    case unauthorized
    case server(Int, String)
    case decode(String)

    var description: String {
        switch self {
        case .notConnected: return "Belum terhubung ke server"
        case .insecureURL: return "Alamat server harus https:// (http hanya untuk localhost)"
        case .network(let m): return "Tidak bisa terhubung: \(m)"
        case .unauthorized: return "Sesi tidak berlaku lagi, hubungkan ulang"
        case .server(let code, let m): return m.isEmpty ? "Server menjawab HTTP \(code)" : m
        case .decode(let m): return "Balasan server tidak dikenali: \(m)"
        }
    }
}

// MARK: - URL server

enum ServerURL {
    /// Rapikan & validasi alamat server. https wajib, kecuali localhost/127.0.0.1.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard u.scheme == "https" || (u.scheme == "http" && local) else { return nil }
        return u
    }
}

/// Menolak redirect: token Bearer tidak boleh ikut terkirim ke host lain.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Klien

final class APIClient {
    private(set) var base: URL?
    private(set) var token: String?
    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral // tanpa cookie/cache di disk
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 100
        session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }

    func configure(base: URL?, token: String?) {
        self.base = base
        self.token = token
    }

    var isConfigured: Bool { base != nil && token != nil }

    static let decoder = JSONDecoder()

    /// Satu request JSON. completion dipanggil di antrean URLSession (bukan main).
    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30,
                            auth: Bool = true, as type: T.Type, completion: @escaping (Result<T, APIError>) -> Void) {
        guard let base else { return completion(.failure(.notConnected)) }
        guard let url = URL(string: base.absoluteString + "/api" + path) else {
            return completion(.failure(.network("alamat tidak valid")))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("1", forHTTPHeaderField: "X-AITodo")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AITodo-Mac", forHTTPHeaderField: "User-Agent")
        if auth {
            guard let token else { return completion(.failure(.notConnected)) }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
        }
        session.dataTask(with: req) { data, resp, err in
            if let err { return completion(.failure(.network(err.localizedDescription))) }
            guard let http = resp as? HTTPURLResponse else { return completion(.failure(.network("tanpa balasan"))) }
            let data = data ?? Data()
            if http.statusCode == 401 && auth { return completion(.failure(.unauthorized)) }
            guard (200..<300).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
                return completion(.failure(.server(http.statusCode, msg)))
            }
            do { completion(.success(try APIClient.decoder.decode(T.self, from: data))) }
            catch { completion(.failure(.decode(String(describing: error)))) }
        }.resume()
    }

    // MARK: Endpoint

    struct DeviceLogin: Decodable { let token: String; let user: User }

    /// Login dengan password → token perangkat (tidak menyimpan password).
    func loginDevice(base: URL, username: String, password: String, device: String,
                     completion: @escaping (Result<DeviceLogin, APIError>) -> Void) {
        self.base = base
        send("POST", "/login/device", body: ["username": username, "password": password, "device": device],
             auth: false, as: DeviceLogin.self, completion: completion)
    }

    func me(_ c: @escaping (Result<Me, APIError>) -> Void) { send("GET", "/me", as: Me.self, completion: c) }

    struct Todos: Decodable { let todos: [Todo]; let rev: Int64 }
    func openTodos(_ c: @escaping (Result<Todos, APIError>) -> Void) {
        send("GET", "/todos?status=open", as: Todos.self, completion: c)
    }

    struct Upcoming: Decodable { let occurrences: [Occurrence]; let rev: Int64 }
    func upcoming(hours: Int, _ c: @escaping (Result<Upcoming, APIError>) -> Void) {
        send("GET", "/reminders/upcoming?hours=\(hours)", as: Upcoming.self, completion: c)
    }

    struct Rev: Decodable { let rev: Int64 }
    /// Long-poll: kembali segera kalau ada perubahan, atau setelah ±25 detik.
    func changes(since: Int64, _ c: @escaping (Result<Rev, APIError>) -> Void) {
        send("GET", "/changes?since=\(since)&wait=1", timeout: 60, as: Rev.self, completion: c)
    }

    struct TodoResult: Decodable { let todo: Todo }
    func createTodo(title: String, dueDate: String, dueTime: String, _ c: @escaping (Result<TodoResult, APIError>) -> Void) {
        send("POST", "/todos", body: ["title": title, "dueDate": dueDate, "dueTime": dueTime], as: TodoResult.self, completion: c)
    }

    func complete(todo id: Int64, _ c: @escaping (Result<TodoResult, APIError>) -> Void) {
        send("POST", "/todos/\(id)/complete", as: TodoResult.self, completion: c)
    }

    struct Ok: Decodable {}
    func snooze(reminder id: Int64, minutes: Int, _ c: @escaping (Result<Ok, APIError>) -> Void) {
        send("POST", "/reminders/\(id)/snooze", body: ["minutes": minutes], as: Ok.self, completion: c)
    }

    func chatHistory(_ c: @escaping (Result<ChatPage, APIError>) -> Void) {
        send("GET", "/chat", as: ChatPage.self, completion: c)
    }

    /// Pesan ke asisten. AI bisa butuh sampai ±75 detik.
    func chat(_ message: String, _ c: @escaping (Result<ChatReply, APIError>) -> Void) {
        send("POST", "/chat", body: ["message": message], timeout: 95, as: ChatReply.self, completion: c)
    }

    struct BatchResult: Decodable { let batch: BatchView }
    /// action: confirm | reject | undo
    func batch(_ id: Int64, _ action: String, _ c: @escaping (Result<BatchResult, APIError>) -> Void) {
        send("POST", "/chat/batches/\(id)/\(action)", as: BatchResult.self, completion: c)
    }

    func logout(_ c: @escaping (Result<Ok, APIError>) -> Void) {
        send("POST", "/logout", as: Ok.self, completion: c)
    }
}

// MARK: - Waktu (zona pengguna, bukan zona Mac)

enum Clock {
    static func zone(_ name: String) -> TimeZone { TimeZone(identifier: name) ?? .current }

    static func parseStamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func ymd(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func hm(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Tanggal + jam tenggat (zona pengguna) → Date.
    static func due(_ date: String, _ time: String, _ tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: date + " " + time)
    }

    static let days = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"]

    /// "hari ini", "besok", atau "Sab 1 Nov".
    static func friendly(_ date: String, now: Date, _ tz: TimeZone) -> String {
        let today = ymd(now, tz)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let tomorrow = ymd(cal.date(byAdding: .day, value: 1, to: now) ?? now, tz)
        if date == today { return "hari ini" }
        if date == tomorrow { return "besok" }
        guard let d = due(date, "12:00", tz) else { return date }
        let c = cal.dateComponents([.weekday, .day, .month], from: d)
        return "\(days[(c.weekday ?? 1) - 1]) \(c.day ?? 0) \(months[(c.month ?? 1) - 1])"
    }
}

// MARK: - Ringkasan daftar untuk menu bar

struct TodoBuckets {
    var overdue: [Todo] = []
    var today: [Todo] = []
    var upcoming: [Todo] = []
    var noDate: [Todo] = []

    /// Angka di menu bar: hari ini + terlambat.
    var badge: Int { overdue.count + today.count }

    init(_ todos: [Todo], now: Date, tz: TimeZone) {
        let t = Clock.ymd(now, tz)
        for x in todos where x.status == "open" {
            if x.dueDate.isEmpty { noDate.append(x) }
            else if x.dueDate < t { overdue.append(x) }
            else if x.dueDate == t { today.append(x) }
            else { upcoming.append(x) }
        }
        let byDue: (Todo, Todo) -> Bool = { a, b in
            if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
            if a.dueTime != b.dueTime { return (a.dueTime.isEmpty ? "99" : a.dueTime) < (b.dueTime.isEmpty ? "99" : b.dueTime) }
            return a.id < b.id
        }
        overdue.sort(by: byDue)
        today.sort(by: byDue)
        upcoming.sort(by: byDue)
    }
}

// MARK: - Notifikasi lokal yang perlu dijadwalkan

struct PlannedNotification: Equatable {
    let id: String // stabil: sama → tidak dijadwalkan ulang
    let title: String
    let body: String
    let fireAt: Date
    let todoId: Int64?
    let reminderId: Int64?
}

enum NotificationPlan {
    static let dueLead: TimeInterval = 10 * 60
    static let maxPending = 50 // macOS membatasi jumlah notifikasi terjadwal

    /// Gabungkan kemunculan pengingat (dari server) + tenggat todo berjam.
    static func build(occurrences: [Occurrence], todos: [Todo], prefs: Prefs, tz: TimeZone, now: Date) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        for o in occurrences {
            guard let at = Clock.parseStamp(o.at), at > now else { continue }
            out.append(PlannedNotification(id: "rem-\(o.reminderId)-\(o.at)", title: o.title, body: o.body, fireAt: at,
                                           todoId: o.todoId, reminderId: o.reminderId))
        }
        if prefs.dueNotify {
            for t in todos where t.status == "open" && !t.dueTime.isEmpty {
                guard let due = Clock.due(t.dueDate, t.dueTime, tz) else { continue }
                let at = due.addingTimeInterval(-dueLead)
                guard at > now, at < now.addingTimeInterval(48 * 3600) else { continue }
                out.append(PlannedNotification(id: "due-\(t.id)-\(t.dueDate)T\(t.dueTime)", title: t.title,
                                               body: "Tenggat 10 menit lagi (\(t.dueTime))", fireAt: at, todoId: t.id, reminderId: nil))
            }
        }
        if prefs.hideContent {
            out = out.map { PlannedNotification(id: $0.id, title: "Pengingat", body: "Buka AI Todo untuk melihatnya",
                                                fireAt: $0.fireAt, todoId: $0.todoId, reminderId: $0.reminderId) }
        }
        out.sort { $0.fireAt < $1.fireAt }
        return Array(out.prefix(maxPending))
    }
}
