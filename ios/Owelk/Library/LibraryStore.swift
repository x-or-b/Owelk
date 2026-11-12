import SwiftUI
import UIKit

/// The library as the UI sees it, and the sync folder it comes from.
///
/// The folder is one the reader picked in Files (where Synctrain keeps the computers' `Owelk` folder); a bookmark keeps
/// access to it across launches. iPadOS tells apps nothing about changes in another app's folder, so it is read again
/// when Owelk comes to the front, every 30 seconds while it is there, and on pull to refresh.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library = Library.empty
    @Published private(set) var status = ""
    @Published private(set) var failed = false
    @Published private(set) var computers: [String] = []
    @Published private(set) var folderName: String?
    @Published private(set) var syncing = false
    /// What adding papers came to, shown for a moment over the list.
    @Published var notice: Notice?

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// The paper to open from the notice, when one was added.
        var paper: Paper?
        var failed = false
    }

    /// A file to add: its name, and its bytes when they could be read.
    struct Incoming {
        let name: String
        let data: Data?
    }

    private enum Saved {
        static let bookmark = "sync.bookmark", library = "sync.library", device = "sync.device", inside = "sync.inside"
    }

    private let defaults = UserDefaults.standard
    let device: String
    private var chosen: URL?
    private var folder: SyncFolder?
    private var libraryId = ""
    private var engine: SyncEngine?
    private var timer: Timer?
    private var pictures: [String: UIImage] = [:]

    init() {
        if let saved = defaults.string(forKey: Saved.device), !saved.isEmpty {
            device = saved
        } else {
            device = UUID().uuidString.lowercased()
            defaults.set(device, forKey: Saved.device)
        }
        restore()
    }

    var hasFolder: Bool { engine != nil }

    /// What this iPad says about itself in `devices/<id>/device.json`.
    private var about: [String: String] {
        ["name": UIDevice.current.name, "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
    }

    // MARK: Folder

    /// Starts syncing with a folder chosen in Files; returns an error to show, or nil.
    func choose(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let root = SyncFolder.locate(in: url), let id = SyncFolder(root: root).library() else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return "This folder has no Owelk library. Choose the folder Synctrain keeps for Owelk (it holds owelk-sync.json), "
                + "after turning on sync on a computer."
        }
        guard let bookmark = try? url.bookmarkData() else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return "Owelk cannot keep access to this folder."
        }
        chosen?.stopAccessingSecurityScopedResource()
        defaults.set(bookmark, forKey: Saved.bookmark)
        defaults.set(id, forKey: Saved.library)
        // The chosen folder itself or its "Owelk": remembered, so a folder not there yet at launch is still found.
        defaults.set(root.standardizedFileURL.path != url.standardizedFileURL.path, forKey: Saved.inside)
        start(chosen: url, root: root, library: id)
        return nil
    }

    private func restore() {
        guard let bookmark = defaults.data(forKey: Saved.bookmark), let id = defaults.string(forKey: Saved.library) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            status = "Choose the sync folder again."
            failed = true
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: Saved.bookmark) }
        // While the sync program has not brought the folder, its marker is missing: keep the place and say so.
        let root = defaults.bool(forKey: Saved.inside) ? url.appendingPathComponent("Owelk", isDirectory: true) : url
        start(chosen: url, root: root, library: id)
    }

    private func start(chosen url: URL, root: URL, library id: String) {
        chosen = url
        folder = SyncFolder(root: root)
        libraryId = id
        folderName = url.lastPathComponent
        let storage = URL.applicationSupportDirectory.appendingPathComponent("Sync/\(id)", isDirectory: true)
        let engine = SyncEngine(storage: storage, device: device)
        self.engine = engine
        pictures = [:]
        Task {
            library = await engine.cachedLibrary()
            await refresh()
        }
        resume()
    }

    // MARK: Passes

    func refresh() async {
        guard let engine, let folder, !syncing else { return }
        syncing = true
        let outcome = await engine.pass(folder, library: libraryId, about: about)
        syncing = false
        guard engine === self.engine else { return }
        if let library = outcome.library { self.library = library }
        computers = outcome.computers
        failed = outcome.error != nil
        status = outcome.error ?? "Synced at " + Date().formatted(date: .omitted, time: .shortened)
            + (outcome.computers.isEmpty ? "" : " · " + outcome.computers.joined(separator: ", "))
    }

    /// Owelk came to the front.
    func resume() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Owelk went to the back: write what is waiting and keep the merged rows for the next launch.
    func pause() {
        timer?.invalidate()
        timer = nil
        guard let engine, let folder else { return }
        let about = about, id = libraryId
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk sync")
        Task {
            await engine.flush(folder, library: id, about: about)
            await engine.saveSnapshot()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: Papers

    func fileURL(of paper: Paper) -> URL? {
        guard paper.hasFile, let url = folder?.paper(paper.sha256) else { return nil }
        return url
    }

    func annotationImage(_ name: String) -> UIImage? {
        if let picture = pictures[name] { return picture }
        guard let url = folder?.annotationImage(name), let data = try? coordinatedRead(url, { try Data(contentsOf: $0) }),
              let picture = UIImage(data: data) else { return nil }
        pictures[name] = picture
        return picture
    }

    /// Adds PDFs picked in Files (each read with the access Files gave for it).
    func addFiles(_ urls: [URL], collection: String? = nil, tag: String? = nil) async {
        let incoming = await Task.detached {
            urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Incoming(name: url.lastPathComponent, data: try? coordinatedRead(url) { try Data(contentsOf: $0) })
            }
        }.value
        await add(incoming, collection: collection, tag: tag)
    }

    /// Adds PDFs to the library and the sync folder, into the collection or tag shown when one is.
    func add(_ incoming: [Incoming], collection: String? = nil, tag: String? = nil) async {
        guard let engine, let folder, !incoming.isEmpty else { return }
        let about = about, id = libraryId
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk add")
        defer { UIApplication.shared.endBackgroundTask(task) }
        var added: [Paper] = [], already: [Paper] = [], problems: [String] = []
        for item in incoming {
            guard let data = item.data else {
                problems.append("Cannot read “\(item.name)”.")
                continue
            }
            guard let paper = await Task.detached(operation: { NewPaper(data: data, name: item.name) }).value else {
                problems.append("“\(item.name)” is not a PDF.")
                continue
            }
            switch await engine.add(paper, to: folder, library: id, collection: collection, tag: tag) {
            case let .added(paper): added.append(paper)
            case let .already(paper): already.append(paper)
            case let .failed(problem): problems.append(problem)
            }
        }
        if !added.isEmpty || !already.isEmpty {
            library = await engine.current()
            if let problem = await engine.flush(folder, library: id, about: about) { problems.append(problem) }
        }
        var parts: [String] = []
        if added.count == 1 { parts.append("Added “\(added[0].title)”.") }
        if added.count > 1 { parts.append("Added \(added.count) papers.") }
        if already.count == 1 { parts.append("“\(already[0].title)” is already in the Library.") }
        if already.count > 1 { parts.append("\(already.count) were already in the Library.") }
        parts += problems.prefix(2)
        if problems.count > 2 { parts.append("\(problems.count - 2) more could not be added.") }
        let single = added.count + already.count == 1 ? (added.first ?? already.first) : nil
        notice = Notice(text: parts.joined(separator: " "), paper: single, failed: added.isEmpty && already.isEmpty)
    }

    /// Pen work, one change after another: a stroke drawn and at once undone is written in that order.
    private var penWork: Task<Void, Never>?

    func addStroke(id: String, to paper: Paper, page: Int, points: [CGPoint], color: String) {
        pen { engine in await engine.addStroke(id: id, to: paper, page: page, points: points, color: color) }
    }

    func addMarks(_ rows: [Row], to paper: Paper) {
        pen { engine in await engine.addMarks(rows, to: paper) }
    }

    func updateMark(_ id: String, color: String, body: String) {
        pen { engine in
            await engine.updateMark(id, color: color, body: body)
            return true
        }
    }

    func setErased(_ ids: [String], _ erased: Bool) {
        pen { engine in
            await engine.setErased(ids, erased)
            return true
        }
    }

    func setReadingState(_ value: String, of paper: Paper) { edit { await $0.setReadingState(value, of: paper) } }
    func setFavorite(_ on: Bool, of paper: Paper) { edit { await $0.setFavorite(on, of: paper) } }
    func setTag(_ tag: String, _ on: Bool, of paper: Paper) { edit { await $0.setTag(tag, on, of: paper) } }
    func setCollection(_ id: String, _ on: Bool, of paper: Paper) { edit { await $0.setCollection(id, on, of: paper) } }

    /// A new tag (or the one with that name) with the paper in it.
    func tag(_ paper: Paper, named name: String) {
        edit { engine in
            if let tag = await engine.tag(named: name) { await engine.setTag(tag, true, of: paper) }
        }
    }

    /// A new collection with the paper in it.
    func collect(_ paper: Paper, inNew name: String) {
        edit { engine in
            if let collection = await engine.collection(named: name) { await engine.setCollection(collection, true, of: paper) }
        }
    }

    /// A change to the library made here: shown at once, then written (in order with the pen's changes).
    private func edit(_ change: @escaping (SyncEngine) async -> Void) {
        guard let engine, let folder else { return }
        let about = about, id = libraryId, before = penWork
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk library")
        penWork = Task {
            await before?.value
            await change(engine)
            library = await engine.current()
            await engine.flush(folder, library: id, about: about)
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func pen(_ change: @escaping (SyncEngine) async -> Bool) {
        guard let engine, let folder else { return }
        let about = about, id = libraryId, before = penWork
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk pen")
        penWork = Task {
            await before?.value
            if await change(engine) { await engine.flush(folder, library: id, about: about) }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func position(of paper: Paper) async -> ReadingPosition? { await engine?.position(of: paper) }
    func marks(of paper: Paper) async -> [Mark] { await engine?.marks(of: paper) ?? [] }

    func opened(_ paper: Paper) {
        guard let engine, let folder else { return }
        let about = about, id = libraryId
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk recent")
        Task {
            library = await engine.saveOpened(paper)
            await engine.flush(folder, library: id, about: about)
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func save(_ position: ReadingPosition, of paper: Paper) {
        guard let engine, let folder else { return }
        let about = about, id = libraryId
        // Saved as Owelk goes to the back too: the write finishes before iPadOS suspends it.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Owelk position")
        Task {
            if await engine.savePosition(position, of: paper) { await engine.flush(folder, library: id, about: about) }
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
