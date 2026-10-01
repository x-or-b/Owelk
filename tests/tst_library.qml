import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "Library"
        when: windowShown
        function cleanupTestCase() { workspace.visible = false }
        function init() {
            workspace.width = 1440; workspace.height = 930
            workspace.documents.restore({})
            workspace.homeVisible = true
        }
        function visualChild(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        function activeTab() {
            const d = workspace.documents, g = Tree.find(d.tree, d.activeGroup)
            return g.tabs.find(function(t) { return t.id === g.activeTab })
        }
        function library() {
            let view = null
            tryVerify(function() { view = findChild(workspace.documents.groupView(workspace.documents.activeGroup), "libraryView"); return view !== null && view.width > 0 && view.height > 0 }, 5000)
            return view
        }
        function test_libraryTabFiltersAndOpensPapers() {
            verify(researchStore.rememberDocument(fixtureSource))
            const second = testInput.copyFixture("library second.pdf")
            verify(researchStore.rememberDocument(second))
            verify(researchStore.setReadingState(second, "read"))
            const home = findChild(workspace, "homeView")
            waitForPolish(home); wait(50) // Home lists many papers in a full run; click once laid out.
            mouseClick(visualChild(home, "openLibraryButton"))
            compare(activeTab().kind, "library")
            const view = library()
            tryVerify(function() { return view.rows.length >= 2 })
            const total = view.rows.length
            // Sidebar filters persist with the tab.
            mouseClick(visualChild(view, "librarySidebar-state-read"))
            tryVerify(function() { return view.rows.length >= 1 && view.rows.every(function(r) { return r.readingState === "read" }) })
            compare(activeTab().filter.state, "read")
            verify(Tree.validate(workspace.documents.snapshot().tree, {}, 0))
            mouseClick(visualChild(view, "librarySidebar-all-"))
            tryVerify(function() { return view.rows.length === total })
            // A collection groups papers without copying them.
            const id = researchStore.createCollection("Library test collection")
            verify(researchStore.setDocumentCollection(second, id, true))
            tryVerify(function() { return visualChild(view, "librarySidebar-collection-" + id) !== null })
            mouseClick(visualChild(view, "librarySidebar-collection-" + id))
            tryVerify(function() { return view.rows.length === 1 })
            compare(view.rows[0].url.toString(), second.toString())
            // The star toggles favorites in place.
            const row = view.rows[0]
            mouseClick(visualChild(view, "libraryFavorite-" + row.id))
            tryVerify(function() { return view.rows.length === 1 && view.rows[0].favorite })
            // The query field narrows by title, author or file name.
            mouseClick(visualChild(view, "librarySidebar-all-"))
            visualChild(view, "libraryQuery").text = "library second"
            tryVerify(function() { return view.rows.length === 1 })
            // Clicking a paper opens it as a new tab next to the library.
            mouseClick(visualChild(view, "libraryPaper-" + view.rows[0].id))
            tryCompare(activeTab(), "kind", undefined)
            verify(researchStore.sameSource(activeTab().source, second))
            researchStore.deleteCollection(id)
        }
        function test_searchResultsOpenCollectionsAndScopeSearch() {
            const id = researchStore.createCollection("Zebra Collection")
            const found = researchStore.searchKnowledge("zebra coll").filter(function(r) { return r.kind === "collection" })
            compare(found.length, 1)
            workspace.openSearchResult(found[0])
            compare(activeTab().kind, "library")
            tryCompare(library(), "filter", ({collection: id}))
            researchStore.deleteCollection(id)
        }
    }
}
