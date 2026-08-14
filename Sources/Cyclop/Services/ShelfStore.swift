import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Cyclop puts on pasteboard writes of its own.
    static let cyclopInternal = NSPasteboard.PasteboardType("com.cyclop.internal")
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Starts as the file-type icon and is replaced by a real preview once
    /// QuickLook renders one — a shelf of identical PNG icons is useless when
    /// what it holds is screenshots.
    var icon: NSImage
    /// Filled when the shelf is looked at, not when it is loaded — reading it
    /// is a disk touch, and the shelf owes the user no prompts until then.
    var bytes: Int?
    /// Whether the file is still being made.
    ///
    /// The card appears the moment the work starts rather than when it ends.
    /// Compressing four gigabytes takes minutes, and the panel folds away as
    /// soon as the pointer leaves it — without this, the answer to "is it doing
    /// anything" was an empty shelf and no way to ask.
    var isPending = false
    /// How far along, where that can be known. Re-encoding counts frames against
    /// a duration and knows exactly; a remux is handed to the system whole and
    /// does not report back, so it shows an ellipsis rather than a number it
    /// would have to invent.
    var progress: Double?
    var name: String { url.lastPathComponent }

    /// "PNG · 1.2 MB" under the name.
    ///
    /// The type comes off the extension, so it is there from the first frame;
    /// the size arrives a moment later with the rest of the disk read. Showing
    /// the half that is free rather than waiting for both is what keeps the
    /// line from flickering in on every visit to the tab.
    var meta: String {
        let kind = url.pathExtension.uppercased()
        if isPending { return progress.map { "\(kind) · \(Int($0 * 100))%" } ?? "\(kind) · …" }
        guard let bytes else { return kind }
        return kind.isEmpty ? Converter.size(bytes) : "\(kind) · \(Converter.size(bytes))"
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so moving the original away simply removes it from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []
    /// Whether the compression rungs are on screen waiting to be chosen from.
    ///
    /// Read by the panel, which must not fold while a question it asked is still
    /// unanswered. The menu item that opens this list sits *below* the panel, so
    /// the click that opens it leaves the pointer outside — and the panel then
    /// started counting down to close before the list had finished appearing.
    @Published private(set) var isChoosing = false

    func setChoosing(_ value: Bool) { isChoosing = value }

    /// Encodes in flight, so a card removed mid-run takes its work with it.
    /// Fifteen minutes is long enough to change your mind, and a job nobody can
    /// stop would keep a core busy for all of them.
    private var jobs: [UUID: Task<Void, Never>] = [:]

    private let defaultsKey = "shelf.urls"
    /// Generous, because saved screenshots accumulate here and nothing is
    /// deleted behind the user's back. Cards past the limit leave the shelf,
    /// but their files stay in the folder.
    private let limit = 60

    /// Rebuilds the cards from the stored paths without reading a single file.
    ///
    /// Nothing here touches the disk, and that is the whole point. Since
    /// Catalina, the first look at anything inside Desktop, Documents or
    /// Downloads raises a system permission prompt — for `stat` as much as for
    /// a read — and this used to run at launch, for every card, whether or not
    /// anyone was going to open the shelf. One file dragged in from Downloads
    /// months ago meant a dialog on every cold start, arriving with no visible
    /// cause: the panel was not even open. Cyclop promises no permissions until
    /// the calendar is opened, and this quietly broke that promise.
    ///
    /// So the icon comes from the file *name* — the extension is enough to
    /// name a type, and a type is enough to draw an icon — and whether the file
    /// is still there is not asked until someone looks at the shelf.
    func load() {
        // Card ids are minted per instance, so a reload orphans any selection:
        // the ids it holds now name nothing. Kept, they showed as a phantom
        // "Selected: N" in the footer with no card marked (#10).
        selection.removeAll()
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths
            .map(URL.init(fileURLWithPath:))
            .map { ShelfItem(url: $0, icon: Self.icon(forName: $0)) }
    }

    /// An icon for a path, derived from its extension alone.
    private static func icon(forName url: URL) -> NSImage {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Called when the shelf comes into view, and only then.
    ///
    /// This is where the disk is finally touched: missing files leave, real
    /// icons and previews arrive. If a permission prompt is coming, it comes
    /// here — with the shelf on screen and the cards in front of the person
    /// being asked, which is the difference between a question and an
    /// interruption.
    func refreshFromDisk() {
        guard !items.isEmpty else { return }
        // A pending card names a file that does not exist yet, on purpose. Asked
        // about, it answers "gone" — so without this exception, opening the shelf
        // during an encode would delete the very card reporting its progress.
        let gone = Set(items.filter { !$0.isPending && Self.isGone($0.url) }.map(\.id))
        if !gone.isEmpty {
            items.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            persist()
        }
        // Sizes ride along with the reachability check above: the file has just
        // been asked about, so asking for one more attribute costs nothing and
        // raises no prompt that was not already raised.
        for index in items.indices where !items[index].isPending {
            items[index].bytes = (try? items[index].url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        items.filter { !$0.isPending }.forEach(loadThumbnail)
    }

    // MARK: - Work in progress

    /// A card for a file that is still being made.
    ///
    /// Returned by id rather than by index: the shelf reorders under it while
    /// the work runs — a drop, another conversion finishing — and an index
    /// would start pointing at somebody else's card halfway through.
    func reserve(_ url: URL, determinate: Bool) -> UUID {
        let item = ShelfItem(
            url: url, icon: Self.icon(forName: url),
            isPending: true, progress: determinate ? 0 : nil
        )
        items.insert(item, at: 0)
        return item.id
    }

    func attach(_ id: UUID, _ task: Task<Void, Never>) {
        jobs[id] = task
    }

    func advance(_ id: UUID, to progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = min(max(progress, 0), 1)
    }

    /// The file is real now: it gets its size, its preview, and a place in the
    /// stored list it was deliberately kept out of until this moment.
    func complete(_ id: UUID) {
        jobs[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPending = false
        items[index].progress = nil
        items[index].bytes = (try? items[index].url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        items[index].icon = NSWorkspace.shared.icon(forFile: items[index].url.path)
        loadThumbnail(items[index])
        persist()
    }

    /// Cancelled or failed. The card goes without a trace: it never named a
    /// file that existed, so there is nothing to leave behind.
    func abandon(_ id: UUID) {
        jobs[id] = nil
        items.removeAll { $0.id == id }
        selection.remove(id)
    }

    /// Whether the file is actually gone, as opposed to merely out of reach.
    ///
    /// `fileExists` answers false to both, and the difference matters: a card
    /// whose file was deleted should leave the shelf, while one the app was
    /// just refused access to should stay exactly where it is. Treating them
    /// alike meant a single "Don't Allow" silently emptied the shelf of
    /// everything kept in Downloads, with the files still sitting there.
    private static func isGone(_ url: URL) -> Bool {
        do {
            return try !url.checkResourceIsReachable()
        } catch let error as NSError {
            return error.code == NSFileReadNoSuchFileError
        }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            // A dropped or freshly converted file is already being read for its
            // icon, so its size comes over in the same breath — a card that
            // arrives complete never has to correct itself a moment later.
            let item = ShelfItem(
                url: url,
                icon: NSWorkspace.shared.icon(forFile: url.path),
                bytes: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            )
            items.insert(item, at: 0)
            loadThumbnail(item)
        }
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    private func loadThumbnail(_ item: ShelfItem) {
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            let image = rep.nsImage
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.url == item.url }) else { return }
                self.items[index].icon = image
            }
        }
    }

    func remove(_ item: ShelfItem) {
        // Removing a card that is still being made is how the work is called
        // off — there is no other stop button, and the ✕ already means "I do
        // not want this one".
        jobs[item.id]?.cancel()
        jobs[item.id] = nil
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ or ⇧ adds to it, matching Finder.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if selection == [item.id] {
            selection.removeAll()
        } else {
            selection = [item.id]
        }
    }

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed card belongs to it, otherwise just that card.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts the card back on the pasteboard. Images go as image data as well as
    /// a file reference, so pasting works both in Finder and in an editor.
    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The file goes on first and everything below is added to the item it
        // creates. Order is the whole of it: `setData` always writes to the
        // first item, `writeObjects` appends a new one — so marking first put
        // the picture on one item and the file on another. One card then
        // arrives as two objects, and an editor that accepts both pastes the
        // screenshot twice.
        pasteboard.writeObjects([item.url as NSURL])
        // Tells ClipboardStore this change came from us, so a copied screenshot
        // is not saved to disk a second time.
        pasteboard.setData(Data(), forType: .cyclopInternal)
        if let type = UTType(filenameExtension: item.url.pathExtension),
           type.conforms(to: .image),
           let data = try? Data(contentsOf: item.url) {
            // Declared as what the bytes are, not renamed to TIFF: consumers
            // that trust the declared type would save a "TIFF" with JPEG
            // inside (#9). The UTI is already the pasteboard type identifier.
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    /// Pending cards are deliberately absent from what is stored. Their files do
    /// not exist yet, and a crash mid-encode would otherwise leave a path in
    /// defaults that resolves to nothing on the next launch — a card that can
    /// never load and can only be removed by hand.
    private func persist() {
        UserDefaults.standard.set(items.filter { !$0.isPending }.map(\.url.path), forKey: defaultsKey)
    }
}
