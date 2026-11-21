// AI Todo — aplikasi menu bar macOS (Swift + AppKit, tanpa dependensi).
//
//   • Ikon ✓ di menu bar + angka todo hari ini & terlambat
//   • Klik ikon = popover: tab Chat (gaya Claude: gelembung pengguna di kanan, jawaban AI penuh lebar)
//     + contoh pertanyaan (chip kaca yang bisa digeser, klik = langsung kirim)
//     dan tab Manual (tambah todo, klik lingkaran = tandai selesai; filter Hari ini | Semua;
//     ubah todo: tahan ⌥ lalu klik ✎, klik dua kali judul, atau klik kanan → Ubah…;
//     urutkan todo / pengingat: tahan ⌃ lalu seret ≡, atau klik kanan → Urutkan — disimpan di Mac ini);
//     ⌥⌘T buka / tutup popover
//     (⇧⌥⌘T = popover di tab terakhir, ⌘1–4 / ⌃⇥ pindah tab; semua bisa diubah di Pengaturan → Pintasan)
//     dan tab Catatan (hal umum tanpa waktu: teks & link; sematkan, kategori, cari — Notes.swift)
//   • Konfirmasi / undo aksi asisten; klik kanan ikon = menu singkat (Pengaturan, Keluar)
//   • Jendela Pengaturan terpisah (tab Umum, Todo, Akun, Ingatan, Tentang — pola PasteLAN);
//     tab Todo = kelola todo lengkap seperti halaman Todo di web
//   • Notifikasi lokal untuk pengingat & tenggat (tombol Selesai / Tunda 10 mnt)
//   • Token perangkat di Keychain; sinkron real-time lewat long-poll
//
// Klien HTTP ada di Client.swift (hanya Foundation, diuji di Linux).

import AppKit
import Carbon.HIToolbox
import CryptoKit
import ServiceManagement
import UniformTypeIdentifiers
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

    /// Sakelar lama "Pintasan ⌥⌘T" (≤0.18); sekarang dipakai hanya sebagai nilai awal pintasan asisten.
    static var hotkey: Bool {
        get { flag("hotkey", default: true) }
        set { d.set(newValue, forKey: "hotkey") }
    }

    /// Pintasan yang diubah di Pengaturan → Pintasan: kunci = `ShortcutAction.rawValue`, nilai = `KeyCombo.stored`,
    /// "" = dimatikan. Yang tidak ada = bawaan (logika di `Shortcuts`, Client.swift).
    static var shortcuts: [String: String] {
        get { d.dictionary(forKey: "shortcuts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "shortcuts") }
    }

    /// Pintasan yang berlaku sekarang.
    static var keys: [ShortcutAction: KeyCombo] { Shortcuts.resolve(shortcuts, chatHotkeyOff: !hotkey) }

    /// Filter daftar di tab Manual: false = Hari ini (bawaan), true = Semua.
    /// (Versi ≤0.8.0; sekarang dipakai hanya sebagai nilai awal `manualScope`.)
    static var showAllTodos: Bool {
        get { flag("showAllTodos", default: false) }
        set { d.set(newValue, forKey: "showAllTodos") }
    }

    /// Filter tab Manual: 0 = Hari ini (bawaan), 1 = Semua, 2 = Pengingat.
    /// (Versi 0.8.x; sekarang dipakai hanya sebagai nilai awal `todoScope`.)
    static var manualScope: Int {
        get { d.object(forKey: "manualScope") == nil ? (showAllTodos ? 1 : 0) : min(max(d.integer(forKey: "manualScope"), 0), 2) }
        set { d.set(newValue, forKey: "manualScope") }
    }

    /// Filter tab Todo: 0 = Hari ini (bawaan), 1 = Semua, 2 = Selesai.
    static var todoScope: Int {
        get { d.object(forKey: "todoScope") == nil ? (manualScope == 1 ? 1 : 0) : min(max(d.integer(forKey: "todoScope"), 0), 2) }
        set { d.set(newValue, forKey: "todoScope") }
    }

    /// Filter tab Pengingat: 0 = Hari ini (bawaan), 1 = Semua, 2 = Selesai.
    /// (Sampai 0.14.x kuncinya "reminderScope" dengan 0 = Aktif, 1 = Selesai → Selesai dipindah ke 2.)
    static var reminderScope: Int {
        get {
            if d.object(forKey: "reminderFilter") == nil { return d.integer(forKey: "reminderScope") == 1 ? 2 : 0 }
            return min(max(d.integer(forKey: "reminderFilter"), 0), 2)
        }
        set { d.set(newValue, forKey: "reminderFilter") }
    }

    /// Filter tab Catatan: 0 = Semua (bawaan), 1 = Disematkan.
    static var notesScope: Int {
        get { min(max(d.integer(forKey: "notesScope"), 0), 1) }
        set { d.set(newValue, forKey: "notesScope") }
    }

    /// Pengelompokan daftar di tab Todo: 0 = Waktu (bawaan: Terlambat, Hari ini, per tanggal, Tanpa tenggat),
    /// 1 = Kategori (per kategori todo, "Tanpa kategori" paling bawah).
    static var todoGroup: Int {
        get { min(max(d.integer(forKey: "todoGroup"), 0), 1) }
        set { d.set(newValue, forKey: "todoGroup") }
    }

    /// Urutan manual di popover (tahan ⌃ lalu seret ≡, atau klik kanan → Urutkan): id todo / pengingat,
    /// yang di depan tampil lebih atas di kelompoknya. Hanya di Mac ini (tidak disinkronkan).
    static var todoOrder: [Int64] {
        get { (d.array(forKey: "todoOrder") as? [Int])?.map(Int64.init) ?? [] }
        set { d.set(newValue.map(Int.init), forKey: "todoOrder") }
    }

    static var reminderOrder: [Int64] {
        get { (d.array(forKey: "reminderOrder") as? [Int])?.map(Int64.init) ?? [] }
        set { d.set(newValue.map(Int.init), forKey: "reminderOrder") }
    }

    /// Carousel contoh pertanyaan di atas kotak input chat (bawaan nyala; disembunyikan lewat klik kanan / Pengaturan).
    static var showSuggestions: Bool {
        get { flag("showSuggestions", default: true) }
        set { d.set(newValue, forKey: "showSuggestions") }
    }

    /// Id kartu aksi yang bar undo-nya sudah ditutup (✕), supaya tidak muncul lagi saat riwayat dimuat ulang.
    static var dismissedUndoBatch: Int64 {
        get { Int64(d.integer(forKey: "dismissedUndoBatch")) }
        set { d.set(Int(newValue), forKey: "dismissedUndoBatch") }
    }
}

// MARK: - Store: keadaan + sinkron

final class Store {
    let api = APIClient()
    var me: Me?
    var todos: [Todo] = []
    var occurrences: [Occurrence] = []
    /// Semua pengingat (aktif & dijeda): yang terkait todo → ikon 🔔 di baris todo, sisanya → filter Pengingat.
    var reminders: [Reminder] = []
    /// Catatan (tab Catatan): yang disematkan dulu, lalu yang terakhir diubah.
    var notes: [Note] = []
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

    /// Pengingat aktif terdekat milik sebuah todo (untuk ikon 🔔 di barisnya).
    func reminder(forTodo id: Int64) -> Reminder? {
        reminders.filter { $0.todoId == id && $0.active && !$0.nextFireAt.isEmpty }.min { $0.nextFireAt < $1.nextFireAt }
    }

    /// Pengingat lepas (tanpa todo): yang aktif urut waktu berbunyi berikutnya, lalu yang dijeda.
    var looseReminders: (active: [Reminder], paused: [Reminder]) {
        let loose = reminders.filter { $0.todoId == nil }
        // RFC3339 UTC → urutan string = urutan waktu; yang tanpa jadwal berikutnya di akhir
        let active = loose.filter(\.active).sorted { ($0.nextFireAt.isEmpty ? "~" : $0.nextFireAt) < ($1.nextFireAt.isEmpty ? "~" : $1.nextFireAt) }
        return (active, loose.filter { !$0.active }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending })
    }

    /// Semua pengingat aktif (lepas & milik todo), urut waktu berbunyi berikutnya; yang tanpa jadwal di akhir.
    var activeReminders: [Reminder] {
        reminders.filter(\.active).sorted { ($0.nextFireAt.isEmpty ? "~" : $0.nextFireAt) < ($1.nextFireAt.isEmpty ? "~" : $1.nextFireAt) }
    }

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
        reminders = []
        notes = []
        rev = 0
        lastSync = nil
        lastError = nil
        onChange?()
    }

    /// Ambil profil, todo terbuka, pengingat 48 jam ke depan, daftar pengingat, dan catatan.
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
                                self.api.reminders { r4 in
                                    switch r4 {
                                    case .failure(let e): return self.finish(error: e)
                                    case .success(let rs):
                                        // Catatan gagal dimuat (mis. server lama tanpa /api/notes) tidak
                                        // menggagalkan sinkron todo & pengingat: daftar catatan lama dipertahankan.
                                        self.api.notes { r5 in
                                            DispatchQueue.main.async {
                                                var rev = max(t.rev, u.rev, rs.rev)
                                                if case .success(let ns) = r5 {
                                                    self.notes = ns.notes
                                                    rev = max(rev, ns.rev)
                                                }
                                                self.me = me
                                                self.todos = t.todos
                                                self.occurrences = u.occurrences
                                                self.reminders = rs.reminders
                                                self.rev = rev
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
            }
        }
    }

    /// Sinkron ulang manual (tombol ↻ di popover / ⌘R / menu klik kanan): ambil ulang semua data dari server.
    /// Long-poll yang sedang menunggu jeda karena gagal (offline) dimulai ulang, supaya tidak menunggu sampai 60 dtk.
    func resync(_ done: @escaping () -> Void) {
        guard api.isConfigured, !needsLogin else { return done() }
        guard failures > 0 else { return refresh(done) }
        failures = 0
        generation += 1
        let g = generation
        refresh { [weak self] in
            self?.poll(g)
            done()
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
    /// Rencana terakhir yang sudah dijadwalkan: rencana sama → tidak perlu bertanya ke Notification Center lagi
    /// (sinkron / percobaan ulang saat offline memanggil `sync` berkali-kali dengan isi yang sama).
    private var lastPlan: [PlannedNotification]?
    private var lastPlanAt = Date.distantPast

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
        // Tetap dicocokkan ulang paling lambat tiap 15 menit, untuk berjaga-jaga bila jadwal diubah dari luar.
        if plan == lastPlan && Date().timeIntervalSince(lastPlanAt) < 15 * 60 { return }
        lastPlan = plan
        lastPlanAt = Date()
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
        lastPlan = nil
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

// MARK: - Pintasan papan ketik (AppKit / Carbon; model & validasi di Client.swift)

extension KeyCombo {
    static func modifiers(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= command }
        if f.contains(.option) { m |= option }
        if f.contains(.control) { m |= control }
        if f.contains(.shift) { m |= shift }
        return m
    }

    var modifierMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & KeyCombo.command != 0 { f.insert(.command) }
        if mods & KeyCombo.option != 0 { f.insert(.option) }
        if mods & KeyCombo.control != 0 { f.insert(.control) }
        if mods & KeyCombo.shift != 0 { f.insert(.shift) }
        return f
    }

    var carbonMods: UInt32 {
        var m = 0
        if mods & KeyCombo.command != 0 { m |= cmdKey }
        if mods & KeyCombo.option != 0 { m |= optionKey }
        if mods & KeyCombo.control != 0 { m |= controlKey }
        if mods & KeyCombo.shift != 0 { m |= shiftKey }
        return UInt32(m)
    }
}

/// Tombol yang memakai pintasan (keyEquivalent + tooltip "Judul (⌘N)"); diperbarui saat pintasan diubah.
enum KeyBindings {
    private final class Entry {
        weak var button: NSButton?
        let action: ShortcutAction
        let tip: String?
        init(_ b: NSButton, _ a: ShortcutAction, _ tip: String?) { button = b; action = a; self.tip = tip }
    }
    private static var entries: [Entry] = []

    /// tip nil = tooltip diatur sendiri oleh pemilik tombol.
    static func bind(_ b: NSButton, _ a: ShortcutAction, tip: String?) {
        entries.append(Entry(b, a, tip))
        apply(entries[entries.count - 1], LocalPrefs.keys)
    }

    static func refresh() {
        entries.removeAll { $0.button == nil }
        let keys = LocalPrefs.keys
        entries.forEach { apply($0, keys) }
    }

    private static func apply(_ e: Entry, _ keys: [ShortcutAction: KeyCombo]) {
        guard let b = e.button else { return }
        let c = keys[e.action]
        b.keyEquivalent = c?.chars ?? ""
        b.keyEquivalentModifierMask = c?.modifierMask ?? []
        guard let tip = e.tip else { return }
        b.toolTip = c.map { "\(tip) (\($0.display))" } ?? tip
    }
}

// MARK: - Hotkey global (Carbon, tanpa izin Aksesibilitas)

final class HotKey {
    static var action: ((ShortcutAction) -> Void)?
    /// Pintasan global, urutannya = id hotkey (1, 2, …).
    private static let globals = ShortcutAction.allCases.filter { $0.isGlobal }
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Daftarkan pintasan global (bawaan ⌥⌘T asisten, ⇧⌥⌘T popover). Hasil = aksi yang kombinasinya
    /// tidak bisa didaftarkan (mis. sudah dipakai aplikasi lain).
    @discardableResult
    func register(_ keys: [ShortcutAction: KeyCombo]) -> [ShortcutAction] {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                let i = Int(id.id) - 1
                DispatchQueue.main.async {
                    if HotKey.globals.indices.contains(i) { HotKey.action?(HotKey.globals[i]) }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var failed: [ShortcutAction] = []
        for (i, a) in HotKey.globals.enumerated() {
            guard let c = keys[a] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4149_5444), id: UInt32(i + 1)) // 'AITD'
            if RegisterEventHotKey(UInt32(c.keyCode), c.carbonMods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(a)
            }
        }
        return failed
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
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

// MARK: - Tema & potongan UI (aksen teal sama dengan web: --accent)

enum Theme {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// Warna yang ikut tema terang / gelap.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static let accent = dynamic(hex(0x0F766E), hex(0x2DD4BF))
    static let accentText = dynamic(.white, hex(0x062A26))
    /// Gelembung pesan pengguna (teal lembut, sama dengan --accent-soft di web).
    static let bubble = dynamic(hex(0xE6F4F2), hex(0x11302D))
    static let warnSoft = dynamic(hex(0xFEF3C7), hex(0x3A2A0A))
    static let danger = dynamic(hex(0xB42318), hex(0xF97066))
    /// Tepi kaca: putih tipis di mode gelap, abu tipis di mode terang.
    static let glassEdge = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.14))
}

/// Kotak bersudut membulat; warna diperbarui saat tema berubah.
final class RoundedBox: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    let radius: CGFloat

    init(fill: NSColor?, stroke: NSColor? = nil, radius: CGFloat) {
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
            layer?.borderColor = stroke?.cgColor
        }
        layer?.borderWidth = stroke == nil ? 0 : 1
        layer?.cornerRadius = radius
    }
}

/// Dokumen scroll yang mengalir dari atas ke bawah.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Kaca gaya Apple (seperti kolom Search di System Settings): teks chat yang lewat di belakangnya jadi buram.
/// macOS 26+ memakai Liquid Glass (NSGlassEffectView); versi lama memakai NSVisualEffectView "within window".
/// Isi diletakkan di `content`.
final class GlassBox: NSView {
    let content = NSView()

    init(radius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.contentView = content
            UI.pin(g, to: self)
            UI.pin(content, to: g)
            return
        }
        #endif
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .withinWindow // yang diburamkan = isi jendela di belakangnya (pesan chat)
        fx.state = .active
        fx.maskImage = GlassBox.mask(radius)
        UI.pin(fx, to: self)
        // garis tepi tipis supaya tepi kaca terbaca di atas teks; di bawah isi agar tidak menghalangi klik
        UI.pin(RoundedBox(fill: nil, stroke: Theme.glassEdge, radius: radius), to: fx)
        UI.pin(content, to: fx)
        wantsLayer = true
        shadow = {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.18)
            sh.shadowBlurRadius = 10
            sh.shadowOffset = NSSize(width: 0, height: -2)
            return sh
        }()
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    /// Topeng bersudut membulat yang bisa direntangkan (capInsets) untuk NSVisualEffectView.
    static func mask(_ r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: Contoh pertanyaan (carousel chip di atas input chat)

/// Satu contoh pertanyaan: ikon SF Symbol + teks yang langsung dikirim ke asisten (sama dengan web).
struct Suggestion {
    let icon: String
    let text: String

    static let all: [Suggestion] = [
        Suggestion(icon: "sun.max", text: "Apa saja todo hari ini?"),
        Suggestion(icon: "exclamationmark.circle", text: "Yang terlambat apa?"),
        Suggestion(icon: "sunrise", text: "Todo besok apa?"),
        Suggestion(icon: "calendar", text: "Ringkas minggu ini"),
        Suggestion(icon: "bell", text: "Pengingat apa saja yang aktif?"),
        Suggestion(icon: "questionmark.circle", text: "/bantuan"),
    ]
}

/// Area klik transparan di atas chip: redup saat ditekan (umpan balik seperti tombol sistem).
final class ChipHit: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        superview?.alphaValue = 0.55
        super.mouseDown(with: event) // loop pelacakan sampai mouse dilepas
        superview?.alphaValue = 1
    }
}

/// Scroll horizontal: roda mouse biasa (atas/bawah) juga menggeser ke samping, trackpad tetap alami.
final class HScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let doc = documentView else {
            return super.scrollWheel(with: event)
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        let x = min(max(0, contentView.bounds.origin.x - step), maxX)
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

/// Baris chip kaca yang bisa digeser ke samping (gaya saran di Pesan / Spotlight).
///   ( ☀︎ Apa saja todo hari ini? ) ( ⓘ Yang terlambat apa? ) ( ☼ To…   ← tepi kanan memudar = masih ada lagi
/// Klik = langsung kirim. Klik kanan = sembunyikan (bisa dinyalakan lagi di Pengaturan → Umum).
final class SuggestionBar: NSView {
    static let chipHeight: CGFloat = 28
    /// Ruang di sekeliling chip supaya bayangan kaca tidak terpotong oleh scroll.
    static let pad: CGFloat = 4

    var onPick: ((String) -> Void)?
    var onHide: (() -> Void)?
    var isEnabled = true {
        didSet {
            hits.forEach { $0.isEnabled = isEnabled }
            stack.alphaValue = isEnabled ? 1 : 0.5
        }
    }

    private let scroll = HScrollView()
    private let stack = UI.stack([], vertical: false, spacing: 6)
    private var hits: [ChipHit] = []
    private let fade = CAGradientLayer()

    init(_ items: [Suggestion]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let p = SuggestionBar.pad
        stack.edgeInsets = NSEdgeInsets(top: p, left: p, bottom: p, right: p)
        for (i, s) in items.enumerated() { stack.addArrangedSubview(chip(s, tag: i)) }

        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        UI.pin(stack, to: doc)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
        // Melebar keluar `pad` di kiri-kanan supaya chip pertama sejajar dengan tepi kotak input.
        UI.pin(scroll, to: self, top: -p, left: -p, bottom: -p, right: -p)
        heightAnchor.constraint(equalToConstant: SuggestionBar.chipHeight).isActive = true

        // Tepi memudar menandakan masih ada chip di luar layar (diperbarui saat menggeser).
        scroll.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.layer?.mask = fade
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateFade),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Contoh pertanyaan")
        menu = contextMenu()
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func chip(_ s: Suggestion, tag: Int) -> NSView {
        let glass = GlassBox(radius: SuggestionBar.chipHeight / 2)
        let icon = NSImageView(image: UI.symbol(s.icon, 12, weight: .medium) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let label = UI.label(s.text, size: 12)
        let row = UI.stack([icon, label], vertical: false, spacing: 5)
        UI.pin(row, to: glass.content, top: 0, left: 10, bottom: 0, right: 12)
        glass.heightAnchor.constraint(equalToConstant: SuggestionBar.chipHeight).isActive = true

        let hit = ChipHit(title: "", target: self, action: #selector(pick(_:)))
        hit.isBordered = false
        hit.tag = tag
        hit.toolTip = "Kirim “\(s.text)” ke asisten"
        hit.setAccessibilityLabel(s.text)
        hit.menu = contextMenu()
        UI.pin(hit, to: glass) // ditambahkan terakhir → di atas isi, menerima klik
        if glass.shadow != nil { // kaca lama (sebelum macOS 26): bayangan kecil supaya muat di dalam `pad`
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.12)
            sh.shadowBlurRadius = 3
            sh.shadowOffset = NSSize(width: 0, height: -1)
            glass.shadow = sh
        }
        hits.append(hit)
        return glass
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        let item = NSMenuItem(title: "Sembunyikan contoh pertanyaan", action: #selector(hide), keyEquivalent: "")
        item.target = self
        m.addItem(item)
        return m
    }

    @objc private func pick(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Suggestion.all.count else { return }
        onPick?(Suggestion.all[sender.tag].text)
    }

    @objc private func hide() { onHide?() }

    /// Kembali ke chip pertama (dipanggil saat carousel tampil lagi).
    func scrollToStart() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    @objc private func updateFade() {
        guard let doc = scroll.documentView else { return }
        let w = max(scroll.bounds.width, 1)
        let edge = min(24 / w, 0.25)
        let x = scroll.contentView.bounds.origin.x
        let left = x > 1          // sudah digeser → tepi kiri ikut memudar
        let right = x + scroll.contentView.bounds.width < doc.frame.width - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        let solid = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        fade.colors = [left ? clear : solid, solid, solid, right ? clear : solid]
        fade.locations = [0, edge, 1 - edge, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }
}

// MARK: Detail todo: salin & pratinjau

/// Salin isi todo sebagai teks polos: "Judul" + baris kosong + detail (bila ada).
enum TodoCopy {
    static func text(_ t: Todo, titleOnly: Bool = false) -> String {
        titleOnly || t.notes.isEmpty ? t.title : t.title + "\n\n" + t.notes
    }

    static func copy(_ todos: [Todo], titleOnly: Bool = false) {
        guard !todos.isEmpty else { return }
        copy(text: todos.map { text($0, titleOnly: titleOnly) }.joined(separator: titleOnly ? "\n" : "\n\n"))
    }

    /// Pengingat: "Judul" + baris kosong + pesan (bila ada) — format yang sama dengan todo.
    static func copy(_ r: Reminder, titleOnly: Bool = false) {
        copy(text: titleOnly || r.message.isEmpty ? r.title : r.title + "\n\n" + r.message)
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Teks detail di pratinjau: ⌘C tanpa pilihan = salin seluruh todo; dengan pilihan = salin yang dipilih.
final class DetailTextView: NSTextView {
    var copyAll: (() -> Void)?
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 { copyAll?() } else { super.copy(sender) }
    }
}

/// Pratinjau detail todo (NSPopover, gaya Quick Look ringkas):
///   ┌ Riset laptop                 ┐  ← judul (bisa dipilih)
///   │ Besok 09:00 · Kantor          │
///   │ ───────────────────────────── │
///   │ •  https://contoh.id/a        │  ← detail: link bisa diklik, daftar "- " tampil sebagai •
///   │ •  bandingkan harga           │     (yang disalin tetap teks asli)
///   └               [Salin] [Ubah…] ┘  ← ⌘C = salin semua (atau bagian yang dipilih)
final class DetailPreview: NSViewController {
    static let width: CGFloat = 300
    static let maxDetailHeight: CGFloat = 280
    let todo: Todo
    let tz: TimeZone
    var onEdit: (() -> Void)?
    var onCopied: (() -> Void)?
    private lazy var copyButton = NSButton(title: "Salin", target: self, action: #selector(copyAll))
    private let textView = DetailTextView()

    init(todo: Todo, tz: TimeZone) {
        self.todo = todo
        self.tz = tz
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    /// Detail siap tampil: daftar "- x" / "* x" jadi "•  x", link (http/https/www) bisa diklik.
    static func detailString(_ notes: String) -> NSAttributedString {
        let shown = notes.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop { $0 == " " }
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? "•  " + t.dropFirst(2) : String(line)
        }.joined(separator: "\n")
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 3
        let s = NSMutableAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                      .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: shown, range: NSRange(location: 0, length: (shown as NSString).length)) {
                if let url = m.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    s.addAttribute(.link, value: url, range: m.range)
                }
            }
        }
        return s
    }

    override func loadView() {
        let w = DetailPreview.width - 32
        let title = NSTextField(wrappingLabelWithString: todo.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.isSelectable = true
        title.preferredMaxLayoutWidth = w
        var rows: [NSView] = [title]

        var meta: [String] = []
        if !todo.dueDate.isEmpty {
            let name = Clock.friendly(todo.dueDate, now: Date(), tz)
            meta.append(name.prefix(1).uppercased() + name.dropFirst() + (todo.dueTime.isEmpty ? "" : " \(todo.dueTime)"))
        }
        if !todo.list.isEmpty { meta.append(todo.list) }
        if todo.priority == "high" { meta.append("Prioritas tinggi") }
        if !meta.isEmpty { rows.append(UI.label(meta.joined(separator: " · "), size: 11, color: .secondaryLabelColor)) }
        let line = NSBox()
        line.boxType = .separator
        rows.append(line)

        // Detail: NSTextView non-edit (link bisa diklik, teks bisa dipilih); menggulir bila panjang
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand]
        textView.textStorage?.setAttributedString(DetailPreview.detailString(todo.notes))
        textView.setAccessibilityLabel("Detail")
        textView.copyAll = { [weak self] in self?.copyAll() }
        textView.frame = NSRect(x: 0, y: 0, width: w, height: 10)
        var h: CGFloat = 16
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            h = ceil(lm.usedRect(for: tc).height) + 2
        }
        textView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = h > DetailPreview.maxDetailHeight
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: min(h, DetailPreview.maxDetailHeight)).isActive = true
        rows.append(scroll)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.toolTip = "Salin judul & detail (⌘C)"
        let edit = NSButton(title: "Ubah…", target: self, action: #selector(editTapped))
        edit.bezelStyle = .rounded
        edit.controlSize = .small
        let buttons = UI.stack([NSView(), copyButton, edit], vertical: false, spacing: 8)
        rows.append(buttons)

        let stack = UI.stack(rows, spacing: 8)
        for v in rows where v !== title { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = NSView()
        UI.pin(stack, to: root, top: 14, left: 16, bottom: 12, right: 16)
        root.widthAnchor.constraint(equalToConstant: DetailPreview.width).isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView) // ⌘C langsung bekerja
    }

    @objc func copyAll() {
        TodoCopy.copy([todo])
        copyButton.title = "Disalin"
        onCopied?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = "Salin" }
    }

    @objc private func editTapped() { onEdit?() }
}

enum UI {
    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// Teks berlipat yang bisa dipilih / disalin. width = lebar maksimum.
    static func text(_ s: String, width: CGFloat, size: CGFloat = 13, color: NSColor = .labelColor, lineSpacing: CGFloat = 2) -> NSTextField {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                             .foregroundColor: color, .paragraphStyle: p])
        l.isSelectable = true
        l.preferredMaxLayoutWidth = width
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        return l
    }

    static func symbol(_ name: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Tombol ikon tanpa bingkai (header popover).
    static func iconButton(_ name: String, tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: symbol(name, 15) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.contentTintColor = .secondaryLabelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let v = NSStackView(views: views)
        v.orientation = vertical ? .vertical : .horizontal
        v.alignment = vertical ? .leading : .centerY
        v.spacing = spacing
        return v
    }

    /// Tempel v ke keempat sisi p. v dimasukkan ke p dulu bila belum: constraint antar-view tanpa induk bersama
    /// melempar exception yang ditelan AppKit (dulu membuat popover diam-diam gagal tampil).
    static func pin(_ v: NSView, to p: NSView, top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        if v.superview !== p { p.addSubview(v) }
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: p.topAnchor, constant: top),
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: left),
            v.bottomAnchor.constraint(equalTo: p.bottomAnchor, constant: -bottom),
            v.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -right),
        ])
    }

    /// Scroll vertikal berisi tumpukan; lebar dokumen = lebar scroll.
    static func scroll(_ stack: NSStackView) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.scrollerStyle = .overlay // lebar isi tetap, walau "selalu tampilkan scroll bar" aktif
        s.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        s.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: s.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: s.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: s.contentView.topAnchor),
        ])
        pin(stack, to: doc)
        return s
    }

    static func scrollToBottom(_ s: NSScrollView) {
        guard let doc = s.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        // contentInsets.bottom = ruang di bawah kotak input kaca yang melayang di atas chat
        let y = max(-s.contentInsets.top, doc.frame.height + s.contentInsets.bottom - s.contentView.bounds.height)
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
    }

    static func dot(_ ok: Bool) -> NSImageView {
        let iv = NSImageView(image: symbol("circle.fill", 9) ?? NSImage())
        iv.contentTintColor = ok ? .systemGreen : .systemOrange
        return iv
    }
}

// MARK: - Popover menu bar: tab Chat (gaya Claude), Todo, Pengingat

/// Isi popover saat ikon menu bar diklik. Tiga tab, satu tujuan per tab:
/// Chat = minta asisten, Todo & Pengingat = kelola manual. "Selesai" selalu filter paling ujung
/// (klik ✓ di sana = batalkan selesai).
///   ┌ [ Chat | Todo | Pengingat ]       🌐 ⚙︎ ┐
///   │                       ┌─────────────┐ │  ← pesan pengguna: gelembung di kanan
///   │                       └─────────────┘ │
///   │ Jawaban asisten penuh lebar, tanpa    │  ← jawaban AI: teks polos
///   │ gelembung.                            │
///   │ (☀︎ Apa saja todo hari ini?) (ⓘ Yang te… │  ← contoh pertanyaan: chip kaca, geser ke samping (SuggestionBar)
///   └ ( ✦ Tulis pesan…                  ↑ ) ┘  ← kotak input kaca (isi chat di belakangnya buram)
///
/// Tab Todo:
///   ┌ [ Chat | Todo | Pengingat ]       🌐 ⚙︎ ┐
///   │ ┌ Judul todo…                       ┐ │  ← kartu tambah cepat (＋ / ⌘N; sembunyi di Selesai)
///   │ │ Hari ini ▾  ☐ Jam [09.00⇅] [Tambah] │ │     jam lewat time picker
///   │ └                     Isian lengkap… ┘ │  ← form lengkap di tempat kartu (detail, kategori, …)
///   │ [ Hari ini 3 | Semua 12 | Selesai ]   │  ← filter kecil; Selesai = todo yang sudah selesai (✓ = buka lagi)
///   │ ○ Bayar listrik                       │  ← ○ = selesai (tahan ⌥: ✎ ubah) · klik teks = salin
///   │   Prioritas tinggi · 🔔 Besok 08:00    │  ← todo yang punya pengingat: ikon 🔔 + waktu berikutnya
///   └ Sinkron 10.42                         ┘
///
/// Tab Pengingat (pengingat tanpa todo; pengingat milik todo = 🔔 di baris todo-nya):
///   │ ┌ Judul pengingat…                  ┐ │  ← kartu tambah cepat (＋ / ⌘N), sama dengan tab Todo
///   │ │ Todo [Tanpa todo              ▾] │ │     todo terkait: judul kosong → judul todo, Kapan/jam → tenggatnya
///   │ │ Hari ini ▾  [10.00⇅]      [Tambah] │ │     Kapan: Hari ini / Besok / Lusa / Tiap hari
///   │ └                     Isian lengkap… ┘ │  ← pesan, todo terkait, jadwal (sekali/harian/mingguan/bulanan)
///   │ [ Hari ini 2 | Semua 5 | Selesai ]    │  ← Semua = semua pengingat aktif per hari, termasuk milik todo
///   │ ○ Minum obat                          │  ← ○ = tandai selesai (berhenti berbunyi) · klik teks = salin
///   │   Besok 08:00 · Tiap hari 08:00       │     klik dua kali / klik kanan → Ubah… (Pengaturan → Pengingat)
///   │ Pengingat baru… · Kelola di Pengaturan │
///
/// Mode ubah (satu todo, kartu menggantikan barisnya di daftar — lihat `TodoEditor`):
///   ⌥ + klik lingkaran · klik dua kali judul · klik kanan → Ubah…   ↩ simpan, esc batal
final class PopoverController: NSViewController, NSGestureRecognizerDelegate {
    enum Mode: Int { case chat, todo, reminders, notes }
    static let size = NSSize(width: 400, height: 600)
    static let inset: CGFloat = 16
    /// Lebar isi (tanpa margin kiri-kanan).
    static let contentWidth = size.width - inset * 2

    unowned let app: AppDelegate
    var store: Store { app.store }
    private(set) var mode: Mode = .chat

    private let segment = NSSegmentedControl(labels: ["Chat", "Todo", "Pengingat", "Catatan"], trackingMode: .selectOne, target: nil, action: nil)
    private let chatBox = NSView()
    /// Isi tab Todo & Pengingat (kartu tambah, filter, daftar, status sinkron).
    private let manualBox = NSView()
    private let offlineBox = NSView()
    /// Isi tab Catatan (Notes.swift): kartu tambah, filter + cari, daftar, status sinkron.
    private lazy var notesPane: NotesPane = {
        let p = NotesPane(app: app)
        p.onCardChanged = { [weak self] in self?.updateAddCard() }
        return p
    }()
    private let offlineTitle = UI.label("", size: 15, weight: .semibold)
    private let offlineNote: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.preferredMaxLayoutWidth = 300
        return l
    }()

    // Chat
    private let chatStack = UI.stack([], spacing: 14)
    private lazy var chatScroll = UI.scroll(chatStack)
    private let input = NSTextField()
    /// Tinggi kolom input & kapsulnya; tumbuh mengikuti isi (⇧↩ = baris baru) sampai `inputMaxLines`.
    private lazy var inputHeight = input.heightAnchor.constraint(equalToConstant: 18)
    private lazy var inputGlassHeight = inputGlass.heightAnchor.constraint(equalToConstant: 44)
    private static let inputMaxLines: CGFloat = 6
    private let sendBox = RoundedBox(fill: Theme.accent, radius: 15)
    private let inputGlass = GlassBox(radius: 22)
    private let actionBar = GlassBox(radius: 14)
    private let actionIcon = NSImageView()
    private let actionLabel = UI.label("", size: 12)
    /// Input + bar aksi yang melayang di atas chat (tingginya dipakai untuk ruang bawah scroll).
    private let chatBottom = UI.stack([], spacing: 8)
    /// Contoh pertanyaan (carousel chip) di atas input; tampil hanya saat input kosong & tidak ada konfirmasi.
    private let suggestions = SuggestionBar(Suggestion.all)
    private lazy var confirmButton = button("Ya, lakukan", #selector(confirm))
    private lazy var rejectButton = button("Batal", #selector(reject))
    private lazy var undoButton = button("Batalkan aksi terakhir", #selector(undo))
    /// Tutup bar undo tanpa membatalkan aksi (masih bisa lewat /undo).
    private lazy var dismissUndoButton: NSButton = {
        let b = NSButton(image: UI.symbol("xmark.circle.fill", 14) ?? NSImage(), target: self, action: #selector(dismissUndo))
        b.isBordered = false
        b.toolTip = "Tutup (aksi tetap bisa dibatalkan lewat /undo)"
        b.setAccessibilityLabel("Tutup")
        b.contentTintColor = .tertiaryLabelColor
        return b
    }()
    private var thinkingRow: NSView?
    private var pending: BatchView?
    private var undoable: BatchView?
    private var busy = false { didSet { updateControls() } }
    private lazy var clearButton = UI.iconButton("trash", tip: "Hapus riwayat chat", self, #selector(confirmClearHistory))
    /// Tombol ＋ di header (tab Todo & Pengingat): buka / tutup kartu tambah cepat (⌘N).
    /// ⌥-klik = langsung ke isian lengkap.
    private lazy var newTodoButton: NSButton = {
        let b = UI.iconButton("plus", tip: "Todo baru (⌘N)", self, #selector(toggleAddCard))
        KeyBindings.bind(b, .newItem, tip: nil) // bawaan ⌘N (Pengaturan → Pintasan); tooltip di updateAddCard
        return b
    }()
    /// Kartu tambah terbuka? Bawaan tertutup supaya daftar tetap ringkas.
    private var addCardOpen = false
    /// Tombol ↻ di header (di samping ⚙): sinkron ulang data dari server sekarang (⌘R).
    private lazy var resyncButton: NSButton = {
        let b = UI.iconButton("arrow.clockwise", tip: "Sinkronkan ulang dari server (⌘R)", self, #selector(resyncTapped))
        KeyBindings.bind(b, .resync, tip: "Sinkronkan ulang dari server") // bawaan ⌘R
        return b
    }()
    /// Kolom cari di samping filter, selalu tampil di tab Todo & Pengingat (dulu di balik tombol 🔍):
    /// menyaring daftar yang sedang tampil (judul, detail, kategori / pesan, jadwal). Popover dibuka → langsung bisa mengetik.
    private let searchField = NSSearchField()
    private var keyMonitor: Any?

    // Manual
    private let titleField = NSTextField()
    /// Kapan: tag = selisih hari (-1 tanpa tenggat, 0 hari ini, 1 besok, 2 lusa) atau `PopoverController.dailyTag`.
    private let duePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let dailyTag = 100
    /// Jam lewat time picker (bukan diketik); di tab Todo opsional lewat kotak centang "Jam".
    private let timeCheck = NSButton(checkboxWithTitle: "Jam", target: nil, action: nil)
    private let timePicker = NSDatePicker()
    private lazy var addButton = button("Tambah", #selector(addManual))
    /// Tab Pengingat: todo terkait (pengingatnya tampil sebagai 🔔 di baris todo itu); tag 0 = tanpa todo.
    private let quickTodoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var quickTodoRow = UI.stack([UI.label("Todo", size: 11, color: .secondaryLabelColor), quickTodoPopup],
                                             vertical: false, spacing: 8)
    /// Judul yang diisi otomatis dari todo terkait (diganti lagi bila todo lain dipilih, selama belum diubah).
    private var quickAutoTitle: String?
    /// Kapan / jam sudah diubah pengguna → tidak ditimpa saat memilih todo terkait.
    private var quickWhenEdited = false
    private let addError = UI.label("", size: 11, color: Theme.danger)
    /// "Isian lengkap…": ganti kartu cepat dengan form lengkap (detail, kategori, prioritas, tanggal, jadwal…).
    private lazy var advancedButton: NSButton = {
        let b = NSButton(title: "Isian lengkap…", target: self, action: #selector(openAdvanced))
        b.isBordered = false
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.contentTintColor = Theme.accent
        return b
    }()
    /// Tempat kartu tambah: berisi kartu cepat (`addCard`) atau form lengkap (`advancedForm`).
    private let addHost = NSView()
    /// Form lengkap yang sedang terbuka (TodoEditor / ReminderEditor ringkas), nil = kartu cepat.
    private var advancedForm: NSView?
    /// Filter daftar, isinya ikut tab: Todo = Hari ini | Semua | Selesai, Pengingat = Hari ini | Semua | Selesai.
    private let scope = NSSegmentedControl(labels: PopoverController.todoScopes, trackingMode: .selectOne, target: nil, action: nil)
    private static let todoScopes = ["Hari ini", "Semua", "Selesai"]
    private static let reminderScopes = ["Hari ini", "Semua", "Selesai"]
    /// Todo selesai (diambil saat filter Selesai dibuka), terbaru di atas.
    private var doneTodos: [Todo] = []
    private var loadingDone = false
    /// Kartu tambah cepat; di tab Todo & Pengingat (bukan filter Selesai).
    private let addCard = RoundedBox(fill: .controlBackgroundColor, stroke: .separatorColor, radius: 12)
    /// Filter + kolom cari dalam satu baris: [Hari ini | Semua | Selesai] [🔍 Cari…        ].
    private lazy var filterBar = UI.stack([scope, searchField], vertical: false, spacing: 8)
    private lazy var scopeBelowCard = filterBar.topAnchor.constraint(equalTo: addHost.bottomAnchor, constant: 12)
    private lazy var scopeAtTop = filterBar.topAnchor.constraint(equalTo: manualBox.topAnchor, constant: 12)
    /// Batas baris di tampilan Semua; sisanya lewat tautan ke browser.
    static let maxAllRows = 200
    // Mode ubah
    /// Tombol lingkaran yang sedang tampil (id todo → tombol & todo), untuk ganti ikon saat ⌥ ditekan.
    private var checkButtons: [(button: NSButton, todo: Todo)] = []
    private var optionDown = false { didSet { if optionDown != oldValue { updateCheckIcons() } } }
    // Mode urutkan
    /// ⌃ ditahan → lingkaran berubah jadi ≡ yang bisa diseret untuk mengubah urutan (hanya di Mac ini).
    private var controlDown = false { didSet { if controlDown != oldValue { updateCheckIcons() } } }
    /// Tombol lingkaran pengingat yang sedang tampil (ganti ikon saat ⌃ ditekan).
    private var reminderChecks: [(button: NSButton, reminder: Reminder)] = []
    /// Kelompok baris yang bisa diurutkan (baris berurutan di `listStack`), diisi saat daftar dibangun.
    private var reorderGroups: [(reminders: Bool, items: [(id: Int64, view: NSView)])] = []
    /// Sedang menyeret baris: daftar tidak dibangun ulang (sinkron ditunda sampai mouse dilepas).
    private var reordering = false
    private var editor: TodoEditor?
    private var flagsMonitor: Any?
    private let listStack = UI.stack([], spacing: 6)
    private lazy var listScroll = UI.scroll(listStack)
    private let syncLabel = UI.label("", size: 11, color: .tertiaryLabelColor)
    /// Pratinjau detail yang sedang terbuka (dipegang supaya tidak lepas saat tampil).
    private var detailPopover: NSPopover?
    /// Baris todo yang tampil (id → baris), jangkar pratinjau dari menu klik kanan.
    private var rowViews: [Int64: NSView] = [:]
    /// Store berubah selama popover tertutup → daftar perlu dibangun ulang sebelum tampil lagi.
    private var listStale = true

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: PopoverController.size))
        preferredContentSize = PopoverController.size

        // Header: tab + tombol pendukung
        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0
        // Empat tab (Catatan ditambahkan): lebar menurut label + huruf 12 pt supaya header tetap muat ＋ 🌐 ↻ ⚙
        // (dulu 3 × 80, sebelumnya 3 × 88)
        segment.font = .systemFont(ofSize: 12)
        for (i, w) in [50, 50, 72, 64].enumerated() { segment.setWidth(CGFloat(w), forSegment: i) }
        segment.translatesAutoresizingMaskIntoConstraints = false
        let web = UI.iconButton("globe", tip: "Buka AI Todo di browser", self, #selector(openWeb))
        let gear = UI.iconButton("gearshape", tip: "Pengaturan (⌘,)", self, #selector(openSettings))
        let header = UI.stack([segment, NSView(), clearButton, newTodoButton, web, resyncButton, gear], vertical: false, spacing: 4)
        header.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, line, chatBox, manualBox, notesPane, offlineBox] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let i = PopoverController.inset
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: i),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -(i - 4)),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        for box in [chatBox, manualBox, notesPane, offlineBox] {
            NSLayoutConstraint.activate([
                box.topAnchor.constraint(equalTo: line.bottomAnchor),
                box.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                box.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                box.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        buildChat()
        buildManual()
        buildOffline()
        view = root
        storeChanged()
    }

    /// Ruang kosong di bawah chat setinggi input yang melayang, supaya pesan terakhir tidak tertutup.
    override func viewDidLayout() {
        super.viewDidLayout()
        resizeInput() // lebar input baru diketahui setelah tata letak
        let h = chatBottom.frame.height + PopoverController.inset + 8
        if chatScroll.contentInsets.bottom != h {
            chatScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: h, right: 0)
            UI.scrollToBottom(chatScroll)
        }
    }

    // MARK: Tata letak chat

    private func buildChat() {
        let i = PopoverController.inset
        chatStack.edgeInsets = NSEdgeInsets(top: 14, left: i, bottom: 14, right: i)

        // Bar konfirmasi / undo di atas input (kaca juga)
        actionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        confirmButton.keyEquivalent = "\r"
        let bar = UI.stack([actionIcon, actionLabel, NSView(), rejectButton, confirmButton, undoButton, dismissUndoButton], vertical: false, spacing: 6)
        UI.pin(bar, to: actionBar.content, top: 7, left: 12, bottom: 7, right: 8)

        // Kotak input kaca berbentuk kapsul (gaya kolom Search Apple): ikon, teks, tombol kirim bulat
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 14)
        input.placeholderString = "Tulis tugas atau tanya asisten…"
        // Multi-baris: ↩ kirim, ⇧↩ (atau ⌥↩) baris baru — lihat control(_:textView:doCommandBy:)
        input.usesSingleLineMode = false
        input.cell?.isScrollable = false
        input.cell?.wraps = true
        input.lineBreakMode = .byWordWrapping
        input.maximumNumberOfLines = 0
        input.delegate = self
        input.target = self
        input.action = #selector(send)
        input.setAccessibilityLabel("Pesan untuk asisten")
        let spark = NSImageView(image: UI.symbol("sparkles", 15) ?? NSImage())
        spark.contentTintColor = .secondaryLabelColor
        let send = NSButton(image: UI.symbol("arrow.up", 13, weight: .bold) ?? NSImage(), target: self, action: #selector(send))
        send.isBordered = false
        send.contentTintColor = Theme.accentText
        send.toolTip = "Kirim (↩) · baris baru (⇧↩)"
        send.setAccessibilityLabel("Kirim")
        UI.pin(send, to: sendBox)
        let box = inputGlass.content
        for v in [spark, input, sendBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            inputGlassHeight,
            inputHeight,
            // Ikon & tombol kirim menempel di baris terakhir saat input tumbuh (seperti Pesan/Messages)
            spark.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            spark.centerYAnchor.constraint(equalTo: sendBox.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: spark.trailingAnchor, constant: 8),
            input.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: sendBox.leadingAnchor, constant: -8),
            sendBox.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            sendBox.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
            sendBox.widthAnchor.constraint(equalToConstant: 30),
            sendBox.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Chat memenuhi seluruh area; input & bar aksi melayang di atasnya → teks yang lewat di belakang jadi buram.
        chatScroll.automaticallyAdjustsContentInsets = false
        suggestions.onPick = { [weak self] text in self?.sendMessage(text) }
        suggestions.onHide = { [weak self] in self?.app.toggleSuggestions() }
        chatBottom.addArrangedSubview(actionBar)
        chatBottom.addArrangedSubview(suggestions)
        chatBottom.addArrangedSubview(inputGlass)
        for v in [actionBar, suggestions, inputGlass] { v.widthAnchor.constraint(equalTo: chatBottom.widthAnchor).isActive = true }
        UI.pin(chatScroll, to: chatBox)
        chatBottom.translatesAutoresizingMaskIntoConstraints = false
        chatBox.addSubview(chatBottom) // setelah scroll → di atasnya
        NSLayoutConstraint.activate([
            chatBottom.leadingAnchor.constraint(equalTo: chatBox.leadingAnchor, constant: i),
            chatBottom.trailingAnchor.constraint(equalTo: chatBox.trailingAnchor, constant: -i),
            chatBottom.bottomAnchor.constraint(equalTo: chatBox.bottomAnchor, constant: -i),
        ])
        resizeInput()
        updateControls()
    }

    /// Sesuaikan tinggi input dengan isinya (1 … inputMaxLines baris); lebih dari itu input menggulir.
    private func resizeInput() {
        guard let cell = input.cell, let font = input.font else { return }
        let line = ceil(font.ascender - font.descender + font.leading)
        let width = max(input.bounds.width, 100)
        var text = input.stringValue
        if let editor = input.currentEditor() { text = editor.string }
        // Baris kosong di akhir (baru tekan ⇧↩) tetap dihitung
        if text.isEmpty || text.hasSuffix("\n") { text += " " }
        let measure = cell.copy() as! NSCell
        measure.stringValue = text
        let h = measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(ceil(h), line), line * PopoverController.inputMaxLines)
        guard inputHeight.constant != height else { return }
        inputHeight.constant = height
        inputGlassHeight.constant = max(44, height + 26)
    }

    /// Pesan pengguna: gelembung teal lembut, rata kanan, maks ±75% lebar.
    private func addUser(_ text: String) {
        let font = NSFont.systemFont(ofSize: 13)
        let maxW = PopoverController.contentWidth * 0.75
        let measured = (text as NSString).boundingRect(with: NSSize(width: maxW, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: font], context: nil).width
        let w = min(maxW, ceil(measured) + 6)
        let l = UI.text(text, width: w)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: w).isActive = true
        let bubble = RoundedBox(fill: Theme.bubble, radius: 14)
        bubble.addSubview(l)
        UI.pin(l, to: bubble, top: 8, left: 12, bottom: 8, right: 12)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor),
        ])
        addRow(row)
    }

    /// Jawaban asisten: teks polos penuh lebar + daftar aksi di bawahnya.
    private func addAssistant(_ text: String, items: [BatchItem] = [], muted: Bool = false, error: Bool = false) {
        let w = PopoverController.contentWidth
        let color: NSColor = error ? Theme.danger : (muted ? .secondaryLabelColor : .labelColor)
        var views: [NSView] = [UI.text(text, width: w, size: 13, color: color, lineSpacing: 3)]
        for it in items {
            let icon = NSImageView(image: UI.symbol("checkmark.circle", 11) ?? NSImage())
            icon.contentTintColor = Theme.accent
            let l = UI.text(it.summary, width: w - 20, size: 12, color: .secondaryLabelColor)
            let r = UI.stack([icon, l], vertical: false, spacing: 6)
            r.alignment = .firstBaseline
            views.append(r)
        }
        let block = UI.stack(views, spacing: 6)
        addRow(block)
    }

    private func addRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        chatStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: chatStack.widthAnchor, constant: -2 * PopoverController.inset).isActive = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UI.scrollToBottom(self.chatScroll)
        }
    }

    private func setThinking(_ on: Bool) {
        thinkingRow?.removeFromSuperview()
        thinkingRow = nil
        guard on else { return }
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        let r = UI.stack([spin, UI.label("Asisten sedang berpikir…", size: 12, color: .secondaryLabelColor)], vertical: false, spacing: 8)
        thinkingRow = r
        addRow(r)
    }

    private func clearChat() {
        chatStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thinkingRow = nil
    }

    private func updateControls() {
        let hasPending = pending != nil
        confirmButton.isHidden = !hasPending
        rejectButton.isHidden = !hasPending
        undoButton.isHidden = hasPending || undoable == nil
        dismissUndoButton.isHidden = undoButton.isHidden
        actionBar.isHidden = !hasPending && undoable == nil
        actionIcon.image = UI.symbol(hasPending ? "exclamationmark.circle.fill" : "arrow.uturn.backward.circle", 14)
        actionIcon.contentTintColor = hasPending ? .systemOrange : Theme.accent
        actionLabel.stringValue = hasPending ? "Perlu konfirmasimu" : "Aksi terakhir sudah dijalankan"
        [confirmButton, rejectButton, undoButton].forEach { $0.isEnabled = !busy }
        input.isEnabled = !busy
        sendBox.alphaValue = busy ? 0.4 : 1
        updateSuggestions()
        // Hapus riwayat: hanya di tab Chat, saat terhubung, dan tidak sedang menunggu server
        clearButton.isEnabled = !busy && store.connected && mode == .chat
        // Di tab Todo & Pengingat tempatnya dipakai tombol cari
        clearButton.isHidden = mode != .chat
        resyncButton.isHidden = !store.connected
    }

    private func setBatch(_ b: BatchView?) {
        guard let b else { return }
        switch b.status {
        case "pending": pending = b
        case "applied":
            if pending?.id == b.id { pending = nil }
            undoable = b.undoable && b.id != LocalPrefs.dismissedUndoBatch ? b : nil
        default:
            if pending?.id == b.id { pending = nil }
            if undoable?.id == b.id { undoable = nil }
        }
        updateControls()
    }

    func loadHistory() {
        guard store.connected, !busy else { return }
        store.api.chatHistory { [weak self] r in
            DispatchQueue.main.async {
                guard let self, !self.busy, case .success(let page) = r else { return }
                self.clearChat()
                self.pending = nil
                self.undoable = nil
                if page.messages.isEmpty {
                    self.addAssistant("Halo! Ceritakan saja apa yang perlu dikerjakan, mis. “beli galon, bayar wifi, servis motor sabtu”. Tanpa AI: /todo, /hari-ini, /undo, /bantuan.", muted: true)
                }
                for m in page.messages.suffix(30) {
                    let batch = m.batchId.flatMap { page.batches[String($0)] }
                    if m.role == "user" { self.addUser(m.content) } else {
                        self.addAssistant(m.content, items: batch?.items ?? [])
                        self.setBatch(batch)
                    }
                }
                self.updateControls()
            }
        }
    }

    /// Carousel contoh pertanyaan: sembunyi saat mengetik, saat menunggu konfirmasi, atau dimatikan pengguna.
    private func updateSuggestions() {
        var typed = input.stringValue
        if let editor = input.currentEditor() { typed = editor.string }
        let show = LocalPrefs.showSuggestions && pending == nil && typed.isEmpty
        if show && suggestions.isHidden { suggestions.scrollToStart() }
        suggestions.isHidden = !show
        suggestions.isEnabled = !busy && store.connected
    }

    @objc private func send() {
        sendMessage(input.stringValue)
    }

    /// Kirim pesan dari kotak input atau dari chip contoh pertanyaan.
    private func sendMessage(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, store.connected else { return }
        input.stringValue = ""
        resizeInput()
        addUser(text)
        busy = true
        setThinking(true)
        store.api.chat(text) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setThinking(false)
                self.busy = false
                switch r {
                case .success(let rep):
                    self.addAssistant(rep.assistant.content, items: rep.batch?.items ?? [])
                    self.setBatch(rep.batch)
                    if rep.batch != nil { self.store.refresh() }
                case .failure(let e):
                    self.addAssistant("Gagal mengirim: \(e.description)", error: true)
                    self.input.stringValue = text
                    self.resizeInput()
                }
                self.view.window?.makeFirstResponder(self.input)
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
                    self.addAssistant(label, items: action == "confirm" ? res.batch.items : [], muted: action != "confirm")
                    if action == "undo" { self.undoable = nil }
                    self.setBatch(res.batch)
                    self.store.refresh()
                case .failure(let e):
                    self.addAssistant("Gagal: \(e.description)", error: true)
                    if action != "undo" { self.pending = nil }
                    self.updateControls()
                }
            }
        }
    }

    @objc private func confirm() { batchAction(pending, "confirm", done: "Sudah kujalankan.") }
    @objc private func reject() { batchAction(pending, "reject", done: "Oke, dibatalkan.") }
    @objc private func undo() { batchAction(undoable, "undo", done: "Aksi terakhir sudah dibatalkan.") }
    @objc private func dismissUndo() {
        guard let b = undoable else { return }
        LocalPrefs.dismissedUndoBatch = b.id
        undoable = nil
        updateControls()
    }

    // MARK: Tata letak manual

    private func buildManual() {
        let i = PopoverController.inset
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Judul todo, mis. Bayar listrik"
        titleField.target = self
        titleField.action = #selector(addManual)
        titleField.delegate = self // Esc = tutup kartu tambah
        titleField.setAccessibilityLabel("Judul todo baru")
        duePopup.controlSize = .small
        duePopup.target = self
        duePopup.action = #selector(quickWhenPicked)
        duePopup.setAccessibilityLabel("Kapan")
        quickTodoPopup.controlSize = .small
        quickTodoPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        quickTodoPopup.target = self
        quickTodoPopup.action = #selector(quickTodoPicked)
        quickTodoPopup.setAccessibilityLabel("Todo terkait")
        quickTodoPopup.toolTip = "Todo terkait: pengingatnya tampil sebagai 🔔 di baris todo itu. Judul kosong = diisi judul todo."
        quickTodoPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Jam: time picker 24 jam (ketik angka atau pakai panah), sama dengan kartu ubah
        timeCheck.controlSize = .small
        timeCheck.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeCheck.target = self
        timeCheck.action = #selector(quickWhenChanged)
        timeCheck.setAccessibilityLabel("Pakai jam")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        timePicker.calendar = cal
        timePicker.timeZone = store.tz
        timePicker.locale = Locale(identifier: "id_ID")
        timePicker.controlSize = .small
        timePicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timePicker.isBezeled = true
        timePicker.drawsBackground = true
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.setAccessibilityLabel("Jam")
        timePicker.target = self
        timePicker.action = #selector(quickTimePicked)
        addButton.bezelColor = Theme.accent
        addError.isHidden = true
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)
        configureScope()
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self // Esc = kosongkan; kosong → tutup popover
        searchField.target = self   // ketik / tombol ⓧ = saring ulang
        searchField.action = #selector(searchFieldChanged)
        // Isi sisa lebar baris filter; filter tetap selebar labelnya
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scope.setContentHuggingPriority(.required, for: .horizontal)
        scope.setContentCompressionResistancePriority(.required, for: .horizontal)
        // ⌘F = fokus ke kolom cari (pintasan standar macOS); ⌘1 / ⌘2 / ⌘3 = pindah tab,
        // ⌃⇥ / ⌃⇧⇥ = tab berikutnya / sebelumnya. Semua bisa diubah di Pengaturan → Pintasan.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.view.window, !ShortcutField.recording,
                  let a = Shortcuts.action(keyCode: Int(e.keyCode), mods: KeyCombo.modifiers(e.modifierFlags), in: LocalPrefs.keys)
            else { return e }
            return self.perform(a) ? nil : e
        }
        // ⌥ ditahan → lingkaran berubah jadi ✎ (pola tombol alternatif ⌥ di macOS)
        // ⌃ ditahan → lingkaran berubah jadi ≡ (seret untuk mengubah urutan)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.optionDown = e.modifierFlags.contains(.option)
            self?.controlDown = e.modifierFlags.contains(.control)
            return e
        }

        //   ┌ Judul…                                   ┐
        //   │ Todo [Tanpa todo                      ▾] │  ← hanya tab Pengingat
        //   │ [Hari ini ▾]  ☑ Jam [09.00 ⇅]    [Tambah] │
        //   └ pesan galat              Isian lengkap… ┘
        let opts = UI.stack([duePopup, timeCheck, timePicker, NSView(), addButton], vertical: false, spacing: 8)
        opts.setCustomSpacing(4, after: timeCheck)
        let foot = UI.stack([addError, NSView(), advancedButton], vertical: false, spacing: 8)
        addError.lineBreakMode = .byTruncatingTail
        addError.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let form = UI.stack([titleField, quickTodoRow, opts, foot], spacing: 6)
        form.setCustomSpacing(8, after: titleField)
        for v in [titleField, quickTodoRow, opts, foot] as [NSView] { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        let card = addCard
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 8, right: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        addHost.addSubview(card)
        UI.pin(card, to: addHost)

        listStack.edgeInsets = NSEdgeInsets(top: 4, left: i, bottom: 12, right: i)
        for v in [addHost, filterBar, listScroll, syncLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            manualBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            addHost.topAnchor.constraint(equalTo: manualBox.topAnchor, constant: 12),
            addHost.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            addHost.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor, constant: -i),
            filterBar.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            filterBar.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor, constant: -i),
            listScroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 2),
            listScroll.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: syncLabel.topAnchor, constant: -6),
            syncLabel.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            syncLabel.trailingAnchor.constraint(lessThanOrEqualTo: manualBox.trailingAnchor, constant: -i),
            syncLabel.bottomAnchor.constraint(equalTo: manualBox.bottomAnchor, constant: -10),
        ])
        resetQuickCard()
        updateAddCard()
    }

    private var showAll: Bool { mode == .todo && scope.selectedSegment == 1 }
    /// Tab Pengingat, filter Semua.
    private var showAllReminders: Bool { mode == .reminders && scope.selectedSegment == 1 }
    /// Filter paling ujung = Selesai (di tab Todo maupun Pengingat).
    private var showDone: Bool { scope.selectedSegment == scope.segmentCount - 1 }

    /// Isi filter mengikuti tab; pilihan tiap tab diingat.
    private func configureScope() {
        let titles = mode == .reminders ? PopoverController.reminderScopes : PopoverController.todoScopes
        if scope.segmentCount != titles.count { scope.segmentCount = titles.count }
        for (i, t) in titles.enumerated() {
            scope.setLabel(t, forSegment: i)
            scope.setWidth(0, forSegment: i) // lebar mengikuti label
        }
        scope.selectedSegment = mode == .reminders ? LocalPrefs.reminderScope : LocalPrefs.todoScope
        scope.menu = mode == .todo ? todoGroupMenu : nil // klik kanan filter = pilih cara mengelompokkan todo
        scope.setAccessibilityLabel(mode == .reminders ? "Tampilkan pengingat" : "Tampilkan todo")
        searchField.placeholderString = mode == .reminders ? "Cari judul, pesan, atau todo" : "Cari judul, detail, atau kategori"
        searchField.setAccessibilityLabel(mode == .reminders ? "Cari pengingat" : "Cari todo")
        scope.toolTip = mode == .reminders
            ? "Hari ini: pengingat tanpa todo yang berbunyi hari ini. Semua: semua pengingat aktif, termasuk milik todo. " +
              "Selesai: dijeda / sudah berbunyi (✓ = aktifkan lagi)."
            : "Hari ini: terlambat & hari ini. Semua: semua todo yang belum selesai. Selesai: ✓ = buka lagi.\n" +
              "Klik kanan untuk mengelompokkan menurut waktu atau kategori."
    }

    /// Kartu tambah hanya di tab Todo / Pengingat (bukan Selesai) dan setelah ＋ ditekan; selain itu filter naik ke atas.
    private func updateAddCard() {
        // Tab Catatan: kartu tambahnya milik NotesPane (tidak ada filter Selesai)
        let notes = mode == .notes
        let canAdd = notes || (mode != .chat && !showDone)
        let noun = notes ? "Catatan" : mode == .reminders ? "Pengingat" : "Todo"
        let addCardOpen = notes ? notesPane.addCardOpen : self.addCardOpen
        newTodoButton.isHidden = !canAdd
        newTodoButton.contentTintColor = addCardOpen ? Theme.accent : .secondaryLabelColor
        let key = LocalPrefs.keys[.newItem].map { " (\($0.display))" } ?? ""
        newTodoButton.toolTip = addCardOpen ? "Tutup form \(noun.lowercased()) baru (Esc)"
                                            : "\(noun) baru\(key) · ⌥-klik: isian lengkap"
        newTodoButton.setAccessibilityLabel(addCardOpen ? "Tutup form \(noun.lowercased()) baru" : "\(noun) baru")
        let card = canAdd && addCardOpen && !notes
        addHost.isHidden = !card
        scopeBelowCard.isActive = card
        scopeAtTop.isActive = !card
    }

    /// Isi kartu cepat mengikuti tab (dipanggil saat kartu dibuka / dikosongkan).
    ///   Todo:      [Tanpa tenggat | Hari ini | Besok | Lusa ▾]  ☐ Jam [⇅]  — jam opsional
    ///   Pengingat: [Hari ini | Besok | Lusa | — | Tiap hari ▾]   [⇅]      — jam wajib, bawaan jam penuh berikutnya
    private func resetQuickCard() {
        let reminders = mode == .reminders
        titleField.stringValue = ""
        titleField.placeholderString = reminders ? "Judul pengingat, mis. Minum obat" : "Judul todo, mis. Bayar listrik"
        titleField.setAccessibilityLabel(reminders ? "Judul pengingat baru" : "Judul todo baru")
        addError.isHidden = true
        duePopup.removeAllItems()
        func item(_ title: String, _ tag: Int) {
            duePopup.addItem(withTitle: title)
            duePopup.lastItem?.tag = tag
        }
        if !reminders { item("Tanpa tenggat", -1) }
        item("Hari ini", 0)
        item("Besok", 1)
        item("Lusa", 2)
        if reminders {
            duePopup.menu?.addItem(.separator())
            item("Tiap hari", PopoverController.dailyTag)
        }
        duePopup.selectItem(withTag: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        timePicker.calendar = cal
        timePicker.timeZone = store.tz
        // Pengingat: jam penuh berikutnya (sama dengan form lengkap); todo: 09.00
        var start = Date().addingTimeInterval(3600)
        start = cal.date(bySetting: .minute, value: 0, of: start) ?? start
        timePicker.dateValue = reminders ? start : (Clock.due(Clock.ymd(Date(), store.tz), "09:00", store.tz) ?? start)
        timeCheck.state = .off
        timeCheck.isHidden = reminders
        quickWhenEdited = false
        quickAutoTitle = nil
        quickTodoRow.isHidden = !reminders
        if reminders { fillQuickTodos() }
        quickWhenChanged()
    }

    /// Isi pilihan todo terkait: todo terbuka, urut abjad (sama dengan form lengkap).
    private func fillQuickTodos() {
        quickTodoPopup.removeAllItems()
        quickTodoPopup.addItem(withTitle: "Tanpa todo")
        quickTodoPopup.lastItem?.tag = 0
        for t in store.todos.sorted(by: { $0.title.localizedCompare($1.title) == .orderedAscending }) {
            quickTodoPopup.addItem(withTitle: t.title)
            quickTodoPopup.lastItem?.tag = Int(t.id)
        }
        quickTodoPopup.selectItem(withTag: 0)
    }

    @objc private func quickWhenPicked() {
        quickWhenEdited = true
        quickWhenChanged()
    }

    @objc private func quickTimePicked() { quickWhenEdited = true }

    /// Pilih todo terkait → isian yang masih kosong / belum diubah menyesuaikan todo:
    /// judul = judul todo; Kapan & jam = tenggat todo (bila hari ini / besok / lusa dan jamnya belum lewat).
    @objc private func quickTodoPicked() {
        let id = Int64(quickTodoPopup.selectedTag())
        let current = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = store.todos.first(where: { $0.id == id }) else {
            // Kembali ke "Tanpa todo": judul otomatis ikut dikosongkan
            if let auto = quickAutoTitle, current == auto { titleField.stringValue = "" }
            quickAutoTitle = nil
            return
        }
        if current.isEmpty || current == quickAutoTitle {
            titleField.stringValue = t.title
            quickAutoTitle = t.title
        }
        guard !quickWhenEdited, !t.dueDate.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        guard let offset = (0...2).first(where: {
            Clock.ymd(cal.date(byAdding: .day, value: $0, to: Date()) ?? Date(), store.tz) == t.dueDate
        }) else { return }
        let time = t.dueTime.isEmpty ? Clock.hm(timePicker.dateValue, store.tz) : t.dueTime
        // Jam tenggat sudah lewat (mis. terlambat hari ini) → biarkan jam bawaan
        guard let at = Clock.due(t.dueDate, time, store.tz), at > Date() else { return }
        duePopup.selectItem(withTag: offset)
        timePicker.dateValue = at
        quickWhenChanged()
    }

    /// Jam todo hanya bisa dipakai kalau ada tenggat (aturan yang sama dengan server & web).
    @objc private func quickWhenChanged() {
        if mode == .reminders {
            timePicker.isEnabled = true
            return
        }
        let hasDate = duePopup.selectedTag() >= 0
        timeCheck.isEnabled = hasDate
        timePicker.isEnabled = hasDate && timeCheck.state == .on
    }

    /// ＋ / ⌘N: buka kartu tambah lalu fokus ke judul; tekan lagi = tutup. ⌥-klik ＋ = langsung isian lengkap.
    @objc private func toggleAddCard() {
        if mode == .notes { return notesPane.toggleAddCard() }
        guard mode != .chat, !showDone else { return }
        if NSEvent.modifierFlags.contains(.option) && advancedForm == nil {
            if !addCardOpen { setAddCard(open: true) }
            return openAdvanced()
        }
        setAddCard(open: !addCardOpen)
    }

    private func setAddCard(open: Bool) {
        if open != addCardOpen || !open {
            closeAdvanced(focus: false)
            resetQuickCard()
        }
        addCardOpen = open
        updateAddCard()
        if open { view.window?.makeFirstResponder(titleField) } else { focusSearch() } // tutup kartu → kembali ke kolom cari
    }

    // MARK: Sinkron ulang (tombol ↻ / ⌘R)

    /// Ambil ulang todo, pengingat, dan (di tab Chat) riwayat chat dari server; hasilnya dikabarkan di baris status.
    @objc private func resyncTapped() {
        guard store.connected, resyncButton.isEnabled else { return }
        resyncButton.isEnabled = false
        syncLabel.stringValue = "Menyinkronkan…"
        if mode == .notes { notesPane.flashStatus("Menyinkronkan…") }
        if mode == .chat { loadHistory() }
        app.resync { [weak self] in
            guard let self else { return }
            self.resyncButton.isEnabled = true
            let flash: (String) -> Void = self.mode == .notes ? self.notesPane.flashStatus : self.flashStatus
            if let e = self.store.lastError { flash("Gagal sinkron: \(e)") } else { flash("Data sudah terbaru") }
        }
    }

    // MARK: Cari (kolom di samping filter / ⌘F)

    /// Fokus ke kolom cari; isi lama terpilih supaya ketikan baru langsung menggantinya.
    private func focusSearch() {
        guard mode != .chat else { return }
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Kata kunci yang sedang dipakai ("" = tidak menyaring).
    private var query: String { mode != .chat ? searchField.stringValue : "" }
    private var searching: Bool { !TextSearch.terms(query).isEmpty }

    /// Todo terbuka yang cocok dengan pencarian (semua bila tidak mencari).
    private var buckets: TodoBuckets {
        guard searching else { return store.buckets }
        let q = query
        return TodoBuckets(store.todos.filter { TextSearch.matches($0, query: q) }, now: Date(), tz: store.tz)
    }

    private func filtered(_ list: [Reminder]) -> [Reminder] {
        guard searching else { return list }
        let q = query
        return list.filter { r in
            TextSearch.matches(r, todoTitle: r.todoId.flatMap { id in store.todos.first { $0.id == id }?.title }, query: q)
        }
    }

    private var noMatchText: String {
        "Tidak ada \(mode == .reminders ? "pengingat" : "todo") yang cocok dengan “\(query.trimmingCharacters(in: .whitespaces))”."
    }

    @objc private func searchFieldChanged() { searchChanged() }

    /// Ketik di kolom cari → saring ulang daftar (kartu ubah ditutup, sama seperti ganti filter).
    private func searchChanged() {
        editor = nil
        rebuildList()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    // MARK: Isian lengkap (form lengkap di tempat kartu cepat)

    /// Tanggal (YYYY-MM-DD) dari pilihan Kapan di kartu cepat; "" = tanpa tenggat / tiap hari.
    private func quickDate() -> String {
        let tag = duePopup.selectedTag()
        guard tag >= 0 && tag != PopoverController.dailyTag else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        return Clock.ymd(cal.date(byAdding: .day, value: tag, to: Date()) ?? Date(), store.tz)
    }

    /// Ganti kartu cepat dengan form lengkap; isian cepat (judul, kapan, jam) ikut terbawa.
    @objc private func openAdvanced() {
        guard advancedForm == nil, mode != .chat else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = Clock.hm(timePicker.dateValue, store.tz)
        let form: NSView
        let focus: NSTextField
        if mode == .reminders {
            let date = quickDate().isEmpty ? Clock.ymd(Date(), store.tz) : quickDate()
            let daily = duePopup.selectedTag() == PopoverController.dailyTag
            let draft = ReminderEditor.Draft(title: title, start: Clock.due(date, time, store.tz) ?? Date(),
                                             kind: daily ? "daily" : "once", todoId: Int64(quickTodoPopup.selectedTag()))
            let e = ReminderEditor(reminder: nil, todos: store.todos, tz: store.tz, compact: true, draft: draft)
            e.onCancel = { [weak self] in self?.closeAdvanced(focus: true) }
            e.onSave = { [weak self, weak e] body in
                guard let self, let e else { return }
                e.busy = true
                self.app.createReminder(body) { err in
                    e.busy = false
                    if let err { return e.showError(err) }
                    self.advancedSaved("Pengingat ditambahkan")
                }
            }
            form = e
            focus = e.titleField
        } else {
            let date = quickDate()
            let hasTime = !date.isEmpty && timeCheck.state == .on
            let blank = Todo(id: 0, title: title, notes: "", status: "open", priority: "normal", list: "",
                             dueDate: date, dueTime: hasTime ? time : "")
            let lists = Array(Set(store.todos.map(\.list).filter { !$0.isEmpty })).sorted()
            let e = TodoEditor(todo: blank, lists: lists, tz: store.tz)
            e.onCancel = { [weak self] in self?.closeAdvanced(focus: true) }
            e.onSave = { [weak self, weak e] fields in
                guard let self, let e else { return }
                e.busy = true
                self.app.createTodo(fields: fields) { err in
                    e.busy = false
                    if let err { return e.showError(err) }
                    self.advancedSaved("Todo ditambahkan")
                }
            }
            form = e
            focus = e.titleField
        }
        addCard.isHidden = true
        form.translatesAutoresizingMaskIntoConstraints = false
        addHost.addSubview(form)
        UI.pin(form, to: addHost)
        advancedForm = form
        view.window?.makeFirstResponder(focus)
        // Judul sudah terisi → kursor di akhir judul, siap lanjut ke isian berikutnya
        focus.currentEditor()?.selectedRange = NSRange(location: focus.stringValue.utf16.count, length: 0)
    }

    /// Batal di form lengkap = kembali ke kartu cepat (isian cepat tetap ada).
    private func closeAdvanced(focus: Bool) {
        guard let form = advancedForm else { return }
        form.removeFromSuperview()
        advancedForm = nil
        addCard.isHidden = false
        if focus { view.window?.makeFirstResponder(titleField) }
    }

    /// Tersimpan dari form lengkap: kembali ke kartu cepat yang kosong (bisa menambah beruntun).
    private func advancedSaved(_ status: String) {
        closeAdvanced(focus: false)
        resetQuickCard()
        view.window?.makeFirstResponder(titleField)
        flashStatus(status)
    }

    /// Form lengkap yang terbuka: judulnya (untuk fokus saat popover tampil lagi).
    private var advancedTitleField: NSTextField? {
        (advancedForm as? TodoEditor)?.titleField ?? (advancedForm as? ReminderEditor)?.titleField
    }

    /// Todo (terbuka atau selesai) menurut id.
    private func findTodo(_ id: Int64) -> Todo? {
        store.todos.first { $0.id == id } ?? doneTodos.first { $0.id == id }
    }

    private func loadDone() {
        guard store.connected, !loadingDone else { return }
        loadingDone = true
        store.api.todos(status: "done") { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingDone = false
                if case .success(let d) = r {
                    self.doneTodos = d.todos.sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
                }
                if self.mode == .todo && self.showDone { self.rebuildList() }
            }
        }
    }

    private func rebuildList() {
        // Baris lama dibuang → tombol Detail yang jadi jangkar pratinjau ikut lepas; pasang ulang setelah dibangun.
        defer { reanchorDetail() }
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        checkButtons = []
        reminderChecks = []
        reorderGroups = []
        rowViews = [:]
        let b = buckets
        updateScopeLabels(b)
        if mode == .reminders { return rebuildReminders() }
        if showDone { return rebuildDone() }
        for item in todoGroupMenu.items where item.action == #selector(groupMenuItem(_:)) {
            item.state = item.tag == LocalPrefs.todoGroup ? .on : .off
        }
        if groupByCategory { return rebuildByCategory(b) }
        section("Terlambat", b.overdue, color: Theme.danger)
        section("Hari ini", b.today, showDate: false)
        if showAll { rebuildAll(b) } else { rebuildToday(b) }
    }

    /// Daftar todo dikelompokkan per kategori (Pengaturan → Umum, atau klik kanan filter).
    private var groupByCategory: Bool { mode == .todo && LocalPrefs.todoGroup == 1 }

    /// Menu klik kanan filter: Kelompokkan menurut Waktu / Kategori (tanda ✓ = pilihan sekarang).
    private lazy var todoGroupMenu: NSMenu = {
        let m = NSMenu()
        let head = NSMenuItem(title: "Kelompokkan menurut", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for (i, title) in ["Waktu", "Kategori"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(groupMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.indentationLevel = 1
            m.addItem(item)
        }
        return m
    }()

    @objc private func groupMenuItem(_ item: NSMenuItem) { app.setTodoGroup(item.tag) }

    /// Kelompok kategori (urut abjad, "Tanpa kategori" paling bawah); di dalamnya urut tenggat seperti biasa:
    /// terlambat, hari ini, mendatang, lalu tanpa tenggat. Hari ini = hanya terlambat & hari ini.
    private func rebuildByCategory(_ b: TodoBuckets) {
        let todos = showAll ? b.overdue + b.today + b.upcoming + b.noDate : b.overdue + b.today
        if todos.isEmpty { return showAll ? rebuildAll(b) : rebuildToday(b) } // pesan kosong yang sama
        var groups: [String: [Todo]] = [:]
        for t in todos { groups[t.list, default: []].append(t) }
        let names = groups.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var left = PopoverController.maxAllRows
        for name in names + (groups[""] == nil ? [] : [""]) where left > 0 {
            let rows = Array((groups[name] ?? []).prefix(left))
            section(name.isEmpty ? "Tanpa kategori" : name, rows)
            left -= rows.count
        }
        let shown = PopoverController.maxAllRows - left
        if todos.count > shown { addListRow(linkButton("\(todos.count - shown) todo lainnya ada di browser", #selector(openWeb))) }
    }

    private func updateScopeLabels(_ b: TodoBuckets) {
        if mode == .reminders {
            guard scope.segmentCount == 3 else { return }
            let today = todayReminders.count, all = filtered(store.activeReminders).count
            scope.setLabel("Hari ini" + (today > 0 ? "  \(today)" : ""), forSegment: 0)
            scope.setLabel("Semua" + (all > 0 ? "  \(all)" : ""), forSegment: 1)
            return
        }
        guard scope.segmentCount == 3 else { return }
        scope.setLabel("Hari ini" + (b.badge > 0 ? "  \(b.badge)" : ""), forSegment: 0)
        scope.setLabel("Semua" + (b.total > 0 ? "  \(b.total)" : ""), forSegment: 1)
    }

    /// Selesai: todo yang sudah selesai, terbaru di atas. Klik ✓ = buka lagi (batalkan yang salah ditandai).
    private func rebuildDone() {
        let q = query
        let doneTodos = searching ? self.doneTodos.filter { TextSearch.matches($0, query: q) } : self.doneTodos
        if doneTodos.isEmpty {
            addListRow(UI.text(loadingDone ? "Memuat…" : searching ? noMatchText : "Belum ada todo yang selesai.",
                               width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
            return
        }
        addListRow(UI.label("Klik ✓ untuk membuka lagi todo yang salah ditandai selesai.", size: 11, color: .tertiaryLabelColor))
        let shown = doneTodos.prefix(PopoverController.maxAllRows)
        addHeader("Selesai", count: doneTodos.count)
        for t in shown { addListRow(doneRow(t)) }
        if doneTodos.count > shown.count {
            addListRow(linkButton("\(doneTodos.count - shown.count) todo lainnya ada di browser", #selector(openWeb)))
        }
    }

    private func doneRow(_ t: Todo) -> NSView {
        let check = NSButton(image: UI.symbol("checkmark.circle.fill", 16) ?? NSImage(), target: self, action: #selector(reopenClicked(_:)))
        check.isBordered = false
        check.tag = Int(t.id)
        check.contentTintColor = Theme.accent
        check.toolTip = "Buka lagi (batalkan selesai)"
        check.setAccessibilityLabel("Buka lagi “\(t.title)”")
        let title = UI.text(t.title, width: PopoverController.contentWidth - 30, size: 13, color: .secondaryLabelColor)
        title.attributedStringValue = NSAttributedString(string: t.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
        title.isSelectable = false
        var meta: [String] = []
        if let at = t.completedAt, !at.isEmpty { meta.append("Selesai " + friendlyStamp(at)) }
        if !t.list.isEmpty { meta.append(t.list) }
        var texts: [NSView] = [title]
        if !meta.isEmpty { texts.append(UI.label(meta.joined(separator: " · "), size: 11, color: .tertiaryLabelColor)) }
        let textStack = UI.stack(texts, spacing: 1)
        addCopyClick(textStack, id: t.id, double: nil)
        let row = UI.stack([check, textStack], vertical: false, spacing: 8)
        row.alignment = .top
        row.toolTip = "Klik untuk menyalin"
        let m = NSMenu()
        for (title, action) in [("Buka lagi", #selector(reopenMenuItem(_:))), ("Salin", #selector(copyMenuItem(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: t.id)
            m.addItem(item)
        }
        row.menu = m
        rowViews[t.id] = row
        return row
    }

    @objc private func reopenClicked(_ sender: NSButton) {
        sender.image = UI.symbol("circle", 16)
        sender.contentTintColor = .tertiaryLabelColor
        sender.isEnabled = false
        reopen(Int64(sender.tag))
    }

    @objc private func reopenMenuItem(_ item: NSMenuItem) {
        (item.representedObject as? NSNumber).map { reopen($0.int64Value) }
    }

    private func reopen(_ id: Int64) {
        store.api.reopen(todo: id) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let res):
                    self.doneTodos.removeAll { $0.id == id }
                    self.flashStatus("Dibuka lagi: \(res.todo.title)")
                case .failure(let e): showError("Gagal membuka lagi todo", e.description)
                }
                self.rebuildList()
                self.store.refresh()
            }
        }
    }

    /// Klik teks = salin (⌥-klik = judul saja); klik dua kali = `double` (ubah). Tombol di dalam baris tidak ikut.
    private func addCopyClick(_ v: NSView, id: Int64, double: Selector?, reminder: Bool = false) {
        let tap = TodoClick(target: self, action: reminder ? #selector(reminderTextClicked(_:)) : #selector(rowClicked(_:)))
        tap.numberOfClicksRequired = 1
        tap.todoID = id
        tap.delegate = self
        v.addGestureRecognizer(tap)
        if let double {
            let dbl = TodoClick(target: self, action: double)
            dbl.numberOfClicksRequired = 2
            dbl.todoID = id
            dbl.delegate = self
            v.addGestureRecognizer(dbl)
        }
    }

    @objc private func rowClicked(_ g: TodoClick) {
        guard let t = findTodo(g.todoID) else { return }
        copyTodo(t, titleOnly: NSEvent.modifierFlags.contains(.option))
        pulse(g.view)
    }

    /// Umpan balik klik-salin: teks berkedip sekali.
    private func pulse(_ v: NSView?) {
        guard let v else { return }
        v.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            v.animator().alphaValue = 1
        }
    }

    // Klik tunggal menunggu klik dua kali gagal (salin vs ubah); klik pada tombol (Detail) tidak memicu salin.
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
        (g as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 &&
            (other as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2 && g.view === other.view
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let v = g.view, let sup = v.superview else { return true }
        return !(v.hitTest(sup.convert(event.locationInWindow, from: nil)) is NSButton)
    }

    /// Hari ini: tetap ringkas — terlambat & hari ini.
    private func rebuildToday(_ b: TodoBuckets) {
        if b.overdue.isEmpty && b.today.isEmpty {
            addListRow(UI.text(searching ? noMatchText : "Tidak ada todo untuk hari ini. Tambah di atas, atau minta asisten di tab Chat.",
                               width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
            let later = b.upcoming.count + b.noDate.count
            if later > 0 {
                addListRow(linkButton(searching ? "Lihat \(later) yang cocok di Semua" : "Lihat \(later) todo lainnya",
                                      #selector(showAllTapped)))
            }
        } else if searching, b.upcoming.count + b.noDate.count > 0 {
            addListRow(linkButton("\(b.upcoming.count + b.noDate.count) lainnya cocok di Semua", #selector(showAllTapped)))
        }
    }

    /// Waktu ramah untuk stempel RFC3339, mis. "Besok 08:00" / "Kam 5 Nov 08:00".
    private func friendlyStamp(_ stamp: String) -> String {
        guard let d = Clock.parseStamp(stamp) else { return "" }
        let day = Clock.friendly(Clock.ymd(d, store.tz), now: Date(), store.tz)
        return day.prefix(1).uppercased() + day.dropFirst() + " " + Clock.hm(d, store.tz)
    }

    /// Hari ini: pengingat tanpa todo yang aktif dan berbunyi hari ini (atau terlewat / tanpa jadwal berikutnya).
    private var todayReminders: [Reminder] {
        let today = Clock.ymd(Date(), store.tz)
        return filtered(store.looseReminders.active).filter { r in
            guard let d = Clock.parseStamp(r.nextFireAt) else { return true }
            return Clock.ymd(d, store.tz) <= today
        }
    }

    /// Pengingat: Hari ini & Selesai hanya pengingat tanpa todo (yang terkait todo cukup ikon 🔔 di baris todo-nya);
    /// Semua = semua pengingat aktif (termasuk milik todo), dikelompokkan per hari.
    ///   ○ Minum obat                         Hari ini / Semua: ○ = tandai selesai (berhenti berbunyi)
    ///     Besok 08:00 · Tiap hari 08:00      Selesai: ✓ = aktifkan lagi
    private func rebuildReminders() {
        if showAllReminders {
            rebuildAllReminders()
        } else {
            let list = showDone ? filtered(store.looseReminders.paused)
                                : ManualOrder.apply(todayReminders, order: LocalPrefs.reminderOrder, id: \.id)
            if list.isEmpty {
                let later = filtered(store.activeReminders).count
                addListRow(UI.text(searching ? noMatchText
                                            : showDone ? "Belum ada pengingat yang selesai."
                                            : later > 0 ? "Tidak ada pengingat untuk hari ini."
                                            : "Belum ada pengingat aktif. Tekan ＋ di atas, atau minta asisten di tab Chat, mis. “ingatkan minum obat tiap hari jam 8”.",
                                   width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
                if !showDone && later > 0 {
                    addListRow(linkButton(searching ? "Lihat \(later) yang cocok di Semua" : "Lihat \(later) pengingat lainnya",
                                          #selector(showAllTapped)))
                }
            } else {
                if showDone {
                    addListRow(UI.label("Klik ✓ untuk mengaktifkan lagi pengingat.", size: 11, color: .tertiaryLabelColor))
                }
                var items: [(id: Int64, view: NSView)] = []
                for r in list {
                    let row = reminderRow(r)
                    addListRow(row)
                    items.append((r.id, row))
                }
                if !showDone { addReorderGroup(items, reminders: true) }
                let later = filtered(store.activeReminders).count - list.count
                if searching && !showDone && later > 0 {
                    addListRow(linkButton("\(later) lainnya cocok di Semua", #selector(showAllTapped)))
                }
            }
        }
        let links = UI.stack([linkButton("Pengingat baru…", #selector(newReminder)),
                              linkButton("Kelola di Pengaturan", #selector(openReminderSettings))], vertical: false, spacing: 16)
        let wrap = NSView()
        links.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(links)
        UI.pin(links, to: wrap, top: 8)
        addListRow(wrap)
    }

    /// Semua: semua pengingat aktif per hari (Hari ini, Besok, Kam 12 Nov, …), lalu yang tanpa jadwal berikutnya.
    private func rebuildAllReminders() {
        let all = filtered(store.activeReminders)
        if all.isEmpty {
            addListRow(UI.text(searching ? noMatchText : "Belum ada pengingat aktif. Tekan ＋ di atas, atau minta asisten di tab Chat, mis. “ingatkan minum obat tiap hari jam 8”.",
                               width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
            return
        }
        let today = Clock.ymd(Date(), store.tz)
        var days: [(day: String, list: [Reminder])] = []
        var noDate: [Reminder] = []
        for r in all.prefix(PopoverController.maxAllRows) {
            guard let d = Clock.parseStamp(r.nextFireAt) else { noDate.append(r); continue }
            let day = max(Clock.ymd(d, store.tz), today) // terlewat = hari ini
            if days.last?.day == day { days[days.count - 1].list.append(r) } else { days.append((day, [r])) }
        }
        // Urutan manual (⌃ + seret) berlaku di dalam tiap hari
        func rows(_ list: [Reminder], showDay: Bool) {
            var items: [(id: Int64, view: NSView)] = []
            for r in ManualOrder.apply(list, order: LocalPrefs.reminderOrder, id: \.id) {
                let row = reminderRow(r, showDay: showDay)
                addListRow(row)
                items.append((r.id, row))
            }
            addReorderGroup(items, reminders: true)
        }
        for g in days {
            let name = Clock.friendly(g.day, now: Date(), store.tz)
            addHeader(name.prefix(1).uppercased() + name.dropFirst(), count: g.list.count)
            rows(g.list, showDay: false)
        }
        if !noDate.isEmpty {
            addHeader("Tanpa jadwal", count: noDate.count)
            rows(noDate, showDay: true)
        }
        if all.count > PopoverController.maxAllRows {
            addListRow(linkButton("\(all.count - PopoverController.maxAllRows) pengingat lainnya di Pengaturan", #selector(openReminderSettings)))
        }
    }

    /// showDay: false di bawah judul tanggal (filter Semua) → baris hanya menampilkan jam.
    /// Pengingat milik todo menampilkan judul todo-nya (🔔 Todo: …) supaya jelas asalnya.
    private func reminderRow(_ r: Reminder, showDay: Bool = true) -> NSView {
        let done = !r.active
        let check = RowCheck(image: NSImage(), target: self, action: #selector(reminderCheckClicked(_:)))
        check.isBordered = false
        check.tag = Int(r.id)
        styleReminderCheck(check, r)
        if !done {
            reminderChecks.append((check, r))
            check.canReorder = { [weak self] in self?.reorderMode ?? false }
            check.onReorder = { [weak self] e in self?.dragReorder(r.id, e) }
        }
        let title = UI.text(r.title, width: PopoverController.contentWidth - 30, size: 13, color: done ? .secondaryLabelColor : .labelColor)
        title.isSelectable = false
        var sub: String
        if done {
            sub = r.ended ? "Sudah berbunyi" : "Dijeda"
            if !r.scheduleText.isEmpty { sub += " · " + r.scheduleText }
        } else {
            sub = showDay ? friendlyStamp(r.nextFireAt) : (Clock.parseStamp(r.nextFireAt).map { Clock.hm($0, store.tz) } ?? "")
            // "Sekali, …" sama dengan waktu berikutnya → tidak diulang
            if !r.scheduleText.isEmpty && !r.scheduleText.hasPrefix("Sekali") {
                sub += (sub.isEmpty ? "" : " · ") + r.scheduleText
            }
        }
        if let tid = r.todoId {
            let todoTitle = store.todos.first { $0.id == tid }?.title ?? "todo"
            sub += (sub.isEmpty ? "" : " · ") + "🔔 " + todoTitle
        }
        var texts: [NSView] = [title]
        if !sub.isEmpty { texts.append(UI.label(sub, size: 11, color: done ? .tertiaryLabelColor : .secondaryLabelColor)) }
        let textStack = UI.stack(texts, spacing: 1)
        addCopyClick(textStack, id: r.id, double: #selector(reminderDoubleClicked(_:)), reminder: true)
        let row = ListRow.make([check, textStack])
        row.toolTip = (r.message.isEmpty ? "" : r.message + "\n\n") + "Klik untuk menyalin · klik dua kali untuk mengubah"
        let m = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: r.id)
            m.addItem(item)
        }
        add("Ubah…", #selector(reminderEditMenuItem(_:)))
        add("Salin", #selector(reminderCopyMenuItem(_:)))
        add(done ? "Aktifkan lagi" : "Tandai selesai", #selector(reminderToggleMenuItem(_:)))
        m.addItem(.separator())
        add("Hapus…", #selector(reminderDeleteMenuItem(_:)))
        row.menu = m
        return row
    }

    private func findReminder(_ id: Int64) -> Reminder? { store.reminders.first { $0.id == id } }
    private func reminder(_ item: NSMenuItem) -> Reminder? {
        (item.representedObject as? NSNumber).flatMap { findReminder($0.int64Value) }
    }

    @objc private func reminderTextClicked(_ g: TodoClick) {
        guard let r = findReminder(g.todoID) else { return }
        let titleOnly = NSEvent.modifierFlags.contains(.option)
        TodoCopy.copy(r, titleOnly: titleOnly)
        flashStatus(titleOnly || r.message.isEmpty ? "Judul disalin" : "Judul & pesan disalin")
        pulse(g.view)
    }
    @objc private func reminderDoubleClicked(_ g: TodoClick) { app.editReminder(findReminder(g.todoID)) }
    @objc private func reminderEditMenuItem(_ item: NSMenuItem) { reminder(item).map { app.editReminder($0) } }
    @objc private func reminderCopyMenuItem(_ item: NSMenuItem) {
        guard let r = reminder(item) else { return }
        TodoCopy.copy(r)
        flashStatus(r.message.isEmpty ? "Judul disalin" : "Judul & pesan disalin")
    }
    @objc private func reminderToggleMenuItem(_ item: NSMenuItem) { reminder(item).map { app.toggleReminder($0) } }
    @objc private func reminderDeleteMenuItem(_ item: NSMenuItem) { reminder(item).map { app.deleteReminder($0) } }
    @objc private func reminderCheckClicked(_ sender: NSButton) {
        guard let r = findReminder(Int64(sender.tag)) else { return }
        sender.image = UI.symbol(r.active ? "checkmark.circle.fill" : "circle", 16)
        sender.contentTintColor = r.active ? Theme.accent : .tertiaryLabelColor
        sender.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.app.toggleReminder(r) }
    }
    /// "Pengingat baru…" = kartu tambah cepat di atas daftar (sama dengan ＋, seperti tab Todo);
    /// form lengkap tetap lewat "Isian lengkap…" di kartu (atau ⌥-klik tautan ini).
    /// Dari filter Selesai: pindah ke Hari ini dulu (kartu tambah tidak tampil di Selesai).
    @objc private func newReminder() {
        let advanced = NSEvent.modifierFlags.contains(.option)
        if showDone {
            scope.selectedSegment = 0
            scopeChanged()
        }
        if !addCardOpen { setAddCard(open: true) } else if advancedForm == nil { view.window?.makeFirstResponder(titleField) }
        if advanced { openAdvanced() }
    }
    @objc private func openReminderSettings() { app.openReminderSettings() }

    /// Semua: semua todo terbuka — terlambat, hari ini, per tanggal (Besok, Rab 5 Nov, …), lalu tanpa tenggat.
    private func rebuildAll(_ b: TodoBuckets) {
        if b.total == 0 {
            addListRow(UI.text(searching ? noMatchText : "Semua todo sudah selesai. Tambah di atas, atau minta asisten di tab Chat.",
                               width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
            return
        }
        var left = max(0, PopoverController.maxAllRows - b.overdue.count - b.today.count)
        for day in b.upcomingByDay where left > 0 {
            let name = Clock.friendly(day.date, now: Date(), store.tz)
            let todos = Array(day.todos.prefix(left))
            section(name.prefix(1).uppercased() + name.dropFirst(), todos, showDate: false)
            left -= todos.count
        }
        let noDate = Array(b.noDate.prefix(left))
        section("Tanpa tenggat", noDate)
        left -= noDate.count
        let shown = PopoverController.maxAllRows - left
        if b.total > shown { addListRow(linkButton("\(b.total - shown) todo lainnya ada di browser", #selector(openWeb))) }
    }

    private func linkButton(_ title: String, _ action: Selector) -> NSButton {
        let l = NSButton(title: title, target: self, action: action)
        l.isBordered = false
        l.contentTintColor = Theme.accent
        l.alignment = .left
        return l
    }

    private func addHeader(_ title: String, count: Int?, color: NSColor = .secondaryLabelColor) {
        let h = UI.label(count.map { "\(title)  \($0)" } ?? title, size: 12, weight: .semibold, color: color)
        let wrap = NSView()
        h.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(h)
        UI.pin(h, to: wrap, top: 10, bottom: 2)
        addListRow(wrap)
    }

    /// showDate: false di bawah judul tanggal (Hari ini, Besok, …) supaya tanggal tidak diulang di tiap baris.
    private func section(_ title: String, _ todos: [Todo], color: NSColor = .secondaryLabelColor, showDate: Bool = true) {
        guard !todos.isEmpty else { return }
        addHeader(title, count: todos.count, color: color)
        var items: [(id: Int64, view: NSView)] = []
        // Urutan manual (⌃ + seret) berlaku di dalam tiap kelompok; todo tanpa urutan tetap di posisi bawaannya
        for t in ManualOrder.apply(todos, order: LocalPrefs.todoOrder, id: \.id) {
            if let editor, editor.todo.id == t.id { addListRow(editor); continue }
            let row = todoRow(t, showDate: showDate)
            addListRow(row)
            items.append((t.id, row))
        }
        addReorderGroup(items, reminders: false)
    }

    private func addListRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -2 * PopoverController.inset).isActive = true
    }

    /// Lingkaran di kiri = tandai selesai (⌥ ditahan = ✎ ubah). Klik dua kali judul / klik kanan = ubah.
    private func todoRow(_ t: Todo, showDate: Bool = true) -> NSView {
        let check = RowCheck(image: NSImage(), target: self, action: #selector(completeClicked(_:)))
        check.isBordered = false
        check.tag = Int(t.id)
        check.canReorder = { [weak self] in self?.reorderMode ?? false }
        check.onReorder = { [weak self] e in self?.dragReorder(t.id, e) }
        styleCheck(check, t)
        checkButtons.append((check, t))
        var meta: [String] = []
        if t.priority == "high" { meta.append("Prioritas tinggi") }
        if !t.dueDate.isEmpty {
            let isToday = t.dueDate == Clock.ymd(Date(), store.tz)
            // Dikelompokkan per kategori: tidak ada judul "Hari ini", jadi tanggal hari ini tetap ditulis
            var due = !showDate || (isToday && !groupByCategory) ? "" : Clock.friendly(t.dueDate, now: Date(), store.tz)
            if !t.dueTime.isEmpty { due += (due.isEmpty ? "" : " ") + t.dueTime }
            if groupByCategory && t.dueDate < Clock.ymd(Date(), store.tz) { meta.append("Terlambat") }
            if !due.isEmpty { meta.append(due) }
        }
        if !t.list.isEmpty && !groupByCategory { meta.append(t.list) } // kategori sudah jadi judul kelompok
        let titleText = UI.text(t.title, width: PopoverController.contentWidth - 30, size: 13)
        titleText.isSelectable = false // klik teks = salin, bukan memilih teks
        var texts: [NSView] = [titleText]
        var metaViews: [NSView] = []
        let moreMeta = !t.notes.isEmpty || store.reminder(forTodo: t.id) != nil
        if !meta.isEmpty { metaViews.append(UI.label(meta.joined(separator: " · ") + (moreMeta ? " ·" : ""),
                                                     size: 11, color: .secondaryLabelColor)) }
        // Todo yang punya pengingat: cukup ikon 🔔 + waktu berbunyi berikutnya (tidak didaftar terpisah)
        // Todo yang punya detail: ikon ≡ "Detail" — klik = pratinjau (judul + detail, Salin, Ubah…)
        if !t.notes.isEmpty {
            let b = NSButton(title: "Detail", image: UI.symbol("text.alignleft", 10) ?? NSImage(), target: self,
                             action: #selector(detailClicked(_:)))
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.contentTintColor = Theme.accent
            b.attributedTitle = NSAttributedString(string: "Detail", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                .foregroundColor: Theme.accent])
            b.tag = Int(t.id)
            b.toolTip = "Lihat detail"
            b.setAccessibilityLabel("Lihat detail “\(t.title)”")
            metaViews.append(b)
        }
        if let r = store.reminder(forTodo: t.id) {
            let bell = NSImageView(image: UI.symbol("bell.fill", 9) ?? NSImage())
            bell.contentTintColor = Theme.accent
            let when = UI.label(friendlyStamp(r.nextFireAt), size: 11, color: .secondaryLabelColor)
            let tip = "Pengingat: " + (r.scheduleText.isEmpty ? when.stringValue : r.scheduleText)
            let group = UI.stack([bell, when], vertical: false, spacing: 3)
            group.toolTip = tip
            group.setAccessibilityElement(true)
            group.setAccessibilityLabel(tip)
            metaViews.append(group)
        }
        if !metaViews.isEmpty { texts.append(UI.stack(metaViews, vertical: false, spacing: 4)) }
        let textStack = UI.stack(texts, spacing: 1)
        addCopyClick(textStack, id: t.id, double: #selector(rowDoubleClicked(_:)))
        let row = ListRow.make([check, textStack])
        // arahkan mouse = intip detail + petunjuk klik
        row.toolTip = (t.notes.isEmpty ? "" : t.notes + "\n\n") + "Klik untuk menyalin · klik dua kali untuk mengubah"
        row.menu = rowMenu(t)
        rowViews[t.id] = row
        return row
    }

    /// Klik kanan baris: Lihat detail / Ubah… / Salin (tahan ⌥: Salin judul saja) / Tandai selesai.
    private func rowMenu(_ t: Todo) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, alternate: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: t.id)
            if alternate {
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
            }
            m.addItem(item)
        }
        if !t.notes.isEmpty { add("Lihat detail", #selector(detailMenuItem(_:))) }
        add("Ubah…", #selector(editMenuItem(_:)))
        add("Salin", #selector(copyMenuItem(_:)))
        if !t.notes.isEmpty { add("Salin judul saja", #selector(copyTitleMenuItem(_:)), alternate: true) }
        m.addItem(.separator())
        add("Tandai selesai", #selector(completeMenuItem(_:)))
        return m
    }

    // MARK: Detail & salin

    private func todo(_ item: NSMenuItem) -> Todo? {
        guard let id = (item.representedObject as? NSNumber)?.int64Value else { return nil }
        return findTodo(id)
    }

    @objc private func detailClicked(_ sender: NSButton) {
        guard let t = findTodo(Int64(sender.tag)) else { return }
        showDetail(t, from: sender)
    }

    @objc private func detailMenuItem(_ item: NSMenuItem) {
        guard let t = todo(item), let v = rowViews[t.id] else { return }
        showDetail(t, from: v)
    }

    @objc private func copyMenuItem(_ item: NSMenuItem) { todo(item).map { copyTodo($0, titleOnly: false) } }
    @objc private func copyTitleMenuItem(_ item: NSMenuItem) { todo(item).map { copyTodo($0, titleOnly: true) } }

    private func copyTodo(_ t: Todo, titleOnly: Bool) {
        TodoCopy.copy([t], titleOnly: titleOnly)
        flashStatus(titleOnly || t.notes.isEmpty ? "Judul disalin" : "Judul & detail disalin")
    }

    /// Umpan balik singkat di baris status bawah, lalu kembali ke status sinkron.
    private func flashStatus(_ text: String) {
        syncLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.syncLabel.stringValue == text else { return }
            self.syncLabel.stringValue = self.app.syncStatus
        }
    }

    private func showDetail(_ t: Todo, from anchor: NSView) {
        closeDetail()
        let vc = DetailPreview(todo: t, tz: store.tz)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.delegate = self
        vc.onEdit = { [weak self] in
            self?.closeDetail()
            self?.beginEdit(t.id)
        }
        vc.onCopied = { [weak self] in self?.flashStatus("Judul & detail disalin") }
        detailPopover = p
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Tutup pratinjau detail (bila terbuka).
    private func closeDetail() {
        let p = detailPopover
        detailPopover = nil
        p?.close()
    }

    /// Daftar dibangun ulang (sinkron dari perangkat lain, ganti tab/filter) saat pratinjau terbuka: tombol
    /// jangkarnya sudah dibuang dari jendela. Popover dengan jangkar yatim bisa menggantung dan menahan klik
    /// di popover utama — jadi pindahkan ke tombol Detail baris yang baru, atau tutup bila todo-nya tidak
    /// tampil lagi / sudah berubah.
    private func reanchorDetail() {
        guard let p = detailPopover else { return }
        guard p.isShown, let vc = p.contentViewController as? DetailPreview, let t = findTodo(vc.todo.id), t == vc.todo,
              let row = rowViews[t.id], let b = detailButton(in: row), b.window != nil else { return closeDetail() }
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) // popover yang sedang tampil hanya pindah jangkar
    }

    private func detailButton(in v: NSView) -> NSButton? {
        if let b = v as? NSButton, b.action == #selector(detailClicked(_:)) { return b }
        for s in v.subviews { if let b = detailButton(in: s) { return b } }
        return nil
    }

    private func styleCheck(_ b: NSButton, _ t: Todo) {
        if reorderMode {
            styleHandle(b, t.title)
        } else if optionDown {
            b.image = UI.symbol("pencil.circle", 16)
            b.contentTintColor = Theme.accent
            b.toolTip = "Ubah"
            b.setAccessibilityLabel("Ubah “\(t.title)”")
        } else {
            b.image = UI.symbol("circle", 16)
            b.contentTintColor = t.priority == "high" ? Theme.danger : .tertiaryLabelColor
            b.toolTip = "Tandai selesai · ⌥-klik untuk mengubah · tahan ⌃ untuk mengurutkan"
            b.setAccessibilityLabel("Tandai “\(t.title)” selesai")
        }
    }

    private func styleReminderCheck(_ b: NSButton, _ r: Reminder) {
        let done = !r.active
        if reorderMode && !done { return styleHandle(b, r.title) }
        b.image = UI.symbol(done ? "checkmark.circle.fill" : "circle", 16)
        b.contentTintColor = done ? Theme.accent : .tertiaryLabelColor
        b.toolTip = done ? "Aktifkan lagi (batalkan selesai)" : "Tandai selesai (pengingat berhenti berbunyi) · tahan ⌃ untuk mengurutkan"
        b.setAccessibilityLabel((done ? "Aktifkan lagi “" : "Tandai selesai “") + r.title + "”")
    }

    /// ⌃ ditahan: lingkaran jadi pegangan ≡ (seret untuk memindah).
    private func styleHandle(_ b: NSButton, _ title: String) {
        b.image = UI.symbol("line.3.horizontal", 14)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Seret untuk memindah urutan"
        b.setAccessibilityLabel("Pindahkan “\(title)”")
    }

    private func updateCheckIcons() {
        for c in checkButtons where c.button.isEnabled { styleCheck(c.button, c.todo) }
        for c in reminderChecks where c.button.isEnabled { styleReminderCheck(c.button, c.reminder) }
        for b in checkButtons.map { $0.button } + reminderChecks.map { $0.button } { view.window?.invalidateCursorRects(for: b) }
        syncLabel.stringValue = reorderMode ? "Mode urutkan: seret ≡ untuk memindah"
            : optionDown && mode == .todo ? "Mode ubah: klik ✎ untuk mengubah todo" : app.syncStatus
    }

    // MARK: Mode urutkan (tahan ⌃ lalu seret ≡, atau klik kanan → Urutkan)

    /// Urutan manual hanya di daftar todo / pengingat yang masih aktif (bukan filter Selesai) dan tidak sedang mengubah.
    private var reorderMode: Bool { controlDown && !optionDown && mode != .chat && !showDone && editor == nil && !searching }

    /// Catat satu kelompok baris yang bisa diurutkan + pasang submenu "Urutkan" di menu klik kanan tiap baris
    /// (jalan lain selain seret: Paling atas / Naikkan / Turunkan / Paling bawah / Urutan bawaan).
    private func addReorderGroup(_ items: [(id: Int64, view: NSView)], reminders: Bool) {
        guard !items.isEmpty, !searching else { return } // saat mencari kelompok hanya sebagian → tidak diurutkan
        reorderGroups.append((reminders, items))
        let saved = Set(reminders ? LocalPrefs.reminderOrder : LocalPrefs.todoOrder)
        let custom = items.contains { saved.contains($0.id) }
        guard items.count > 1 || custom else { return }
        for (i, item) in items.enumerated() {
            guard let menu = item.view.menu else { continue }
            let sub = NSMenu()
            // action nil = otomatis nonaktif (menu memakai autoenablesItems)
            func add(_ title: String, _ tag: Int, _ enabled: Bool) {
                let mi = NSMenuItem(title: title, action: enabled ? #selector(reorderMenuItem(_:)) : nil, keyEquivalent: "")
                mi.target = self
                mi.tag = tag
                mi.representedObject = NSNumber(value: item.id)
                sub.addItem(mi)
            }
            let last = items.count - 1
            add("Paling atas", -2, i > 0)
            add("Naikkan", -1, i > 0)
            add("Turunkan", 1, i < last)
            add("Paling bawah", 2, i < last)
            sub.addItem(.separator())
            add("Urutan bawaan (menurut waktu)", 0, custom)
            let hint = NSMenuItem(title: "Tip: tahan ⌃ lalu seret ≡", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            let parent = NSMenuItem(title: "Urutkan", action: nil, keyEquivalent: "")
            parent.submenu = sub
            // sebelum pemisah terakhir (di atas Tandai selesai / Hapus…)
            let at = menu.items.lastIndex(where: \.isSeparatorItem) ?? menu.items.count
            menu.insertItem(parent, at: at)
        }
    }

    @objc private func reorderMenuItem(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.int64Value,
              let g = reorderGroups.first(where: { $0.items.contains { $0.id == id } }) else { return }
        var ids = g.items.map { $0.id }
        if item.tag == 0 {
            if g.reminders { LocalPrefs.reminderOrder = ManualOrder.reset(ids, in: LocalPrefs.reminderOrder) }
            else { LocalPrefs.todoOrder = ManualOrder.reset(ids, in: LocalPrefs.todoOrder) }
            rebuildList()
            return flashStatus("Urutan kembali menurut waktu")
        }
        guard let i = ids.firstIndex(of: id) else { return }
        ids.remove(at: i)
        switch item.tag {
        case -2: ids.insert(id, at: 0)
        case -1: ids.insert(id, at: max(0, i - 1))
        case 1: ids.insert(id, at: min(ids.count, i + 1))
        default: ids.append(id)
        }
        commitOrder(ids, reminders: g.reminders)
    }

    /// Seret baris lewat pegangan ≡: baris ikut berpindah selama mouse ditahan (hanya di dalam kelompoknya),
    /// urutan disimpan saat dilepas.
    private func dragReorder(_ id: Int64, _ event: NSEvent) {
        guard let window = view.window, let g = reorderGroups.first(where: { $0.items.contains { $0.id == id } }),
              g.items.count > 1, let row = g.items.first(where: { $0.id == id })?.view else { return }
        let before = g.items.map { $0.id }
        var views = g.items.map { $0.view }
        reordering = true
        row.alphaValue = 0.6
        NSCursor.closedHand.push()
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .rightMouseDragged, .rightMouseUp]
        while let e = window.nextEvent(matching: mask) {
            if e.type == .leftMouseUp || e.type == .rightMouseUp { break }
            listScroll.contentView.autoscroll(with: e)
            // posisi baru = jumlah baris lain yang titik tengahnya di atas mouse (koordinat jendela: y ke atas)
            let others = views.filter { $0 !== row }
            let target = others.filter { $0.convert($0.bounds, to: nil).midY > e.locationInWindow.y }.count
            guard views.firstIndex(where: { $0 === row }) != target, let first = others.first else { continue }
            listStack.removeArrangedSubview(row)
            let start = listStack.arrangedSubviews.firstIndex(where: { $0 === first }) ?? 0
            listStack.insertArrangedSubview(row, at: start + target)
            views = others
            views.insert(row, at: target)
            listStack.layoutSubtreeIfNeeded()
        }
        NSCursor.pop()
        row.alphaValue = 1
        reordering = false
        controlDown = NSEvent.modifierFlags.contains(.control)
        let after = views.compactMap { v in g.items.first { $0.view === v }?.id }
        if after != before { commitOrder(after, reminders: g.reminders) } else if listStale { refreshList() }
    }

    /// Simpan urutan baru satu kelompok (hanya di Mac ini), lalu bangun ulang daftar.
    private func commitOrder(_ ids: [Int64], reminders: Bool) {
        if reminders {
            LocalPrefs.reminderOrder = ManualOrder.place(ids, in: LocalPrefs.reminderOrder, keep: Set(store.reminders.map(\.id)))
        } else {
            LocalPrefs.todoOrder = ManualOrder.place(ids, in: LocalPrefs.todoOrder, keep: Set(store.todos.map(\.id)))
        }
        if listStale { refreshList() } else { rebuildList() }
        flashStatus("Urutan disimpan")
    }

    // MARK: Mode ubah

    func beginEdit(_ id: Int64) {
        guard let t = store.todos.first(where: { $0.id == id }) else { return }
        let lists = Array(Set(store.todos.map(\.list).filter { !$0.isEmpty })).sorted()
        let e = TodoEditor(todo: t, lists: lists, tz: store.tz)
        e.onCancel = { [weak self] in self?.endEdit() }
        e.onSave = { [weak self, weak e] fields in
            guard let self, let e else { return }
            e.busy = true
            self.app.updateTodo(id, fields) { err in
                e.busy = false
                if let err { e.showError(err) } else { self.endEdit() }
            }
        }
        editor = e
        rebuildList()
        DispatchQueue.main.async { [weak self, weak e] in
            guard let self, let e, self.editor === e else { return }
            e.scrollToVisible(e.bounds)
            self.view.window?.makeFirstResponder(e.titleField)
        }
    }

    private func endEdit() {
        guard editor != nil else { return }
        editor = nil
        rebuildList()
    }

    @objc private func rowDoubleClicked(_ g: TodoClick) { beginEdit(g.todoID) }
    @objc private func editMenuItem(_ item: NSMenuItem) { (item.representedObject as? NSNumber).map { beginEdit($0.int64Value) } }
    @objc private func completeMenuItem(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.int64Value else { return }
        if editor?.todo.id == id { editor = nil }
        app.complete(todo: id)
    }

    @objc private func scopeChanged() {
        editor = nil // ganti filter = batal ubah
        if mode == .reminders { LocalPrefs.reminderScope = scope.selectedSegment } else { LocalPrefs.todoScope = scope.selectedSegment }
        updateAddCard()
        if mode == .todo && showDone { loadDone() }
        rebuildList()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    @objc private func showAllTapped() {
        scope.selectedSegment = 1
        scopeChanged()
    }

    @objc private func completeClicked(_ sender: NSButton) {
        // ⌥-klik = ubah (dicek langsung dari keyboard, tidak bergantung pada monitor flagsChanged)
        if NSEvent.modifierFlags.contains(.option) { return beginEdit(Int64(sender.tag)) }
        sender.image = UI.symbol("checkmark.circle.fill", 16)
        sender.contentTintColor = Theme.accent
        sender.isEnabled = false
        let id = Int64(sender.tag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.app.complete(todo: id) }
    }

    /// Tambah dari kartu cepat: todo (tab Todo) atau pengingat sekali / tiap hari (tab Pengingat).
    @objc private func addManual() {
        guard addButton.isEnabled else { return }
        addError.isHidden = true
        let done: (String?) -> Void = { [weak self] err in
            guard let self else { return }
            self.addButton.isEnabled = true
            if let err {
                self.addError.stringValue = err
                self.addError.toolTip = err
                self.addError.isHidden = false
            } else {
                self.titleField.stringValue = ""
                self.view.window?.makeFirstResponder(self.titleField)
                self.flashStatus(self.mode == .reminders ? "Pengingat ditambahkan" : "Todo ditambahkan")
            }
        }
        let time = Clock.hm(timePicker.dateValue, store.tz)
        if mode == .reminders {
            let daily = duePopup.selectedTag() == PopoverController.dailyTag
            let todoID = Int64(quickTodoPopup.selectedTag())
            let todo = store.todos.first { $0.id == todoID }
            if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let todo {
                titleField.stringValue = todo.title // judul kosong = judul todo terkait
            }
            addButton.isEnabled = false
            app.createReminder(title: titleField.stringValue, date: daily ? nil : quickDate(), time: time,
                               todoId: todo?.id ?? 0) { [weak self] err in
                done(err)
                guard err == nil, let self, let todo else { return }
                // Pengingat milik todo tidak tampil di tab ini, tapi sebagai 🔔 di baris todo-nya
                self.quickTodoPopup.selectItem(withTag: 0)
                self.quickAutoTitle = nil
                self.flashStatus("Pengingat ditambahkan · 🔔 di todo “\(todo.title)”")
            }
            return
        }
        let hasTime = duePopup.selectedTag() >= 0 && timeCheck.state == .on
        addButton.isEnabled = false
        app.createTodo(title: titleField.stringValue, dayOffset: duePopup.selectedTag(), time: hasTime ? time : "", done: done)
    }

    // MARK: Belum terhubung

    private func buildOffline() {
        let icon = NSImageView(image: UI.symbol("checklist", 30) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let connect = NSButton(title: "Hubungkan ke server…", target: app, action: #selector(AppDelegate.connect))
        connect.bezelStyle = .rounded
        connect.bezelColor = Theme.accent
        let token = NSButton(title: "Pakai token perangkat…", target: app, action: #selector(AppDelegate.connectToken))
        token.isBordered = false
        token.contentTintColor = Theme.accent
        let s = UI.stack([icon, offlineTitle, offlineNote, connect, token], spacing: 10)
        s.alignment = .centerX
        s.setCustomSpacing(16, after: offlineNote)
        s.translatesAutoresizingMaskIntoConstraints = false
        offlineBox.addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: offlineBox.centerXAnchor),
            s.centerYAnchor.constraint(equalTo: offlineBox.centerYAnchor, constant: -20),
        ])
    }

    // MARK: Keadaan

    /// Dipanggil AppDelegate setiap keadaan store berubah.
    func storeChanged() {
        guard isViewLoaded else { return }
        let online = store.connected
        offlineBox.isHidden = online
        chatBox.isHidden = !online || mode != .chat
        manualBox.isHidden = !online || mode == .chat || mode == .notes
        notesPane.isHidden = !online || mode != .notes
        segment.isEnabled = online
        if store.needsLogin {
            offlineTitle.stringValue = "Sesi berakhir"
            offlineNote.stringValue = "Token Mac ini sudah dicabut atau tidak berlaku lagi. Hubungkan ulang untuk lanjut."
        } else {
            offlineTitle.stringValue = "Hubungkan Mac ini ke AI Todo"
            offlineNote.stringValue = "Masuk dengan akun AI Todo. Password tidak disimpan: Mac ini mendapat token sendiri di Keychain."
        }
        syncLabel.stringValue = app.syncStatus
        if online {
            // Hemat sumber daya: popover tertutup → daftar tidak digambar ulang di latar (bisa ratusan baris
            // setiap sinkron); cukup ditandai, lalu dibangun sekali tepat sebelum popover tampil (`willShow`).
            // Sedang menyeret baris (mode urutkan) → juga ditunda sampai mouse dilepas.
            let visible = view.window?.isVisible == true
            // Tab Catatan: daftar todo/pengingat tersembunyi → cukup ditandai, dibangun saat tabnya dibuka lagi
            if visible && !reordering && mode != .notes { refreshList() } else { listStale = true }
            notesPane.storeChanged(visible: visible && mode == .notes)
        }
        updateControls()
    }

    /// Bangun ulang daftar mengikuti store (dipanggil saat popover terlihat, atau dari `willShow`).
    private func refreshList() {
        listStale = false
        // Selama mengubah, daftar tidak dibangun ulang (isi kartu ubah tidak boleh hilang karena sinkron),
        // kecuali todo yang diubah sudah tidak ada (selesai / dihapus di perangkat lain).
        if let editor, store.todos.contains(where: { $0.id == editor.todo.id }) {
            updateScopeLabels(buckets)
        } else {
            editor = nil
            rebuildList()
            if mode == .todo && showDone { loadDone() } // todo bisa selesai/dibuka lagi di perangkat lain
        }
    }

    /// Tepat sebelum popover tampil: lengkapi perubahan yang ditunda selama popover tertutup.
    func willShow() {
        _ = view
        if listStale && store.connected && mode != .notes { refreshList() }
        if mode == .notes { notesPane.willShow() }
    }

    func select(_ m: Mode) {
        _ = view
        if m != mode {
            editor = nil; addCardOpen = false; closeAdvanced(focus: false); searchField.stringValue = ""
            if mode == .notes { notesPane.leave() }
        }
        mode = m
        segment.selectedSegment = m.rawValue
        configureScope()
        updateAddCard()
        storeChanged()
    }

    /// Popover utama tertutup: pratinjau detail ikut ditutup (jangan tertinggal melayang tanpa induk).
    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeDetail()
    }

    /// Popover baru tampil: fokus ke input & muat riwayat chat terbaru.
    func didShow() {
        guard store.connected else { return }
        optionDown = NSEvent.modifierFlags.contains(.option)
        controlDown = NSEvent.modifierFlags.contains(.control)
        if mode == .chat {
            view.window?.makeFirstResponder(input)
            loadHistory()
        } else if mode == .notes {
            notesPane.didShow()
        } else if let editor {
            view.window?.makeFirstResponder(editor.titleField)
        } else if mode != .chat && !showDone && addCardOpen {
            view.window?.makeFirstResponder(advancedTitleField ?? titleField)
        } else {
            focusSearch() // kartu tambah tertutup → langsung bisa mengetik untuk mencari
        }
    }

    @objc private func segmentChanged() {
        select(Mode(rawValue: segment.selectedSegment) ?? .chat)
        didShow()
    }

    /// Pintasan popover (cari & pindah tab). false = tidak berlaku di keadaan ini → event diteruskan seperti biasa.
    /// ＋ dan ↻ lewat keyEquivalent tombolnya (`KeyBindings`).
    private func perform(_ a: ShortcutAction) -> Bool {
        let tabs = 4
        let target: Mode
        switch a {
        case .search:
            if mode == .notes && !notesPane.isHidden {
                notesPane.focusSearch()
                return true
            }
            guard mode != .chat, !manualBox.isHidden else { return false }
            focusSearch()
            return true
        case .tabChat: target = .chat
        case .tabTodo: target = .todo
        case .tabReminders: target = .reminders
        case .tabNotes: target = .notes
        case .nextTab: target = Mode(rawValue: (mode.rawValue + 1) % tabs) ?? .chat
        case .previousTab: target = Mode(rawValue: (mode.rawValue + tabs - 1) % tabs) ?? .chat
        default: return false
        }
        segment.selectedSegment = target.rawValue
        segmentChanged()
        return true
    }

    /// Konfirmasi lalu hapus seluruh riwayat chat (DELETE /api/chat, sama dengan web → Hapus riwayat).
    /// Server ikut menghapus semua kartu aksi: yang menunggu konfirmasi batal tanpa dijalankan,
    /// dan aksi yang sudah dijalankan tidak bisa di-undo lagi (todo/pengingatnya tetap ada).
    @objc func confirmClearHistory() {
        guard store.connected, !busy, mode == .chat else { return }
        var text = "Riwayat juga terhapus di web. Todo, pengingat, dan Ingatan AI tidak terhapus."
        if pending != nil { text += "\n\nAksi yang menunggu konfirmasi ikut dibatalkan (tidak dijalankan)." }
        if undoable != nil { text += "\n\nAksi terakhir tidak bisa dibatalkan (undo) lagi; hasilnya tetap ada." }
        let a = NSAlert()
        a.messageText = "Hapus semua riwayat chat?"
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        store.api.clearChat { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch r {
                case .success:
                    self.pending = nil
                    self.undoable = nil
                    self.updateControls()
                    self.loadHistory() // riwayat kosong → sapaan awal
                case .failure(let e):
                    showError("Gagal menghapus riwayat chat", e.description)
                }
            }
        }
    }

    @objc private func openWeb() { app.openWebPage(["/", "/todo", "/pengingat", "/catatan"][mode.rawValue]) }
    @objc private func openSettings() { app.openSettings() }
}

// MARK: - Kartu ubah todo (mode ubah di tab Manual)

/// Klik dua kali judul todo → ubah (menyimpan id todo di recognizer).
final class TodoClick: NSClickGestureRecognizer {
    var todoID: Int64 = 0
}

/// Lingkaran ○ di kiri baris todo / pengingat. Selama ⌃ ditahan (mode urutkan) menjadi pegangan ≡:
/// tekan lalu seret = pindahkan baris. ⌃-klik biasanya = klik kanan (menu), jadi di mode urutkan menu
/// tidak dibuka dari tombol ini — klik kanan di teks baris tetap membuka menu.
final class RowCheck: NSButton {
    /// Mode urutkan sedang aktif untuk baris ini?
    var canReorder: () -> Bool = { false }
    /// Mulai menyeret (melacak mouse sampai dilepas).
    var onReorder: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if canReorder(), let onReorder { return onReorder(event) }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), canReorder(), let onReorder { return onReorder(event) }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        canReorder() ? nil : super.menu(for: event)
    }

    override func resetCursorRects() {
        if canReorder() { addCursorRect(bounds, cursor: .openHand) } else { super.resetCursorRects() }
    }
}

/// Baris daftar di popover (○ + teks). ⌃-klik pada pegangan ≡ di mode urutkan tidak membuka menu baris,
/// supaya tekan-lalu-seret sampai ke `RowCheck`.
final class ListRow: NSStackView {
    /// Tinggi satu baris judul (13 pt). Ikon kiri (○ / ≡ / ✎) diberi kotak tetap setinggi baris pertama
    /// judul dengan ikon di tengahnya, supaya ikon sejajar dengan baris teks pertama — tidak bergeser
    /// saat ikon berganti ukuran (○ 16 pt ↔ ≡ 14 pt) atau judul berlipat beberapa baris.
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)))
    static let iconWidth: CGFloat = 18

    static func make(_ views: [NSView]) -> ListRow {
        let r = ListRow(views: views)
        r.orientation = .horizontal
        r.alignment = .top
        r.spacing = 8
        if let icon = views.first as? NSButton {
            icon.imagePosition = .imageOnly
            icon.imageScaling = .scaleProportionallyDown // ikon di tengah kotak; hanya diperkecil bila lebih besar
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.widthAnchor.constraint(equalToConstant: iconWidth).isActive = true
            icon.heightAnchor.constraint(equalToConstant: lineHeight).isActive = true
        }
        return r
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = superview.map { $0.convert(event.locationInWindow, from: nil) } ?? .zero
        if let c = hitTest(p) as? RowCheck, c.canReorder() { return nil }
        return super.menu(for: event)
    }
}

/// Menggantikan baris todo di daftar selama diubah. Tanggal & jam memakai NSDatePicker bawaan macOS
/// (kalender muncul saat tanggal diklik; jam bisa diketik atau pakai panah).
/// `full: true` = lembar (sheet) di tab Todo Pengaturan: ada judul lembar, catatan, dan tombol Hapus…;
/// todo dengan id 0 = todo baru (di popover: "Isian lengkap…" kartu tambah, tombol Simpan jadi Tambah).
///   ┌ Judul todo______________________________ ┐
///   │ Kategori [Belanja        ▾]  [Normal ▾]  │
///   │ ☑ Tanggal [2/11/2026]  ☑ Jam [14.30 ⇅]   │
///   └ pesan galat              [Batal] [Simpan] ┘
final class TodoEditor: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    let todo: Todo
    let tz: TimeZone
    let titleField = NSTextField()
    private let listBox = NSComboBox()
    private let priority = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dateCheck = NSButton(checkboxWithTitle: "Tanggal", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let timeCheck = NSButton(checkboxWithTitle: "Jam", target: nil, action: nil)
    private let timePicker = NSDatePicker()
    private let error = UI.label("", size: 11, color: Theme.danger)
    private let cancelButton = NSButton(title: "Batal", target: nil, action: nil)
    private let saveButton = NSButton(title: "Simpan", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Hapus…", target: nil, action: nil)
    private let notesField = NSTextField()
    private let full: Bool
    private static let priorities = ["low", "normal", "high"]

    var onSave: (([String: String]) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var busy = false { didSet { [saveButton, cancelButton, deleteButton].forEach { $0.isEnabled = !busy } } }

    init(todo: Todo, lists: [String], tz: TimeZone, full: Bool = false) {
        self.todo = todo
        self.tz = tz
        self.full = full
        super.init(frame: .zero)
        build(lists)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private func build(_ lists: [String]) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let locale = Locale(identifier: "id_ID")

        titleField.stringValue = todo.title
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Judul todo"
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(save)
        titleField.setAccessibilityLabel("Judul todo")

        listBox.addItems(withObjectValues: lists)
        listBox.stringValue = todo.list
        listBox.placeholderString = "Kategori (opsional)"
        listBox.completes = true
        listBox.controlSize = .small
        listBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        listBox.delegate = self // ↩ = simpan lewat doCommandBy (action combo box juga terpanggil saat memilih item)
        listBox.setAccessibilityLabel("Kategori")

        priority.addItems(withTitles: ["Prioritas rendah", "Prioritas normal", "Prioritas tinggi"])
        priority.selectItem(at: TodoEditor.priorities.firstIndex(of: todo.priority) ?? 1)
        priority.controlSize = .small
        priority.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        for p in [datePicker, timePicker] {
            p.calendar = cal
            p.timeZone = tz
            p.locale = locale
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.isBezeled = true
            p.drawsBackground = true
        }
        datePicker.datePickerStyle = .textField
        datePicker.datePickerElements = .yearMonthDay
        datePicker.presentsCalendarOverlay = true // kalender kecil saat diklik (date picker)
        datePicker.dateValue = Clock.due(todo.dueDate, "12:00", tz) ?? Date()
        datePicker.setAccessibilityLabel("Tanggal tenggat")
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute // time picker 24 jam
        let today = Clock.ymd(Date(), tz)
        timePicker.dateValue = Clock.due(today, todo.dueTime.isEmpty ? "09:00" : todo.dueTime, tz) ?? Date()
        timePicker.setAccessibilityLabel("Jam tenggat")

        for c in [dateCheck, timeCheck] {
            c.controlSize = .small
            c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            c.target = self
            c.action = #selector(checksChanged)
        }
        dateCheck.state = todo.dueDate.isEmpty ? .off : .on
        timeCheck.state = todo.dueTime.isEmpty ? .off : .on
        checksChanged()

        for b in [cancelButton, saveButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        cancelButton.action = #selector(cancel)
        saveButton.action = #selector(save)
        saveButton.bezelColor = Theme.accent
        error.isHidden = true
        error.lineBreakMode = .byTruncatingTail
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let meta = UI.stack([listBox, priority], vertical: false, spacing: 8)
        let when = UI.stack([dateCheck, datePicker, NSView(), timeCheck, timePicker], vertical: false, spacing: 6)
        var buttonViews: [NSView] = [error, NSView(), cancelButton, saveButton]
        var rows: [NSView] = [titleField, meta, when]
        // Detail (opsional): link, rincian, daftar catatan — ↩ = baris baru. Ada di kartu ubah & lembar penuh.
        notesField.stringValue = todo.notes
        notesField.placeholderString = "Detail (opsional): link, rincian, daftar…"
        notesField.bezelStyle = .roundedBezel
        notesField.usesSingleLineMode = false
        notesField.cell?.wraps = true
        notesField.cell?.isScrollable = false
        notesField.lineBreakMode = .byWordWrapping
        notesField.delegate = self
        notesField.setAccessibilityLabel("Detail")
        // todo baru di popover: kolom detail sedikit lebih tinggi (isian lengkap = tempat menulis detail)
        notesField.heightAnchor.constraint(equalToConstant: full ? 96 : (todo.id == 0 ? 72 : 52)).isActive = true
        if !full {
            notesField.controlSize = .small
            notesField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        rows.insert(notesField, at: 1)
        if full {
            let head = UI.label(todo.id == 0 ? "Todo baru" : "Ubah todo", size: 15, weight: .semibold)
            rows.insert(head, at: 0)
            if todo.id != 0 {
                deleteButton.bezelStyle = .rounded
                deleteButton.target = self
                deleteButton.action = #selector(deleteTapped)
                deleteButton.hasDestructiveAction = true
                buttonViews.insert(deleteButton, at: 0)
            }
            [cancelButton, saveButton, deleteButton].forEach { $0.controlSize = .regular }
            cancelButton.keyEquivalent = "\u{1b}"
            saveButton.keyEquivalent = "\r" // lembar: ↩ = Simpan (tombol bawaan)
        } else if todo.id == 0 {
            // Popover → Isian lengkap: judul kecil seperti judul kelompok daftar
            rows.insert(UI.label("Todo baru", size: 12, weight: .semibold, color: .secondaryLabelColor), at: 0)
            saveButton.title = "Tambah"
        }
        let buttons = UI.stack(buttonViews, vertical: false, spacing: 8)
        rows.append(buttons)
        let form = UI.stack(rows, spacing: full ? 12 : 8)
        for v in rows { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        listBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if full {
            form.translatesAutoresizingMaskIntoConstraints = false
            addSubview(form)
            UI.pin(form, to: self, top: 20, left: 20, bottom: 20, right: 20)
            return
        }
        let card = RoundedBox(fill: .controlBackgroundColor, stroke: Theme.accent, radius: 12)
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        UI.pin(card, to: self, top: 4, bottom: 4)
    }

    @objc private func deleteTapped() { onDelete?() }

    /// Jam hanya bisa dipakai kalau ada tanggal (aturan yang sama dengan server & web).
    @objc private func checksChanged() {
        let hasDate = dateCheck.state == .on
        datePicker.isEnabled = hasDate
        timeCheck.isEnabled = hasDate
        timePicker.isEnabled = hasDate && timeCheck.state == .on
    }

    func showError(_ text: String) {
        error.stringValue = text
        error.toolTip = text
        error.isHidden = false
    }

    @objc private func save() {
        guard !busy else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return showError("Judul tidak boleh kosong.") }
        error.isHidden = true
        let hasDate = dateCheck.state == .on
        let hasTime = hasDate && timeCheck.state == .on
        var fields = [
            "title": title,
            "list": listBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "priority": TodoEditor.priorities[max(0, priority.indexOfSelectedItem)],
            "dueDate": hasDate ? Clock.ymd(datePicker.dateValue, tz) : "",
            "dueTime": hasTime ? Clock.hm(timePicker.dateValue, tz) : "",
        ]
        fields["notes"] = notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(fields)
    }

    @objc private func cancel() { onCancel?() }

    /// esc di kolom judul / kategori = batal; ↩ di kategori = simpan.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        if control === listBox, selector == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        // Detail: ↩ = baris baru (bukan simpan)
        if control === notesField, selector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}

// MARK: Input chat: ↩ kirim, ⇧↩ baris baru

extension PopoverController: NSPopoverDelegate {
    /// Pratinjau detail tertutup: kembalikan fokus ke popover utama supaya kliknya langsung bekerja lagi.
    func popoverDidClose(_ notification: Notification) {
        if let p = notification.object as? NSPopover, p === detailPopover { detailPopover = nil }
        if let w = view.window, w.isVisible, !w.isKeyWindow { w.makeKey() }
    }
}

/// Kolom cari popover (NSSearchField butuh delegate NSSearchFieldDelegate; isinya di NSTextFieldDelegate di bawah).
extension PopoverController: NSSearchFieldDelegate {}

extension PopoverController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Esc di kartu tambah cepat = tutup kartu (Esc berikutnya baru menutup popover)
        if control === titleField, selector == #selector(NSResponder.cancelOperation(_:)) {
            setAddCard(open: false)
            return true
        }
        // Esc di kolom cari: kosongkan dulu, Esc berikutnya menutup popover (seperti biasa)
        if control === searchField, selector == #selector(NSResponder.cancelOperation(_:)) {
            if searchField.stringValue.isEmpty { app.closePopover() } else { searchField.stringValue = ""; searchChanged() }
            return true
        }
        guard control === input, selector == #selector(NSResponder.insertNewline(_:)),
              NSApp.currentEvent?.modifierFlags.contains(.shift) == true else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        resizeInput()
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === input else { return }
        resizeInput()
        updateSuggestions()
    }
}

// MARK: - Jendela Pengaturan (tab Umum, Todo, Akun, Ingatan, Tentang — pola PasteLAN)

/// Kartu berlatar gaya System Settings; warnanya ikut tema terang / gelap
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
    }
}

/// Perekam pintasan (Pengaturan → Pintasan), pola System Settings → Papan Ketik: klik → "Ketik pintasan…" →
/// tekan kombinasi baru. ⌫ = kosongkan (pintasan nonaktif), Esc / klik lagi / klik di tempat lain = batal.
final class ShortcutField: NSButton {
    /// Ada perekam yang aktif: monitor pintasan lain (popover, menu Edit) melewatkan event.
    static var recording: Bool { current != nil }
    private static weak var current: ShortcutField?

    let shortcut: ShortcutAction
    /// Mulai / selesai merekam (hotkey global dilepas selama merekam).
    var onRecording: ((Bool) -> Void)?
    /// Kombinasi baru; nil = dikosongkan.
    var onPick: ((ShortcutAction, KeyCombo?) -> Void)?
    private var isRecording = false
    private var monitor: Any?
    private var resignObserver: Any?

    init(_ shortcut: ShortcutAction) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 128).isActive = true
        setAccessibilityLabel("Pintasan \(shortcut.title)")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    func refresh() {
        title = isRecording ? "Ketik pintasan…" : (LocalPrefs.keys[shortcut]?.display ?? "Tidak ada")
        bezelColor = isRecording ? Theme.accent : nil
        toolTip = isRecording ? "⌫ = kosongkan, Esc = batal" : "Klik untuk mengubah"
    }

    @objc private func clicked() { isRecording ? stop() : start() }

    private func start() {
        ShortcutField.current?.stop()
        ShortcutField.current = self
        isRecording = true
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.isRecording else { return e }
            if e.type != .keyDown {
                // klik di luar perekam = batal (klik di perekam sendiri ditangani `clicked`)
                if e.window !== self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) { self.stop() }
                return e
            }
            self.record(e)
            return nil
        }
        if let w = window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w,
                                                                    queue: .main) { [weak self] _ in self?.stop() }
        }
        refresh()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if ShortcutField.current === self { ShortcutField.current = nil }
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        onRecording?(false)
        refresh()
    }

    private func record(_ e: NSEvent) {
        let mods = KeyCombo.modifiers(e.modifierFlags)
        let code = Int(e.keyCode)
        if mods == 0 && code == KeyCombo.escapeKey { return stop() }
        if mods == 0 && (code == KeyCombo.deleteKey || code == KeyCombo.forwardDeleteKey) {
            stop()
            onPick?(shortcut, nil)
            return
        }
        let chars = e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? ""
        guard !chars.isEmpty else { return NSSound.beep() }
        stop()
        onPick?(shortcut, KeyCombo(keyCode: code, chars: chars, mods: mods))
    }
}

/// Potongan tata letak formulir: setiap baris = judul + keterangan di kiri, satu kontrol di kanan.
/// Pilihan nyala / mati selalu NSSwitch, aksi selalu tombol berlabel kata kerja → mudah dibedakan.
enum Form {
    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        return l
    }

    static func note(_ s: String, width: CGFloat = 340) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
        return l
    }

    static func row(_ title: String, _ detail: String?, _ control: NSView?) -> NSView {
        row(label(title, weight: .medium), detail, control)
    }

    static func row(_ head: NSView, _ detail: String?, _ control: NSView?) -> NSView {
        var texts: [NSView] = [head]
        if let detail { texts.append(note(detail, width: control == nil ? 500 : 340)) }
        let left = UI.stack(texts, spacing: 3)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let r = UI.stack([left], vertical: false, spacing: 16)
        r.distribution = .fill // teks melebar, kontrol selalu rata kanan → semua switch sejajar
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            r.addArrangedSubview(control)
        }
        return r
    }

    static func section(_ title: String, _ rows: [NSView]) -> NSView {
        let card = CardView()
        let inner = UI.stack([], spacing: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                inner.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            }
            inner.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        let out = UI.stack([label(title, weight: .semibold), card], spacing: 6)
        card.widthAnchor.constraint(equalTo: out.widthAnchor).isActive = true
        return out
    }

    static func toggle(_ target: AnyObject, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        return s
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }
}

/// Halaman berukuran tetap berisi bagian-bagian formulir dari atas ke bawah
final class FormPage: NSViewController {
    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        view = v
        preferredContentSize = SettingsWindow.size
    }

    func set(_ sections: [NSView]) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let content = UI.stack([], spacing: 18)
        // Margin lewat edgeInsets, lalu dibungkus scroll: isi yang lebih tinggi dari jendela bisa digulir.
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        UI.pin(UI.scroll(content), to: view)
        for s in sections {
            content.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
    }
}

/// Tab Todo: kelola semua todo seperti halaman Todo di web (filter, cari, kategori, tambah, ubah,
/// selesai / buka lagi, hapus, arsipkan). Semua aksi lewat API yang sama → validasi di server (internal/core).
///   [ Hari ini | Akan datang | Tanpa tenggat | Semua | Selesai ]
///   [🔍 Cari                ] [Semua kategori ▾]        [ + ]
///   ┌──────────────────────────────────────────────────────┐
///   │ ○ Bayar listrik                            Kemarin    │  ← klik dua kali / ↩ = ubah, spasi = selesai,
///   │   Belanja · Prioritas tinggi                          │    ⌫ = hapus, klik kanan = menu
///   └──────────────────────────────────────────────────────┘
///   7 todo                               [Arsipkan yang selesai]
final class TodoPage: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    enum Filter: Int, CaseIterable { case today, upcoming, nodate, all, done }
    static let filterTitles = ["Hari ini", "Akan datang", "Tanpa tenggat", "Semua", "Selesai"]

    unowned let app: AppDelegate
    private var store: Store { app.store }
    private let filterControl = NSSegmentedControl(labels: TodoPage.filterTitles, trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let listPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = TodoTable()
    private var detailPopover: NSPopover?
    private lazy var tableScroll = NSScrollView()
    private let empty = UI.label("", size: 13, color: .secondaryLabelColor)
    private let footer = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var archiveButton = Form.button("Arsipkan yang selesai", self, #selector(archiveTapped))
    private var rows: [Todo] = []
    private var doneTodos: [Todo] = []
    private var loadingDone = false
    private var sheetWindow: NSWindow?

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private var filter: Filter { Filter(rawValue: filterControl.selectedSegment) ?? .today }

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        view = v
        preferredContentSize = SettingsWindow.size

        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.selectedSegment = 0
        filterControl.segmentDistribution = .fillEqually
        filterControl.setAccessibilityLabel("Filter todo")

        search.placeholderString = "Cari judul atau catatan"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        listPopup.target = self
        listPopup.action = #selector(searchChanged)
        listPopup.setAccessibilityLabel("Filter kategori")
        let add = NSButton(image: UI.symbol("plus", 13, weight: .semibold) ?? NSImage(), target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.toolTip = "Todo baru (⌘N)"
        KeyBindings.bind(add, .newItem, tip: "Todo baru") // bawaan ⌘N (Pengaturan → Pintasan)
        add.setAccessibilityLabel("Todo baru")
        let tools = UI.stack([search, listPopup, add], vertical: false, spacing: 8)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("todo"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Daftar todo")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.autohidesScrollers = true

        empty.alignment = .center
        archiveButton.controlSize = .small
        let bottom = UI.stack([footer, NSView(), archiveButton], vertical: false, spacing: 8)

        for x in [filterControl, tools, tableScroll, empty, bottom] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            filterControl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            filterControl.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            tools.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 12),
            tools.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            tools.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            tableScroll.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m - 10),
            tableScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -(m - 10)),
            tableScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: tableScroll.widthAnchor, constant: -40),
            bottom.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            bottom.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            bottom.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    // MARK: Data

    /// Dipanggil saat tab dibuka dan setiap store berubah (sinkron dari perangkat lain).
    func reload() {
        guard isViewLoaded else { return }
        if filter == .done && store.connected && !loadingDone {
            loadingDone = true
            store.api.todos(status: "done") { [weak self] r in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loadingDone = false
                    if case .success(let d) = r { self.doneTodos = d.todos }
                    self.render()
                }
            }
        }
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        let b = store.buckets
        let counts = [b.badge, b.upcoming.count, b.noDate.count, b.total, doneTodos.count]
        for (i, title) in TodoPage.filterTitles.enumerated() {
            filterControl.setLabel(counts[i] > 0 && i != Filter.done.rawValue ? "\(title)  \(counts[i])" : title, forSegment: i)
        }

        // Kategori: dari semua todo yang dikenal; pilihan dipertahankan
        let lists = Array(Set((store.todos + doneTodos).map(\.list).filter { !$0.isEmpty })).sorted()
        let picked = listPopup.indexOfSelectedItem > 0 ? listPopup.titleOfSelectedItem : nil
        listPopup.removeAllItems()
        listPopup.addItem(withTitle: "Semua kategori")
        listPopup.addItems(withTitles: lists)
        if let picked, lists.contains(picked) { listPopup.selectItem(withTitle: picked) }
        listPopup.isHidden = lists.isEmpty

        let base: [Todo]
        switch filter {
        case .today: base = b.overdue + b.today
        case .upcoming: base = b.upcoming
        case .nodate: base = b.noDate
        case .all: base = b.overdue + b.today + b.upcoming + b.noDate
        case .done: base = doneTodos
        }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let list = listPopup.indexOfSelectedItem > 0 ? listPopup.titleOfSelectedItem ?? "" : ""
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        rows = base.filter { t in
            (list.isEmpty || t.list == list) &&
                (q.isEmpty || t.title.lowercased().contains(q) || t.notes.lowercased().contains(q))
        }
        table.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }

        if !store.connected {
            empty.stringValue = "Hubungkan Mac ini ke server dulu (tab Akun)."
        } else if rows.isEmpty {
            empty.stringValue = !q.isEmpty || !list.isEmpty ? "Tidak ada todo yang cocok." : [
                "Tidak ada todo untuk hari ini 🎉", "Tidak ada todo terjadwal.", "Semua todo punya tenggat.",
                "Semua todo sudah selesai 🎉", "Belum ada todo yang selesai.",
            ][filter.rawValue]
        }
        empty.isHidden = store.connected && !rows.isEmpty
        footer.stringValue = rows.isEmpty ? "" : "\(rows.count) todo · klik dua kali untuk mengubah"
        archiveButton.isHidden = filter != .done || doneTodos.isEmpty
        filterControl.isEnabled = store.connected
    }

    // MARK: Tabel

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TodoCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TodoCell ?? {
            let c = TodoCell()
            c.identifier = id
            c.check.target = self
            c.check.action = #selector(checkClicked(_:))
            return c
        }()
        cell.configure(rows[row], reminder: store.reminder(forTodo: rows[row].id), tz: store.tz)
        return cell
    }

    private func todo(at row: Int) -> Todo? { row >= 0 && row < rows.count ? rows[row] : nil }

    /// ↩ = ubah, spasi = selesai / buka lagi, ⌫ = hapus, ⌘C = salin (judul & detail; semua baris terpilih).
    private func handleKey(_ key: TodoTable.Key) -> Bool {
        if key == .copy {
            let picked = table.selectedRowIndexes.compactMap { todo(at: $0) }
            TodoCopy.copy(picked)
            return !picked.isEmpty
        }
        guard let t = todo(at: table.selectedRow) else { return false }
        switch key {
        case .copy: break
        case .enter: edit(t)
        case .space: toggle(t)
        case .delete: delete(t)
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let t = todo(at: table.clickedRow) else { return }
        func item(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = NSNumber(value: t.id)
            menu.addItem(i)
        }
        if !t.notes.isEmpty { item("Lihat detail", #selector(detailMenu(_:))) }
        item("Ubah…", #selector(editMenu(_:)))
        item("Salin", #selector(copyMenu(_:)))
        if !t.notes.isEmpty {
            item("Salin judul saja", #selector(copyTitleMenu(_:)))
            menu.items.last?.isAlternate = true // tahan ⌥ di menu
            menu.items.last?.keyEquivalentModifierMask = .option
        }
        item(t.status == "done" ? "Buka lagi" : "Tandai selesai", #selector(toggleMenu(_:)))
        menu.addItem(.separator())
        item("Hapus…", #selector(deleteMenu(_:)))
    }

    private func find(_ sender: NSMenuItem) -> Todo? {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return nil }
        return rows.first { $0.id == id }
    }

    @objc private func editMenu(_ s: NSMenuItem) { find(s).map(edit) }
    @objc private func copyMenu(_ s: NSMenuItem) { find(s).map { TodoCopy.copy([$0]) } }
    @objc private func copyTitleMenu(_ s: NSMenuItem) { find(s).map { TodoCopy.copy([$0], titleOnly: true) } }
    @objc private func detailMenu(_ s: NSMenuItem) {
        guard let t = find(s), let row = rows.firstIndex(where: { $0.id == t.id }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        detailPopover?.close()
        let vc = DetailPreview(todo: t, tz: store.tz)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        vc.onEdit = { [weak self, weak p] in
            p?.close()
            self?.edit(t)
        }
        detailPopover = p
        p.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxX)
    }
    @objc private func toggleMenu(_ s: NSMenuItem) { find(s).map(toggle) }
    @objc private func deleteMenu(_ s: NSMenuItem) { find(s).map(delete) }
    @objc private func editClicked() { todo(at: table.clickedRow).map(edit) }
    @objc private func checkClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard let t = todo(at: row) else { return }
        sender.image = UI.symbol(t.status == "done" ? "circle" : "checkmark.circle.fill", 17)
        toggle(t)
    }
    @objc private func filterChanged() { reload() }
    @objc private func searchChanged() { render() }
    func controlTextDidChange(_ obj: Notification) { render() }

    // MARK: Aksi (semua lewat API → validasi server)

    private func run<T>(_ title: String, _ call: (@escaping (Result<T, APIError>) -> Void) -> Void, done: ((T) -> Void)? = nil) {
        call { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success(let v): done?(v)
                case .failure(let e): showError(title, e.description)
                }
                self?.store.refresh()
                if self?.filter == .done { self?.reload() }
            }
        }
    }

    private func toggle(_ t: Todo) {
        if t.status == "done" {
            doneTodos.removeAll { $0.id == t.id }
            run("Gagal membuka lagi todo", { store.api.reopen(todo: t.id, $0) })
        } else {
            run("Gagal menandai selesai", { store.api.complete(todo: t.id, $0) })
        }
    }

    private func delete(_ t: Todo) {
        let a = NSAlert()
        a.messageText = "Hapus “\(t.title)”?"
        a.informativeText = "Pengingat milik todo ini ikut terhapus. Tindakan ini tidak bisa dibatalkan."
        a.alertStyle = .warning
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons.first?.hasDestructiveAction = true
        let go = { [weak self] in
            guard let self else { return }
            self.doneTodos.removeAll { $0.id == t.id }
            self.run("Gagal menghapus todo", { self.store.api.deleteTodo(t.id, $0) })
        }
        if let w = view.window, sheetWindow == nil {
            a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { go() } }
        } else if a.runModal() == .alertFirstButtonReturn { go() }
    }

    @objc private func archiveTapped() {
        let n = doneTodos.count
        let a = NSAlert()
        a.messageText = "Arsipkan \(n) todo yang sudah selesai?"
        a.informativeText = "Todo yang diarsipkan tidak tampil lagi di daftar."
        a.addButton(withTitle: "Arsipkan")
        a.addButton(withTitle: "Batal")
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            self.doneTodos = []
            self.run("Gagal mengarsipkan", { self.store.api.archiveDone($0) })
        }
    }

    @objc private func addTapped() {
        guard store.connected else { return }
        let preset = filter == .today ? Clock.ymd(Date(), store.tz) : ""
        let blank = Todo(id: 0, title: "", notes: "", status: "open", priority: "normal",
                         list: listPopup.indexOfSelectedItem > 0 ? listPopup.titleOfSelectedItem ?? "" : "",
                         dueDate: preset, dueTime: "")
        edit(blank)
    }

    /// Lembar ubah / todo baru (TodoEditor mode lengkap) di atas jendela Pengaturan.
    private func edit(_ t: Todo) {
        guard let window = view.window, sheetWindow == nil else { return }
        let lists = Array(Set((store.todos + doneTodos).map(\.list).filter { !$0.isEmpty })).sorted()
        let e = TodoEditor(todo: t, lists: lists, tz: store.tz, full: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentView = e
        e.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let close = { [weak self, weak sheet] in
            guard let sheet else { return }
            window.endSheet(sheet)
            self?.sheetWindow = nil
        }
        e.onCancel = close
        e.onSave = { [weak self, weak e] fields in
            guard let self, let e else { return }
            e.busy = true
            let finish: (Result<APIClient.TodoResult, APIError>) -> Void = { r in
                DispatchQueue.main.async {
                    e.busy = false
                    switch r {
                    case .success: close()
                    case .failure(let err): e.showError("Gagal menyimpan: \(err.description)")
                    }
                    self.store.refresh()
                    if self.filter == .done { self.reload() }
                }
            }
            if t.id == 0 { self.store.api.createTodo(fields, finish) } else { self.store.api.updateTodo(t.id, fields, finish) }
        }
        e.onDelete = { [weak self] in
            close()
            DispatchQueue.main.async { self?.delete(t) }
        }
        sheetWindow = sheet
        e.layoutSubtreeIfNeeded()
        sheet.setContentSize(NSSize(width: 460, height: max(200, e.fittingSize.height)))
        window.beginSheet(sheet)
        sheet.makeFirstResponder(e.titleField)
    }
}

/// Satu baris di tab Todo: lingkaran selesai, judul, keterangan, dan tenggat di kanan.
final class TodoCell: NSTableCellView {
    let check = NSButton(image: NSImage(), target: nil, action: nil)
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = UI.label("", size: 11, color: .secondaryLabelColor)
    private let due = UI.label("", size: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.isBordered = false
        title.font = .systemFont(ofSize: 13)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        due.alignment = .right
        due.setContentHuggingPriority(.required, for: .horizontal)
        due.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = UI.stack([title, meta], spacing: 2)
        let row = UI.stack([check, texts, due], vertical: false, spacing: 8)
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        UI.pin(row, to: self, top: 6, left: 4, bottom: 6, right: 8)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    func configure(_ t: Todo, reminder: Reminder? = nil, tz: TimeZone) {
        let done = t.status == "done"
        check.image = UI.symbol(done ? "checkmark.circle.fill" : "circle", 17)
        check.contentTintColor = done ? Theme.accent : t.priority == "high" ? Theme.danger : .tertiaryLabelColor
        check.isEnabled = true
        check.toolTip = done ? "Buka lagi" : "Tandai selesai"
        check.setAccessibilityLabel(done ? "Buka lagi “\(t.title)”" : "Tandai “\(t.title)” selesai")
        let attrs: [NSAttributedString.Key: Any] = done
            ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor]
            : [.foregroundColor: NSColor.labelColor]
        title.attributedStringValue = NSAttributedString(string: (t.priority == "high" ? "! " : "") + t.title,
                                                         attributes: attrs.merging([.font: NSFont.systemFont(ofSize: 13)]) { a, _ in a })
        var m: [String] = []
        if !t.list.isEmpty { m.append(t.list) }
        if t.priority == "high" { m.append("Prioritas tinggi") } else if t.priority == "low" { m.append("Prioritas rendah") }
        if !t.notes.isEmpty { m.append(t.notes.replacingOccurrences(of: "\n", with: " ")) }
        // Todo yang punya pengingat aktif: 🔔 + waktu berbunyi berikutnya di depan keterangan
        let text = NSMutableAttributedString()
        let metaAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        if let r = reminder, let d = Clock.parseStamp(r.nextFireAt), let bell = UI.symbol("bell.fill", 9)?.withSymbolConfiguration(.init(paletteColors: [Theme.accent])) {
            let icon = NSTextAttachment()
            icon.image = bell
            text.append(NSAttributedString(attachment: icon))
            let name = Clock.friendly(Clock.ymd(d, tz), now: Date(), tz)
            text.append(NSAttributedString(string: " " + name.prefix(1).uppercased() + name.dropFirst() + " " + Clock.hm(d, tz)
                + (m.isEmpty ? "" : " · "), attributes: metaAttrs))
        }
        text.append(NSAttributedString(string: m.joined(separator: " · "), attributes: metaAttrs))
        meta.attributedStringValue = text
        meta.lineBreakMode = .byTruncatingTail
        meta.isHidden = text.length == 0
        if t.dueDate.isEmpty {
            due.stringValue = ""
        } else {
            let today = Clock.ymd(Date(), tz)
            let name = Clock.friendly(t.dueDate, now: Date(), tz)
            due.stringValue = (name.prefix(1).uppercased() + name.dropFirst()) + (t.dueTime.isEmpty ? "" : " \(t.dueTime)")
            due.textColor = !done && t.dueDate < today ? Theme.danger : done ? .secondaryLabelColor : Theme.accent
            if !done && t.dueDate < today { due.stringValue = "Terlambat · " + due.stringValue }
        }
    }
}

/// NSTableView dengan pintasan papan ketik untuk tab Todo.
final class TodoTable: NSTableView {
    enum Key { case enter, space, delete, copy }
    var onKey: ((Key) -> Bool)?

    /// ⌘C (lewat menu Edit aplikasi) = salin todo yang dipilih.
    @objc func copy(_ sender: Any?) { _ = onKey?(.copy) }

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch event.keyCode {
        case 36, 76: key = .enter // Return, Enter
        case 49: key = .space
        case 51, 117: key = .delete // ⌫, ⌦
        default: key = nil
        }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }
}

/// Tab Pengingat di Pengaturan: kelola semua pengingat (juga yang terkait todo) — sama dengan web → Pengingat.
///   [        Aktif 3        |        Selesai        ]
///   [🔍 Cari judul atau pesan               ] [+]
///   ○ Minum obat                       Besok 08:00
///     Tiap hari 08:00 · Todo: Beli obat
/// ↩ / klik dua kali = ubah, spasi = selesai / aktifkan lagi, ⌫ = hapus, ⌘C = salin, ⌘N = baru.
final class ReminderPage: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    static let filterTitles = ["Aktif", "Selesai"]

    unowned let app: AppDelegate
    private var store: Store { app.store }
    private let filterControl = NSSegmentedControl(labels: ReminderPage.filterTitles, trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = TodoTable()
    private lazy var tableScroll = NSScrollView()
    private let empty = UI.label("", size: 13, color: .secondaryLabelColor)
    private let footer = UI.label("", size: 11, color: .secondaryLabelColor)
    private var rows: [Reminder] = []
    private var sheetWindow: NSWindow?

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private var showDone: Bool { filterControl.selectedSegment == 1 }

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        view = v
        preferredContentSize = SettingsWindow.size

        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.selectedSegment = 0
        filterControl.segmentDistribution = .fillEqually
        filterControl.setAccessibilityLabel("Filter pengingat")

        search.placeholderString = "Cari judul atau pesan"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        let add = NSButton(image: UI.symbol("plus", 13, weight: .semibold) ?? NSImage(), target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.toolTip = "Pengingat baru (⌘N)"
        KeyBindings.bind(add, .newItem, tip: "Pengingat baru") // bawaan ⌘N (Pengaturan → Pintasan)
        add.setAccessibilityLabel("Pengingat baru")
        let tools = UI.stack([search, add], vertical: false, spacing: 8)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reminder"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Daftar pengingat")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.autohidesScrollers = true
        empty.alignment = .center
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 3

        for x in [filterControl, tools, tableScroll, empty, footer] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            filterControl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            filterControl.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            tools.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 12),
            tools.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            tools.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            tableScroll.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m - 10),
            tableScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -(m - 10)),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: tableScroll.widthAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -14),
        ])
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// Data dari store (sudah tersinkron); dipanggil saat tab dibuka & setiap store berubah.
    func reload() {
        guard isViewLoaded else { return }
        let active = store.reminders.filter(\.active)
        filterControl.setLabel("Aktif" + (active.isEmpty ? "" : "  \(active.count)"), forSegment: 0)
        let base = showDone
            ? store.reminders.filter { !$0.active }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            : active.sorted { ($0.nextFireAt.isEmpty ? "~" : $0.nextFireAt) < ($1.nextFireAt.isEmpty ? "~" : $1.nextFireAt) }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        rows = base.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.message.lowercased().contains(q) }
        table.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        if !store.connected {
            empty.stringValue = "Hubungkan Mac ini ke server dulu (tab Akun)."
        } else if rows.isEmpty {
            empty.stringValue = !q.isEmpty ? "Tidak ada pengingat yang cocok."
                : showDone ? "Belum ada pengingat yang selesai."
                : "Belum ada pengingat aktif. Klik + atau minta asisten: “tiap hari jam 8 ingetin minum vitamin”."
        }
        empty.isHidden = store.connected && !rows.isEmpty
        footer.stringValue = rows.isEmpty ? "" : showDone
            ? "\(rows.count) pengingat · klik ✓ untuk mengaktifkan lagi"
            : "\(rows.count) pengingat · klik dua kali untuk mengubah"
        filterControl.isEnabled = store.connected
    }

    // MARK: Tabel

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ReminderCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ReminderCell ?? {
            let c = ReminderCell()
            c.identifier = id
            c.check.target = self
            c.check.action = #selector(checkClicked(_:))
            return c
        }()
        let r = rows[row]
        let todo = r.todoId.flatMap { id in store.todos.first { $0.id == id } }
        cell.configure(r, todoTitle: todo?.title ?? (r.todoId == nil ? nil : "#\(r.todoId!)"), tz: store.tz)
        return cell
    }

    private func reminder(at row: Int) -> Reminder? { row >= 0 && row < rows.count ? rows[row] : nil }

    private func handleKey(_ key: TodoTable.Key) -> Bool {
        if key == .copy {
            let picked = table.selectedRowIndexes.compactMap { reminder(at: $0) }
            TodoCopy.copy(text: picked.map { $0.message.isEmpty ? $0.title : $0.title + "\n\n" + $0.message }.joined(separator: "\n\n"))
            return !picked.isEmpty
        }
        guard let r = reminder(at: table.selectedRow) else { return false }
        switch key {
        case .copy: break
        case .enter: edit(r)
        case .space: app.toggleReminder(r)
        case .delete: app.deleteReminder(r)
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let r = reminder(at: table.clickedRow) else { return }
        func item(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = NSNumber(value: r.id)
            menu.addItem(i)
        }
        item("Ubah…", #selector(editMenu(_:)))
        item("Salin", #selector(copyMenu(_:)))
        item(r.active ? "Tandai selesai" : "Aktifkan lagi", #selector(toggleMenu(_:)))
        menu.addItem(.separator())
        item("Hapus…", #selector(deleteMenu(_:)))
    }

    private func find(_ sender: NSMenuItem) -> Reminder? {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return nil }
        return rows.first { $0.id == id }
    }

    @objc private func editMenu(_ s: NSMenuItem) { find(s).map { edit($0) } }
    @objc private func copyMenu(_ s: NSMenuItem) { find(s).map { TodoCopy.copy($0) } }
    @objc private func toggleMenu(_ s: NSMenuItem) { find(s).map { app.toggleReminder($0) } }
    @objc private func deleteMenu(_ s: NSMenuItem) { find(s).map { app.deleteReminder($0) } }
    @objc private func editClicked() { reminder(at: table.clickedRow).map { edit($0) } }
    @objc private func checkClicked(_ sender: NSButton) {
        guard let r = reminder(at: table.row(for: sender)) else { return }
        sender.image = UI.symbol(r.active ? "checkmark.circle.fill" : "circle", 17)
        app.toggleReminder(r)
    }
    @objc private func filterChanged() { reload() }
    @objc private func searchChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func addTapped() { edit(nil) }

    /// Lembar pengingat baru (nil) / ubah, di atas jendela Pengaturan.
    func edit(_ r: Reminder?) {
        guard store.connected, let window = view.window, sheetWindow == nil else { return }
        let e = ReminderEditor(reminder: r, todos: store.todos, tz: store.tz)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentView = e
        e.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let fit = { [weak e, weak sheet] in
            guard let e, let sheet else { return }
            e.layoutSubtreeIfNeeded()
            sheet.setContentSize(NSSize(width: 460, height: max(200, e.fittingSize.height)))
        }
        e.onLayoutChange = fit
        let close = { [weak self, weak sheet] in
            guard let sheet else { return }
            window.endSheet(sheet)
            self?.sheetWindow = nil
        }
        e.onCancel = close
        e.onSave = { [weak self, weak e] body in
            guard let self, let e else { return }
            e.busy = true
            let finish: (Result<APIClient.ReminderResult, APIError>) -> Void = { res in
                DispatchQueue.main.async {
                    e.busy = false
                    switch res {
                    case .success: close()
                    case .failure(let err): e.showError("Gagal menyimpan: \(err.description)")
                    }
                    self.store.refresh()
                }
            }
            if let r { self.store.api.updateReminder(r.id, body, finish) } else { self.store.api.createReminder(body, finish) }
        }
        e.onDelete = { [weak self] in
            close()
            guard let r else { return }
            DispatchQueue.main.async { self?.app.deleteReminder(r) }
        }
        sheetWindow = sheet
        fit()
        window.beginSheet(sheet)
        sheet.makeFirstResponder(e.titleField)
    }
}

/// Satu baris di tab Pengingat: lingkaran selesai, judul, jadwal (+ todo terkait), dan waktu berikutnya.
final class ReminderCell: NSTableCellView {
    let check = NSButton(image: NSImage(), target: nil, action: nil)
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = UI.label("", size: 11, color: .secondaryLabelColor)
    private let next = UI.label("", size: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.isBordered = false
        title.font = .systemFont(ofSize: 13)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        next.alignment = .right
        next.setContentHuggingPriority(.required, for: .horizontal)
        next.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = UI.stack([title, meta], spacing: 2)
        let row = UI.stack([check, texts, next], vertical: false, spacing: 8)
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        UI.pin(row, to: self, top: 6, left: 4, bottom: 6, right: 8)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    func configure(_ r: Reminder, todoTitle: String?, tz: TimeZone) {
        let done = !r.active
        check.image = UI.symbol(done ? "checkmark.circle.fill" : "circle", 17)
        check.contentTintColor = done ? Theme.accent : .tertiaryLabelColor
        check.isEnabled = true
        check.toolTip = done ? "Aktifkan lagi" : "Tandai selesai (berhenti berbunyi)"
        check.setAccessibilityLabel((done ? "Aktifkan lagi “" : "Tandai selesai “") + r.title + "”")
        title.attributedStringValue = NSAttributedString(string: r.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: done ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        var m: [String] = []
        if !r.scheduleText.isEmpty { m.append(r.scheduleText) }
        if let todoTitle { m.append("Todo: " + todoTitle) }
        if !r.message.isEmpty { m.append(r.message.replacingOccurrences(of: "\n", with: " ")) }
        meta.stringValue = m.joined(separator: " · ")
        meta.isHidden = m.isEmpty
        if done {
            next.stringValue = r.ended ? "Sudah berbunyi" : "Dijeda"
            next.textColor = .secondaryLabelColor
        } else if let d = Clock.parseStamp(r.nextFireAt) {
            let name = Clock.friendly(Clock.ymd(d, tz), now: Date(), tz)
            next.stringValue = name.prefix(1).uppercased() + name.dropFirst() + " " + Clock.hm(d, tz)
            next.textColor = Theme.accent
        } else {
            next.stringValue = ""
        }
    }
}

/// Lembar pengingat baru / ubah. Jenis jadwal yang umum diatur di sini (Sekali, Tiap hari, Tiap minggu, Tiap bulan);
/// jenis lain (interval, tahunan) tetap bisa diubah judul/todo-nya, jadwalnya lewat web.
///   Pengingat baru
///   [Judul______________________________]
///   [Pesan (opsional)___________________]
///   Todo terkait   [Tanpa todo        ▾]
///   Jadwal         [Sekali            ▾]
///   Tanggal [5/11/2026]   Jam [08.00 ⇅]          ← Sekali
///   Jam [08.00 ⇅]  [Sen|Sel|Rab|Kam|Jum|Sab|Min]  ← Tiap minggu (pilih beberapa hari)
///   [Hapus…]                   [Batal] [Simpan]
/// `compact: true` = isian lengkap di kartu tambah popover (tab Pengingat): kartu beraksen, kontrol kecil,
/// pesan bisa beberapa baris (↩ = baris baru), tombol Tambah; isian awal dari kartu cepat (`Draft`).
final class ReminderEditor: NSView, NSTextFieldDelegate {
    /// Isian awal pengingat baru (dari kartu cepat popover).
    struct Draft {
        var title: String
        var start: Date
        var kind: String
        /// Todo terkait dari kartu cepat (0 = tanpa todo).
        var todoId: Int64 = 0
    }
    let reminder: Reminder?
    let tz: TimeZone
    let compact: Bool
    private let draft: Draft?
    let titleField = NSTextField()
    private let messageField = NSTextField()
    private let todoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePicker = NSDatePicker()
    private let timePicker = NSDatePicker()
    private let weekdays = NSSegmentedControl(labels: ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"],
                                              trackingMode: .selectAny, target: nil, action: nil)
    private let monthDay = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = UI.label("", size: 11, color: .secondaryLabelColor)
    private let error = UI.label("", size: 11, color: Theme.danger)
    private let saveButton = NSButton(title: "Simpan", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Batal", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Hapus…", target: nil, action: nil)
    private var dateRow = NSView()
    private var timeRow = NSView()
    private var dayRow = NSView()
    /// Jenis yang bisa diatur di Mac (urutan = isi kindPopup).
    private static let kinds = ["once", "daily", "weekly", "monthly"]
    private var supported: Bool { reminder?.schedule.map { ReminderEditor.kinds.contains($0.kind) } ?? true }

    var onSave: (([String: Any]) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var busy = false { didSet { [saveButton, cancelButton, deleteButton].forEach { $0.isEnabled = !busy } } }

    init(reminder: Reminder?, todos: [Todo], tz: TimeZone, compact: Bool = false, draft: Draft? = nil) {
        self.reminder = reminder
        self.tz = tz
        self.compact = compact
        self.draft = reminder == nil ? draft : nil
        super.init(frame: .zero)
        build(todos)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private func caption(_ s: String) -> NSTextField {
        let l = UI.label(s, size: compact ? 11 : 12, color: .secondaryLabelColor)
        l.widthAnchor.constraint(equalToConstant: compact ? 64 : 92).isActive = true
        return l
    }

    private func build(_ todos: [Todo]) {
        let r = reminder
        let sch = r?.schedule
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        titleField.stringValue = r?.title ?? draft?.title ?? ""
        titleField.placeholderString = "Judul, mis. Minum obat"
        titleField.bezelStyle = .roundedBezel
        titleField.delegate = self
        titleField.setAccessibilityLabel("Judul pengingat")
        messageField.stringValue = r?.message ?? ""
        messageField.placeholderString = "Pesan (opsional)"
        messageField.bezelStyle = .roundedBezel
        messageField.delegate = self
        messageField.setAccessibilityLabel("Pesan")
        if compact {
            // Pesan = detail pengingat (isi notifikasi); beberapa baris, ↩ = baris baru
            messageField.placeholderString = "Pesan / detail (opsional)"
            messageField.usesSingleLineMode = false
            messageField.cell?.wraps = true
            messageField.cell?.isScrollable = false
            messageField.lineBreakMode = .byWordWrapping
            messageField.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }

        // Todo terkait: pengingatnya tampil sebagai 🔔 di baris todo itu
        todoPopup.addItem(withTitle: "Tanpa todo")
        todoPopup.lastItem?.tag = 0
        var open = todos.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        if let id = r?.todoId, !open.contains(where: { $0.id == id }) {
            open.insert(Todo(id: id, title: "Todo #\(id) (selesai)", notes: "", status: "done", priority: "normal",
                             list: "", dueDate: "", dueTime: ""), at: 0)
        }
        for t in open {
            todoPopup.addItem(withTitle: t.title)
            todoPopup.lastItem?.tag = Int(t.id)
        }
        todoPopup.selectItem(withTag: Int(r?.todoId ?? draft?.todoId ?? 0))
        todoPopup.target = self
        todoPopup.action = #selector(todoPicked)
        todoPopup.setAccessibilityLabel("Todo terkait")

        kindPopup.addItems(withTitles: ["Sekali", "Tiap hari", "Tiap minggu", "Tiap bulan"])
        if supported {
            kindPopup.selectItem(at: ReminderEditor.kinds.firstIndex(of: sch?.kind ?? draft?.kind ?? "once") ?? 0)
        } else {
            kindPopup.addItem(withTitle: r?.scheduleText.isEmpty == false ? r!.scheduleText : "Jadwal lain")
            kindPopup.selectItem(at: kindPopup.numberOfItems - 1)
            kindPopup.isEnabled = false
            note.stringValue = "Jenis jadwal ini diubah lewat web (Pengingat). Judul, pesan, dan todo bisa diubah di sini."
        }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel("Jenis jadwal")

        for p in [datePicker, timePicker] {
            p.calendar = cal
            p.timeZone = tz
            p.locale = Locale(identifier: "id_ID")
            p.isBezeled = true
            p.drawsBackground = true
        }
        datePicker.datePickerStyle = .textField
        datePicker.datePickerElements = .yearMonthDay
        datePicker.presentsCalendarOverlay = true
        datePicker.setAccessibilityLabel("Tanggal")
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.setAccessibilityLabel("Jam")
        // Bawaan pengingat baru: satu jam lagi (dibulatkan ke jam penuh)
        var start = Date().addingTimeInterval(3600)
        start = cal.date(bySetting: .minute, value: 0, of: start) ?? start
        if let at = sch?.at, at.count >= 16 {
            start = Clock.due(String(at.prefix(10)), String(at.suffix(5)), tz) ?? start
        } else if let d = draft?.start {
            start = d
        } else if let t = sch?.time {
            start = Clock.due(Clock.ymd(Date(), tz), t, tz) ?? start
        }
        datePicker.dateValue = start
        timePicker.dateValue = start

        weekdays.setAccessibilityLabel("Hari")
        for (i, _) in (0..<7).enumerated() { weekdays.setWidth(compact ? 34 : 40, forSegment: i) }
        let days = sch?.weekdays ?? [cal.component(.weekday, from: Date()) == 1 ? 7 : cal.component(.weekday, from: Date()) - 1]
        for d in days where d >= 1 && d <= 7 { weekdays.setSelected(true, forSegment: d - 1) }
        for d in 1...31 { monthDay.addItem(withTitle: "\(d)") }
        monthDay.selectItem(at: (sch?.monthDay ?? cal.component(.day, from: Date())) - 1)
        monthDay.setAccessibilityLabel("Tanggal tiap bulan")

        dateRow = UI.stack([caption("Tanggal"), datePicker], vertical: false, spacing: 8)
        timeRow = UI.stack([caption("Jam"), timePicker, NSView(), UI.label("Tanggal", size: 12, color: .secondaryLabelColor), monthDay],
                           vertical: false, spacing: 8)
        dayRow = UI.stack([caption("Hari"), weekdays], vertical: false, spacing: 8)

        for b in [cancelButton, saveButton, deleteButton] {
            b.bezelStyle = .rounded
            b.target = self
        }
        cancelButton.action = #selector(cancel)
        saveButton.action = #selector(save)
        if !compact {
            cancelButton.keyEquivalent = "\u{1b}"
            saveButton.keyEquivalent = "\r"
        }
        saveButton.bezelColor = Theme.accent
        deleteButton.action = #selector(deleteTapped)
        deleteButton.hasDestructiveAction = true
        error.isHidden = true
        error.lineBreakMode = .byTruncatingTail
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.isHidden = note.stringValue.isEmpty

        var buttonViews: [NSView] = [error, NSView(), cancelButton, saveButton]
        if r != nil { buttonViews.insert(deleteButton, at: 0) }
        if compact {
            saveButton.title = r == nil ? "Tambah" : "Simpan"
            // Kontrol kecil seperti kartu ubah todo di popover
            for c in [titleField, messageField, todoPopup, kindPopup, datePicker, timePicker, weekdays, monthDay,
                      cancelButton, saveButton] as [NSControl] {
                c.controlSize = .small
                c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
            for p in [todoPopup, kindPopup] { p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        }
        let head = compact
            ? UI.label(r == nil ? "Pengingat baru" : "Ubah pengingat", size: 12, weight: .semibold, color: .secondaryLabelColor)
            : UI.label(r == nil ? "Pengingat baru" : "Ubah pengingat", size: 15, weight: .semibold)
        let rows: [NSView] = [
            head,
            titleField, messageField,
            UI.stack([caption("Todo terkait"), todoPopup], vertical: false, spacing: 8),
            UI.stack([caption("Jadwal"), kindPopup], vertical: false, spacing: 8),
            dateRow, timeRow, dayRow, note,
            UI.stack(buttonViews, vertical: false, spacing: 8),
        ]
        let form = UI.stack(rows, spacing: compact ? 8 : 12)
        for v in rows { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        form.translatesAutoresizingMaskIntoConstraints = false
        if compact {
            let card = RoundedBox(fill: .controlBackgroundColor, stroke: Theme.accent, radius: 12)
            card.addSubview(form)
            UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)
            card.translatesAutoresizingMaskIntoConstraints = false
            addSubview(card)
            UI.pin(card, to: self, top: 4, bottom: 4)
        } else {
            addSubview(form)
            UI.pin(form, to: self, top: 20, left: 20, bottom: 20, right: 20)
        }
        updateKind()
    }

    private var kind: String? { supported ? ReminderEditor.kinds[max(0, kindPopup.indexOfSelectedItem)] : nil }

    /// Tampilkan hanya isian milik jenis jadwal yang dipilih.
    private func updateKind() {
        let k = kind
        dateRow.isHidden = k != "once"
        timeRow.isHidden = k == nil
        dayRow.isHidden = k != "weekly"
        let monthly = k == "monthly"
        if let row = timeRow as? NSStackView {
            row.arrangedSubviews.suffix(2).forEach { $0.isHidden = !monthly }
        }
    }

    @objc private func kindChanged() {
        updateKind()
        onLayoutChange?()
    }

    @objc private func todoPicked() {
        // Judul kosong → pakai judul todo (sama dengan web)
        if titleField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, todoPopup.selectedTag() != 0 {
            titleField.stringValue = todoPopup.titleOfSelectedItem ?? ""
        }
    }

    /// Jadwal dari isian; until/count/startDate/every lama dipertahankan bila jenisnya sama.
    private func buildSchedule() -> ReminderSchedule? {
        guard let k = kind else { return nil }
        let old = reminder?.schedule?.kind == k ? reminder?.schedule : nil
        let time = Clock.hm(timePicker.dateValue, tz)
        var s = ReminderSchedule(kind: k)
        switch k {
        case "once":
            s.at = Clock.ymd(datePicker.dateValue, tz) + "T" + time
        case "daily":
            s.time = time
            s.every = old?.every ?? 1
        case "weekly":
            s.time = time
            s.every = old?.every ?? 1
            s.weekdays = (0..<7).filter { weekdays.isSelected(forSegment: $0) }.map { $0 + 1 }
        default:
            s.time = time
            s.monthDay = monthDay.indexOfSelectedItem + 1
        }
        if k != "once" {
            s.startDate = old?.startDate
            s.until = old?.until
            s.count = old?.count
        }
        return s
    }

    func showError(_ text: String) {
        error.stringValue = text
        error.toolTip = text
        error.isHidden = false
    }

    @objc private func save() {
        guard !busy else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let todoID = todoPopup.selectedTag()
        guard !title.isEmpty || todoID != 0 else { return showError("Judul tidak boleh kosong.") }
        var body: [String: Any] = [
            "title": title,
            "message": messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "todoId": todoID,
        ]
        if let s = buildSchedule() {
            if s.kind == "weekly" && (s.weekdays ?? []).isEmpty { return showError("Pilih minimal satu hari.") }
            // Jadwal hanya dikirim bila berubah; jadwal baru = pengingat aktif lagi (mis. yang sudah berbunyi).
            if reminder == nil || s != reminder?.schedule {
                body["schedule"] = s.body
                if reminder != nil { body["active"] = true }
            }
        }
        error.isHidden = true
        onSave?(body)
    }

    @objc private func cancel() { onCancel?() }
    @objc private func deleteTapped() { onDelete?() }
    /// Esc saat fokus di popup / picker (popover tidak punya tombol Batal dengan ⎋).
    override func cancelOperation(_ sender: Any?) { cancel() }

    /// ↩ di kolom teks = simpan, esc = batal (ringkas: ↩ di pesan = baris baru).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        if compact, control === messageField, selector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        return false
    }
}

/// Tab Ingatan: lihat, tambah, ubah, hapus, dan ekspor ingatan AI — sama dengan web → Ingatan.
/// Isinya hanya milik pengguna yang terhubung; server memindai rahasia/injeksi sebelum menyimpan.
final class MemoryPage: NSViewController {
    static let sections: [(key: String, title: String, desc: String)] = [
        ("profile", "Profil saya", "Siapa kamu: kebiasaan, preferensi, gaya komunikasi. Contoh: “Biasanya belanja Sabtu pagi”."),
        ("notes", "Catatan asisten", "Konteks & kesepakatan yang perlu diingat. Contoh: “List Kantor = pekerjaan kantor”."),
    ]

    unowned let app: AppDelegate
    private let stack = UI.stack([], spacing: 18)
    private lazy var scroll = UI.scroll(stack)
    private var data: MemoryList?
    private var loadError: String?
    private var loading = false
    private var busy = false
    /// Kolom "Tambah satu fakta…" per bagian; teksnya dipertahankan saat daftar digambar ulang.
    private var drafts: [String: NSTextField] = [:]

    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        view = v
        preferredContentSize = SettingsWindow.size
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        UI.pin(scroll, to: v)
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        load()
    }

    /// Muat ulang dari server (dipanggil saat tab dibuka, setelah aksi, dan saat ada perubahan dari perangkat lain).
    func load() {
        guard isViewLoaded else { return }
        guard app.store.connected else {
            data = nil
            loadError = nil
            return render()
        }
        guard !loading else { return }
        loading = true
        app.store.api.memories { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch r {
                case .success(let d):
                    self.data = d
                    self.loadError = nil
                case .failure(let e):
                    self.loadError = e.description
                }
                self.render()
            }
        }
    }

    // MARK: Tampilan

    private var width: CGFloat { SettingsWindow.size.width - 48 }

    private func render() {
        guard isViewLoaded else { return }
        let keep = drafts.mapValues { $0.stringValue }
        drafts = [:]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let intro = Form.note("Hal yang diingat asisten tentangmu di setiap percakapan. Asisten bisa menambahkannya sendiri saat kamu " +
                              "bercerita; di sini kamu bisa memeriksa, mengubah, atau menghapusnya. Hanya kamu yang bisa melihatnya. " +
                              "Password, PIN, nomor kartu, dan token otomatis ditolak.", width: width)
        add(intro)

        guard app.store.connected else {
            add(Form.section("Ingatan AI", [
                Form.row("Belum terhubung", "Hubungkan Mac ini ke server dulu untuk melihat ingatan asisten.",
                         Form.button("Hubungkan…", app, #selector(AppDelegate.connect))),
            ]))
            return
        }

        let reload = Form.button("Muat ulang", self, #selector(reloadTapped))
        let export = Form.button("Ekspor .md…", self, #selector(exportTapped))
        let web = Form.button("Buka di web", self, #selector(openWebTapped))
        let tools = UI.stack([reload, export, web], vertical: false, spacing: 8)
        export.isEnabled = data != nil
        add(tools)

        if let loadError {
            add(Form.section("Ingatan AI", [Form.row("Gagal memuat", loadError, nil)]))
        }
        guard let data else {
            if loadError == nil { add(Form.label("Memuat…")) }
            return
        }
        for (i, s) in MemoryPage.sections.enumerated() {
            add(section(i, s.key, s.title, s.desc, data, draft: keep[s.key] ?? ""))
        }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }

    private func section(_ index: Int, _ key: String, _ title: String, _ desc: String, _ d: MemoryList, draft: String) -> NSView {
        let used = d.usage[key] ?? 0
        let limit = max(1, d.limits[key] ?? 1)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(limit)
        bar.doubleValue = Double(min(used, limit))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let count = Form.note("\(used)/\(limit) karakter" + (used * 100 / limit >= 80 ? " — hampir penuh" : ""), width: 200)
        var rows: [NSView] = [Form.row(UI.stack([bar, count], spacing: 3), desc, nil)]

        let items = d.items(key)
        if items.isEmpty { rows.append(Form.note("Belum ada.", width: width - 28)) }
        for m in items {
            let edit = iconButton("pencil", "Ubah", #selector(editTapped(_:)), m.id)
            let del = iconButton("trash", "Hapus", #selector(deleteTapped(_:)), m.id)
            let detail = "\(m.source == "chat" ? "dari chat" : "manual") · \(MemoryPage.ago(m.updatedAt))"
            rows.append(Form.row(UI.text(m.content, width: width - 120), detail, UI.stack([edit, del], vertical: false, spacing: 4)))
        }

        let field = NSTextField(string: draft)
        field.placeholderString = "Tambah satu fakta…"
        field.tag = index
        field.target = self
        field.action = #selector(addTapped(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width - 120).isActive = true
        drafts[key] = field
        let addButton = Form.button("Tambah", self, #selector(addTapped(_:)))
        addButton.tag = index
        rows.append(UI.stack([field, addButton], vertical: false, spacing: 8))
        field.isEnabled = !busy
        addButton.isEnabled = !busy
        return Form.section(title, rows)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, _ id: Int64) -> NSButton {
        let b = NSButton(image: UI.symbol(symbol, 13) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.tag = Int(id)
        b.isEnabled = !busy
        return b
    }

    /// "baru saja", "5 mnt lalu", "3 jam lalu", "2 hari lalu".
    static func ago(_ stamp: String, now: Date = Date()) -> String {
        guard let d = Clock.parseStamp(stamp) else { return "" }
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return "baru saja"
        case ..<3600: return "\(Int(s / 60)) mnt lalu"
        case ..<86400: return "\(Int(s / 3600)) jam lalu"
        default: return "\(Int(s / 86400)) hari lalu"
        }
    }

    // MARK: Aksi

    private func memory(_ id: Int) -> Memory? { data?.memories.first { $0.id == Int64(id) } }

    /// Jalankan satu aksi ke server, lalu muat ulang daftar. Galat tampil sebagai peringatan.
    private func run<T>(_ title: String, _ call: (@escaping (Result<T, APIError>) -> Void) -> Void, done: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        render()
        call { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if case .failure(let e) = r { showError(title, e.description) } else { done?() }
                self.load()
            }
        }
    }

    @objc private func addTapped(_ sender: NSControl) {
        guard sender.tag >= 0, sender.tag < MemoryPage.sections.count else { return }
        let key = MemoryPage.sections[sender.tag].key
        guard let field = drafts[key] else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run("Gagal menambah ingatan", { self.app.store.api.addMemory(target: key, content: text, $0) }) { [weak self] in
            self?.drafts[key]?.stringValue = ""
        }
    }

    @objc private func editTapped(_ sender: NSButton) {
        guard let m = memory(sender.tag) else { return }
        let f = field(m.content)
        let a = NSAlert()
        a.messageText = "Ubah ingatan"
        a.informativeText = "Satu fakta singkat, maksimal \(data?.maxEntry ?? 0) karakter."
        a.accessoryView = formView([("Isi", f)], width: 360)
        a.addButton(withTitle: "Simpan")
        a.addButton(withTitle: "Batal")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != m.content else { return }
        run("Gagal mengubah ingatan", { self.app.store.api.updateMemory(m.id, content: text, $0) })
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let m = memory(sender.tag) else { return }
        let a = NSAlert()
        a.messageText = "Lupakan ingatan ini?"
        a.informativeText = "“\(m.content)”"
        a.addButton(withTitle: "Lupakan")
        a.addButton(withTitle: "Batal")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run("Gagal menghapus ingatan", { self.app.store.api.deleteMemory(m.id, $0) })
    }

    @objc private func reloadTapped() { load() }
    @objc private func openWebTapped() { app.openWebPage("/ingatan") }

    @objc private func exportTapped() {
        app.store.api.exportMemory { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .failure(let e): showError("Gagal mengekspor ingatan", e.description)
                case .success(let md):
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "ingatan-ai-\(Clock.ymd(Date(), self.app.store.tz)).md"
                    panel.allowedContentTypes = [.plainText]
                    panel.allowsOtherFileTypes = true
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try md.write(to: url, atomically: true, encoding: .utf8) }
                    catch { showError("Gagal menyimpan berkas", error.localizedDescription) }
                }
            }
        }
    }
}

final class SettingsWindow: NSObject {
    enum Tab: Int { case general, shortcuts, todos, reminders, account, memory, about }
    static let size = NSSize(width: 600, height: 470)

    unowned let app: AppDelegate
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let general = FormPage()
    private let keysPage = FormPage()
    private let account = FormPage()
    private lazy var todos = TodoPage(app: app)
    private lazy var reminders = ReminderPage(app: app)
    private lazy var memory = MemoryPage(app: app)
    private let about = FormPage()
    private var signature = ""
    private var pending = false

    // kontrol tab Umum (dibuat sekali, statusnya diperbarui di tempat supaya animasi NSSwitch tidak terputus)
    private lazy var badgeSwitch = Form.toggle(self, #selector(badgeChanged(_:)))
    /// Tab Pintasan: satu perekam per aksi + baris keterangan / galat di bawahnya.
    private lazy var shortcutFields: [ShortcutField] = ShortcutAction.allCases.map { a in
        let f = ShortcutField(a)
        f.onRecording = { [weak self] on in self?.app.shortcutsPaused = on }
        f.onPick = { [weak self] action, combo in self?.pickShortcut(action, combo) }
        return f
    }
    private static let shortcutHint = "Klik pintasan lalu tekan kombinasi baru. ⌫ = kosongkan (nonaktif), Esc = batal."
    private lazy var shortcutNote = Form.note(SettingsWindow.shortcutHint, width: 380)
    private lazy var notifySwitch = Form.toggle(self, #selector(notifyChanged(_:)))
    private lazy var loginSwitch = Form.toggle(self, #selector(loginChanged(_:)))
    private lazy var suggestSwitch = Form.toggle(self, #selector(suggestChanged(_:)))
    /// Kelompokkan daftar todo di popover: Waktu | Kategori.
    private lazy var groupControl: NSSegmentedControl = {
        let c = NSSegmentedControl(labels: ["Waktu", "Kategori"], trackingMode: .selectOne, target: self, action: #selector(groupChanged(_:)))
        c.setAccessibilityLabel("Kelompokkan todo menurut")
        return c
    }()

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    func show(_ tab: Tab = .general) {
        if window == nil { build() }
        rebuild()
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Buka lembar pengingat baru (nil) / ubah pengingat di tab Pengingat.
    func editReminder(_ r: Reminder?) {
        show(.reminders)
        DispatchQueue.main.async { [weak self] in self?.reminders.edit(r) }
    }

    /// Status aplikasi berubah → perbarui isi jendela (digabung, dijalankan setelah aksi yang sedang berjalan selesai)
    func reload() {
        guard window != nil, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.rebuild()
        }
    }

    private func build() {
        tabs.tabStyle = .toolbar
        let pages: [(NSViewController, String, String)] = [(general, "Umum", "gearshape"), (keysPage, "Pintasan", "keyboard"),
                                                           (todos, "Todo", "checklist"),
                                                           (reminders, "Pengingat", "bell"),
                                                           (account, "Akun", "person.crop.circle"),
                                                           (memory, "Ingatan", "brain"), (about, "Tentang", "info.circle")]
        for (vc, title, icon) in pages {
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.title = "Pengaturan AI Todo"
        w.isReleasedWhenClosed = false
        w.setContentSize(SettingsWindow.size)
        w.center()
        window = w

        let systemNotif = Form.button("Buka Pengaturan Sistem…", self, #selector(openSystemNotifications))
        general.set([
            Form.section("Menu bar", [
                Form.row("Tampilkan jumlah todo", "Angka todo hari ini + terlambat di samping ikon ✓.", badgeSwitch),
                Form.row("Contoh pertanyaan", "Tombol cepat di atas kotak chat, mis. “Apa saja todo hari ini?”.", suggestSwitch),
                Form.row("Kelompokkan todo", "Daftar di tab Todo: per waktu (tanggal) atau per kategori. Juga lewat klik kanan filter.", groupControl),
            ]),
            Form.section("Notifikasi", [
                Form.row("Notifikasi di Mac ini", "Pengingat & tenggat dari server dijadwalkan di Mac, jadi tetap muncul walau sedang offline. " +
                         "Isi notifikasi bisa disembunyikan dari web → Pengaturan.", notifySwitch),
                Form.row("Izin notifikasi macOS", "Kalau notifikasi tidak muncul, izinkan AI Todo di Pengaturan Sistem → Notifikasi.", systemNotif),
            ]),
            Form.section("Sistem", [
                Form.row("Buka saat login", "AI Todo otomatis berjalan setiap Mac dinyalakan.", loginSwitch),
            ]),
        ])

        // Pintasan (dulu hanya sakelar "Pintasan ⌥⌘T" di Umum)
        func rows(_ global: Bool) -> [NSView] {
            shortcutFields.filter { $0.shortcut.isGlobal == global }.map { Form.row($0.shortcut.title, $0.shortcut.detail, $0) }
        }
        let reset = Form.button("Kembalikan bawaan", self, #selector(resetShortcuts))
        let foot = UI.stack([shortcutNote, NSView(), reset], vertical: false, spacing: 16)
        shortcutNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keysPage.set([
            Form.section("Dari aplikasi mana pun", rows(true)),
            Form.section("Di popover", rows(false)),
            foot,
        ])
    }

    /// Pintasan baru dari perekam (nil = dikosongkan): simpan bila valid, selain itu tampilkan alasannya.
    private func pickShortcut(_ a: ShortcutAction, _ c: KeyCombo?) { showShortcutResult(app.setShortcut(a, c)) }

    /// nil = berhasil (kembali ke petunjuk biasa); selain itu galat berwarna + bunyi.
    private func showShortcutResult(_ error: String?) {
        if let err = error {
            NSSound.beep()
            shortcutNote.stringValue = err
            shortcutNote.textColor = Theme.danger
        } else {
            shortcutNote.stringValue = SettingsWindow.shortcutHint
            shortcutNote.textColor = .secondaryLabelColor
        }
        shortcutFields.forEach { $0.refresh() }
    }

    @objc private func resetShortcuts() {
        shortcutFields.forEach { $0.stop() }
        app.resetShortcuts()
        showShortcutResult(nil)
    }

    private func rebuild() {
        guard window != nil else { return }
        badgeSwitch.state = LocalPrefs.showBadge ? .on : .off
        shortcutFields.forEach { $0.refresh() }
        notifySwitch.state = LocalPrefs.notifications ? .on : .off
        suggestSwitch.state = LocalPrefs.showSuggestions ? .on : .off
        groupControl.selectedSegment = LocalPrefs.todoGroup
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // Akun & Tentang dibangun ulang hanya kalau isinya berubah
        let s = app.store
        let who = s.me.map { $0.user.displayName.isEmpty ? $0.user.username : $0.user.displayName } ?? ""
        let sig = [s.connected ? "1" : "0", s.needsLogin ? "1" : "0", app.updater.hasUpdate ? "1" : "0",
                   LocalPrefs.serverURL, who, app.syncStatus].joined(separator: "|")
        if sig != signature {
            signature = sig
            account.set(accountSections(who: who))
            about.set(aboutSections())
        }
        // Ingatan bisa berubah dari chat / perangkat lain: muat ulang hanya kalau tab-nya sedang terlihat.
        if window?.isVisible == true, tabs.selectedTabViewItemIndex == Tab.memory.rawValue { memory.load() }
        // Todo: data dari store (sudah tersinkron), cukup gambar ulang kalau tab-nya terlihat.
        if window?.isVisible == true, tabs.selectedTabViewItemIndex == Tab.todos.rawValue { todos.reload() }
        if window?.isVisible == true, tabs.selectedTabViewItemIndex == Tab.reminders.rawValue { reminders.reload() }
    }

    private func accountSections(who: String) -> [NSView] {
        let s = app.store
        let line = Form.label(app.syncStatus)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [UI.stack([UI.dot(s.connected && s.lastError == nil), line], vertical: false, spacing: 8)]
        if s.connected {
            let host = ServerURL.normalize(LocalPrefs.serverURL)?.host ?? LocalPrefs.serverURL
            rows.append(Form.row("Server", host, Form.button("Ganti server…", app, #selector(AppDelegate.connect))))
            rows.append(Form.row("Akun", who.isEmpty ? "Memuat…" : "Masuk sebagai \(who).",
                                 Form.button("Buka di browser", app, #selector(AppDelegate.openWeb))))
            rows.append(Form.row("Perangkat", "Token Mac ini bisa dicabut dari web → Pengaturan → Perangkat.",
                                 Form.button("Kelola perangkat", self, #selector(openDevices))))
            let out = Form.button("Putuskan…", app, #selector(AppDelegate.disconnect))
            out.hasDestructiveAction = true
            rows.append(Form.row("Putuskan Mac ini", "Token dicabut di server dan dihapus dari Keychain. Notifikasi terjadwal ikut dihapus.", out))
        } else {
            rows.append(Form.row(s.needsLogin ? "Sesi berakhir" : "Belum terhubung",
                                 "Masuk dengan username & password. Password tidak disimpan; Mac ini mendapat token perangkat sendiri.",
                                 Form.button("Hubungkan…", app, #selector(AppDelegate.connect))))
            rows.append(Form.row("Pakai token perangkat", "Buat token di web: Pengaturan → Perangkat & aplikasi Mac.",
                                 Form.button("Pakai token…", app, #selector(AppDelegate.connectToken))))
        }
        return [Form.section("Koneksi", rows)]
    }

    private func aboutSections() -> [NSView] {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let head = UI.stack([icon, UI.stack([Form.label("AI Todo", size: 15, weight: .semibold),
                                             Form.note("Versi \(Updater.current). Todo list dengan asisten AI di server milik sendiri.")],
                                            spacing: 2)],
                            vertical: false, spacing: 12)
        let up = app.updater
        let quit = Form.button("Keluar", app, #selector(AppDelegate.quit))
        return [
            head,
            Form.section("Pembaruan", [
                Form.row("Pembaruan aplikasi", up.hasUpdate ? "Versi \(up.latest?.version ?? "") tersedia." : "Dicek otomatis sehari sekali.",
                         Form.button(up.hasUpdate ? "Update…" : "Cek pembaruan…", up, #selector(Updater.checkNow))),
            ]),
            Form.section("Aplikasi", [
                Form.row("Keluar AI Todo", "Ikon menu bar hilang sampai AI Todo dibuka lagi. Notifikasi yang sudah dijadwalkan tetap muncul.", quit),
            ]),
        ]
    }

    @objc func badgeChanged(_ s: NSSwitch) { if (s.state == .on) != LocalPrefs.showBadge { app.toggleBadge() } }
    @objc func suggestChanged(_ s: NSSwitch) { if (s.state == .on) != LocalPrefs.showSuggestions { app.toggleSuggestions() } }
    @objc func groupChanged(_ c: NSSegmentedControl) { app.setTodoGroup(c.selectedSegment) }
    @objc func notifyChanged(_ s: NSSwitch) { if (s.state == .on) != LocalPrefs.notifications { app.toggleNotifications() } }
    @objc func loginChanged(_ s: NSSwitch) {
        app.toggleLogin()
        reload()
    }
    @objc func openDevices() { app.openWebPage("/pengaturan") }
    @objc func openSystemNotifications() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Pembaruan (rilis GitHub bertanda tangan Ed25519, pola PasteLAN)
// Rilis diambil LEWAT SERVER AI Todo (GET /api/app/mac/latest & /download/...), karena repo GitHub private:
// server memegang token GitHub read-only, aplikasi memakai token perangkat yang sudah ada. Server hanya perantara —
// keaslian file tetap dipastikan di sini lewat tanda tangan Ed25519.

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-ai-todo"
    let appName = "AITodo"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: Bool, sig: Bool, page: URL)
    var latest: Release?
    /// Klien server (token perangkat). Diisi AppDelegate sebelum start().
    weak var api: APIClient?
    /// Penyebab pengecekan terakhir gagal (nil kalau berhasil), untuk ditampilkan di alert.
    var lastError: String?

    /// Kunci publik Ed25519 (base64) dari `swift scripts/sign-release.swift keygen`.
    /// Kosong → update selalu lewat halaman rilis (unduh manual), tidak pernah dipasang otomatis.
    /// Sengaja sama dengan kunci PasteLAN (pemilik yang sama). Aman: yang ditandatangani diawali "AITodo <tag>\n",
    /// jadi tanda tangan rilis PasteLAN tidak bisa dipakai untuk AI Todo, begitu juga sebaliknya.
    static let publicKey = "PTtPJWvtz/ZOCSWubniY+8mQwWJCb5uc/KEb9U1mGTg="

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
        // Beri waktu aplikasi tersambung ke server dulu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check { _ in self?.refreshMenu() } }
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
        guard let api, api.isConfigured else {
            lastError = "Hubungkan AI Todo ke server dulu (Pengaturan → Akun). Pembaruan diunduh lewat server Anda."
            return done(false)
        }
        api.macRelease { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let m):
                    let page = m.page.flatMap { URL(string: $0) } ?? URL(string: "https://github.com/\(self.repo)/releases")!
                    self.latest = (m.version, m.zip, m.sig, page)
                    self.lastError = nil
                    done(true)
                case .failure(let e):
                    self.lastError = Updater.explain(e)
                    done(false)
                }
            }
        }
    }

    /// Pesan gagal yang menyebut penyebabnya (pesan dari server sudah berbahasa Indonesia).
    static func explain(_ e: APIError) -> String {
        switch e {
        case .server(404, "endpoint tidak ada"):
            return "Server AI Todo Anda belum mendukung pembaruan lewat server. Perbarui server dulu, lalu coba lagi."
        case .server(501, let m):
            return "Server belum diatur untuk pembaruan: \(m)"
        case .network:
            return "Tidak bisa terhubung ke server AI Todo. Periksa koneksi internet, lalu coba lagi."
        default:
            return e.description
        }
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
                a.informativeText = self.lastError ?? "Periksa koneksi internet, lalu coba lagi."
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
        guard let api, l.zip, l.sig, !Updater.publicKey.isEmpty, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            // Jelaskan kenapa tidak bisa dipasang otomatis, jangan diam-diam membuka GitHub.
            let why: String
            if Updater.publicKey.isEmpty { why = "Versi AI Todo ini belum punya kunci publik untuk memeriksa tanda tangan rilis, jadi update otomatis nonaktif. Pasang versi baru ini secara manual sekali; setelah itu update berikutnya bisa otomatis." }
            else if api == nil { why = "AI Todo belum terhubung ke server." }
            else if !l.zip { why = "Rilis \(l.version) tidak berisi \(appName).zip." }
            else if !l.sig { why = "Rilis \(l.version) belum ditandatangani (secret AITODO_SIGNING_KEY belum diatur di GitHub)." }
            else if dest.pathExtension != "app" { why = "AI Todo tidak berjalan dari file .app." }
            else { why = "Folder \(dest.deletingLastPathComponent().path) tidak bisa ditulis. Pindahkan AITodo.app ke Applications." }
            return fail(why, l.page)
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        // Keduanya lewat server (token perangkat); file zip dicek tanda tangannya sebelum dipasang.
        api.macDownload("\(appName).zip.sig") { sigResult in
            let signature = (try? sigResult.get()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            api.macDownload("\(self.appName).zip") { zipResult in
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
                let zipFile = work.appendingPathComponent("update.zip")
                let newApp = work.appendingPathComponent("\(self.appName).app")
                var problem: String?
                switch zipResult {
                case .success(let data):
                    do {
                        try fm.createDirectory(at: work, withIntermediateDirectories: true)
                        try data.write(to: zipFile)
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
                case .failure(let e):
                    problem = "Unduhan gagal: \(Updater.explain(e))"
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
            } // macDownload sudah menjalankan request (raw → dataTask.resume)
        }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let notifier = Notifier()
    let hotkey = HotKey()
    let updater = Updater()
    lazy var panel = PopoverController(app: self)
    lazy var settings = SettingsWindow(app: self)
    lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient // klik di luar = tutup
        p.animates = true
        p.contentViewController = self.panel
        p.contentSize = PopoverController.size
        return p
    }()
    var statusItem: NSStatusItem!
    /// Menu klik kanan (pintasan & Keluar). Klik kiri = popover.
    let contextMenu = NSMenu()
    var tick: Timer?
    /// Klik di indikator menu bar app lain tidak membuat app ini nonaktif, jadi popover `.transient`
    /// tidak ikut tertutup. Selama popover tampil, klik apa pun di luar app (monitor global) = tutup.
    var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: "AI Todo")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu.autoenablesItems = false
        NSApp.mainMenu = AppDelegate.editMenu()
        installEditShortcuts()

        notifier.store = store
        notifier.openApp = { [weak self] in self?.showPopover(.chat) }
        notifier.setup()

        store.onChange = { [weak self] in self?.stateChanged() }
        store.configureFromKeychain()

        // ⌥⌘T = asisten (tab Chat), ⇧⌥⌘T = popover di tab terakhir (sama dengan klik ikon); bisa diubah di Pengaturan → Pintasan
        HotKey.action = { [weak self] a in self?.togglePopover(a == .toggleChat ? .chat : nil) }
        applyShortcuts()

        // Bangun dari tidur / ganti hari: segarkan & jadwalkan ulang notifikasi.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.start()
        }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.store.refresh() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        tick = t

        updater.api = store.api // pembaruan diunduh lewat server (token perangkat)
        updater.start()
        if store.api.isConfigured {
            store.start()
        } else {
            stateChanged()
            // Pertama kali: tampilkan popover berisi ajakan "Hubungkan ke server…".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }

    // MARK: Keadaan → tampilan

    var syncStatus: String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm"
        if !store.api.isConfigured { return "Belum terhubung ke server" }
        if store.needsLogin { return "Sesi berakhir — hubungkan ulang" }
        if let e = store.lastError, store.lastSync == nil { return "Gagal: \(e)" }
        if let s = store.lastSync { return "Tersinkron \(f.string(from: s))" + (store.lastError != nil ? " (offline)" : "") }
        return "Menyinkronkan…"
    }

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
        panel.storeChanged()
        settings.reload()
    }

    // MARK: Popover & menu klik kanan

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showContextMenu() } else { togglePopover() }
    }

    func showPopover(_ mode: PopoverController.Mode? = nil) {
        guard let button = statusItem.button else { return }
        if let mode { panel.select(mode) }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { panel.willShow() }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
        panel.didShow()
        watchOutsideClicks()
    }

    /// Pasang monitor global (hanya menerima klik yang dikirim ke app lain, termasuk indikator menu bar
    /// lain); dilepas lagi begitu popover tertutup.
    func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(popoverDidClose(_:)),
                                               name: NSPopover.didCloseNotification, object: popover)
    }

    @objc func popoverDidClose(_ note: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: popover)
    }

    func togglePopover(_ mode: PopoverController.Mode? = nil) {
        if popover.isShown { popover.performClose(nil) } else { showPopover(mode) }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func showContextMenu() {
        closePopover()
        contextMenu.removeAllItems()
        let st = NSMenuItem(title: syncStatus, action: nil, keyEquivalent: "")
        st.isEnabled = false
        contextMenu.addItem(st)
        let sync = item("Sinkronkan sekarang", #selector(resyncNow), shortcut: .resync)
        sync.isEnabled = store.connected
        contextMenu.addItem(sync)
        contextMenu.addItem(.separator())
        let ask = item("Buka asisten", #selector(openChat), shortcut: .toggleChat)
        contextMenu.addItem(ask)
        contextMenu.addItem(item("Tambah todo manual", #selector(openManual)))
        contextMenu.addItem(item("Kelola semua todo…", #selector(openTodos)))
        contextMenu.addItem(item("Kelola pengingat…", #selector(openReminderSettings)))
        contextMenu.addItem(item("Catatan", #selector(openNotes)))
        let clear = item("Hapus riwayat chat…", #selector(clearChatHistory))
        clear.isEnabled = store.connected
        contextMenu.addItem(clear)
        contextMenu.addItem(item("Buka AI Todo di browser", #selector(openWeb)))
        contextMenu.addItem(.separator())
        contextMenu.addItem(item("Pengaturan…", #selector(openSettings), key: ","))
        contextMenu.addItem(item("Ingatan AI…", #selector(openMemory)))
        updater.refreshMenu()
        contextMenu.addItem(updater.menuItem)
        contextMenu.addItem(.separator())
        contextMenu.addItem(item("Keluar AI Todo", #selector(quit), key: "q"))
        // Pasang menu sementara supaya tampil di bawah ikon seperti menu biasa.
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Item menu dengan pintasan yang sedang berlaku (Pengaturan → Pintasan); kosong bila dimatikan.
    func item(_ title: String, _ action: Selector, shortcut: ShortcutAction) -> NSMenuItem {
        let i = item(title, action)
        if let c = LocalPrefs.keys[shortcut] {
            i.keyEquivalent = c.chars
            i.keyEquivalentModifierMask = c.modifierMask
        }
        return i
    }

    // MARK: Aksi

    @objc func openChat() { showPopover(.chat) }

    /// Sinkron ulang manual dari server (tombol ↻ di popover, ⌘R, atau menu klik kanan ikon menu bar).
    func resync(_ done: @escaping () -> Void = {}) {
        guard store.connected else { return done() }
        store.resync(done)
    }
    @objc func resyncNow() { resync() }
    @objc func openManual() { showPopover(.todo) }
    @objc func openNotes() { showPopover(.notes) }

    /// Menu klik kanan: buka popover tab Chat, lalu konfirmasi yang sama dengan tombol tempat sampah.
    @objc func clearChatHistory() {
        showPopover(.chat)
        DispatchQueue.main.async { [weak self] in self?.panel.confirmClearHistory() }
    }

    @objc func openSettings() {
        closePopover()
        settings.show()
    }

    @objc func openMemory() {
        closePopover()
        settings.show(.memory)
    }

    @objc func openTodos() {
        closePopover()
        settings.show(.todos)
    }

    // MARK: Pengingat (dipakai tab Pengingat popover & Pengaturan → Pengingat)

    @objc func openReminderSettings() {
        closePopover()
        settings.show(.reminders)
    }

    /// nil = pengingat baru.
    func editReminder(_ r: Reminder?) {
        closePopover()
        settings.editReminder(r)
    }

    /// Aktif → selesai (berhenti berbunyi), atau selesai → aktif lagi. Jadwal yang sudah lewat tidak bisa
    /// diaktifkan lagi (server menolak) → tawarkan ubah jadwal.
    func toggleReminder(_ r: Reminder) {
        store.api.updateReminder(r.id, ["active": !r.active]) { [weak self] res in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let e) = res {
                    if r.active {
                        showError("Gagal menandai selesai", e.description)
                    } else {
                        let a = NSAlert()
                        a.messageText = "“\(r.title)” tidak bisa diaktifkan lagi"
                        a.informativeText = e.description + ". Pilih waktu yang akan datang."
                        a.addButton(withTitle: "Ubah jadwal…")
                        a.addButton(withTitle: "Batal")
                        NSApp.activate(ignoringOtherApps: true)
                        if a.runModal() == .alertFirstButtonReturn { self.editReminder(r) }
                    }
                }
                self.store.refresh()
            }
        }
    }

    /// Hapus pengingat setelah konfirmasi.
    func deleteReminder(_ r: Reminder) {
        let a = NSAlert()
        a.messageText = "Hapus pengingat “\(r.title)”?"
        a.informativeText = "Tindakan ini tidak bisa dibatalkan."
        a.alertStyle = .warning
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.api.deleteReminder(r.id) { [weak self] res in
            DispatchQueue.main.async {
                if case .failure(let e) = res { showError("Gagal menghapus pengingat", e.description) }
                self?.store.refresh()
            }
        }
    }

    @objc func openWeb() { openWebPage("/todo") }

    func openWebPage(_ path: String) {
        guard let base = ServerURL.normalize(LocalPrefs.serverURL), let url = URL(string: base.absoluteString + path) else { return }
        closePopover()
        NSWorkspace.shared.open(url)
    }

    /// Tandai selesai: langsung hilang dari daftar; server yang memastikan.
    func complete(todo id: Int64) {
        store.todos.removeAll { $0.id == id }
        stateChanged()
        store.api.complete(todo: id) { [weak self] r in
            DispatchQueue.main.async {
                if case .failure(let e) = r { showError("Gagal menandai selesai", e.description) }
                self?.store.refresh()
            }
        }
    }

    /// Simpan perubahan dari kartu ubah di tab Manual (validasi akhir tetap di server / internal/core).
    func updateTodo(_ id: Int64, _ fields: [String: String], done: @escaping (String?) -> Void) {
        store.api.updateTodo(id, fields) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success: done(nil)
                case .failure(let e): done("Gagal menyimpan: \(e.description)")
                }
                self?.store.refresh()
            }
        }
    }

    /// Tambah todo dari tab Manual. dayOffset: -1 = tanpa tenggat, 0 = hari ini, 1 = besok, 2 = lusa.
    /// done(nil) = berhasil; selain itu pesan galat untuk ditampilkan di form.
    func createTodo(title: String, dayOffset: Int, time: String, done: @escaping (String?) -> Void) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return done("Isi judul todo dulu.") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = store.tz
        let date = dayOffset < 0 ? "" : Clock.ymd(cal.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date(), store.tz)
        let hm = time.trimmingCharacters(in: .whitespaces)
        if !hm.isEmpty && (date.isEmpty || hm.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil) {
            return done("Isi jam dengan format HH:MM (mis. 09:30) dan pilih tanggal tenggat.")
        }
        store.api.createTodo(title: t, dueDate: date, dueTime: hm) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success: done(nil)
                case .failure(let e): done("Gagal menambah todo: \(e.description)")
                }
                self?.store.refresh()
            }
        }
    }

    /// Tambah todo dari isian lengkap di popover (kolom sama dengan lembar Pengaturan → Todo baru).
    func createTodo(fields: [String: String], done: @escaping (String?) -> Void) {
        store.api.createTodo(fields) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success: done(nil)
                case .failure(let e): done("Gagal menambah todo: \(e.description)")
                }
                self?.store.refresh()
            }
        }
    }

    /// Tambah pengingat cepat dari tab Pengingat: date = YYYY-MM-DD (sekali) atau nil (tiap hari), time = HH:MM.
    /// Jadwal tetap dihitung server (internal/schedule).
    func createReminder(title: String, date: String?, time: String, todoId: Int64 = 0, done: @escaping (String?) -> Void) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return done("Isi judul pengingat dulu.") }
        var s = ReminderSchedule(kind: date == nil ? "daily" : "once")
        if let date {
            if let at = Clock.due(date, time, store.tz), at <= Date() {
                return done("Jam itu sudah lewat. Pilih jam lain atau Besok.")
            }
            s.at = date + "T" + time
        } else {
            s.time = time
            s.every = 1
        }
        createReminder(["title": t, "message": "", "todoId": todoId, "schedule": s.body], done: done)
    }

    /// Tambah pengingat (body sama dengan lembar Pengaturan → Pengingat baru).
    func createReminder(_ body: [String: Any], done: @escaping (String?) -> Void) {
        store.api.createReminder(body) { [weak self] r in
            DispatchQueue.main.async {
                switch r {
                case .success: done(nil)
                case .failure(let e): done("Gagal menambah pengingat: \(e.description)")
                }
                self?.store.refresh()
            }
        }
    }

    @objc func connect() {
        closePopover()
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

    @objc func connectToken() { connectWithToken(LocalPrefs.serverURL) }

    func connectWithToken(_ serverValue: String) {
        closePopover()
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
        closePopover()
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
        settings.reload()
    }

    /// Pengelompokan daftar tab Todo (0 = Waktu, 1 = Kategori): klik kanan filter di popover, atau Pengaturan → Umum.
    func setTodoGroup(_ g: Int) {
        guard g != LocalPrefs.todoGroup else { return }
        LocalPrefs.todoGroup = g
        stateChanged()
    }

    /// Contoh pertanyaan di atas input chat: klik kanan chip → sembunyikan, atau Pengaturan → Umum.
    @objc func toggleSuggestions() {
        LocalPrefs.showSuggestions.toggle()
        stateChanged()
    }

    /// Pintasan berubah (Pengaturan → Pintasan) → daftar ulang hotkey global & perbarui tombol / tooltip.
    /// Hasil = pintasan global yang gagal didaftarkan (kombinasinya dipakai aplikasi lain).
    @discardableResult
    func applyShortcuts() -> [ShortcutAction] {
        KeyBindings.refresh()
        return shortcutsPaused ? [] : hotkey.register(LocalPrefs.keys)
    }

    /// Selama merekam pintasan baru, hotkey global dilepas supaya kombinasi yang ditekan tidak menjalankan aksinya.
    var shortcutsPaused = false {
        didSet {
            guard shortcutsPaused != oldValue else { return }
            if shortcutsPaused { hotkey.unregister() } else { applyShortcuts() }
        }
    }

    /// Simpan pintasan baru (nil = matikan). Hasil = pesan galat bila ditolak (bentrok / dipakai macOS / aplikasi lain).
    func setShortcut(_ a: ShortcutAction, _ c: KeyCombo?) -> String? {
        let before = LocalPrefs.shortcuts
        if let c, let err = Shortcuts.validate(c, for: a, in: LocalPrefs.keys) { return err }
        var s = before
        s[a.rawValue] = c?.stored ?? ""
        LocalPrefs.shortcuts = s
        if applyShortcuts().contains(a) {
            LocalPrefs.shortcuts = before
            applyShortcuts()
            return "\(c?.display ?? "") sudah dipakai aplikasi lain."
        }
        return nil
    }

    /// Kembalikan semua pintasan ke bawaan.
    func resetShortcuts() {
        LocalPrefs.shortcuts = [:]
        LocalPrefs.hotkey = true
        applyShortcuts()
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

    private var editMonitor: Any?

    /// Pintasan standar macOS di popover & jendela aplikasi: ⌘C salin, ⌘V tempel, ⌘X potong, ⌘A pilih semua,
    /// ⌘Z urungkan, ⇧⌘Z ulangi, ⌘W tutup jendela (di popover: tutup popover).
    /// Aplikasi menu bar tidak punya bilah menu di layar, jadi menu Edit saja kadang tidak menerima pintasan
    /// (mis. saat popover baru dibuka). Monitor lokal ini meneruskannya langsung ke kolom / daftar yang aktif
    /// lewat action standar (copy:, paste:, …) — sama dengan menu Edit, hanya lebih pasti sampai.
    func installEditShortcuts() {
        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if ShortcutField.recording { return e } // sedang merekam pintasan baru (Pengaturan → Pintasan)
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard mods == .command || mods == [.command, .shift],
                  let key = e.charactersIgnoringModifiers?.lowercased() else { return e }
            let plain = mods == .command
            if key == "w" && plain {
                if let w = NSApp.keyWindow, w.styleMask.contains(.closable) { w.performClose(nil) } else { self?.closePopover() }
                return nil
            }
            let action: Selector?
            switch (key, plain) {
            case ("c", true): action = #selector(NSText.copy(_:))
            case ("v", true): action = #selector(NSText.paste(_:))
            case ("x", true): action = #selector(NSText.cut(_:))
            case ("a", true): action = #selector(NSText.selectAll(_:))
            case ("z", true): action = Selector(("undo:"))
            case ("z", false): action = Selector(("redo:"))
            default: action = nil
            }
            // Tidak ada yang menangani (mis. ⌘C tanpa kolom aktif) → biarkan event lewat seperti biasa.
            guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return e }
            return nil
        }
    }

    /// Menu utama tak terlihat (aplikasi menu bar) berisi menu Edit, supaya ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z bekerja di
    /// semua kolom teks, ⌘C di pratinjau detail, dan ⌘C di daftar Pengaturan → Todo.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Urungkan", Selector(("undo:")), "z", [.command]),
            ("Ulangi", Selector(("redo:")), "z", [.command, .shift]),
            ("Potong", #selector(NSText.cut(_:)), "x", [.command]),
            ("Salin", #selector(NSText.copy(_:)), "c", [.command]),
            ("Tempel", #selector(NSText.paste(_:)), "v", [.command]),
            ("Pilih Semua", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, key, mods) in items {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            edit.addItem(i)
        }
        editItem.submenu = edit
        main.addItem(NSMenuItem()) // posisi menu aplikasi
        main.addItem(editItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
