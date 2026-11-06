import Network
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
    /// The ID of the paper this iPad adds.
    static let addedId = "0a11ce00-0000-4000-8000-00000000a001"
    /// The pen stroke this iPad draws on the Mac's paper, and the Mac's own pen mark it erases.
    static let strokeId = "0a11ce00-0000-4000-8000-00000000b001"
    static let macStroke = "4c08b2b3-27fd-40fe-9175-8f82166b1ed0"
    static let strokePoints = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.15), CGPoint(x: 0.3, y: 0.2)]
    /// The PDF it adds (tests/data/sync/ipad/Papers), with a title of its own.
    static let addedPdf = sync.appendingPathComponent(
        "ipad/Papers/e549b32af3d995d3d7d8b61f5c7b8f3af29ca1df65a1618884a400c14a19a263.pdf")

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

    /// The rows this iPad writes, as the desktop's test reads them back: where the paper was left, when it was
    /// opened, and a paper added here into the Mac's collection and tag. A row keeps what it had and only the known
    /// columns change (the Mac's zoom and fit stay).
    func testWritesWhatTheDesktopReads() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let drive = temporary.appendingPathComponent("Owelk", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.mac, to: drive)
        let folder = SyncFolder(root: drive)
        let library = try XCTUnwrap(folder.library())
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: Self.ipad, clock: { Self.clock },
                                newId: { Self.addedId })
        let about = ["name": "iPad", "system": "iPadOS"]
        _ = await engine.pass(folder, library: library, about: about)
        let cached = await engine.cachedLibrary()
        let paper = try XCTUnwrap(cached.papers.first)
        await engine.saveOpened(paper, at: Date(timeIntervalSince1970: TimeInterval(Self.clock / 1000)))
        let moved = await engine.savePosition(ReadingPosition(page: 2, y: 0.5), of: paper)
        XCTAssertTrue(moved)
        let again = await engine.savePosition(ReadingPosition(page: 2, y: 0.5), of: paper)
        XCTAssertFalse(again, "the same place is not written twice")
        let drawn = await engine.addStroke(id: Self.strokeId, to: paper, page: 1, points: Self.strokePoints,
                                           color: "#54a878")
        XCTAssertTrue(drawn)
        await engine.setErased([Self.macStroke], true)
        await engine.setErased([Self.macStroke], true)
        let marks = await engine.marks(of: paper).map(\.id)
        XCTAssertTrue(marks.contains(Self.strokeId))
        XCTAssertFalse(marks.contains(Self.macStroke), "erased")

        let pdf = try Data(contentsOf: Self.addedPdf)
        let newPaper = try XCTUnwrap(NewPaper(data: pdf, name: "Long Halls.pdf"))
        let mapping = try XCTUnwrap(cached.collections.first { $0.name == "Mapping" }?.id)
        let radar = try XCTUnwrap(cached.tags.first { $0.name == "radar" }?.id)
        guard case let .added(added) = await engine.add(newPaper, to: folder, library: library, collection: mapping, tag: radar)
        else { return XCTFail("the PDF is added") }
        XCTAssertEqual(added.title, "Echoes in Long Halls")
        XCTAssertEqual(added.documentId, Self.addedId)
        XCTAssertTrue(added.hasFile)
        XCTAssertEqual(added.collections, [mapping])
        XCTAssertEqual(added.tags, ["radar"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(folder.paper(newPaper.sha256))), pdf)
        guard case .already = await engine.add(newPaper, to: folder, library: library, collection: mapping, tag: radar)
        else { return XCTFail("the same PDF is not added twice") }
        // The Mac's own paper, from another copy of its PDF: already there, nothing written.
        let macPdf = try Data(contentsOf: try XCTUnwrap(folder.paper(paper.sha256)))
        guard case let .already(same) = await engine.add(try XCTUnwrap(NewPaper(data: macPdf, name: "copy.pdf")),
                                                         to: folder, library: library)
        else { return XCTFail("a PDF the Mac has is not added again") }
        XCTAssertEqual(same.documentId, paper.documentId)
        let papers = await engine.current().papers
        XCTAssertEqual(papers.count, 2)

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
        var lines = try Self.lines(written.appendingPathComponent("00000001.jsonl"))
        XCTAssertEqual(lines, try Self.lines(committed.appendingPathComponent("00000001.jsonl")),
                       "the iPad's change file differs from tests/data/sync/ipad: run with OWELK_WRITE_FIXTURES=1 and check the desktop's sync_conformance test")
        XCTAssertEqual(lines.map { $0["t"] as? String },
                       ["documents", "highlights", "highlights", "recent_documents", "reading_positions",
                        "collection_documents", "document_tags"])
        // The stroke with every column the desktop writes for one, the Mac's mark with only `deleted_at` changed.
        let macMark = try XCTUnwrap(try expected()["highlights"]?.first { $0.string("id") == Self.macStroke })
        let marksWritten = lines.filter { $0["t"] as? String == "highlights" }.compactMap { $0["r"] as? Row }
        let stroke = try XCTUnwrap(marksWritten.first { $0.string("id") == Self.strokeId })
        XCTAssertEqual(Set(stroke.keys), Set(macMark.keys))
        XCTAssertEqual(stroke.string("kind"), "draw")
        XCTAssertEqual(stroke.string("color"), "#54a878")
        XCTAssertEqual(stroke.int("page"), 1)
        XCTAssertEqual(stroke.string("document_id"), paper.documentId)
        XCTAssertEqual(stroke.string("sha256"), paper.sha256)
        XCTAssertEqual(stroke.int("start_index"), -1)
        XCTAssertEqual(stroke.string("created_at"), "2030-01-01T00:00:00.000Z")
        XCTAssertTrue(isNull(stroke["deleted_at"]))
        let points = try XCTUnwrap(JSON.value(stroke.string("drawing")) as? [Row]).map {
            CGPoint(x: $0.double("x"), y: $0.double("y"))
        }
        XCTAssertEqual(points, Self.strokePoints)
        let box = try XCTUnwrap((JSON.value(stroke.string("rectangles")) as? [Row])?.first)
        XCTAssertEqual(box.double("x"), 0.1)
        XCTAssertEqual(box.double("width"), 0.2)
        XCTAssertEqual(box.double("height"), 0.1)
        let erased = try XCTUnwrap(marksWritten.first { $0.string("id") == Self.macStroke })
        XCTAssertEqual(erased.string("deleted_at"), "2030-01-01T00:00:00.000Z")
        for key in macMark.keys where key != "deleted_at" {
            XCTAssertEqual(erased[key] as? NSObject, macMark[key] as? NSObject, key)
        }
        lines.removeAll { $0["t"] as? String == "highlights" }
        let document = try XCTUnwrap(lines[0]["r"] as? Row)
        // Every column the desktop sends for a paper, so a computer that inserts it has them all.
        let macRow = try XCTUnwrap(try expected()["documents"]?.first)
        XCTAssertEqual(Set(document.keys), Set(macRow.keys))
        XCTAssertEqual(document.string("url"), "file:///Long%20Halls.pdf")
        XCTAssertEqual(document.string("sha256"), newPaper.sha256)
        XCTAssertEqual(document.string("metadata_origin"), "", "the computers read the rest of the details")
        XCTAssertEqual(document.string("added_at"), "2030-01-01T00:00:00.000Z")
        lines.removeFirst()
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

    /// The desktop's highlight tints the page where its rectangle is; the pen draws where its points are (drawn by the
    /// reader's page overlay, over the page).
    @MainActor
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
            let shape = try XCTUnwrap(MarkShape.layer(mark, on: OverlayGeometry(page)))
            let after = Self.color(of: page, at: geometry.point(spot), under: shape)
            // Yellow over the page takes blue away; the pink pen takes green away.
            if kind == "highlight" { XCTAssertLessThan(after.blue, before.blue - 20, "\(before) → \(after)") }
            else { XCTAssertLessThan(after.green, before.green - 40, "\(before) → \(after)") }
        }
    }

    /// The average color of a 5-point square of the page around a point in page space, with an overlay's layer over it.
    private static func color(of page: PDFPage, at point: CGPoint,
                              under overlay: CALayer? = nil) -> (red: Double, green: Double, blue: Double) {
        let box = page.bounds(for: .cropBox)
        let width = Int(box.width), height = Int(box.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: context)
            // The overlay is the unturned crop box from its top left, y down.
            context.translateBy(x: box.minX, y: box.maxY)
            context.scaleBy(x: 1, y: -1)
            overlay?.render(in: context)
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

    /// As the app opens a paper: the reader is on screen first, and the PDF arrives once it has been read.
    func testComesBackWhenThePdfArrivesAfterTheViewIsShown() throws {
        let folder = SyncFolder(root: ConformanceTests.mac)
        var state = SyncState()
        _ = folder.read(into: &state)
        let paper = try XCTUnwrap(Library.build(state, files: folder.paperFiles()).papers.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let controller = ReaderViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.start = ReadingPosition(page: 2, y: 0.1)
        controller.document = PDFDocument(url: try XCTUnwrap(folder.paper(paper.sha256)))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let position = try XCTUnwrap(controller.position())
        XCTAssertEqual(position.page, 2)
        // The last page cannot scroll its top quite that far up.
        XCTAssertEqual(position.y, 0.1, accuracy: 0.03)
    }
}

/// Adding a PDF on the iPad, as the desktop does it.
final class AddPaperTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ConformanceTests.mac, to: temporary.appendingPathComponent("Owelk"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: temporary) }

    private var folder: SyncFolder { SyncFolder(root: temporary.appendingPathComponent("Owelk")) }

    /// A paper taken out of the Library comes back under its own row, everything else as it was.
    func testAPaperTakenOutComesBack() async throws {
        let library = try XCTUnwrap(folder.library())
        var state = SyncState()
        _ = folder.read(into: &state)
        var row = try XCTUnwrap(state.entries("documents").values.compactMap(\.row).first)
        row["removed_at"] = "2030-01-01T00:00:00.000Z"
        let removal = Change(table: "documents", key: [row.string("id")],
                             version: Version(time: ConformanceTests.clock, device: "ffffffff-0000-4000-8000-000000000000"),
                             row: row)
        try folder.append(removal.line(), device: "ffffffff-0000-4000-8000-000000000000", about: ["name": "Ubuntu"])
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: ConformanceTests.ipad,
                                clock: { ConformanceTests.clock + 5 })
        _ = await engine.pass(folder, library: library, about: [:])
        let before = await engine.current().papers
        XCTAssertTrue(before.isEmpty, "taken out of the Library")

        let pdf = try Data(contentsOf: try XCTUnwrap(folder.paper(row.string("sha256"))))
        guard case let .added(paper) = await engine.add(try XCTUnwrap(NewPaper(data: pdf, name: "Again.pdf")), to: folder,
                                                        library: library)
        else { return XCTFail("the paper comes back") }
        XCTAssertEqual(paper.documentId, row.string("id"))
        XCTAssertEqual(paper.title, "Occlusion in Small Rooms", "its details stay")
        let failure = await engine.flush(folder, library: library, about: [:])
        XCTAssertNil(failure)
        let written = try Data(contentsOf: folder.devices.appendingPathComponent("\(ConformanceTests.ipad)/00000001.jsonl"))
        let back = try XCTUnwrap(Change(line: written.dropLast()))
        XCTAssertEqual(back.table, "documents")
        XCTAssertTrue(isNull(back.row?["removed_at"]))
        XCTAssertEqual(back.row?.string("authors"), row.string("authors"))
        XCTAssertGreaterThan(back.version.time, ConformanceTests.clock)
    }

    /// A paper deleted for good on a computer: the same PDF added here is a new paper, not the old one back.
    func testAPaperDeletedForGoodComesBackNew() async throws {
        let library = try XCTUnwrap(folder.library())
        var state = SyncState()
        _ = folder.read(into: &state)
        let row = try XCTUnwrap(state.entries("documents").values.compactMap(\.row).first)
        let file = try XCTUnwrap(folder.paper(row.string("sha256")))
        let pdf = try Data(contentsOf: file)
        let gone = Change(table: "documents", key: [row.string("id")],
                          version: Version(time: ConformanceTests.clock, device: "ffffffff-0000-4000-8000-000000000000"),
                          row: nil)
        try folder.append(gone.line(), device: "ffffffff-0000-4000-8000-000000000000", about: ["name": "Ubuntu"])
        try FileManager.default.removeItem(at: file)
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: ConformanceTests.ipad,
                                clock: { ConformanceTests.clock + 5 }, newId: { ConformanceTests.addedId })
        _ = await engine.pass(folder, library: library, about: [:])
        let before = await engine.current().papers
        XCTAssertTrue(before.isEmpty, "deleted for good")

        guard case let .added(paper) = await engine.add(try XCTUnwrap(NewPaper(data: pdf, name: "Again.pdf")), to: folder,
                                                        library: library)
        else { return XCTFail("the PDF is added") }
        XCTAssertEqual(paper.documentId, ConformanceTests.addedId)
        XCTAssertEqual(paper.readingState, "unread")
        XCTAssertTrue(paper.hasFile)
        XCTAssertEqual(try Data(contentsOf: file), pdf)
    }

    /// A listed paper whose PDF left the folder: adding the same PDF puts the file back, and adds no paper.
    func testAddingAPaperWhosePdfIsGonePutsItBack() async throws {
        let library = try XCTUnwrap(folder.library())
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: ConformanceTests.ipad)
        _ = await engine.pass(folder, library: library, about: [:])
        let listed = await engine.current().papers
        let paper = try XCTUnwrap(listed.first)
        let file = try XCTUnwrap(folder.paper(paper.sha256))
        let pdf = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        _ = await engine.pass(folder, library: library, about: [:])
        let waiting = await engine.current().papers
        XCTAssertEqual(waiting.first?.hasFile, false)
        guard case let .already(back) = await engine.add(try XCTUnwrap(NewPaper(data: pdf, name: "copy.pdf")), to: folder,
                                                         library: library)
        else { return XCTFail("the paper is there already") }
        XCTAssertTrue(back.hasFile)
        XCTAssertEqual(try Data(contentsOf: file), pdf)
        let papers = await engine.current().papers
        XCTAssertEqual(papers.count, 1)
    }

    func testNothingIsAddedWhileTheFolderIsAway() async throws {
        let engine = SyncEngine(storage: temporary.appendingPathComponent("app"), device: ConformanceTests.ipad)
        let pdf = try XCTUnwrap(NewPaper(data: try Data(contentsOf: ConformanceTests.addedPdf), name: "a.pdf"))
        guard case .failed = await engine.add(pdf, to: folder, library: "another library") else {
            return XCTFail("a folder that is not the library's is left alone")
        }
        XCTAssertNil(folder.paper(pdf.sha256).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    func testOnlyPdfsAreAdded() throws {
        XCTAssertNil(NewPaper(data: Data("not a pdf".utf8), name: "notes.pdf"))
        let pdf = try XCTUnwrap(NewPaper(data: try Data(contentsOf: ConformanceTests.addedPdf), name: ""))
        XCTAssertEqual(pdf.name, String(pdf.sha256.prefix(16)) + ".pdf")
        XCTAssertEqual(NewPaper.fileName("Notes", sha256: pdf.sha256), "Notes.pdf")
        XCTAssertEqual(NewPaper.fileName("../a/Paper.PDF", sha256: pdf.sha256), "Paper.PDF")
    }

    func testTitlesThatAreNotTitlesAreLeftOut() {
        XCTAssertTrue(NewPaper.usableTitle("Echoes in Long Halls", fileName: "x.pdf"))
        for title in ["Microsoft Word - draft.docx", "untitled", "main", "Draft 2", "paper.pdf", "abc", "/Users/a/b", "x"] {
            XCTAssertFalse(NewPaper.usableTitle(title, fileName: "x.pdf"), title)
        }
        XCTAssertFalse(NewPaper.usableTitle("Long Halls", fileName: "Long Halls.pdf"), "the file's own name")
    }
}

/// Finding papers on the web.
@MainActor
final class WebSearchTests: XCTestCase {
    func testTheAddressFieldSearchesOrOpens() {
        let scholar = SearchEngine.scholar
        XCTAssertEqual(scholar.address("attention is all you need")?.absoluteString,
                       "https://scholar.google.com/scholar?q=attention%20is%20all%20you%20need")
        XCTAssertEqual(SearchEngine.arxiv.address("c++ & graphs")?.absoluteString,
                       "https://arxiv.org/search/?query=c%2B%2B%20%26%20graphs&searchtype=all")
        XCTAssertEqual(scholar.address("arxiv.org/abs/1706.03762")?.absoluteString, "https://arxiv.org/abs/1706.03762")
        XCTAssertEqual(scholar.address("https://example.org/a.pdf")?.absoluteString, "https://example.org/a.pdf")
        XCTAssertEqual(scholar.address("10.1145/3292500.3330701")?.absoluteString, "https://doi.org/10.1145/3292500.3330701")
        XCTAssertEqual(scholar.address("1706.03762v7")?.absoluteString, "https://arxiv.org/abs/1706.03762v7")
        XCTAssertEqual(scholar.address("e.g.")?.absoluteString, "https://scholar.google.com/scholar?q=e.g.")
        XCTAssertNil(scholar.address("  "))
    }

    func testAnArxivAbstractLeadsToItsPdf() {
        XCTAssertEqual(SearchEngine.arxivPdf(URL(string: "https://arxiv.org/abs/1706.03762v7?context=cs"))?.absoluteString,
                       "https://arxiv.org/pdf/1706.03762v7")
        XCTAssertEqual(SearchEngine.arxivPdf(URL(string: "https://www.arxiv.org/abs/hep-th/9901001"))?.absoluteString,
                       "https://arxiv.org/pdf/hep-th/9901001")
        XCTAssertNil(SearchEngine.arxivPdf(URL(string: "https://arxiv.org/pdf/1706.03762")))
        XCTAssertNil(SearchEngine.arxivPdf(nil))
    }

    /// A page that is a PDF offers to add it, and adding fetches it again and hands its bytes over.
    func testAPageThatIsAPdfCanBeAdded() async throws {
        let bytes = try Data(contentsOf: ConformanceTests.addedPdf)
        let server = try await PdfServer.start(serving: bytes)
        defer { server.stop() }
        let page = WebPage()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(page.webView)
        page.webView.frame = window.bounds
        let address = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/Long%20Halls.pdf"))
        page.load(address)
        for _ in 0..<200 where page.pdf == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(page.pdf, address)

        let added = expectation(description: "the PDF is handed over")
        var received: LibraryStore.Incoming?
        page.received = { received = $0; added.fulfill() }
        page.problem = { XCTFail($0); added.fulfill() }
        page.addShownPdf()
        await fulfillment(of: [added], timeout: 10)
        XCTAssertEqual(received?.data, bytes)
        XCTAssertEqual(received?.name, "Long Halls.pdf")
        XCTAssertEqual(page.downloads, 0)
    }

    /// A link that hands over a PDF as a file adds it straight away, as the desktop's web tab does.
    func testAPdfALinkDownloadsIsAddedAtOnce() async throws {
        let bytes = try Data(contentsOf: ConformanceTests.addedPdf)
        let server = try await PdfServer.start(serving: bytes, attachment: true)
        defer { server.stop() }
        let page = WebPage()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(page.webView)
        page.webView.frame = window.bounds
        let added = expectation(description: "the PDF is handed over")
        var received: LibraryStore.Incoming?
        page.received = { received = $0; added.fulfill() }
        page.problem = { XCTFail($0); added.fulfill() }
        page.load(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/download")))
        await fulfillment(of: [added], timeout: 15)
        XCTAssertEqual(received?.data, bytes)
        XCTAssertEqual(received?.name, "Long Halls.pdf")
        XCTAssertNil(page.pdf)
    }
}

/// A web server on this device that answers every request with one PDF.
private final class PdfServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private(set) var port: UInt16 = 0

    private init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// `attachment`: handed over as a file to save rather than a page to show.
    static func start(serving body: Data, attachment: Bool = false) async throws -> PdfServer {
        let server = try PdfServer(body: body)
        let queue = DispatchQueue(label: "pdf server")
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(body.count)\r\n" + (attachment ? "Content-Disposition: attachment; filename=\"Long Halls.pdf\"\r\n" : "") + "Connection: close\r\n\r\n"
                var reply = Data(head.utf8)
                reply.append(body)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            var finished = false
            server.listener.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; done.resume()
                case let .failed(error): finished = true; done.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: queue)
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }
}
