import XCTest
@testable import Owelk

/// The left column's shelves as Settings › Sidebar keeps them.
final class SidebarTests: XCTestCase {
    func testTheOrderKeptAndTheShelvesItLeavesOut() {
        XCTAssertEqual(SidebarItem.order(""), SidebarItem.allCases)
        XCTAssertEqual(SidebarItem.order("chats,notes"), [.chats, .notes, .favorites, .reading, .annotated])
        // Unknown and repeated names are passed over.
        XCTAssertEqual(SidebarItem.order("recent,notes,notes"), [.notes, .favorites, .reading, .annotated, .chats])
        XCTAssertEqual(SidebarItem.keep([.notes, .chats]), "notes,chats")
        XCTAssertEqual(SidebarItem.hidden("reading,nothing"), [.reading])
        XCTAssertEqual(SidebarItem.hidden(""), [])
    }

    /// What a chat is about: its paper, its collection, or the folder it is kept in.
    func testWhatAChatIsAbout() {
        var library = Library()
        library.collections = [PaperCollection(id: "c1", name: "Multi-SLAM", depth: 0)]
        library.chatFolders = ["collection:c1": "", "f1": "Reading Lists"]
        func chat(paper: String = "", folder: String) -> AiThread {
            AiThread(id: folder, title: "", updatedAt: "", paper: paper, folder: folder)
        }
        XCTAssertEqual(library.place(of: chat(folder: "collection:c1")), "Multi-SLAM")
        XCTAssertEqual(library.place(of: chat(folder: "f1")), "Reading Lists")
        XCTAssertEqual(library.place(of: chat(folder: "")), "")
        XCTAssertNil(library.paper(of: chat(paper: "missing", folder: "document:x")))
    }
}
