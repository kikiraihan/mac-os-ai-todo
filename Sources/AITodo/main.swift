// AI Todo — aplikasi menu bar macOS (Swift + AppKit, tanpa dependensi).
//
//   • Ikon ✓ di menu bar + angka todo hari ini & terlambat
//   • Klik ikon = popover: tab Chat (gaya Claude: gelembung pengguna di kanan, jawaban AI penuh lebar)
//     dan tab Manual (tambah todo, klik lingkaran = tandai selesai); ⌥⌘T buka / tutup popover
//   • Konfirmasi / undo aksi asisten; klik kanan ikon = menu singkat (Pengaturan, Keluar)
//   • Jendela Pengaturan terpisah (tab Umum, Akun, Tentang — pola PasteLAN)
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

    static func pin(_ v: NSView, to p: NSView, top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
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
        let y = max(0, doc.frame.height - s.contentView.bounds.height)
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
///   └ ( Tulis pesan…                    ↑ ) ┘  ← kotak input
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
    private let sendBox = RoundedBox(fill: Theme.accent, radius: 14)
    private let actionBar = RoundedBox(fill: Theme.warnSoft, radius: 10)
    private let actionLabel = UI.label("", size: 12)
    private lazy var confirmButton = button("Ya, lakukan", #selector(confirm))
    private lazy var rejectButton = button("Batal", #selector(reject))
    private lazy var undoButton = button("Batalkan aksi terakhir", #selector(undo))
    private var thinkingRow: NSView?
    private var pending: BatchView?
    private var undoable: BatchView?
    private var busy = false { didSet { updateControls() } }

    // Manual
    private let titleField = NSTextField()
    private let duePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeField = NSTextField()
    private lazy var addButton = button("Tambah", #selector(addManual))
    private let addError = UI.label("", size: 11, color: Theme.danger)
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
        let header = UI.stack([segment, NSView(), web, gear], vertical: false, spacing: 4)
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

    // MARK: Tata letak chat

    private func buildChat() {
        let i = PopoverController.inset
        chatStack.edgeInsets = NSEdgeInsets(top: 14, left: i, bottom: 14, right: i)

        // Bar konfirmasi / undo di atas input
        actionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        confirmButton.keyEquivalent = "\r"
        let bar = UI.stack([actionLabel, NSView(), rejectButton, confirmButton, undoButton], vertical: false, spacing: 6)
        actionBar.addSubview(bar)
        UI.pin(bar, to: actionBar, top: 6, left: 10, bottom: 6, right: 6)

        // Kotak input (gaya Claude): teks di kiri, tombol kirim bulat di kanan
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 13)
        input.placeholderString = "Tulis tugas atau tanya asisten…"
        input.cell?.isScrollable = true
        input.target = self
        input.action = #selector(send)
        input.setAccessibilityLabel("Pesan untuk asisten")
        let send = NSButton(image: UI.symbol("arrow.up", 13, weight: .bold) ?? NSImage(), target: self, action: #selector(send))
        send.isBordered = false
        send.contentTintColor = Theme.accentText
        send.toolTip = "Kirim (↩)"
        send.setAccessibilityLabel("Kirim")
        sendBox.addSubview(send)
        UI.pin(send, to: sendBox)
        let inputBox = RoundedBox(fill: .controlBackgroundColor, stroke: .separatorColor, radius: 14)
        for v in [input, sendBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            inputBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            inputBox.heightAnchor.constraint(equalToConstant: 46),
            input.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 14),
            input.centerYAnchor.constraint(equalTo: inputBox.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: sendBox.leadingAnchor, constant: -8),
            sendBox.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -9),
            sendBox.centerYAnchor.constraint(equalTo: inputBox.centerYAnchor),
            sendBox.widthAnchor.constraint(equalToConstant: 28),
            sendBox.heightAnchor.constraint(equalToConstant: 28),
        ])

        let bottom = UI.stack([actionBar, inputBox], spacing: 8)
        bottom.translatesAutoresizingMaskIntoConstraints = false
        for v in [actionBar, inputBox] { v.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true }
        chatBox.addSubview(chatScroll)
        chatBox.addSubview(bottom)
        NSLayoutConstraint.activate([
            chatScroll.topAnchor.constraint(equalTo: chatBox.topAnchor),
            chatScroll.leadingAnchor.constraint(equalTo: chatBox.leadingAnchor),
            chatScroll.trailingAnchor.constraint(equalTo: chatBox.trailingAnchor),
            chatScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: chatBox.leadingAnchor, constant: i),
            bottom.trailingAnchor.constraint(equalTo: chatBox.trailingAnchor, constant: -i),
            bottom.bottomAnchor.constraint(equalTo: chatBox.bottomAnchor, constant: -i),
        ])
        updateControls()
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
        actionBar.fill = hasPending ? Theme.warnSoft : Theme.bubble
        actionLabel.stringValue = hasPending ? "Perlu konfirmasimu" : "Aksi terakhir sudah dijalankan"
        [confirmButton, rejectButton, undoButton].forEach { $0.isEnabled = !busy }
        input.isEnabled = !busy
        sendBox.alphaValue = busy ? 0.4 : 1
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

        let opts = UI.stack([duePopup, timeField, NSView(), addButton], vertical: false, spacing: 8)
        let form = UI.stack([titleField, opts, addError], spacing: 8)
        for v in [titleField, opts] as [NSView] { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        let card = RoundedBox(fill: .controlBackgroundColor, stroke: .separatorColor, radius: 12)
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)

        listStack.edgeInsets = NSEdgeInsets(top: 4, left: i, bottom: 12, right: i)
        for v in [card, listScroll, syncLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            manualBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: manualBox.topAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            card.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor, constant: -i),
            listScroll.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: manualBox.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: syncLabel.topAnchor, constant: -6),
            syncLabel.leadingAnchor.constraint(equalTo: manualBox.leadingAnchor, constant: i),
            syncLabel.trailingAnchor.constraint(lessThanOrEqualTo: manualBox.trailingAnchor, constant: -i),
            syncLabel.bottomAnchor.constraint(equalTo: manualBox.bottomAnchor, constant: -10),
        ])
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let b = store.buckets
        section("Terlambat", b.overdue, color: Theme.danger)
        section("Hari ini", b.today)
        if b.overdue.isEmpty && b.today.isEmpty {
            addListRow(UI.label("Tidak ada todo untuk hari ini. Tambah di atas, atau minta asisten di tab Chat.", size: 12,
                                color: .secondaryLabelColor))
        }
        section("Nanti", Array(b.upcoming.prefix(30)))
        section("Tanpa tenggat", Array(b.noDate.prefix(30)))
        let more = b.upcoming.count + b.noDate.count - min(30, b.upcoming.count) - min(30, b.noDate.count)
        if more > 0 {
            let l = NSButton(title: "\(more) todo lainnya ada di browser", target: self, action: #selector(openWeb))
            l.isBordered = false
            l.contentTintColor = Theme.accent
            addListRow(l)
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

    private func addHeader(_ title: String, count: Int?, color: NSColor = .secondaryLabelColor) {
        let h = UI.label(count.map { "\(title)  \($0)" } ?? title, size: 12, weight: .semibold, color: color)
        let wrap = NSView()
        h.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(h)
        UI.pin(h, to: wrap, top: 10, bottom: 2)
        addListRow(wrap)
    }

    private func section(_ title: String, _ todos: [Todo], color: NSColor = .secondaryLabelColor) {
        guard !todos.isEmpty else { return }
        addHeader(title, count: todos.count, color: color)
        for t in todos { addListRow(todoRow(t)) }
    }

    private func addListRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -2 * PopoverController.inset).isActive = true
    }

    /// Lingkaran di kiri = tandai selesai.
    private func todoRow(_ t: Todo) -> NSView {
        let check = NSButton(image: UI.symbol("circle", 16) ?? NSImage(), target: self, action: #selector(completeClicked(_:)))
        check.isBordered = false
        check.contentTintColor = t.priority == "high" ? Theme.danger : .tertiaryLabelColor
        check.tag = Int(t.id)
        check.toolTip = "Tandai selesai"
        check.setAccessibilityLabel("Tandai “\(t.title)” selesai")
        var meta: [String] = []
        if t.priority == "high" { meta.append("Prioritas tinggi") }
        if !t.dueDate.isEmpty {
            var due = t.dueDate == Clock.ymd(Date(), store.tz) ? "" : Clock.friendly(t.dueDate, now: Date(), store.tz)
            if !t.dueTime.isEmpty { due += (due.isEmpty ? "" : " ") + t.dueTime }
            if !due.isEmpty { meta.append(due) }
        }
        if !t.list.isEmpty { meta.append(t.list) }
        var texts: [NSView] = [UI.text(t.title, width: PopoverController.contentWidth - 30, size: 13)]
        if !meta.isEmpty { texts.append(UI.label(meta.joined(separator: " · "), size: 11, color: .secondaryLabelColor)) }
        let row = UI.stack([check, UI.stack(texts, spacing: 1)], vertical: false, spacing: 8)
        row.alignment = .top
        row.toolTip = t.notes.isEmpty ? nil : t.notes
        return row
    }

    @objc private func completeClicked(_ sender: NSButton) {
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
        if online { rebuildList() }
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
        if mode == .chat {
            view.window?.makeFirstResponder(input)
            loadHistory()
        } else {
            view.window?.makeFirstResponder(titleField)
        }
    }

    @objc private func segmentChanged() {
        select(Mode(rawValue: segment.selectedSegment) ?? .chat)
        didShow()
    }

    @objc private func openWeb() { app.openWebPage(mode == .chat ? "/" : "/todo") }
    @objc private func openSettings() { app.openSettings() }
}

// MARK: - Jendela Pengaturan (tab Umum, Akun, Tentang — pola PasteLAN)

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

final class SettingsWindow: NSObject {
    enum Tab: Int { case general, account, about }
    static let size = NSSize(width: 600, height: 470)

    unowned let app: AppDelegate
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let general = FormPage()
    private let account = FormPage()
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
                                                           (about, "Tentang", "info.circle")]
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
        contextMenu.addItem(item("Buka AI Todo di browser", #selector(openWeb)))
        contextMenu.addItem(.separator())
        contextMenu.addItem(item("Pengaturan…", #selector(openSettings), key: ","))
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

    @objc func openSettings() {
        closePopover()
        settings.show()
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
