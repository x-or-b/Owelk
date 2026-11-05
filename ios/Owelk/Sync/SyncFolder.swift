import Foundation

/// The `Owelk` folder that a sync program (Synctrain here, Syncthing on the computers) keeps the same everywhere:
///
///     owelk-sync.json          the library's marker
///     devices/<id>/*.jsonl     each computer's change files (each writes only its own)
///     Papers/<sha256>.pdf      the PDFs
///     Files/annotations/<name> pictures placed on pages
///
/// Reads and writes go through `NSFileCoordinator`, so files a file provider has not brought down yet are fetched.
struct SyncFolder {
    let root: URL

    /// The Owelk folder in a folder the reader chose: that folder itself when it holds the marker, else its `Owelk`.
    static func locate(in chosen: URL) -> URL? {
        for candidate in [chosen, chosen.appendingPathComponent("Owelk", isDirectory: true)] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(SyncProtocol.marker).path) {
                return candidate
            }
        }
        return nil
    }

    var devices: URL { root.appendingPathComponent("devices", isDirectory: true) }

    /// The library this folder belongs to, from its marker; nil while the folder is not there (sync program off).
    func library() -> String? {
        let data = try? coordinatedRead(root.appendingPathComponent(SyncProtocol.marker)) { try Data(contentsOf: $0) }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return (object?["library"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func paper(_ sha256: String) -> URL? {
        SyncProtocol.isSha256(sha256) ? root.appendingPathComponent("Papers/\(sha256).pdf") : nil
    }

    func annotationImage(_ name: String) -> URL? {
        SyncProtocol.isPlainName(name) ? root.appendingPathComponent("Files/annotations/\(name)") : nil
    }

    /// The fingerprints of the PDFs that have arrived.
    func paperFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Papers").path)) ?? []
        return Set(names.compactMap { name in
            name.hasSuffix(".pdf") ? String(name.dropLast(4)) : nil
        }.filter(SyncProtocol.isSha256))
    }

    /// The names of the other computers, from their `device.json`.
    func computers(except device: String) -> [String] {
        deviceFolders().filter { $0.lastPathComponent != device }.map { folder in
            let data = try? Data(contentsOf: folder.appendingPathComponent("device.json"))
            let about = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return (about?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(folder.lastPathComponent.prefix(8))
        }
    }

    private func deviceFolders() -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct ReadOutcome {
        var applied = 0
        var tables = Set<String>()
    }

    /// Applies what every computer (this one too) added since the last read. Change files only grow, so each is read
    /// from where the last read stopped; an unfinished last line waits for the rest of the file.
    func read(into state: inout SyncState) -> ReadOutcome {
        var outcome = ReadOutcome()
        for folder in deviceFolders() {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
            for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let mark = folder.lastPathComponent + "/" + file.lastPathComponent
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                var offset = state.read[mark] ?? 0
                if size == offset { continue }
                if size < offset { offset = 0 } // Written anew: read it all again (applying the same version twice is harmless).
                guard let data = try? coordinatedRead(file, { url -> Data in
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    return try handle.readToEnd() ?? Data()
                }), let end = data.lastIndex(of: 0x0A) else { continue } // Still arriving; read on the next pass.
                var start = data.startIndex
                while start <= end {
                    let stop = data[start...end].firstIndex(of: 0x0A) ?? end
                    if stop > start, let change = Change(line: data[start..<stop]), state.apply(change) {
                        outcome.applied += 1
                        outcome.tables.insert(change.table)
                    }
                    start = stop + 1
                }
                state.read[mark] = offset + (end - data.startIndex) + 1
            }
        }
        return outcome
    }

    /// Appends change lines to this computer's own files, as the desktop's `writeSegments` does: the last file goes on
    /// while it is under the size limit and ends with a whole line, and each file holds whole lines only.
    func append(_ lines: Data, device: String, about: [String: String]) throws {
        let manager = FileManager.default
        let folder = devices.appendingPathComponent(device, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let aboutFile = folder.appendingPathComponent("device.json")
        if !manager.fileExists(atPath: aboutFile.path) {
            let data = try JSONSerialization.data(withJSONObject: about, options: [.prettyPrinted, .sortedKeys])
            try coordinatedWrite(aboutFile) { try data.write(to: $0, options: .atomic) }
        }
        let existing = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        var sequence = existing.last.flatMap { Int($0.dropLast(6)) } ?? 1
        if let last = existing.last {
            let url = folder.appendingPathComponent(last)
            let size = Self.size(url)
            let whole = size < SyncProtocol.segmentLimit && (size == 0 || Self.lastByte(url) == 0x0A)
            if !whole { sequence += 1 }
        }
        var start = lines.startIndex
        while start < lines.endIndex {
            let url = folder.appendingPathComponent(SyncProtocol.segmentName(sequence))
            let size = Self.size(url)
            var end = start
            while end < lines.endIndex {
                let next = (lines[end...].firstIndex(of: 0x0A) ?? lines.endIndex - 1) + 1
                if end > start && size + (next - start) > SyncProtocol.segmentLimit { break }
                end = next
            }
            let chunk = lines[start..<end]
            try coordinatedWrite(url) { url in
                if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: chunk)
                try handle.synchronize()
            }
            start = end
            if start < lines.endIndex { sequence += 1 }
        }
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func lastByte(_ url: URL) -> UInt8? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        try? handle.seek(toOffset: end - 1)
        return (try? handle.read(upToCount: 1))?.first
    }
}

func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
    var failure: NSError?
    var result: Result<T, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &failure) { url in
        result = Result { try body(url) }
    }
    if let failure { throw failure }
    return try result.get()
}

func coordinatedWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
    var failure: NSError?
    var result: Result<Void, Error> = .success(())
    NSFileCoordinator().coordinate(writingItemAt: url, options: [.forMerging], error: &failure) { url in
        result = Result { try body(url) }
    }
    if let failure { throw failure }
    try result.get()
}
