// Tab Catatan di popover menu bar: hal umum tanpa waktu (teks, kumpulan link).
// Polanya sama dengan tab Todo (lihat PopoverController di main.swift):
//
//   ┌ [ Chat | Todo | Pengingat | Catatan ]   ＋ 🌐 ↻ ⚙︎ ┐
//   │ ┌ Judul atau link…                 [Simpan] ┐ │  ← kartu tambah cepat (＋ / ⌘N; Esc menutup)
//   │ └                           Isian lengkap… ┘ │  ← form lengkap (isi, kategori, sematkan) di tempat kartu
//   │ [ Semua 12 | Disematkan 2 ] [🔍 Cari…       ] │  ← filter (diingat) + cari (judul, isi, kategori)
//   │ Disematkan  2                                 │
//   │ 📌 Resep sambal                               │  ← 📌 = sematkan / lepas · klik teks = salin
//   │    cabai, bawang, terasi                      │     (⌥-klik = judul saja) · klik dua kali = ubah
//   │    Link · Kam 5 Nov 10.42 · ≡ Isi             │  ← Isi = pratinjau (link bisa diklik, Salin, Ubah…)
//   │ Link  5                                       │  ← lainnya dikelompokkan per kategori
//   └ Tersinkron 10.42                              ┘
//
// Klik kanan baris: Lihat isi / Ubah… / Salin (⌥: Salin judul saja) / Sematkan / Hapus… (dikonfirmasi).
// Semua perubahan lewat API yang sama dengan web (validasi & undo di server).

import AppKit

final class NotesPane: NSView, NSGestureRecognizerDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    unowned let app: AppDelegate
    var store: Store { app.store }
    /// Kartu tambah dibuka / ditutup → PopoverController memperbarui tombol ＋ di header.
    var onCardChanged: (() -> Void)?
    private(set) var addCardOpen = false

    // Kartu tambah cepat
    private let titleField = NSTextField()
    private lazy var addButton: NSButton = {
        let b = NSButton(title: "Simpan", target: self, action: #selector(addQuick))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.bezelColor = Theme.accent
        return b
    }()
    private let addError = UI.label("", size: 11, color: Theme.danger)
    private lazy var advancedButton: NSButton = {
        let b = NSButton(title: "Isian lengkap…", target: self, action: #selector(openAdvanced))
        b.isBordered = false
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.contentTintColor = Theme.accent
        return b
    }()
    private let addHost = NSView()
    private let addCard = RoundedBox(fill: .controlBackgroundColor, stroke: .separatorColor, radius: 12)
    /// Form lengkap yang sedang terbuka di tempat kartu cepat (nil = kartu cepat).
    private var advancedForm: NoteEditor?

    // Filter + cari
    private let scope = NSSegmentedControl(labels: ["Semua", "Disematkan"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private lazy var filterBar = UI.stack([scope, searchField], vertical: false, spacing: 8)
    private lazy var barBelowCard = filterBar.topAnchor.constraint(equalTo: addHost.bottomAnchor, constant: 12)
    private lazy var barAtTop = filterBar.topAnchor.constraint(equalTo: topAnchor, constant: 12)

    // Daftar
    private let listStack = UI.stack([], spacing: 6)
    private lazy var listScroll = UI.scroll(listStack)
    private let syncLabel = UI.label("", size: 11, color: .tertiaryLabelColor)
    /// Kartu ubah yang menggantikan baris catatan di daftar (nil = tidak sedang mengubah).
    private var editor: NoteEditor?
    private var detailPopover: NSPopover?
    private var rowViews: [Int64: NSView] = [:]
    /// Store berubah selama tab tidak terlihat → daftar dibangun ulang sebelum tampil.
    private var stale = true

    init(app: AppDelegate) {
        self.app = app
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private var pinnedOnly: Bool { scope.selectedSegment == 1 }
    private var query: String { searchField.stringValue }
    private var searching: Bool { !TextSearch.terms(query).isEmpty }

    // MARK: Tata letak

    private func build() {
        let i = PopoverController.inset
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Judul atau link, mis. https://…"
        titleField.target = self
        titleField.action = #selector(addQuick)
        titleField.delegate = self // Esc = tutup kartu
        titleField.setAccessibilityLabel("Catatan baru")
        addError.isHidden = true
        addError.lineBreakMode = .byTruncatingTail
        addError.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = UI.stack([titleField, addButton], vertical: false, spacing: 8)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let foot = UI.stack([addError, NSView(), advancedButton], vertical: false, spacing: 8)
        let form = UI.stack([top, foot], spacing: 6)
        for v in [top, foot] as [NSView] { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        addCard.addSubview(form)
        UI.pin(form, to: addCard, top: 10, left: 10, bottom: 8, right: 10)
        addHost.addSubview(addCard)
        UI.pin(addCard, to: addHost)

        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)
        scope.selectedSegment = LocalPrefs.notesScope
        scope.setAccessibilityLabel("Tampilkan catatan")
        scope.toolTip = "Semua: catatan disematkan di atas, lalu per kategori. Disematkan: hanya yang disematkan."
        scope.setContentHuggingPriority(.required, for: .horizontal)
        scope.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.placeholderString = "Cari judul, isi, atau kategori"
        searchField.setAccessibilityLabel("Cari catatan")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self // Esc = kosongkan; kosong → tutup popover
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        listStack.edgeInsets = NSEdgeInsets(top: 4, left: i, bottom: 12, right: i)
        for v in [addHost, filterBar, listScroll, syncLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            addHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            addHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i),
            addHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i),
            listScroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 2),
            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: syncLabel.topAnchor, constant: -6),
            syncLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i),
            syncLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -i),
            syncLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        updateCard()
    }

    private func updateCard() {
        addHost.isHidden = !addCardOpen
        barBelowCard.isActive = addCardOpen
        barAtTop.isActive = !addCardOpen
    }

    // MARK: Dipanggil PopoverController

    /// Store berubah: bangun ulang sekarang bila terlihat, selain itu tandai saja (hemat sumber daya).
    func storeChanged(visible: Bool) {
        syncLabel.stringValue = app.syncStatus
        if visible { refresh() } else { stale = true }
    }

    func willShow() {
        if stale && store.connected { refresh() }
    }

    func didShow() {
        if let editor {
            window?.makeFirstResponder(editor.titleField)
        } else if addCardOpen {
            window?.makeFirstResponder(advancedForm?.titleField ?? titleField)
        } else {
            focusSearch()
        }
    }

    /// Pindah ke tab lain: tutup kartu & form, kosongkan pencarian.
    func leave() {
        editor = nil
        closeDetail()
        closeAdvanced()
        addCardOpen = false
        updateCard()
        searchField.stringValue = ""
        stale = true
    }

    /// ＋ / ⌘N: buka kartu tambah lalu fokus ke judul; tekan lagi = tutup. ⌥-klik ＋ = langsung isian lengkap.
    func toggleAddCard() {
        if NSEvent.modifierFlags.contains(.option) && advancedForm == nil {
            if !addCardOpen { setAddCard(open: true) }
            return openAdvanced()
        }
        setAddCard(open: !addCardOpen)
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Umpan balik singkat di baris status bawah, lalu kembali ke status sinkron.
    func flashStatus(_ text: String) {
        syncLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.syncLabel.stringValue == text else { return }
            self.syncLabel.stringValue = self.app.syncStatus
        }
    }

    // MARK: Kartu tambah

    private func setAddCard(open: Bool) {
        closeAdvanced()
        titleField.stringValue = ""
        addError.isHidden = true
        addCardOpen = open
        updateCard()
        onCardChanged?()
        if open { window?.makeFirstResponder(titleField) } else { focusSearch() }
    }

    /// Teks berisi link → masuk ke isi (bisa diklik di pratinjau), judul otomatis dari baris pertama (server).
    private static func body(from text: String) -> [String: Any] {
        let lower = text.lowercased()
        let link = lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
        return link ? ["content": text] : ["title": text]
    }

    @objc private func addQuick() {
        let text = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, addButton.isEnabled else { return }
        var body = NotesPane.body(from: text)
        if pinnedOnly { body["pinned"] = true } // filter Disematkan → catatan baru langsung tampil di sana
        addButton.isEnabled = false
        addError.isHidden = true
        store.api.createNote(body) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.addButton.isEnabled = true
                switch r {
                case .success:
                    self.titleField.stringValue = ""
                    self.window?.makeFirstResponder(self.titleField)
                    self.flashStatus("Catatan disimpan")
                    self.store.refresh()
                case .failure(let e):
                    self.addError.stringValue = e.description
                    self.addError.toolTip = e.description
                    self.addError.isHidden = false
                }
            }
        }
    }

    /// Ganti kartu cepat dengan form lengkap; isian cepat ikut terbawa.
    @objc private func openAdvanced() {
        guard advancedForm == nil else { return }
        let text = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let quick = NotesPane.body(from: text)
        let blank = Note(id: 0, title: quick["title"] as? String ?? "", content: quick["content"] as? String ?? "",
                         list: "", pinned: pinnedOnly)
        let e = NoteEditor(note: blank, lists: lists)
        // Batal = kembali ke kartu cepat (isian cepat tetap ada)
        e.onCancel = { [weak self] in
            guard let self else { return }
            self.closeAdvanced()
            self.window?.makeFirstResponder(self.titleField)
        }
        e.onSave = { [weak self, weak e] body in
            guard let self, let e else { return }
            e.busy = true
            self.store.api.createNote(body) { r in
                DispatchQueue.main.async {
                    e.busy = false
                    switch r {
                    case .success:
                        self.closeAdvanced()
                        self.titleField.stringValue = ""
                        self.window?.makeFirstResponder(self.titleField)
                        self.flashStatus("Catatan disimpan")
                        self.store.refresh()
                    case .failure(let err): e.showError(err.description)
                    }
                }
            }
        }
        addCard.isHidden = true
        addHost.addSubview(e)
        UI.pin(e, to: addHost)
        advancedForm = e
        // Link dari kartu cepat sudah masuk ke isi → fokus ke judul untuk memberi nama
        window?.makeFirstResponder(e.titleField)
        e.titleField.currentEditor()?.selectedRange = NSRange(location: e.titleField.stringValue.utf16.count, length: 0)
    }

    private func closeAdvanced() {
        guard let form = advancedForm else { return }
        form.removeFromSuperview()
        advancedForm = nil
        addCard.isHidden = false
    }

    // MARK: Filter & cari

    @objc private func scopeChanged() {
        LocalPrefs.notesScope = scope.selectedSegment
        editor = nil
        rebuild()
        scrollToTop()
    }

    @objc private func searchChanged() {
        editor = nil
        rebuild()
        scrollToTop()
    }

    private func scrollToTop() {
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    private var lists: [String] { Array(Set(store.notes.map(\.list).filter { !$0.isEmpty })).sorted() }

    // MARK: Daftar

    /// Bangun ulang mengikuti store; kartu ubah dipertahankan selama catatannya masih ada.
    private func refresh() {
        stale = false
        syncLabel.stringValue = app.syncStatus
        if let editor, store.notes.contains(where: { $0.id == editor.note.id }) {
            updateScopeLabels()
            return
        }
        editor = nil
        rebuild()
    }

    private func updateScopeLabels() {
        let all = store.notes.filter { TextSearch.matches($0, query: query) }
        let pinned = all.filter(\.pinned).count
        scope.setLabel("Semua" + (all.isEmpty ? "" : "  \(all.count)"), forSegment: 0)
        scope.setLabel("Disematkan" + (pinned > 0 ? "  \(pinned)" : ""), forSegment: 1)
        scope.setWidth(0, forSegment: 0)
        scope.setWidth(0, forSegment: 1)
    }

    private func rebuild() {
        closeDetail()
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = [:]
        updateScopeLabels()
        let q = query
        let all = store.notes.filter { TextSearch.matches($0, query: q) }
        let pinned = all.filter(\.pinned)
        let noMatch = "Tidak ada catatan yang cocok dengan “\(q.trimmingCharacters(in: .whitespaces))”."
        if pinnedOnly {
            if pinned.isEmpty {
                return addEmpty(searching ? noMatch : "Belum ada catatan yang disematkan. Klik 📌 di baris catatan untuk menyematkannya.")
            }
            var left = PopoverController.maxAllRows
            section("Disematkan", pinned, left: &left)
            return
        }
        if all.isEmpty {
            return addEmpty(searching ? noMatch
                : "Belum ada catatan. Simpan teks atau link lewat ＋, atau minta asisten di tab Chat: “catat link …”.")
        }
        var left = PopoverController.maxAllRows
        section("Disematkan", pinned, left: &left)
        var groups: [String: [Note]] = [:]
        for n in all where !n.pinned { groups[n.list, default: []].append(n) }
        let names = groups.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names { section(name, groups[name] ?? [], left: &left) }
        if let rest = groups[""] {
            section(names.isEmpty && pinned.isEmpty ? "Catatan" : "Tanpa kategori", rest, left: &left)
        }
        let shown = PopoverController.maxAllRows - left
        if all.count > shown {
            let more = NSButton(title: "\(all.count - shown) catatan lainnya ada di browser", target: self, action: #selector(openWeb))
            more.isBordered = false
            more.contentTintColor = Theme.accent
            more.alignment = .left
            addListRow(more)
        }
    }

    @objc private func openWeb() { app.openWebPage("/catatan") }

    private func addEmpty(_ text: String) {
        addListRow(UI.text(text, width: PopoverController.contentWidth, size: 12, color: .secondaryLabelColor))
    }

    private func section(_ title: String, _ notes: [Note], left: inout Int) {
        guard !notes.isEmpty, left > 0 else { return }
        let rows = Array(notes.prefix(left))
        left -= rows.count
        let h = UI.label("\(title)  \(notes.count)", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let wrap = NSView()
        wrap.addSubview(h)
        UI.pin(h, to: wrap, top: 10, bottom: 2)
        addListRow(wrap)
        for n in rows {
            if let editor, editor.note.id == n.id { addListRow(editor); continue }
            addListRow(noteRow(n, inPinned: title == "Disematkan"))
        }
    }

    private func addListRow(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -2 * PopoverController.inset).isActive = true
    }

    /// Satu baris pratinjau isi (baris pertama yang berisi & bukan judul; "- " dibuang).
    private static func preview(_ n: Note) -> String {
        for line in n.content.split(separator: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") { t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            if !t.isEmpty && t != n.title { return t }
        }
        return ""
    }

    /// "Kam 5 Nov 10.42" / "Hari ini 10.42" di zona pengguna.
    private func friendlyStamp(_ stamp: String) -> String {
        guard let d = Clock.parseStamp(stamp) else { return "" }
        let day = Clock.friendly(Clock.ymd(d, store.tz), now: Date(), store.tz)
        return day.prefix(1).uppercased() + day.dropFirst() + " " + Clock.hm(d, store.tz)
    }

    /// 📌 di kiri = sematkan / lepas. Klik teks = salin (⌥ = judul saja), klik dua kali = ubah, klik kanan = menu.
    private func noteRow(_ n: Note, inPinned: Bool) -> NSView {
        let pin = NSButton(image: UI.symbol(n.pinned ? "pin.fill" : "pin", 13) ?? NSImage(), target: self, action: #selector(pinClicked(_:)))
        pin.isBordered = false
        pin.tag = Int(n.id)
        pin.contentTintColor = n.pinned ? Theme.accent : .tertiaryLabelColor
        pin.toolTip = n.pinned ? "Lepas sematan" : "Sematkan di atas"
        pin.setAccessibilityLabel((n.pinned ? "Lepas sematan “" : "Sematkan “") + n.title + "”")

        let titleText = UI.text(n.title, width: PopoverController.contentWidth - 30, size: 13)
        titleText.isSelectable = false // klik teks = salin, bukan memilih teks
        var texts: [NSView] = [titleText]
        let pv = NotesPane.preview(n)
        if !pv.isEmpty {
            let l = UI.label(pv, size: 12, color: .secondaryLabelColor)
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            texts.append(l)
        }
        var meta: [String] = []
        if inPinned && !n.list.isEmpty { meta.append(n.list) } // di luar Disematkan, kategori = judul kelompok
        if let at = n.updatedAt, !at.isEmpty { meta.append(friendlyStamp(at)) }
        if n.source == "chat" { meta.append("AI") }
        var metaViews: [NSView] = []
        if !meta.isEmpty {
            metaViews.append(UI.label(meta.joined(separator: " · ") + (n.content.isEmpty ? "" : " ·"), size: 11,
                                      color: .tertiaryLabelColor))
        }
        if !n.content.isEmpty {
            let b = NSButton(title: "Isi", image: UI.symbol("text.alignleft", 10) ?? NSImage(), target: self,
                             action: #selector(detailClicked(_:)))
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.contentTintColor = Theme.accent
            b.attributedTitle = NSAttributedString(string: "Isi", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                             .foregroundColor: Theme.accent])
            b.tag = Int(n.id)
            b.toolTip = "Lihat isi"
            b.setAccessibilityLabel("Lihat isi “\(n.title)”")
            metaViews.append(b)
        }
        if !metaViews.isEmpty { texts.append(UI.stack(metaViews, vertical: false, spacing: 4)) }
        let textStack = UI.stack(texts, spacing: 1)
        addClicks(textStack, id: n.id)
        let row = ListRow.make([pin, textStack])
        row.toolTip = (n.content.isEmpty ? "" : String(n.content.prefix(500)) + "\n\n") +
            "Klik untuk menyalin · klik dua kali untuk mengubah"
        row.menu = rowMenu(n)
        rowViews[n.id] = row
        return row
    }

    private func rowMenu(_ n: Note) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, alternate: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: n.id)
            if alternate {
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
            }
            m.addItem(item)
        }
        if !n.content.isEmpty { add("Lihat isi", #selector(detailMenuItem(_:))) }
        add("Ubah…", #selector(editMenuItem(_:)))
        add("Salin", #selector(copyMenuItem(_:)))
        if !n.content.isEmpty { add("Salin judul saja", #selector(copyTitleMenuItem(_:)), alternate: true) }
        m.addItem(.separator())
        add(n.pinned ? "Lepas sematan" : "Sematkan", #selector(pinMenuItem(_:)))
        add("Hapus…", #selector(deleteMenuItem(_:)))
        return m
    }

    private func find(_ id: Int64) -> Note? { store.notes.first { $0.id == id } }
    private func note(_ item: NSMenuItem) -> Note? { (item.representedObject as? NSNumber).flatMap { find($0.int64Value) } }

    // MARK: Klik

    private func addClicks(_ v: NSView, id: Int64) {
        let tap = TodoClick(target: self, action: #selector(rowClicked(_:)))
        tap.numberOfClicksRequired = 1
        tap.todoID = id
        tap.delegate = self
        v.addGestureRecognizer(tap)
        let dbl = TodoClick(target: self, action: #selector(rowDoubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.todoID = id
        dbl.delegate = self
        v.addGestureRecognizer(dbl)
    }

    // Klik tunggal menunggu klik dua kali gagal (salin vs ubah); klik pada tombol (Isi) tidak memicu salin.
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
        (g as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 &&
            (other as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2 && g.view === other.view
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let v = g.view, let sup = v.superview else { return true }
        return !(v.hitTest(sup.convert(event.locationInWindow, from: nil)) is NSButton)
    }

    @objc private func rowClicked(_ g: TodoClick) {
        guard let n = find(g.todoID) else { return }
        copy(n, titleOnly: NSEvent.modifierFlags.contains(.option))
        if let v = g.view {
            v.alphaValue = 0.35
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                v.animator().alphaValue = 1
            }
        }
    }

    @objc private func rowDoubleClicked(_ g: TodoClick) { beginEdit(g.todoID) }
    @objc private func editMenuItem(_ item: NSMenuItem) { note(item).map { beginEdit($0.id) } }
    @objc private func copyMenuItem(_ item: NSMenuItem) { note(item).map { copy($0, titleOnly: false) } }
    @objc private func copyTitleMenuItem(_ item: NSMenuItem) { note(item).map { copy($0, titleOnly: true) } }
    @objc private func pinMenuItem(_ item: NSMenuItem) { note(item).map { setPinned($0, !$0.pinned) } }
    @objc private func deleteMenuItem(_ item: NSMenuItem) { note(item).map { delete($0) } }

    @objc private func pinClicked(_ sender: NSButton) {
        guard let n = find(Int64(sender.tag)) else { return }
        sender.isEnabled = false
        setPinned(n, !n.pinned)
    }

    /// Salin = teks polos "Judul" + baris kosong + isi (format yang sama dengan todo & web).
    private func copy(_ n: Note, titleOnly: Bool) {
        TodoCopy.copy(text: titleOnly || n.content.isEmpty ? n.title : n.title + "\n\n" + n.content)
        flashStatus(titleOnly || n.content.isEmpty ? "Judul disalin" : "Judul & isi disalin")
    }

    // MARK: Pratinjau isi (pola sama dengan Detail todo)

    /// DetailPreview dipakai ulang: catatan ditampilkan sebagai todo tanpa tenggat (judul, kategori, isi).
    private static func asTodo(_ n: Note) -> Todo {
        Todo(id: n.id, title: n.title, notes: n.content, status: "open", priority: "normal", list: n.list, dueDate: "", dueTime: "")
    }

    @objc private func detailClicked(_ sender: NSButton) {
        guard let n = find(Int64(sender.tag)) else { return }
        showDetail(n, from: sender)
    }

    @objc private func detailMenuItem(_ item: NSMenuItem) {
        guard let n = note(item), let v = rowViews[n.id] else { return }
        showDetail(n, from: v)
    }

    private func showDetail(_ n: Note, from anchor: NSView) {
        closeDetail()
        let vc = DetailPreview(todo: NotesPane.asTodo(n), tz: store.tz)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.delegate = self
        vc.onEdit = { [weak self] in
            self?.closeDetail()
            self?.beginEdit(n.id)
        }
        vc.onCopied = { [weak self] in self?.flashStatus("Judul & isi disalin") }
        detailPopover = p
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func closeDetail() {
        let p = detailPopover
        detailPopover = nil
        p?.close()
    }

    /// Pratinjau tertutup: kembalikan fokus ke popover utama supaya kliknya langsung bekerja lagi.
    func popoverDidClose(_ notification: Notification) {
        if let p = notification.object as? NSPopover, p === detailPopover { detailPopover = nil }
        if let w = window, w.isVisible, !w.isKeyWindow { w.makeKey() }
    }

    // MARK: Ubah, sematkan, hapus

    private func beginEdit(_ id: Int64) {
        guard let n = find(id) else { return }
        let e = NoteEditor(note: n, lists: lists)
        e.onCancel = { [weak self] in self?.endEdit() }
        e.onDelete = { [weak self] in self?.delete(n) }
        e.onSave = { [weak self, weak e] body in
            guard let self, let e else { return }
            e.busy = true
            self.store.api.updateNote(id, body) { r in
                DispatchQueue.main.async {
                    e.busy = false
                    switch r {
                    case .success:
                        self.flashStatus("Catatan disimpan")
                        self.endEdit()
                        self.store.refresh()
                    case .failure(let err): e.showError(err.description)
                    }
                }
            }
        }
        editor = e
        rebuild()
        DispatchQueue.main.async { [weak self, weak e] in
            guard let self, let e, self.editor === e else { return }
            e.scrollToVisible(e.bounds)
            self.window?.makeFirstResponder(e.titleField)
        }
    }

    private func endEdit() {
        guard editor != nil else { return }
        editor = nil
        rebuild()
    }

    private func setPinned(_ n: Note, _ pinned: Bool) {
        store.api.updateNote(n.id, ["pinned": pinned]) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success: self.flashStatus(pinned ? "Catatan disematkan" : "Sematan dilepas")
                case .failure(let e): showError("Gagal mengubah sematan", e.description)
                }
                self.store.refresh()
            }
        }
    }

    /// Hapus selalu dikonfirmasi.
    private func delete(_ n: Note) {
        let a = NSAlert()
        a.messageText = "Hapus catatan “\(n.title)”?"
        a.informativeText = "Catatan juga terhapus di web."
        a.alertStyle = .warning
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.api.deleteNote(n.id) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success:
                    if self.editor?.note.id == n.id { self.editor = nil }
                    self.flashStatus("Catatan dihapus")
                case .failure(let e): showError("Gagal menghapus catatan", e.description)
                }
                self.store.refresh()
            }
        }
    }

    // MARK: Esc

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Esc di kartu tambah = tutup kartu (Esc berikutnya baru menutup popover)
        if control === titleField {
            setAddCard(open: false)
            return true
        }
        // Esc di kolom cari: kosongkan dulu, Esc berikutnya menutup popover
        if control === searchField {
            if searchField.stringValue.isEmpty { app.closePopover() } else { searchField.stringValue = ""; searchChanged() }
            return true
        }
        return false
    }
}

/// Form catatan di popover: menggantikan baris saat diubah, atau kartu cepat saat "Isian lengkap…" (id 0 = baru).
///   ┌ Judul___________________________________ ┐
///   │ Isi: teks, link, daftar…                  │
///   │                                           │
///   │ Kategori [Link            ▾]  ☐ Sematkan  │
///   └ pesan galat         [Hapus…] [Batal] [Simpan] ┘
final class NoteEditor: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    let note: Note
    let titleField = NSTextField()
    let contentField = NSTextField()
    private let listBox = NSComboBox()
    private let pinCheck = NSButton(checkboxWithTitle: "Sematkan", target: nil, action: nil)
    private let error = UI.label("", size: 11, color: Theme.danger)
    private let cancelButton = NSButton(title: "Batal", target: nil, action: nil)
    private let saveButton = NSButton(title: "Simpan", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Hapus…", target: nil, action: nil)

    var onSave: (([String: Any]) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var busy = false { didSet { [saveButton, cancelButton, deleteButton].forEach { $0.isEnabled = !busy } } }

    init(note: Note, lists: [String]) {
        self.note = note
        super.init(frame: .zero)
        build(lists)
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    private func build(_ lists: [String]) {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.stringValue = note.title
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Judul (kosong = baris pertama isi)"
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(save)
        titleField.setAccessibilityLabel("Judul catatan")

        // Isi: teks, link, daftar — ↩ = baris baru (bukan simpan)
        contentField.stringValue = note.content
        contentField.placeholderString = "Isi: teks, link, daftar (satu butir per baris)…"
        contentField.bezelStyle = .roundedBezel
        contentField.usesSingleLineMode = false
        contentField.cell?.wraps = true
        contentField.cell?.isScrollable = false
        contentField.lineBreakMode = .byWordWrapping
        contentField.controlSize = .small
        contentField.font = small
        contentField.delegate = self
        contentField.setAccessibilityLabel("Isi catatan")
        contentField.heightAnchor.constraint(equalToConstant: 120).isActive = true

        listBox.addItems(withObjectValues: lists)
        listBox.stringValue = note.list
        listBox.placeholderString = "Kategori (opsional)"
        listBox.completes = true
        listBox.controlSize = .small
        listBox.font = small
        listBox.delegate = self
        listBox.setAccessibilityLabel("Kategori")
        listBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pinCheck.controlSize = .small
        pinCheck.font = small
        pinCheck.state = note.pinned ? .on : .off

        for b in [cancelButton, saveButton, deleteButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        cancelButton.action = #selector(cancel)
        saveButton.action = #selector(save)
        saveButton.bezelColor = Theme.accent
        deleteButton.action = #selector(deleteTapped)
        deleteButton.hasDestructiveAction = true
        error.isHidden = true
        error.lineBreakMode = .byTruncatingTail
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = []
        if note.id == 0 {
            rows.append(UI.label("Catatan baru", size: 12, weight: .semibold, color: .secondaryLabelColor))
            saveButton.title = "Simpan"
        }
        let meta = UI.stack([listBox, pinCheck], vertical: false, spacing: 8)
        var buttonViews: [NSView] = [error, NSView(), cancelButton, saveButton]
        if note.id != 0 { buttonViews.insert(deleteButton, at: 2) }
        let buttons = UI.stack(buttonViews, vertical: false, spacing: 8)
        rows += [titleField, contentField, meta, buttons]
        let form = UI.stack(rows, spacing: 8)
        for v in rows { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }

        let card = RoundedBox(fill: .controlBackgroundColor, stroke: Theme.accent, radius: 12)
        card.addSubview(form)
        UI.pin(form, to: card, top: 10, left: 10, bottom: 10, right: 10)
        addSubview(card)
        UI.pin(card, to: self, top: 4, bottom: 4)
    }

    func showError(_ text: String) {
        error.stringValue = text
        error.toolTip = text
        error.isHidden = false
    }

    @objc private func save() {
        guard !busy else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !content.isEmpty else { return showError("Isi judul atau isinya dulu.") }
        error.isHidden = true
        onSave?([
            "title": title,
            "content": content,
            "list": listBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "pinned": pinCheck.state == .on,
        ])
    }

    @objc private func cancel() { onCancel?() }
    @objc private func deleteTapped() { onDelete?() }

    /// Esc = batal; ↩ di kategori = simpan; ↩ di isi = baris baru.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        if control === listBox, selector == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        if control === contentField, selector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}
