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
            findChild(home, "homeRecentHeading").opened()
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
            // Other test files leave other panels in this dock; show the Library panel.
            workspace.setPanelShown("files", true); workspace.closeOthers("files")
            let panel = null
            tryVerify(function() { panel = findChild(workspace, "libraryPanel"); return panel !== null })
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
            // Clicking the collection opens the Library filtered to it; the navigator's other rows too.
            mouseClick(visibleChild(panel, "panelCollection-Panel Topic"))
            const view = library()
            tryVerify(function() { return view.filter.collection === topic })
            // Favorites unfold in the panel; Open Library goes to the whole Library.
            mouseClick(visibleChild(panel, "panelFavorites"))
            tryCompare(panel, "favoritesOpen", true)
            mouseClick(visibleChild(panel, "panelFavorites"))
            tryCompare(panel, "favoritesOpen", false)
            mouseClick(visibleChild(panel, "panelOpenLibrary"))
            tryVerify(function() { return Object.keys(view.filter).length === 0 })
            // New and renamed collections from the panel.
            mouseClick(visibleChild(panel, "panelNewCollection"))
            const nameDialog = findChild(panel, "panelCollectionName")
            tryCompare(nameDialog, "opened", true)
            findChild(nameDialog, "panelCollectionNameField").text = "Made in Panel"
            nameDialog.accept()
            tryVerify(function() { return visibleChild(panel, "panelCollection-Made in Panel") !== null })
            researchStore.deleteCollection(researchStore.collections().find(function(c) { return c.name === "Made in Panel" }).id)
            // Sections fold, and stay folded.
            mouseClick(visibleChild(panel, "collectionsSection"))
            tryCompare(panel, "collectionsOpen", false)
            compare(researchStore.setting("library.section.collections"), "0")
            mouseClick(visibleChild(panel, "collectionsSection"))
            tryCompare(panel, "collectionsOpen", true)
            researchStore.deleteCollection(topic)
        }
        function test_deletedPaperWaitsInTheTrash() {
            const copy = testInput.copyFixture("to delete.pdf")
            verify(researchStore.addDocuments([copy], "") === 1)
            workspace.documents.openLibrary({})
            const view = library()
            tryVerify(function() { return view.rows.some(function(r) { return researchStore.sameSource(r.url, copy) }) })
            const row = view.rows.find(function(r) { return researchStore.sameSource(r.url, copy) })
            waitForPolish(view); wait(50)
            mouseClick(visualChild(view, "libraryPaper-" + row.id), 60, 12, Qt.RightButton)
            const menu = findChild(view, "paperMenu")
            tryCompare(menu, "opened", true)
            findChild(menu, "deletePaperOption").triggered()
            tryVerify(function() { return !view.rows.some(function(r) { return researchStore.sameSource(r.url, copy) }) })
            verify(testInput.fileExists(copy), "the PDF file waits with the paper")
            // In the Trash (with notes and AI conversations) until restored.
            mouseClick(visualChild(view, "libraryTrashTab"))
            compare(view.view, "trash")
            tryVerify(function() { return view.trashRows.some(function(r) { return r.kind === "paper" && r.id === row.id }) })
            tryVerify(function() { return findChild(view, "restore-paper-" + row.id) !== null })
            findChild(view, "restore-paper-" + row.id).clicked()
            mouseClick(visualChild(view, "libraryPapersTab"))
            compare(view.view, "papers")
            tryVerify(function() { return view.rows.some(function(r) { return researchStore.sameSource(r.url, copy) }) })
            compare(view.trashCount, 0)
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
        function test_selectButtonPicksPapersWithoutOpening() {
            const one = testInput.copyFixture("select one.pdf"), two = testInput.copyFixture("select two.pdf")
            verify(researchStore.addDocuments([one, two], "") === 2)
            workspace.documents.openLibrary({})
            const view = library()
            tryVerify(function() { return view.rows.some(function(r) { return researchStore.sameSource(r.url, two) }) })
            const first = view.rows.find(function(r) { return researchStore.sameSource(r.url, one) })
            const second = view.rows.find(function(r) { return researchStore.sameSource(r.url, two) })
            waitForPolish(view); wait(50)
            const tabs = Tree.find(workspace.documents.tree, workspace.documents.activeGroup).tabs.length
            // The check button turns a click into picking; the bar holds Select All, Delete and Done.
            waitForPolish(visibleChild(view, "libraryCount").parent); wait(20)
            mouseClick(visibleChild(view, "librarySelect"))
            verify(view.selecting)
            verify(visibleChild(view, "libraryAddPdfs") === null, "the usual buttons step aside")
            verify(visibleChild(view, "librarySelect") === null)
            verify(!visibleChild(view, "libraryDeleteSelection").enabled, "Delete waits for a choice")
            mouseClick(visualChild(view, "libraryPaper-" + first.id), 60, 12)
            compare(view.selection.length, 1)
            compare(Tree.find(workspace.documents.tree, workspace.documents.activeGroup).tabs.length, tabs, "nothing opened")
            verify(visibleChild(visualChild(view, "libraryPaper-" + first.id), "librarySelectMark").chosen)
            verify(visibleChild(view, "libraryDeleteSelection").enabled)
            mouseClick(visualChild(view, "libraryPaper-" + first.id), 60, 12)
            compare(view.selection.length, 0, "a second click unpicks")
            waitForPolish(visibleChild(view, "libraryCount").parent); wait(20)
            mouseClick(visibleChild(view, "librarySelectAll"))
            compare(view.selection.length, view.rows.length)
            verify(view.allSelected)
            waitForPolish(visibleChild(view, "libraryCount").parent); wait(20)
            mouseClick(visibleChild(view, "librarySelectAll"))
            compare(view.selection.length, 0)
            // Backspace (or Delete) moves the chosen papers to the Trash and leaves select mode.
            mouseClick(visualChild(view, "libraryPaper-" + second.id), 60, 12)
            // Typing in the filter field keeps its Backspace.
            const query = visibleChild(view, "libraryQuery")
            workspace.requestActivate()
            query.text = "select"; query.forceActiveFocus(); query.cursorPosition = query.text.length
            tryVerify(function() { return query.activeFocus })
            keyClick(Qt.Key_Backspace)
            compare(query.text, "selec")
            query.text = ""
            wait(200)
            verify(view.rows.some(function(r) { return researchStore.sameSource(r.url, two) }), "nothing deleted from the field")
            mouseClick(visualChild(view, "libraryPaper-" + second.id), 60, 12)
            mouseClick(visualChild(view, "libraryPaper-" + second.id), 60, 12)
            compare(view.selection.length, 1)
            view.forceActiveFocus()
            keyClick(Qt.Key_Backspace)
            tryVerify(function() { return !view.rows.some(function(r) { return researchStore.sameSource(r.url, two) }) })
            verify(!view.selecting)
            verify(view.rows.some(function(r) { return researchStore.sameSource(r.url, one) }))
            // Done (or Esc) leaves without deleting.
            waitForPolish(visibleChild(view, "libraryCount").parent); wait(20)
            mouseClick(visibleChild(view, "librarySelect"))
            mouseClick(visualChild(view, "libraryPaper-" + first.id), 60, 12)
            keyClick(Qt.Key_Escape)
            verify(!view.selecting)
            compare(view.selection.length, 0)
            verify(visibleChild(view, "libraryAddPdfs") !== null)
            researchStore.restoreFromTrash([{kind: "paper", id: second.id}])
        }
        function test_notesSelectAskAiAndDelete() {
            const one = researchStore.createNote("Select note one", "first"), two = researchStore.createNote("Select note two", "second")
            workspace.documents.openLibrary({view: "notes"})
            const view = library()
            tryVerify(function() { return view.noteRows.some(function(n) { return n.id === two }) })
            waitForPolish(view); wait(50)
            mouseClick(visibleChild(view, "libraryNoteSelect"))
            verify(view.selecting)
            verify(!visibleChild(view, "libraryNoteAsk").enabled)
            mouseClick(visualChild(view, "libraryNote-" + one), 60, 12)
            mouseClick(visualChild(view, "libraryNote-" + two), 60, 12)
            compare(view.selection.length, 2)
            verify(visualChild(view, "libraryNote-" + one).highlighted)
            compare(activeTab().kind, "library", "nothing opened")
            // Ask AI: a new chat with both notes attached.
            waitForPolish(visibleChild(view, "libraryNoteCount").parent); wait(20)
            mouseClick(visibleChild(view, "libraryNoteAsk"))
            const ai = findChild(workspace, "aiController")
            tryVerify(function() { return (ai.spec.noteIds || []).length === 2 })
            verify(ai.attachments.filter(function(a) { return a.kind === "note" }).length === 2)
            verify(!view.selecting)
            // Backspace moves chosen notes to the Trash.
            mouseClick(visibleChild(view, "libraryNoteSelect"))
            mouseClick(visualChild(view, "libraryNote-" + two), 60, 12)
            view.forceActiveFocus()
            keyClick(Qt.Key_Backspace)
            tryVerify(function() { return researchStore.note(two).deleted })
            verify(!researchStore.note(one).deleted)
            researchStore.deleteNote(one)
        }
        function test_forYouOnHomeAndInTheLibrary() {
            const forYou = researchStore.forYou
            researchStore.setSetting("forYou.arxivBaseUrl", testInput.webFixture("/api").toString())
            researchStore.setSetting("forYou.recommendBaseUrl", testInput.webFixture("/recommendations/v1").toString())
            researchStore.setSetting("forYou.delayMs", "10")
            forYou.saveTopics([]); researchStore.setSetting("forYou.collections", "")
            // Nothing followed: Home shows one line that leads to the settings.
            workspace.homeVisible = true
            const home = findChild(workspace, "homeView")
            waitForPolish(home); wait(50)
            verify(!forYou.configured)
            verify(visualChild(home, "homeForYouHint").visible)
            mouseClick(visualChild(home, "homeForYouHint"))
            const settings = findChild(workspace, "settingsDialog")
            tryCompare(settings, "opened", true)
            compare(settings.page, "foryou")
            settings.close(); tryCompare(settings, "visible", false)
            // A topic: Check finds a paper. The AI, set up after the check, then says why it fits.
            researchStore.setSetting("ai.baseUrl.claude", testInput.webFixture("/").toString())
            researchStore.ai.provider = "claude"
            researchStore.ai.clearApiKey("claude")
            researchStore.setSetting("forYou.ai", "1")
            verify(!forYou.aiReady())
            verify(forYou.saveTopics([{words: "odometry", categories: "cs.RO"}]))
            verify(forYou.configured)
            forYou.refresh()
            tryVerify(function() { return !forYou.checking }, 10000)
            compare(forYou.problem, "")
            compare(forYou.items.length, 1)
            verify(!forYou.items[0].why)
            researchStore.ai.giveConsent("claude")
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            tryVerify(function() { return !forYou.explaining && !!forYou.items[0].why }, 10000)
            compare(forYou.items[0].why, "Directly on the odometry you follow.")
            compare(forYou.items[0].score, 92)
            compare(forYou.aiProblem, "")
            tryVerify(function() { return visualChild(home, "homeForYou-0") !== null && !visualChild(home, "homeForYouHint").visible })
            verify(visualChild(home, "homeForYouHeading").detail.indexOf("1") === 0)
            compare(visualChild(home, "homeForYouWhy-0").text, "Directly on the odometry you follow.")
            // A paper on Home opens in Library › For You, already open.
            mouseClick(visualChild(home, "homeForYou-0"), 60, 12)
            let view = library()
            tryCompare(view, "forYouOpen", forYou.items[0].id)
            workspace.homeVisible = true
            // The heading goes to Library › For You.
            const heading = visualChild(home, "homeForYouHeading").children[0]
            waitForPolish(home); wait(50)
            mouseClick(heading, 12, heading.height / 2)
            view = library()
            tryCompare(view, "view", "foryou")
            tryVerify(function() { return visualChild(view, "libraryForYou-0") !== null })
            verify(Tree.validate(workspace.documents.snapshot().tree, {}, 0), "a For You tab is a valid saved tab")
            // A click opens the paper in place (its whole abstract, Add, its page); Open Page goes to the web.
            waitForPolish(view); wait(50)
            const libraryTab = activeTab().id
            mouseClick(visualChild(view, "libraryForYou-0"), 60, 12)
            compare(view.forYouOpen, forYou.items[0].id)
            compare(activeTab().kind, "library", "no web tab yet")
            let openPage = null
            tryVerify(function() { openPage = visibleChild(view, "libraryForYouOpenPage"); return openPage !== null })
            wait(500) // Not a double click.
            mouseClick(visualChild(view, "libraryForYou-0"), 60, 12)
            compare(view.forYouOpen, "", "a second click closes it")
            wait(500)
            mouseClick(visualChild(view, "libraryForYou-0"), 60, 12)
            tryVerify(function() { openPage = visibleChild(view, "libraryForYouOpenPage"); return openPage !== null })
            openPage.clicked()
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("arxiv.org/abs/2609.01234") >= 0 })
            const page = activeTab().id
            workspace.documents.activateTab(libraryTab)
            workspace.documents.closeTab(page)
            view = library()
            tryCompare(view, "view", "foryou")
            // Select and Add: the PDF comes into the Library with its arXiv details.
            waitForPolish(view); wait(50)
            mouseClick(visibleChild(view, "libraryForYouSelect"))
            mouseClick(visualChild(view, "libraryForYou-0"), 60, 12)
            compare(view.selection.length, 1)
            waitForPolish(visibleChild(view, "libraryForYouCount").parent); wait(20)
            mouseClick(visibleChild(view, "libraryForYouAddSelection"))
            tryVerify(function() { return forYou.adding.length === 0 && forYou.items.length === 0 }, 10000)
            const added = researchStore.libraryDocuments({text: "Fresh Odometry From arXiv"})
            compare(added.length, 1)
            compare(researchStore.documentDetails(added[0].url).arxiv, "2609.01234")
            // Nothing new now: Home hides the box; the Library says when it last looked.
            tryVerify(function() { return !visualChild(home, "homeForYou").visible })
            tryVerify(function() { return view.forYouRows.length === 0 })
            // A paper added is not suggested again.
            forYou.refresh()
            tryVerify(function() { return !forYou.checking }, 10000)
            compare(forYou.items.length, 0, "the added paper is in the Library now")
            researchStore.deletePapers([added[0].url])
            researchStore.ai.clearApiKey("claude")
            forYou.saveTopics([])
            verify(!forYou.configured)
        }
        function test_dragPaperOntoCollection() {
            const one = testInput.copyFixture("drag one.pdf")
            verify(researchStore.addDocuments([one], "") === 1)
            const topic = researchStore.createCollection("Drag Topic")
            workspace.documents.openLibrary({})
            const view = library()
            tryVerify(function() { return view.rows.some(function(r) { return researchStore.sameSource(r.url, one) }) })
            tryVerify(function() { return visualChild(view, "librarySidebar-collection-" + topic) !== null })
            waitForPolish(view); wait(50)
            const row = visualChild(view, "libraryPaper-" + view.rows.find(function(r) { return researchStore.sameSource(r.url, one) }).id)
            const target = visualChild(view, "librarySidebar-collection-" + topic)
            const to = target.mapToItem(row, target.width / 2, target.height / 2)
            // Down, a little up and to the left (as a hand does), then onto the collection.
            mousePress(row, 80, 12)
            for (let i = 1; i <= 12; ++i) mouseMove(row, 80 + (to.x - 80) * i / 12, 12 + (to.y - 12) * i / 12)
            const ghost = findChild(view, "libraryDragGhost")
            verify(ghost.visible, "a label follows the pointer")
            mouseRelease(row, to.x, to.y)
            tryVerify(function() { return researchStore.libraryDocuments({collection: topic}).length === 1 })
            verify(!ghost.visible)
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
