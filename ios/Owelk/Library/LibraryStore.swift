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

    private enum Saved {
        static let bookmark = "sync.bookmark", library = "sync.library", device = "sync.device"
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
        // While the sync program has not mounted the folder, its marker is missing: keep the place and say so.
        let root = SyncFolder.locate(in: url) ?? url.appendingPathComponent("Owelk", isDirectory: true)
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
