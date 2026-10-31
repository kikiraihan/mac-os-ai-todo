// AI Todo — aplikasi menu bar macOS (Swift + AppKit, tanpa dependensi).
//
//   • Ikon ✓ di menu bar + angka todo hari ini & terlambat
//   • Klik todo di menu = tandai selesai (⌥ + klik = buka di web)
//   • Tambah todo manual, panel chat asisten (⌥⌘T), konfirmasi / undo aksi
//   • Notifikasi lokal untuk pengingat & tenggat (tombol Selesai / Tunda 10 mnt)
//   • Token perangkat di Keychain; sinkron real-time lewat long-poll
//
// Klien HTTP ada di Client.swift (hanya Foundation, diuji di Linux).

import AppKit
import Carbon.HIToolbox
import CryptoKit
import ServiceManagement
import UserNotifications

// MARK: - Keychain (token perangkat; tidak pernah ditulis ke file pengaturan)

enum Keychain {
    static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "id.local.aitodo",
                                      kSecAttrAccount as String: "device-token"]

    static var token: String? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var q = base
            q[kSecValueData as String] = Data(newValue.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

// MARK: - Pengaturan lokal (UserDefaults; tanpa rahasia)

enum LocalPrefs {
    static let d = UserDefaults.standard

    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "" }
        set { d.set(newValue, forKey: "serverURL") }
    }

    private static func flag(_ key: String, default def: Bool) -> Bool { d.object(forKey: key) == nil ? def : d.bool(forKey: key) }

    static var showBadge: Bool {
        get { flag("showBadge", default: true) }
        set { d.set(newValue, forKey: "showBadge") }
    }

    static var notifications: Bool {
        get { flag("notifications", default: true) }
        set { d.set(newValue, forKey: "notifications") }
    }

    static var hotkey: Bool {
        get { flag("hotkey", default: true) }
        set { d.set(newValue, forKey: "hotkey") }
    }
}

// MARK: - Store: keadaan + sinkron

final class Store {
    let api = APIClient()
    var me: Me?
    var todos: [Todo] = []
    var occurrences: [Occurrence] = []
    var rev: Int64 = 0
    var lastSync: Date?
    var lastError: String?
    var needsLogin = false
    /// Dipanggil di main thread setiap keadaan berubah.
    var onChange: (() -> Void)?

    private var generation = 0
    private var failures = 0
    private var refreshing = false
    private var refreshWaiters: [() -> Void] = []

    var tz: TimeZone { Clock.zone(me?.timezone ?? TimeZone.current.identifier) }
    var buckets: TodoBuckets { TodoBuckets(todos, now: Date(), tz: tz) }
    var connected: Bool { api.isConfigured && !needsLogin }

    func configureFromKeychain() {
        let base = ServerURL.normalize(LocalPrefs.serverURL)
        api.configure(base: base, token: base == nil ? nil : Keychain.token)
    }

    func start() {
        guard api.isConfigured else {
            onChange?()
            return
        }
        needsLogin = false
        refresh()
        generation += 1
        let g = generation
        poll(g)
    }

    func stop() {
        generation += 1
    }

    func reset() {
        stop()
        me = nil
        todos = []
        occurrences = []
        rev = 0
        lastSync = nil
        lastError = nil
        onChange?()
    }

    /// Ambil profil, todo terbuka, dan pengingat 48 jam ke depan.
    func refresh(_ done: (() -> Void)? = nil) {
        if let done { refreshWaiters.append(done) }
        guard !refreshing else { return }
        refreshing = true
        api.me { [weak self] r1 in
            guard let self else { return }
            switch r1 {
            case .failure(let e): return self.finish(error: e)
            case .success(let me):
                self.api.openTodos { r2 in
                    switch r2 {
                    case .failure(let e): return self.finish(error: e)
                    case .success(let t):
                        self.api.upcoming(hours: 48) { r3 in
                            switch r3 {
                            case .failure(let e): return self.finish(error: e)
                            case .success(let u):
                                DispatchQueue.main.async {
                                    self.me = me
                                    self.todos = t.todos
                                    self.occurrences = u.occurrences
                                    self.rev = max(t.rev, u.rev)
                                    self.lastSync = Date()
                                    self.lastError = nil
                                    self.finish(error: nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(error: APIError?) {
        if !Thread.isMainThread { return DispatchQueue.main.async { self.finish(error: error) } }
        refreshing = false
        if let error {
            lastError = error.description
            if case .unauthorized = error { needsLogin = true; stop() }
        }
        let waiters = refreshWaiters
        refreshWaiters = []
        onChange?()
        waiters.forEach { $0() }
    }

    private func poll(_ g: Int) {
        guard g == generation, api.isConfigured, !needsLogin else { return }
        api.changes(since: rev) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                switch r {
                case .success(let v):
                    self.failures = 0
                    if v.rev != self.rev { self.refresh { self.poll(g) } } else { self.poll(g) }
                case .failure(.unauthorized):
                    self.needsLogin = true
                    self.lastError = APIError.unauthorized.description
                    self.onChange?()
                case .failure(let e):
                    self.failures += 1
                    self.lastError = e.description
                    self.onChange?()
                    let delay = min(60.0, pow(2.0, Double(min(self.failures, 6))))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.poll(g) }
                }
            }
        }
    }
}

// MARK: - Notifikasi lokal

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    let center = UNUserNotificationCenter.current()
    weak var store: Store?
    var openApp: (() -> Void)?
    static let ourPrefixes = ["rem-", "due-"]

    func setup() {
        center.delegate = self
        let done = UNNotificationAction(identifier: "DONE", title: "Selesai", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Tunda 10 mnt", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "todo", actions: [done], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "reminder", actions: [snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "reminder-todo", actions: [done, snooze], intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Samakan notifikasi terjadwal dengan rencana: yang hilang dicabut, yang baru ditambah.
    func sync(_ plan: [PlannedNotification]) {
        let wanted = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let ours = pending.map(\.identifier).filter { id in Notifier.ourPrefixes.contains { id.hasPrefix($0) } }
            let stale = ours.filter { wanted[$0] == nil }
            if !stale.isEmpty { self.center.removePendingNotificationRequests(withIdentifiers: stale) }
            let existing = Set(ours)
            for p in plan where !existing.contains(p.id) {
                let c = UNMutableNotificationContent()
                c.title = p.title
                c.body = p.body
                c.sound = .default
                c.threadIdentifier = "aitodo"
                var info: [String: Any] = [:]
                if let t = p.todoId { info["todoId"] = NSNumber(value: t) }
                if let r = p.reminderId { info["reminderId"] = NSNumber(value: r) }
                c.userInfo = info
                c.categoryIdentifier = p.reminderId != nil ? (p.todoId != nil ? "reminder-todo" : "reminder") : "todo"
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                self.center.add(UNNotificationRequest(identifier: p.id, content: c, trigger: trigger))
            }
        }
    }

    func clearAll() {
        center.getPendingNotificationRequests { [weak self] pending in
            let ours = pending.map(\.identifier).filter { id in Notifier.ourPrefixes.contains { id.hasPrefix($0) } }
            self?.center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let todoId = (info["todoId"] as? NSNumber)?.int64Value
        let reminderId = (info["reminderId"] as? NSNumber)?.int64Value
        guard let store else { return completionHandler() }
        switch response.actionIdentifier {
        case "DONE":
            if let todoId { store.api.complete(todo: todoId) { _ in DispatchQueue.main.async { store.refresh() } } }
        case "SNOOZE":
            if let reminderId { store.api.snooze(reminder: reminderId, minutes: 10) { _ in DispatchQueue.main.async { store.refresh() } } }
        default:
            DispatchQueue.main.async { self.openApp?() }
        }
        completionHandler()
    }
}

// MARK: - Hotkey global (Carbon, tanpa izin Aksesibilitas)

final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// ⌥⌘T
    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4149_5444), id: 1) // 'AITD'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

// MARK: - Form kecil untuk NSAlert

/// Kolom berlabel bertumpuk, dengan frame manual (cukup untuk accessoryView NSAlert).
func formView(_ rows: [(String, NSView)], width: CGFloat = 320) -> NSView {
    let rowH: CGFloat = 46
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowH))
    for (i, row) in rows.enumerated() {
        let y = v.frame.height - CGFloat(i + 1) * rowH
        let label = NSTextField(labelWithString: row.0)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: y + 26, width: width, height: 16)
        row.1.frame = NSRect(x: 0, y: y + 2, width: width, height: 24)
        v.addSubview(label)
        v.addSubview(row.1)
    }
    return v
}

func field(_ value: String = "", placeholder: String = "") -> NSTextField {
    let f = NSTextField(string: value)
    f.placeholderString = placeholder
    return f
}

func showError(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = .warning
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

// MARK: - Panel chat asisten

final class ChatPanel: NSObject, NSWindowDelegate {
    let store: Store
    private var panel: NSPanel?
    private var textView: NSTextView!
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Kirim", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let confirmButton = NSButton(title: "Ya, lakukan", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Batal", target: nil, action: nil)
    private let undoButton = NSButton(title: "↶ Batalkan aksi terakhir", target: nil, action: nil)
    private var pending: BatchView?
    private var undoable: BatchView?
    private var busy = false { didSet { updateControls() } }

    init(store: Store) {
        self.store = store
        super.init()
    }

    func show() {
        if panel == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(input)
        loadHistory()
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        p.title = "Asisten AI Todo"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 340, height: 360)
        p.delegate = self
        p.center()

        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = .systemFont(ofSize: 13)

        input.placeholderString = "mis. besok jam 9 ingetin telpon bengkel"
        input.target = self
        input.action = #selector(send)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.bezelStyle = .rounded
        rejectButton.target = self
        rejectButton.action = #selector(reject)
        rejectButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded

        let actionBar = NSStackView(views: [status, NSView(), rejectButton, confirmButton, undoButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 6
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inputRow = NSStackView(views: [input, sendButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 6
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [scroll, actionBar, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        p.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            actionBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        panel = p
        updateControls()
    }

    private func updateControls() {
        let hasPending = pending != nil
        confirmButton.isHidden = !hasPending
        rejectButton.isHidden = !hasPending
        undoButton.isHidden = hasPending || undoable == nil
        [confirmButton, rejectButton, undoButton, sendButton].forEach { $0.isEnabled = !busy }
        input.isEnabled = !busy
        if busy { status.stringValue = "Menunggu asisten…" }
        else if hasPending { status.stringValue = "Perlu konfirmasimu" }
        else { status.stringValue = "" }
    }

    // MARK: Teks

    private func append(_ who: String, _ text: String, items: [BatchItem] = [], muted: Bool = false) {
        guard let storage = textView?.textStorage else { return }
        let body = NSMutableAttributedString()
        if storage.length > 0 { body.append(NSAttributedString(string: "\n")) }
        let color: NSColor = muted ? .secondaryLabelColor : .labelColor
        body.append(NSAttributedString(string: who + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        body.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]))
        for it in items {
            body.append(NSAttributedString(string: "  • " + it.summary + "\n",
                                           attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemTeal]))
        }
        storage.append(body)
        textView.scrollToEndOfDocument(nil)
    }

    private func setBatch(_ b: BatchView?) {
        guard let b else { return }
        switch b.status {
        case "pending": pending = b
        case "applied":
            if pending?.id == b.id { pending = nil }
            undoable = b.undoable ? b : nil
        default:
            if pending?.id == b.id { pending = nil }
            if undoable?.id == b.id { undoable = nil }
        }
        updateControls()
    }

    private func loadHistory() {
        guard store.connected else {
            textView.string = ""
            append("AI Todo", "Belum terhubung. Klik ikon ✓ di menu bar → Hubungkan ke server…", muted: true)
            return
        }
        store.api.chatHistory { [weak self] r in
            DispatchQueue.main.async {
                guard let self, case .success(let page) = r else { return }
                self.textView.string = ""
                self.pending = nil
                self.undoable = nil
                if page.messages.isEmpty {
                    self.append("Asisten", "Halo! Ceritakan saja apa yang perlu dikerjakan, mis. “beli galon, bayar wifi, servis motor sabtu”. Tanpa AI: /todo, /hari-ini, /undo, /bantuan.", muted: true)
                }
                for m in page.messages.suffix(30) {
                    let batch = m.batchId.flatMap { page.batches[String($0)] }
                    self.append(m.role == "user" ? "Kamu" : "Asisten", m.content, items: batch?.items ?? [])
                    if m.role == "assistant" { self.setBatch(batch) }
                }
                self.updateControls()
            }
        }
    }

    // MARK: Aksi

    @objc private func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, store.connected else { return }
        input.stringValue = ""
        append("Kamu", text)
        busy = true
        store.api.chat(text) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch r {
                case .success(let rep):
                    self.append("Asisten", rep.assistant.content, items: rep.batch?.items ?? [])
                    self.setBatch(rep.batch)
                    if rep.batch != nil { self.store.refresh() }
                case .failure(let e):
                    self.append("Gagal", e.description, muted: true)
                    self.input.stringValue = text
                }
                self.panel?.makeFirstResponder(self.input)
            }
        }
    }

    private func batchAction(_ b: BatchView?, _ action: String, done label: String) {
        guard let b, !busy else { return }
        busy = true
        store.api.batch(b.id, action) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch r {
                case .success(let res):
                    self.append("Asisten", label, items: action == "confirm" ? res.batch.items : [], muted: action != "confirm")
                    if action == "undo" { self.undoable = nil }
                    self.setBatch(res.batch)
                    self.store.refresh()
                case .failure(let e):
                    self.append("Gagal", e.description, muted: true)
                    if action != "undo" { self.pending = nil }
                    self.updateControls()
                }
            }
        }
    }

    @objc private func confirm() { batchAction(pending, "confirm", done: "Sudah kujalankan.") }
    @objc private func reject() { batchAction(pending, "reject", done: "Oke, dibatalkan.") }
    @objc private func undo() { batchAction(undoable, "undo", done: "Aksi terakhir sudah dibatalkan.") }
}

// MARK: - Pembaruan (rilis GitHub bertanda tangan Ed25519, pola PasteLAN)

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-ai-todo"
    let appName = "AITodo"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: URL?, sig: URL?, page: URL)
    var latest: Release?

    /// Kunci publik Ed25519 (base64) dari `swift scripts/sign-release.swift keygen`.
    /// Kosong → update selalu lewat halaman rilis (unduh manual), tidak pernah dipasang otomatis.
    static let publicKey = ""

    static func verify(zip: URL, tag: String, signature: String) -> Bool {
        guard let k = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: k),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: zip) else { return false }
        return key.isValidSignature(sig, for: Data("AITodo \(tag)\n".utf8) + data)
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check { _ in self?.refreshMenu() } }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate { menuItem.title = "Update tersedia: \(l.version)…" }
        else { menuItem.title = "Cek pembaruan…" }
    }

    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var info: Release?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String,
               let page = (j["html_url"] as? String).flatMap({ URL(string: $0) }) {
                let assets = j["assets"] as? [[String: Any]] ?? []
                func asset(_ name: String) -> URL? {
                    (assets.first { ($0["name"] as? String) == name }?["browser_download_url"] as? String).flatMap { URL(string: $0) }
                }
                info = (tag, asset("\(self.appName).zip"), asset("\(self.appName).zip.sig"), page)
            }
            DispatchQueue.main.async {
                if let info { self.latest = info }
                done(info != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = "Periksa koneksi internet, lalu coba lagi."
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "AI Todo sudah versi terbaru"
                a.informativeText = "Versi terpasang: \(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "AI Todo \(l.version) tersedia"
            a.informativeText = "Versi terpasang: \(Updater.current).\n\nAI Todo akan ditutup, diganti versi baru, lalu dibuka lagi. Login & pengaturan tetap."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, cek tanda tangan, ekstrak, lalu ganti .app lama setelah aplikasi ini keluar.
    func install(_ l: Release) {
        let dest = Bundle.main.bundleURL
        guard let zip = l.zip, let sigURL = l.sig, !Updater.publicKey.isEmpty, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        URLSession.shared.dataTask(with: sigURL) { sigData, _, _ in
            let signature = sigData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            URLSession.shared.downloadTask(with: zip) { tmp, _, err in
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
                let zipFile = work.appendingPathComponent("update.zip")
                let newApp = work.appendingPathComponent("\(self.appName).app")
                var problem: String?
                if let tmp {
                    do {
                        try fm.createDirectory(at: work, withIntermediateDirectories: true)
                        try fm.moveItem(at: tmp, to: zipFile)
                        guard Updater.verify(zip: zipFile, tag: l.version, signature: signature) else {
                            throw NSError(domain: "AITodo", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "Tanda tangan rilis tidak cocok. Update dibatalkan demi keamanan."])
                        }
                        let unzip = Process()
                        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                        try unzip.run()
                        unzip.waitUntilExit()
                        if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                            problem = "File rilis tidak berisi \(self.appName).app."
                        } else if Bundle(url: newApp)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                            problem = "File rilis berisi aplikasi lain."
                        }
                    } catch { problem = error.localizedDescription }
                } else {
                    problem = err?.localizedDescription ?? "Unduhan gagal."
                }
                DispatchQueue.main.async {
                    if let problem { return self.fail(problem, l.page) }
                    let script = """
                    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                    if mv "$3" "$4"; then
                      if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                    fi
                    xattr -cr "$3" 2>/dev/null
                    open "$3"
                    """
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                                   work.appendingPathComponent("old.app").path]
                    do { try p.run() } catch { return self.fail(error.localizedDescription, l.page) }
                    NSApp.terminate(nil)
                }
            }.resume()
        }.resume()
    }

    func fail(_ message: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = message + "\n\nUnduh manual dari halaman rilis?"
        a.addButton(withTitle: "Buka halaman rilis")
        a.addButton(withTitle: "Tutup")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }
}

// MARK: - Aplikasi

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let notifier = Notifier()
    let hotkey = HotKey()
    let updater = Updater()
    lazy var chat = ChatPanel(store: store)
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var tick: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: "AI Todo")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        notifier.store = store
        notifier.openApp = { [weak self] in self?.chat.show() }
        notifier.setup()

        store.onChange = { [weak self] in self?.stateChanged() }
        store.configureFromKeychain()

        HotKey.action = { [weak self] in self?.chat.show() }
        if LocalPrefs.hotkey { hotkey.register() }

        // Bangun dari tidur / ganti hari: segarkan & jadwalkan ulang notifikasi.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.start()
        }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.store.refresh() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        tick = t

        updater.start()
        if store.api.isConfigured {
            store.start()
        } else {
            stateChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
        }
    }

    // MARK: Keadaan → tampilan

    func stateChanged() {
        let b = store.buckets
        if let button = statusItem.button {
            button.title = (LocalPrefs.showBadge && b.badge > 0 && store.connected) ? " \(b.badge)" : ""
            button.toolTip = store.connected ? "AI Todo — \(b.today.count) hari ini, \(b.overdue.count) terlambat" : "AI Todo — belum terhubung"
        }
        if store.connected, LocalPrefs.notifications, let me = store.me {
            notifier.sync(NotificationPlan.build(occurrences: store.occurrences, todos: store.todos, prefs: me.prefs,
                                                 tz: store.tz, now: Date()))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let f = DateFormatter()
        f.dateFormat = "HH.mm"

        // Baris status
        let statusText: String
        if !store.api.isConfigured { statusText = "Belum terhubung ke server" }
        else if store.needsLogin { statusText = "Sesi berakhir — hubungkan ulang" }
        else if let e = store.lastError, store.lastSync == nil { statusText = "Gagal: \(e)" }
        else if let s = store.lastSync { statusText = "Tersinkron \(f.string(from: s))" + (store.lastError != nil ? " (offline)" : "") }
        else { statusText = "Menyinkronkan…" }
        let st = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())

        guard store.connected else {
            menu.addItem(item("Hubungkan ke server…", #selector(connect)))
            addFooter(menu)
            return
        }

        let ask = item("Tanya asisten…", #selector(openChat), key: "t")
        ask.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(ask)
        menu.addItem(item("Tambah todo…", #selector(addTodo), key: "n"))
        menu.addItem(.separator())

        let b = store.buckets
        addTodoSection(menu, "Terlambat", b.overdue)
        addTodoSection(menu, "Hari ini", b.today)
        if b.overdue.isEmpty && b.today.isEmpty {
            let none = NSMenuItem(title: "Tidak ada todo untuk hari ini 🎉", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        if !b.upcoming.isEmpty || !b.noDate.isEmpty {
            let more = NSMenuItem(title: "Lainnya (\(b.upcoming.count + b.noDate.count))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for t in (b.upcoming + b.noDate).prefix(30) { addTodoItem(sub, t) }
            more.submenu = sub
            menu.addItem(more)
        }

        let upcoming = store.occurrences.prefix(3)
        if !upcoming.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Pengingat berikutnya"))
            for o in upcoming {
                let when = Clock.parseStamp(o.at).map { Clock.friendly(Clock.ymd($0, store.tz), now: Date(), store.tz) + " " + Clock.hm($0, store.tz) } ?? ""
                let it = NSMenuItem(title: "\(when) · \(o.title)", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Buka AI Todo di browser", #selector(openWeb)))
        addFooter(menu)
    }

    func addFooter(_ menu: NSMenu) {
        let settings = NSMenuItem(title: "Pengaturan", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if store.api.isConfigured {
            let who = store.me.map { "Masuk sebagai \($0.user.displayName.isEmpty ? $0.user.username : $0.user.displayName)" } ?? "Terhubung"
            let w = NSMenuItem(title: "\(who) · \(LocalPrefs.serverURL)", action: nil, keyEquivalent: "")
            w.isEnabled = false
            sub.addItem(w)
            sub.addItem(item("Hubungkan ulang / ganti server…", #selector(connect)))
            sub.addItem(item("Putuskan dari server", #selector(disconnect)))
            sub.addItem(.separator())
        }
        sub.addItem(toggle("Tampilkan jumlah di menu bar", LocalPrefs.showBadge, #selector(toggleBadge)))
        sub.addItem(toggle("Notifikasi di Mac ini", LocalPrefs.notifications, #selector(toggleNotifications)))
        sub.addItem(toggle("Hotkey ⌥⌘T untuk asisten", LocalPrefs.hotkey, #selector(toggleHotkey)))
        sub.addItem(toggle("Buka saat login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        settings.submenu = sub
        menu.addItem(settings)
        updater.refreshMenu()
        menu.addItem(updater.menuItem)
        let ver = NSMenuItem(title: "Versi \(Updater.current)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        menu.addItem(.separator())
        menu.addItem(item("Keluar AI Todo", #selector(quit), key: "q"))
    }

    func header(_ title: String) -> NSMenuItem {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.isEnabled = false
        h.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                                                           .foregroundColor: NSColor.secondaryLabelColor])
        return h
    }

    func addTodoSection(_ menu: NSMenu, _ title: String, _ todos: [Todo]) {
        guard !todos.isEmpty else { return }
        menu.addItem(header("\(title) (\(todos.count))"))
        for t in todos.prefix(15) { addTodoItem(menu, t) }
        if todos.count > 15 {
            let more = NSMenuItem(title: "… \(todos.count - 15) lagi (buka di browser)", action: #selector(openWeb), keyEquivalent: "")
            more.target = self
            menu.addItem(more)
        }
    }

    /// Klik = tandai selesai; tahan ⌥ = buka di web.
    func addTodoItem(_ menu: NSMenu, _ t: Todo) {
        var label = "☐ " + (t.priority == "high" ? "❗" : "") + t.title
        if !t.dueDate.isEmpty {
            let today = Clock.ymd(Date(), store.tz)
            if t.dueDate != today { label += " · " + Clock.friendly(t.dueDate, now: Date(), store.tz) }
            if !t.dueTime.isEmpty { label += " " + t.dueTime }
        }
        if !t.list.isEmpty { label += "  [\(t.list)]" }
        let done = NSMenuItem(title: label, action: #selector(completeTodo(_:)), keyEquivalent: "")
        done.target = self
        done.representedObject = NSNumber(value: t.id)
        done.toolTip = t.notes.isEmpty ? "Klik untuk menandai selesai" : t.notes
        menu.addItem(done)
        let open = NSMenuItem(title: "Buka “\(t.title)” di browser", action: #selector(openWeb), keyEquivalent: "")
        open.target = self
        open.isAlternate = true
        open.keyEquivalentModifierMask = .option
        menu.addItem(open)
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    // MARK: Aksi menu

    @objc func openChat() { chat.show() }

    @objc func openWeb() {
        guard let base = ServerURL.normalize(LocalPrefs.serverURL), let url = URL(string: base.absoluteString + "/todo") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func completeTodo(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return }
        // Langsung hilang dari menu; server yang memastikan.
        store.todos.removeAll { $0.id == id }
        stateChanged()
        store.api.complete(todo: id) { [weak self] r in
            DispatchQueue.main.async {
                if case .failure(let e) = r { showError("Gagal menandai selesai", e.description) }
                self?.store.refresh()
            }
        }
    }

    @objc func addTodo() {
        let title = field(placeholder: "mis. Bayar listrik")
        let when = NSPopUpButton(frame: .zero, pullsDown: false)
        when.addItems(withTitles: ["Tanpa tenggat", "Hari ini", "Besok", "Lusa"])
        when.selectItem(at: 1)
        let time = field(placeholder: "HH:MM (opsional)")
        let a = NSAlert()
        a.messageText = "Tambah todo"
        a.informativeText = "Untuk pengingat berulang atau detail lain, minta asisten atau buka di browser."
        a.accessoryView = formView([("Judul", title), ("Tenggat", when), ("Jam", time)])
        a.addButton(withTitle: "Tambah")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = title
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        let offset = [-1, 0, 1, 2][when.indexOfSelectedItem]
        let date = offset < 0 ? "" : Clock.ymd(cal.date(byAdding: .day, value: offset, to: Date()) ?? Date(), store.tz)
        let hm = time.stringValue.trimmingCharacters(in: .whitespaces)
        if !hm.isEmpty && (date.isEmpty || hm.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil) {
            return showError("Jam tidak valid", "Isi jam dengan format HH:MM (mis. 09:30) dan pilih tanggal tenggat.")
        }
        store.api.createTodo(title: t, dueDate: date, dueTime: hm) { [weak self] r in
            DispatchQueue.main.async {
                if case .failure(let e) = r { showError("Gagal menambah todo", e.description) }
                self?.store.refresh()
            }
        }
    }

    @objc func connect() {
        let server = field(LocalPrefs.serverURL, placeholder: "https://todo.domain-anda.com")
        let user = field(placeholder: "username")
        let pass = NSSecureTextField()
        pass.placeholderString = "password"
        let device = field(Host.current().localizedName ?? "Mac", placeholder: "nama perangkat")
        let a = NSAlert()
        a.messageText = "Hubungkan ke server AI Todo"
        a.informativeText = "Password tidak disimpan. Mac ini mendapat token perangkat sendiri (disimpan di Keychain) yang bisa dicabut dari web → Pengaturan → Perangkat."
        a.accessoryView = formView([("Alamat server", server), ("Username", user), ("Password", pass), ("Nama perangkat", device)])
        a.addButton(withTitle: "Hubungkan")
        a.addButton(withTitle: "Pakai token…")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = LocalPrefs.serverURL.isEmpty ? server : user
        let choice = a.runModal()
        if choice == .alertSecondButtonReturn { return connectWithToken(server.stringValue) }
        guard choice == .alertFirstButtonReturn else { return }
        guard let base = ServerURL.normalize(server.stringValue) else {
            return showError("Alamat server tidak valid", APIError.insecureURL.description)
        }
        store.api.loginDevice(base: base, username: user.stringValue.trimmingCharacters(in: .whitespaces),
                              password: pass.stringValue, device: device.stringValue) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success(let login): self?.connected(base: base, token: login.token)
                case .failure(let e):
                    self?.store.configureFromKeychain()
                    showError("Gagal terhubung", e.description)
                }
            }
        }
    }

    func connectWithToken(_ serverValue: String) {
        let server = field(serverValue, placeholder: "https://todo.domain-anda.com")
        let token = NSSecureTextField()
        token.placeholderString = "ait_…"
        let a = NSAlert()
        a.messageText = "Hubungkan dengan token perangkat"
        a.informativeText = "Buat token di web: Pengaturan → Perangkat & aplikasi Mac → Buat token perangkat."
        a.accessoryView = formView([("Alamat server", server), ("Token", token)])
        a.addButton(withTitle: "Hubungkan")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let base = ServerURL.normalize(server.stringValue) else {
            return showError("Alamat server tidak valid", APIError.insecureURL.description)
        }
        let t = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        store.api.configure(base: base, token: t)
        store.api.me { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success: self?.connected(base: base, token: t)
                case .failure(let e):
                    self?.store.configureFromKeychain()
                    showError("Token ditolak", e.description)
                }
            }
        }
    }

    func connected(base: URL, token: String) {
        LocalPrefs.serverURL = base.absoluteString
        Keychain.token = token
        store.stop()
        store.reset()
        store.configureFromKeychain()
        store.start()
        if LocalPrefs.notifications { notifier.requestAuthorization { _ in } }
    }

    @objc func disconnect() {
        let a = NSAlert()
        a.messageText = "Putuskan Mac ini dari server?"
        a.informativeText = "Token perangkat dicabut di server dan dihapus dari Keychain. Notifikasi terjadwal ikut dihapus."
        a.addButton(withTitle: "Putuskan")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.api.logout { _ in }
        Keychain.token = nil
        notifier.clearAll()
        store.reset()
        store.configureFromKeychain()
        stateChanged()
    }

    @objc func toggleBadge() {
        LocalPrefs.showBadge.toggle()
        stateChanged()
    }

    @objc func toggleNotifications() {
        LocalPrefs.notifications.toggle()
        if LocalPrefs.notifications {
            notifier.requestAuthorization { [weak self] ok in
                if !ok { showError("Notifikasi diblokir", "Izinkan notifikasi untuk AI Todo di Pengaturan Sistem → Notifikasi.") }
                self?.stateChanged()
            }
        } else {
            notifier.clearAll()
        }
    }

    @objc func toggleHotkey() {
        LocalPrefs.hotkey.toggle()
        if LocalPrefs.hotkey { hotkey.register() } else { hotkey.unregister() }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            showError("Gagal mengubah Buka saat login", error.localizedDescription)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
