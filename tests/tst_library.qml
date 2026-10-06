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
        function visibleChild(item, name) {
            if (!item || !item.visible) return null
            if (item.objectName === name) return item
            for (let i = 0; i < item.children.length; ++i) { const f = visibleChild(item.children[i], name); if (f) return f }
            return null
        }
        function test_libraryPanelFilesTabsIntoCollections() {
            const topic = researchStore.createCollection("Panel Topic")
            workspace.filesVisible = true; workspace.filesSide = "left"
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            tryVerify(function() { return workspace.currentReader && workspace.currentReader.pdfReady }, 10000)
            const panel = findChild(workspace, "libraryPanel")
            verify(panel !== null)
            tryVerify(function() { return visibleChild(panel, "panelCollection-Panel Topic") !== null })
            waitForPolish(workspace); wait(50)
            // Drag the open paper's tab onto the collection: it is filed there and stays open.
            const d = workspace.documents
            const tab = Tree.leaves(d.tree)[0].activeTab
            const row = visibleChild(panel, "panelCollection-Panel Topic")
            const point = row.mapToItem(null, row.width / 2, row.height / 2)
            d.dragTitle = "dragged"
            d.dragTab(tab, point.x, point.y)
            compare(d.dropTarget.collection, topic)
            verify(row.highlighted)
            d.finishDrag(false)
            tryVerify(function() { return researchStore.libraryDocuments({collection: topic}).length === 1 })
            verify(Tree.owner(d.tree, tab) !== null, "the tab stays open")
            // Clicking the collection opens the Library filtered to it.
            mouseClick(visibleChild(panel, "panelCollection-Panel Topic"))
            const view = library()
            tryVerify(function() { return view.filter.collection === topic })
            // Sections fold, and stay folded.
            mouseClick(visibleChild(panel, "collectionsSection"))
            tryCompare(panel, "collectionsOpen", false)
            compare(researchStore.setting("library.section.collections"), "0")
            mouseClick(visibleChild(panel, "collectionsSection"))
            tryCompare(panel, "collectionsOpen", true)
            researchStore.deleteCollection(topic)
        }
        function test_newCollectionButton() {
            workspace.documents.openLibrary({})
            const view = library()
            tryVerify(function() { return visibleChild(view, "newCollectionButton") !== null })
            waitForPolish(view); wait(50)
            mouseClick(visibleChild(view, "newCollectionButton"))
            const dialog = findChild(view, "collectionDialog")
            tryCompare(dialog, "opened", true)
            findChild(dialog, "collectionName").text = "From the plus button"
            dialog.accept()
            tryVerify(function() { return researchStore.collections().some(function(c) { return c.name === "From the plus button" }) })
            researchStore.deleteCollection(researchStore.collections().find(function(c) { return c.name === "From the plus button" }).id)
        }
        function test_unsortedMultiSelectAndBatchCollection() {
            const one = testInput.copyFixture("topic one.pdf"), two = testInput.copyFixture("topic two.pdf")
            verify(researchStore.rememberDocument(one)); verify(researchStore.rememberDocument(two))
            const topic = researchStore.createCollection("Batch Topic")
            workspace.documents.openLibrary({unsorted: true})
            const view = library()
            tryVerify(function() { return visualChild(view, "librarySidebar-unsorted-true") !== null })
            tryVerify(function() { return view.rows.some(function(r) { return researchStore.sameSource(r.url, one) }) })
            verify(view.rows.every(function(r) { return researchStore.documentOrganization(r.url).collections.length === 0 }), "only papers in no collection")
            const first = view.rows.find(function(r) { return researchStore.sameSource(r.url, one) })
            const second = view.rows.find(function(r) { return researchStore.sameSource(r.url, two) })
            waitForPolish(view); wait(50)
            // Cmd/Ctrl-click selects without opening; right-click acts on the whole selection.
            const tabs = Tree.find(workspace.documents.tree, workspace.documents.activeGroup).tabs.length
            mouseClick(visualChild(view, "libraryPaper-" + first.id), 60, 12, Qt.LeftButton, Qt.ControlModifier)
            mouseClick(visualChild(view, "libraryPaper-" + second.id), 60, 12, Qt.LeftButton, Qt.ControlModifier)
            compare(view.selection.length, 2)
            compare(Tree.find(workspace.documents.tree, workspace.documents.activeGroup).tabs.length, tabs, "nothing opened")
            verify(visualChild(view, "libraryPaper-" + first.id).highlighted)
            mouseClick(visualChild(view, "libraryPaper-" + second.id), 60, 12, Qt.RightButton)
            const batch = findChild(view, "libraryBatchMenu")
            tryCompare(batch, "opened", true)
            compare(batch.urls.length, 2)
            const sub = findChild(view, "libraryBatchCollections")
            let item = null
            for (let i = 0; i < sub.count; ++i) if (sub.itemAt(i).text.trim() === "Batch Topic") item = sub.itemAt(i)
            verify(item !== null)
            item.triggered()
            batch.close()
            // Both papers left Unsorted together.
            tryVerify(function() { return !view.rows.some(function(r) { return researchStore.sameSource(r.url, one) || researchStore.sameSource(r.url, two) }) })
            compare(researchStore.libraryDocuments({collection: topic}).length, 2)
            compare(view.selection.length, 0)
            researchStore.deleteCollection(topic)
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
