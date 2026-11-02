// AI Todo — aplikasi menu bar macOS (Swift + AppKit, tanpa dependensi).
//
//   • Ikon ✓ di menu bar + angka todo hari ini & terlambat
//   • Klik ikon = popover: tab Chat (gaya Claude: gelembung pengguna di kanan, jawaban AI penuh lebar)
//     dan tab Manual (tambah todo, klik lingkaran = tandai selesai; filter Hari ini | Semua;
//     ubah todo: tahan ⌥ lalu klik ✎, klik dua kali judul, atau klik kanan → Ubah…);
//     ⌥⌘T buka / tutup popover
//   • Konfirmasi / undo aksi asisten; klik kanan ikon = menu singkat (Pengaturan, Keluar)
//   • Jendela Pengaturan terpisah (tab Umum, Akun, Ingatan, Tentang — pola PasteLAN)
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

    static var hotkey: Bool {
        get { flag("hotkey", default: true) }
        set { d.set(newValue, forKey: "hotkey") }
    }

    /// Filter daftar di tab Manual: false = Hari ini (bawaan), true = Semua.
    static var showAllTodos: Bool {
        get { flag("showAllTodos", default: false) }
        set { d.set(newValue, forKey: "showAllTodos") }
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

// MARK: - Popover menu bar: tab Chat (gaya Claude) & Manual

/// Isi popover saat ikon menu bar diklik.
///   ┌ [ Chat | Manual ]                 🌐 ⚙︎ ┐
///   │                       ┌─────────────┐ │  ← pesan pengguna: gelembung di kanan
///   │                       └─────────────┘ │
///   │ Jawaban asisten penuh lebar, tanpa    │  ← jawaban AI: teks polos
///   │ gelembung.                            │
///   └ ( ✦ Tulis pesan…                  ↑ ) ┘  ← kotak input kaca (isi chat di belakangnya buram)
///
/// Tab Manual:
///   ┌ [ Chat | Manual ]                 🌐 ⚙︎ ┐
///   │ ┌ Judul todo…                       ┐ │  ← kartu tambah todo (tidak berubah)
///   │ └ Hari ini ▾  Jam        [Tambah]    ┘ │
///   │ [ Hari ini 3 | Semua 12 ]             │  ← filter kecil: fokus hari ini, atau semua todo terbuka
///   │ ○ Bayar listrik                       │  ← tahan ⌥: ○ berubah jadi ✎ (klik = ubah, bukan selesai)
///   └ Sinkron 10.42                         ┘
///
/// Mode ubah (satu todo, kartu menggantikan barisnya di daftar — lihat `TodoEditor`):
///   ⌥ + klik lingkaran · klik dua kali judul · klik kanan → Ubah…   ↩ simpan, esc batal
final class PopoverController: NSViewController {
    enum Mode: Int { case chat, manual }
    static let size = NSSize(width: 400, height: 600)
    static let inset: CGFloat = 16
    /// Lebar isi (tanpa margin kiri-kanan).
    static let contentWidth = size.width - inset * 2

    unowned let app: AppDelegate
    var store: Store { app.store }
    private(set) var mode: Mode = .chat

    private let segment = NSSegmentedControl(labels: ["Chat", "Manual"], trackingMode: .selectOne, target: nil, action: nil)
    private let chatBox = NSView()
    private let manualBox = NSView()
    private let offlineBox = NSView()
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
    private lazy var confirmButton = button("Ya, lakukan", #selector(confirm))
    private lazy var rejectButton = button("Batal", #selector(reject))
    private lazy var undoButton = button("Batalkan aksi terakhir", #selector(undo))
    private var thinkingRow: NSView?
    private var pending: BatchView?
    private var undoable: BatchView?
    private var busy = false { didSet { updateControls() } }
    private lazy var clearButton = UI.iconButton("trash", tip: "Hapus riwayat chat", self, #selector(confirmClearHistory))

    // Manual
    private let titleField = NSTextField()
    private let duePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeField = NSTextField()
    private lazy var addButton = button("Tambah", #selector(addManual))
    private let addError = UI.label("", size: 11, color: Theme.danger)
    /// Filter daftar: Hari ini (terlambat + hari ini + pengingat) | Semua (semua todo terbuka per tanggal).
    private let scope = NSSegmentedControl(labels: ["Hari ini", "Semua"], trackingMode: .selectOne, target: nil, action: nil)
    /// Batas baris di tampilan Semua; sisanya lewat tautan ke browser.
    static let maxAllRows = 200
    // Mode ubah
    /// Tombol lingkaran yang sedang tampil (id todo → tombol & todo), untuk ganti ikon saat ⌥ ditekan.
    private var checkButtons: [(button: NSButton, todo: Todo)] = []
    private var optionDown = false { didSet { if optionDown != oldValue { updateCheckIcons() } } }
    private var editor: TodoEditor?
    private var flagsMonitor: Any?
    private let listStack = UI.stack([], spacing: 6)
    private lazy var listScroll = UI.scroll(listStack)
    private let syncLabel = UI.label("", size: 11, color: .tertiaryLabelColor)

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
        segment.setWidth(118, forSegment: 0)
        segment.setWidth(118, forSegment: 1)
        segment.translatesAutoresizingMaskIntoConstraints = false
        let web = UI.iconButton("globe", tip: "Buka AI Todo di browser", self, #selector(openWeb))
        let gear = UI.iconButton("gearshape", tip: "Pengaturan (⌘,)", self, #selector(openSettings))
        let header = UI.stack([segment, NSView(), clearButton, web, gear], vertical: false, spacing: 4)
        header.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, line, chatBox, manualBox, offlineBox] {
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
        for box in [chatBox, manualBox, offlineBox] {
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
        let bar = UI.stack([actionIcon, actionLabel, NSView(), rejectButton, confirmButton, undoButton], vertical: false, spacing: 6)
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
        chatBottom.addArrangedSubview(actionBar)
        chatBottom.addArrangedSubview(inputGlass)
        for v in [actionBar, inputGlass] { v.widthAnchor.constraint(equalTo: chatBottom.widthAnchor).isActive = true }
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
        actionBar.isHidden = !hasPending && undoable == nil
        actionIcon.image = UI.symbol(hasPending ? "exclamationmark.circle.fill" : "arrow.uturn.backward.circle", 14)
        actionIcon.contentTintColor = hasPending ? .systemOrange : Theme.accent
        actionLabel.stringValue = hasPending ? "Perlu konfirmasimu" : "Aksi terakhir sudah dijalankan"
        [confirmButton, rejectButton, undoButton].forEach { $0.isEnabled = !busy }
        input.isEnabled = !busy
        sendBox.alphaValue = busy ? 0.4 : 1
        // Hapus riwayat: hanya di tab Chat, saat terhubung, dan tidak sedang menunggu server
        clearButton.isEnabled = !busy && store.connected && mode == .chat
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

    @objc private func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: Tata letak manual

    private func buildManual() {
        let i = PopoverController.inset
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Judul todo, mis. Bayar listrik"
        titleField.target = self
        titleField.action = #selector(addManual)
        duePopup.addItems(withTitles: ["Tanpa tenggat", "Hari ini", "Besok", "Lusa"])
        duePopup.selectItem(at: 1)
        duePopup.controlSize = .small
        timeField.bezelStyle = .roundedBezel
        timeField.placeholderString = "Jam (HH:MM)"
        timeField.controlSize = .small
        timeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeField.widthAnchor.constraint(equalToConstant: 92).isActive = true
        addButton.bezelColor = Theme.accent
        addError.isHidden = true
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)
        scope.selectedSegment = LocalPrefs.showAllTodos ? 1 : 0
        scope.setAccessibilityLabel("Tampilkan todo")
        scope.toolTip = "Hari ini: terlambat, hari ini & pengingat. Semua: semua todo yang belum selesai."
        // ⌥ ditahan → lingkaran berubah jadi ✎ (pola tombol alternatif ⌥ di macOS)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.optionDown = e.modifierFlags.contains(.option)
            return e
        }

        let opts = UI.stack([duePopup, timeField, NSView(), addButton], vertical: false, spacing: 8)
        let form = UI.stack([titleField, opts, addError], spacing: 8)
        for v in [titleField, opts] as [NSView] { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        let card = RoundedBox(fill: .controlBackgroundColor, stroke: .separatorColor, radius: 12)
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)

        listStack.edgeInsets = NSEdgeInsets(top: 4, left: i, bottom: 12, right: i)
        for v in [card, scope, listScroll, syncLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            manualBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: manualBox.topAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            card.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor, constant: -i),
            scope.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            scope.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            listScroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 2),
            listScroll.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: syncLabel.topAnchor, constant: -6),
            syncLabel.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            syncLabel.trailingAnchor.constraint(lessThanOrEqualTo: manualBox.trailingAnchor, constant: -i),
            syncLabel.bottomAnchor.constraint(equalTo: manualBox.bottomAnchor, constant: -10),
        ])
    }

    private var showAll: Bool { scope.selectedSegment == 1 }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        checkButtons = []
        let b = store.buckets
        updateScopeLabels(b)
        section("Terlambat", b.overdue, color: Theme.danger)
        section("Hari ini", b.today, showDate: false)
        if showAll { rebuildAll(b) } else { rebuildToday(b) }
    }

    private func updateScopeLabels(_ b: TodoBuckets) {
        scope.setLabel("Hari ini" + (b.badge > 0 ? "  \(b.badge)" : ""), forSegment: 0)
        scope.setLabel("Semua" + (b.total > 0 ? "  \(b.total)" : ""), forSegment: 1)
    }

    /// Hari ini: tetap ringkas — terlambat, hari ini, lalu pengingat 48 jam.
    private func rebuildToday(_ b: TodoBuckets) {
        if b.overdue.isEmpty && b.today.isEmpty {
            addListRow(UI.label("Tidak ada todo untuk hari ini. Tambah di atas, atau minta asisten di tab Chat.", size: 12,
                                color: .secondaryLabelColor))
            let later = b.upcoming.count + b.noDate.count
            if later > 0 { addListRow(linkButton("Lihat \(later) todo lainnya", #selector(showAllTapped))) }
        }

        let upcoming = store.occurrences.prefix(3)
        if !upcoming.isEmpty {
            addHeader("Pengingat berikutnya", count: nil)
            for o in upcoming {
                let when = Clock.parseStamp(o.at).map { Clock.friendly(Clock.ymd($0, store.tz), now: Date(), store.tz) + " " + Clock.hm($0, store.tz) } ?? ""
                let icon = NSImageView(image: UI.symbol("bell", 12) ?? NSImage())
                icon.contentTintColor = .secondaryLabelColor
                let t = UI.label(o.title, size: 13)
                let w = UI.label(when, size: 11, color: .secondaryLabelColor)
                addListRow(UI.stack([icon, UI.stack([t, w], spacing: 1)], vertical: false, spacing: 10))
            }
        }
    }

    /// Semua: semua todo terbuka — terlambat, hari ini, per tanggal (Besok, Rab 5 Nov, …), lalu tanpa tenggat.
    private func rebuildAll(_ b: TodoBuckets) {
        if b.total == 0 {
            addListRow(UI.label("Semua todo sudah selesai. Tambah di atas, atau minta asisten di tab Chat.", size: 12,
                                color: .secondaryLabelColor))
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
        for t in todos {
            if let editor, editor.todo.id == t.id { addListRow(editor) } else { addListRow(todoRow(t, showDate: showDate)) }
        }
    }

    private func addListRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -2 * PopoverController.inset).isActive = true
    }

    /// Lingkaran di kiri = tandai selesai (⌥ ditahan = ✎ ubah). Klik dua kali judul / klik kanan = ubah.
    private func todoRow(_ t: Todo, showDate: Bool = true) -> NSView {
        let check = NSButton(image: NSImage(), target: self, action: #selector(completeClicked(_:)))
        check.isBordered = false
        check.tag = Int(t.id)
        styleCheck(check, t)
        checkButtons.append((check, t))
        var meta: [String] = []
        if t.priority == "high" { meta.append("Prioritas tinggi") }
        if !t.dueDate.isEmpty {
            var due = !showDate || t.dueDate == Clock.ymd(Date(), store.tz) ? "" : Clock.friendly(t.dueDate, now: Date(), store.tz)
            if !t.dueTime.isEmpty { due += (due.isEmpty ? "" : " ") + t.dueTime }
            if !due.isEmpty { meta.append(due) }
        }
        if !t.list.isEmpty { meta.append(t.list) }
        var texts: [NSView] = [UI.text(t.title, width: PopoverController.contentWidth - 30, size: 13)]
        if !meta.isEmpty { texts.append(UI.label(meta.joined(separator: " · "), size: 11, color: .secondaryLabelColor)) }
        let textStack = UI.stack(texts, spacing: 1)
        let dbl = TodoClick(target: self, action: #selector(rowDoubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.todoID = t.id
        textStack.addGestureRecognizer(dbl)
        let row = UI.stack([check, textStack], vertical: false, spacing: 8)
        row.alignment = .top
        row.toolTip = t.notes.isEmpty ? nil : t.notes
        row.menu = rowMenu(t)
        return row
    }

    /// Klik kanan baris: Ubah… / Tandai selesai.
    private func rowMenu(_ t: Todo) -> NSMenu {
        let m = NSMenu()
        for (title, action) in [("Ubah…", #selector(editMenuItem(_:))), ("Tandai selesai", #selector(completeMenuItem(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: t.id)
            m.addItem(item)
        }
        return m
    }

    private func styleCheck(_ b: NSButton, _ t: Todo) {
        if optionDown {
            b.image = UI.symbol("pencil.circle", 16)
            b.contentTintColor = Theme.accent
            b.toolTip = "Ubah"
            b.setAccessibilityLabel("Ubah “\(t.title)”")
        } else {
            b.image = UI.symbol("circle", 16)
            b.contentTintColor = t.priority == "high" ? Theme.danger : .tertiaryLabelColor
            b.toolTip = "Tandai selesai · ⌥-klik untuk mengubah"
            b.setAccessibilityLabel("Tandai “\(t.title)” selesai")
        }
    }

    private func updateCheckIcons() {
        for c in checkButtons where c.button.isEnabled { styleCheck(c.button, c.todo) }
        syncLabel.stringValue = optionDown && mode == .manual ? "Mode ubah: klik ✎ untuk mengubah todo" : app.syncStatus
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
        LocalPrefs.showAllTodos = showAll
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

    @objc private func addManual() {
        guard addButton.isEnabled else { return }
        addError.isHidden = true
        addButton.isEnabled = false
        app.createTodo(title: titleField.stringValue, dayOffset: duePopup.indexOfSelectedItem - 1, time: timeField.stringValue) { [weak self] err in
            guard let self else { return }
            self.addButton.isEnabled = true
            if let err {
                self.addError.stringValue = err
                self.addError.isHidden = false
            } else {
                self.titleField.stringValue = ""
                self.timeField.stringValue = ""
                self.view.window?.makeFirstResponder(self.titleField)
            }
        }
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
        manualBox.isHidden = !online || mode != .manual
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
            // Selama mengubah, daftar tidak dibangun ulang (isi kartu ubah tidak boleh hilang karena sinkron),
            // kecuali todo yang diubah sudah tidak ada (selesai / dihapus di perangkat lain).
            if let editor, store.todos.contains(where: { $0.id == editor.todo.id }) {
                updateScopeLabels(store.buckets)
            } else {
                editor = nil
                rebuildList()
            }
        }
        updateControls()
    }

    func select(_ m: Mode) {
        _ = view
        mode = m
        segment.selectedSegment = m.rawValue
        storeChanged()
    }

    /// Popover baru tampil: fokus ke input & muat riwayat chat terbaru.
    func didShow() {
        guard store.connected else { return }
        optionDown = NSEvent.modifierFlags.contains(.option)
        if mode == .chat {
            view.window?.makeFirstResponder(input)
            loadHistory()
        } else {
            view.window?.makeFirstResponder(editor?.titleField ?? titleField)
        }
    }

    @objc private func segmentChanged() {
        select(Mode(rawValue: segment.selectedSegment) ?? .chat)
        didShow()
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

    @objc private func openWeb() { app.openWebPage(mode == .chat ? "/" : "/todo") }
    @objc private func openSettings() { app.openSettings() }
}

// MARK: - Kartu ubah todo (mode ubah di tab Manual)

/// Klik dua kali judul todo → ubah (menyimpan id todo di recognizer).
final class TodoClick: NSClickGestureRecognizer {
    var todoID: Int64 = 0
}

/// Menggantikan baris todo di daftar selama diubah. Tanggal & jam memakai NSDatePicker bawaan macOS
/// (kalender muncul saat tanggal diklik; jam bisa diketik atau pakai panah).
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
    private static let priorities = ["low", "normal", "high"]

    var onSave: (([String: String]) -> Void)?
    var onCancel: (() -> Void)?
    var busy = false { didSet { saveButton.isEnabled = !busy; cancelButton.isEnabled = !busy } }

    init(todo: Todo, lists: [String], tz: TimeZone) {
        self.todo = todo
        self.tz = tz
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
        let buttons = UI.stack([error, NSView(), cancelButton, saveButton], vertical: false, spacing: 8)
        let form = UI.stack([titleField, meta, when, buttons], spacing: 8)
        for v in [titleField, meta, when, buttons] as [NSView] { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        listBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let card = RoundedBox(fill: .controlBackgroundColor, stroke: Theme.accent, radius: 12)
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        UI.pin(card, to: self, top: 4, bottom: 4)
    }

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
        onSave?([
            "title": title,
            "list": listBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "priority": TodoEditor.priorities[max(0, priority.indexOfSelectedItem)],
            "dueDate": hasDate ? Clock.ymd(datePicker.dateValue, tz) : "",
            "dueTime": hasTime ? Clock.hm(timePicker.dateValue, tz) : "",
        ])
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
        return false
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}

// MARK: Input chat: ↩ kirim, ⇧↩ baris baru

extension PopoverController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === input, selector == #selector(NSResponder.insertNewline(_:)),
              NSApp.currentEvent?.modifierFlags.contains(.shift) == true else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        resizeInput()
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === input else { return }
        resizeInput()
    }
}

// MARK: - Jendela Pengaturan (tab Umum, Akun, Ingatan, Tentang — pola PasteLAN)

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
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        for s in sections {
            content.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
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
    enum Tab: Int { case general, account, memory, about }
    static let size = NSSize(width: 600, height: 470)

    unowned let app: AppDelegate
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let general = FormPage()
    private let account = FormPage()
    private lazy var memory = MemoryPage(app: app)
    private let about = FormPage()
    private var signature = ""
    private var pending = false

    // kontrol tab Umum (dibuat sekali, statusnya diperbarui di tempat supaya animasi NSSwitch tidak terputus)
    private lazy var badgeSwitch = Form.toggle(self, #selector(badgeChanged(_:)))
    private lazy var hotkeySwitch = Form.toggle(self, #selector(hotkeyChanged(_:)))
    private lazy var notifySwitch = Form.toggle(self, #selector(notifyChanged(_:)))
    private lazy var loginSwitch = Form.toggle(self, #selector(loginChanged(_:)))

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
        let pages: [(NSViewController, String, String)] = [(general, "Umum", "gearshape"), (account, "Akun", "person.crop.circle"),
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
                Form.row("Pintasan ⌥⌘T", "Buka / tutup asisten dari aplikasi mana pun.", hotkeySwitch),
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
    }

    private func rebuild() {
        guard window != nil else { return }
        badgeSwitch.state = LocalPrefs.showBadge ? .on : .off
        hotkeySwitch.state = LocalPrefs.hotkey ? .on : .off
        notifySwitch.state = LocalPrefs.notifications ? .on : .off
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
    @objc func hotkeyChanged(_ s: NSSwitch) { if (s.state == .on) != LocalPrefs.hotkey { app.toggleHotkey() } }
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

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-ai-todo"
    let appName = "AITodo"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: URL?, sig: URL?, page: URL)
    var latest: Release?

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
            // Jelaskan kenapa tidak bisa dipasang otomatis, jangan diam-diam membuka GitHub.
            let why: String
            if Updater.publicKey.isEmpty { why = "Versi AI Todo ini belum punya kunci publik untuk memeriksa tanda tangan rilis, jadi update otomatis nonaktif. Pasang versi baru ini secara manual sekali; setelah itu update berikutnya bisa otomatis." }
            else if l.zip == nil { why = "Rilis \(l.version) tidak berisi \(appName).zip." }
            else if l.sig == nil { why = "Rilis \(l.version) belum ditandatangani (secret AITODO_SIGNING_KEY belum diatur di GitHub)." }
            else if dest.pathExtension != "app" { why = "AI Todo tidak berjalan dari file .app." }
            else { why = "Folder \(dest.deletingLastPathComponent().path) tidak bisa ditulis. Pindahkan AITodo.app ke Applications." }
            return fail(why, l.page)
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

        notifier.store = store
        notifier.openApp = { [weak self] in self?.showPopover(.chat) }
        notifier.setup()

        store.onChange = { [weak self] in self?.stateChanged() }
        store.configureFromKeychain()

        HotKey.action = { [weak self] in self?.togglePopover(.chat) }
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
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
        panel.didShow()
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
        contextMenu.addItem(.separator())
        let ask = item("Buka asisten", #selector(openChat), key: "t")
        ask.keyEquivalentModifierMask = [.command, .option]
        contextMenu.addItem(ask)
        contextMenu.addItem(item("Tambah todo manual", #selector(openManual)))
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

    // MARK: Aksi

    @objc func openChat() { showPopover(.chat) }
    @objc func openManual() { showPopover(.manual) }

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

    @objc func toggleHotkey() {
        LocalPrefs.hotkey.toggle()
        if LocalPrefs.hotkey { hotkey.register() } else { hotkey.unregister() }
        settings.reload()
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
