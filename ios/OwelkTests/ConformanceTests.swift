import PDFKit
import XCTest
@testable import Owelk

/// The desktop and this app read and write the same sync folder with separate code. These tests use the files the
/// desktop's own test (tests/SyncConformanceTest.cpp) uses:
///
///     tests/data/sync/mac/Owelk/         written by the desktop's code
///     tests/data/sync/mac/expected.json  what that library holds there
///     tests/data/sync/ipad/<id>/         written by this app's code (OWELK_WRITE_FIXTURES=1 writes it anew),
///                                        which the desktop's test reads back
final class ConformanceTests: XCTestCase {
    static let sync = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tests/data/sync", isDirectory: true)
    static let mac = sync.appendingPathComponent("mac/Owelk", isDirectory: true)
    /// The iPad's ID and clock (2030-01-01) here, so the files it writes are always the same.
    static let ipad = "0a11ce00-0000-4000-8000-000000000001"
    static let clock: Int64 = 1_893_456_000_000

    private func expected() throws -> [String: [Row]] {
        let data = try Data(contentsOf: Self.sync.appendingPathComponent("mac/expected.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [Row]])
    }

    private func readMac() -> (SyncState, Library, SyncFolder) {
        let folder = SyncFolder(root: Self.mac)
        var state = SyncState()
        _ = folder.read(into: &state)
        return (state, Library.build(state, files: folder.paperFiles()), folder)
    }

    func testReadsTheLibraryTheDesktopWrote() throws {
        let expected = try expected()
        let (state, library, folder) = readMac()
        XCTAssertNotNil(folder.library())
        let row = try XCTUnwrap(expected["documents"]?.first)
        XCTAssertEqual(library.papers.count, 1)
        let paper = try XCTUnwrap(library.papers.first)
        XCTAssertEqual(paper.id, row.string("sha256"))
        XCTAssertEqual(paper.documentId, row.string("id"))
        XCTAssertEqual(paper.title, row.string("title"))
        XCTAssertEqual(paper.authors, row.string("authors"))
        XCTAssertEqual(paper.year, row.string("year"))
        XCTAssertEqual(paper.readingLabel, "Reading")
        XCTAssertTrue(paper.hasFile)
        XCTAssertEqual(paper.tags, ["radar", "to read"])
        XCTAssertEqual(paper.openedAt, expected["recent_documents"]?.first?.string("opened_at"))
        // Collections nest: Mapping inside Robots, and the paper is in Mapping.
        XCTAssertEqual(library.collections.map(\.name), ["Robots", "Mapping"])
        XCTAssertEqual(library.collections.map(\.depth), [0, 1])
        XCTAssertEqual(paper.collections, [library.collections[1].id])
        XCTAssertEqual(library.position(of: paper, in: state), ReadingPosition(page: 1, y: 0.25))

        let marks = state.entries("highlights").values.compactMap { $0.row.flatMap(Mark.init(row:)) }
        let rows = try XCTUnwrap(expected["highlights"])
        XCTAssertEqual(marks.count, rows.count)
        for row in rows {
            let mark = try XCTUnwrap(marks.first { $0.id == row.string("id") })
            XCTAssertEqual(mark.kind, row.string("kind"))
            XCTAssertEqual(mark.page, row.int("page"))
            XCTAssertEqual(mark.body, row.string("body"))
            XCTAssertEqual(mark.rectangles.count, (JSON.value(row.string("rectangles")) as? [Any])?.count)
            XCTAssertEqual(mark.drawing.count, (JSON.value(row.string("drawing")) as? [Any])?.count)
            if mark.kind == "image" { XCTAssertNotNil(folder.annotationImage(mark.image).flatMap { UIImage(contentsOfFile: $0.path) }) }
        }
        XCTAssertTrue(marks.contains { $0.kind == "highlight" && $0.rectangles.count >= 2 && $0.hasNote })
    }

    func testReadingAgainOrFromTheSnapshotChangesNothing() throws {
        let (state, library, folder) = readMac()
        var again = state
        XCTAssertEqual(folder.read(into: &again).applied, 0)
        let restored = try XCTUnwrap(SyncState(snapshot: try XCTUnwrap(state.snapshot())))
        XCTAssertEqual(restored.read, state.read)
        XCTAssertEqual(Library.build(restored, files: folder.paperFiles()).papers, library.papers)
    }

    /// The rows this iPad writes, as the desktop's test reads them back: where the paper was left, and when it was
    /// opened. A row keeps what it had and only the known columns change (the Mac's zoom and fit stay).
    func testWritesWhatTheDesktopReads() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let drive = temporary.appendingPathComponent("Owelk", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.mac, to: drive)
        let folder = SyncFolder(root: drive)
        let library = try XCTUnwrap(folder.library())
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: Self.ipad, clock: { Self.clock })
        let about = ["name": "iPad", "system": "iPadOS"]
        _ = await engine.pass(folder, library: library, about: about)
        let cached = await engine.cachedLibrary()
        let paper = try XCTUnwrap(cached.papers.first)
        await engine.saveOpened(paper, at: Date(timeIntervalSince1970: TimeInterval(Self.clock / 1000)))
        let moved = await engine.savePosition(ReadingPosition(page: 2, y: 0.5), of: paper)
        XCTAssertTrue(moved)
        let again = await engine.savePosition(ReadingPosition(page: 2, y: 0.5), of: paper)
        XCTAssertFalse(again, "the same place is not written twice")
        let failure = await engine.flush(folder, library: library, about: about)
        XCTAssertNil(failure)
        let position = await engine.position(of: paper)
        XCTAssertEqual(position, ReadingPosition(page: 2, y: 0.5))

        let written = drive.appendingPathComponent("devices/\(Self.ipad)", isDirectory: true)
        let committed = Self.sync.appendingPathComponent("ipad/\(Self.ipad)", isDirectory: true)
        if ProcessInfo.processInfo.environment["OWELK_WRITE_FIXTURES"] != nil {
            try? FileManager.default.removeItem(at: committed)
            try FileManager.default.createDirectory(at: committed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: written, to: committed)
        }
        let lines = try Self.lines(written.appendingPathComponent("00000001.jsonl"))
        XCTAssertEqual(lines, try Self.lines(committed.appendingPathComponent("00000001.jsonl")),
                       "the iPad's change file differs from tests/data/sync/ipad: run with OWELK_WRITE_FIXTURES=1 and check the desktop's sync_conformance test")
        XCTAssertEqual(lines.map { $0["t"] as? String }, ["recent_documents", "reading_positions"])
        let row = try XCTUnwrap(lines[1]["r"] as? Row)
        XCTAssertEqual(Set(row.keys), ["document_id", "position"])
        XCTAssertEqual(row.string("document_id"), paper.documentId)
        let json = try XCTUnwrap(JSON.value(row.string("position")) as? Row)
        XCTAssertEqual(json.int("page"), 2)
        XCTAssertEqual(json.double("y"), 0.5)
        XCTAssertEqual(json.string("fit"), "width")
        XCTAssertEqual(json.double("zoom"), 1)
        XCTAssertEqual((lines[0]["r"] as? Row)?.string("opened_at"), "2030-01-01T00:00:00.000Z")
        XCTAssertEqual(folder.computers(except: "nobody").sorted(), ["Mac", "iPad"])
    }

    private static func lines(_ url: URL) throws -> [NSDictionary] {
        try Data(contentsOf: url).split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? NSDictionary)
        }
    }
}

/// The rules the desktop's LibrarySync follows, checked on this app's code.
final class SyncRuleTests: XCTestCase {
    private func change(_ table: String = "notes", _ id: String = "a", _ time: Int64, _ device: String,
                        _ row: Row? = nil) -> Change {
        Change(table: table, key: [id], version: Version(time: time, device: device), row: row)
    }

    func testNewestWinsAndTheLargerDeviceBreaksATie() {
        var state = SyncState()
        let row: (String) -> Row = { ["id": "a", "title": $0] }
        XCTAssertTrue(state.apply(change("tags", "a", 10, "m", row("first"))))
        XCTAssertFalse(state.apply(change("tags", "a", 9, "z", row("older"))))
        XCTAssertFalse(state.apply(change("tags", "a", 10, "a", row("same time, smaller device"))))
        XCTAssertTrue(state.apply(change("tags", "a", 10, "m", row("the same version again"))))
        XCTAssertTrue(state.apply(change("tags", "a", 10, "z", row("same time, larger device"))))
        XCTAssertEqual(state.entry("tags", key: ["a"])?.row?.string("title"), "same time, larger device")
        XCTAssertTrue(state.apply(change("tags", "a", 11, "b")))
        XCTAssertNil(state.entry("tags", key: ["a"])?.row, "a removal travels as a row without contents")
        XCTAssertFalse(state.apply(change("notes", "a", 99, "z", row("a table this app does not keep"))))
    }

    func testAnUnfinishedLineWaitsForTheRestOfTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = root.appendingPathComponent("devices/m", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let file = device.appendingPathComponent("00000001.jsonl")
        var line = change("tags", "a", 1, "m", ["id": "a", "name": "radar"]).line()
        line.removeLast()
        try line.write(to: file)
        var state = SyncState()
        let folder = SyncFolder(root: root)
        XCTAssertEqual(folder.read(into: &state).applied, 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + Data("{damaged\n".utf8))
        try handle.close()
        XCTAssertEqual(folder.read(into: &state).applied, 1, "the line completes; a damaged one is passed over")
        XCTAssertEqual(state.entry("tags", key: ["a"])?.row?.string("name"), "radar")
    }

    func testChangeFilesStopAtTheSizeLimitWithWholeLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SyncFolder(root: root)
        let filler = String(repeating: "x", count: 1000)
        let lines = (0..<400).reduce(into: Data()) { data, i in
            data.append(change("tags", "t\(i)", Int64(i), "ipad", ["id": "t\(i)", "name": filler]).line())
        }
        try folder.append(lines, device: "ipad", about: ["name": "iPad"])
        try folder.append(change("tags", "last", 500, "ipad", ["id": "last", "name": "z"]).line(), device: "ipad",
                          about: ["name": "iPad"])
        let device = root.appendingPathComponent("devices/ipad", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: device.path).filter { $0.hasSuffix(".jsonl") }.sorted()
        XCTAssertEqual(names, ["00000001.jsonl", "00000002.jsonl"])
        for name in names {
            let data = try Data(contentsOf: device.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, SyncProtocol.segmentLimit)
            XCTAssertEqual(data.last, 0x0A)
        }
        var state = SyncState()
        XCTAssertEqual(folder.read(into: &state).applied, 401)
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.appendingPathComponent("device.json").path))
    }
}

/// Marks land where the desktop puts them.
final class MarkGeometryTests: XCTestCase {
    /// `Page::point` in src/AnnotatedPdf.cpp, written out again.
    private func desktop(_ fx: CGFloat, _ fy: CGFloat, _ box: CGRect, _ rotation: Int) -> CGPoint {
        let (l, b, w, h) = (box.minX, box.minY, box.width, box.height)
        let turned = rotation == 90 || rotation == 270
        let X = fx * (turned ? h : w), Y = fy * (turned ? w : h)
        var u = X, v = h - Y
        if rotation == 90 { (u, v) = (Y, X) } else if rotation == 180 { (u, v) = (w - X, Y) } else if rotation == 270 {
            (u, v) = (w - Y, h - X)
        }
        return CGPoint(x: l + u, y: b + v)
    }

    func testPageFractionsTurnWithThePage() {
        let box = CGRect(x: 12, y: 30, width: 600, height: 800)
        for rotation in [0, 90, 180, 270, -90, 450] {
            let geometry = PageGeometry(box: box, rotation: rotation)
            for (fx, fy) in [(0.0, 0.0), (1.0, 1.0), (0.25, 0.75), (0.9, 0.1)] {
                let point = geometry.point(CGPoint(x: fx, y: fy))
                let expected = desktop(fx, fy, box, ((rotation % 360) + 360) % 360)
                XCTAssertEqual(point.x, expected.x, accuracy: 1e-6)
                XCTAssertEqual(point.y, expected.y, accuracy: 1e-6)
                let back = geometry.fraction(point)
                XCTAssertEqual(back.x, fx, accuracy: 1e-9)
                XCTAssertEqual(back.y, fy, accuracy: 1e-9)
            }
        }
    }

    /// The desktop's highlight tints the page where its rectangle is; the pen draws where its points are.
    func testMarksAreDrawnOnTheirPlaces() throws {
        let folder = SyncFolder(root: ConformanceTests.mac)
        var state = SyncState()
        _ = folder.read(into: &state)
        let paper = try XCTUnwrap(Library.build(state, files: folder.paperFiles()).papers.first)
        let document = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(folder.paper(paper.sha256))))
        let marks = state.entries("highlights").values.compactMap { $0.row.flatMap(Mark.init(row:)) }
        for kind in ["highlight", "draw"] {
            let mark = try XCTUnwrap(marks.first { $0.kind == kind })
            let page = try XCTUnwrap(document.page(at: mark.page))
            let geometry = PageGeometry(page)
            // A stroke passes through the midpoints between its samples.
            let spot = kind == "draw"
                ? CGPoint(x: (mark.drawing[1].x + mark.drawing[2].x) / 2, y: (mark.drawing[1].y + mark.drawing[2].y) / 2)
                : CGPoint(x: mark.rectangles[0].midX, y: mark.rectangles[0].midY)
            let before = Self.color(of: page, at: geometry.point(spot))
            page.addAnnotation(MarkAnnotation(mark: mark, geometry: geometry, picture: nil))
            let after = Self.color(of: page, at: geometry.point(spot))
            // Yellow over the page takes blue away; the pink pen takes green away.
            if kind == "highlight" { XCTAssertLessThan(after.blue, before.blue - 20, "\(before) → \(after)") }
            else { XCTAssertLessThan(after.green, before.green - 40, "\(before) → \(after)") }
        }
    }

    /// The average color of a 5-point square of the page around a point in page space.
    private static func color(of page: PDFPage, at point: CGPoint) -> (red: Double, green: Double, blue: Double) {
        let box = page.bounds(for: .cropBox)
        let width = Int(box.width), height = Int(box.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: context)
        }
        var sum = (0.0, 0.0, 0.0), count = 0.0
        let cx = Int(point.x - box.minX), cy = height - 1 - Int(point.y - box.minY)
        for y in max(0, cy - 2)...min(height - 1, cy + 2) {
            for x in max(0, cx - 2)...min(width - 1, cx + 2) {
                let i = (y * width + x) * 4
                sum = (sum.0 + Double(pixels[i]), sum.1 + Double(pixels[i + 1]), sum.2 + Double(pixels[i + 2]))
                count += 1
            }
        }
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }
}

/// The reader opens where the paper was left, and says where it is in the same terms.
@MainActor
final class ReaderPositionTests: XCTestCase {
    func testComesBackWhereThePaperWasLeft() throws {
        let folder = SyncFolder(root: ConformanceTests.mac)
        var state = SyncState()
        _ = folder.read(into: &state)
        let paper = try XCTUnwrap(Library.build(state, files: folder.paperFiles()).papers.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let controller = ReaderViewController()
        controller.start = ReadingPosition(page: 1, y: 0.3)
        controller.document = PDFDocument(url: try XCTUnwrap(folder.paper(paper.sha256)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let position = try XCTUnwrap(controller.position())
        XCTAssertEqual(position.page, 1)
        XCTAssertEqual(position.y, 0.3, accuracy: 0.02)
    }
}
