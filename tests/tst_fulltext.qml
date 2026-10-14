import QtQuick
import QtTest
import Owelk.Ui
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    App.ResearchSearch { id: search; active: true }
    TestCase {
        name: "FullTextSearch"
        when: windowShown
        function init() {
            workspace.documents.restore({})
            workspace.homeVisible = true
            researchStore.rememberDocument(fixtureSource)
            tryCompare(researchStore.paperIndex, "busy", false, 10000)
            search.query = ""
            findChild(workspace, "searchPalette").searchController.resetFilters()
        }
        function test_groupingFiltersAndMore() {
            const pair = testInput.relinkFixture(true)
            researchStore.rememberDocument(pair.source); researchStore.rememberDocument(pair.candidate)
            tryCompare(researchStore.paperIndex, "busy", false, 10000)
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            const field = palette.queryField
            field.text = "occlusion"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "moreInPaper" && researchStore.sameSource(r.source, pair.source) }) })
            compare(palette.results.filter(function(r) { return r.kind === "text" && researchStore.sameSource(r.source, pair.source) }).length, 3)
            palette.choose(palette.results.findIndex(function(r) { return r.kind === "moreInPaper" && researchStore.sameSource(r.source, pair.source) }))
            tryVerify(function() { return palette.results.filter(function(r) { return r.kind === "text" }).length === 8 })
            compare(palette.visible, true); compare(field.text, "occlusion")
            verify(palette.results.every(function(r) { return researchStore.sameSource(r.source, pair.source) }))
            palette.searchController.back()
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "paperGroup" && researchStore.sameSource(r.source, pair.candidate) }) })
            palette.searchController.sourceFilter = pair.source
            palette.searchController.targetFilter = "filename"
            field.text = "relink paper"
            tryVerify(function() { return palette.results.length === 1 && palette.results[0].kind === "paper" })
            verify(researchStore.sameSource(palette.results[0].source, pair.source))
        }
        function cleanup() {
            findChild(workspace, "searchPalette").close()
            const details = findChild(workspace, "indexDetails")
            if (details) details.close()
            researchStore.paperIndex.setPaused(false)
        }
        function visualChild(item, name) {
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        function test_meaningResultsFollowKeywordResults() {
            const semantic = researchStore.semantic
            researchStore.setSetting("semantic.baseUrl.ollama", testInput.webFixture("/").toString())
            semantic.configure("ollama", "test-embed")
            tryVerify(function() { return !semantic.busy && semantic.storedCount() > 0 }, 20000)
            compare(semantic.error, "")
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            // No page has these words, but "hidden view" means occlusion and observation.
            palette.queryField.text = "hidden view"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "section" }) }, 10000)
            tryVerify(function() { return !palette.searchController.waiting }, 10000)
            // Library changes from earlier tests can refresh the list once more; read it when settled.
            tryVerify(function() { return !palette.searchController.waiting && palette.results.some(function(r) { return r.kind === "section" }) }, 10000)
            const at = palette.results.findIndex(function(r) { return r.kind === "section" })
            compare(palette.results[at].title, "Similar meaning")
            verify(palette.results[at + 1].semantic)
            // Fixture pages (other test files add more copies of the same text) are found by meaning.
            verify(palette.results.some(function(r) { return r.semantic && r.kind === "text" && r.title === "A Small Research Reader" }))
            // The heading is never selected: not first, and skipped by the keyboard.
            const list = findChild(palette, "searchPaletteResults")
            verify(palette.results[list.currentIndex].kind !== "section")
            for (let i = 0; i < palette.results.length; ++i) {
                palette.move(1)
                verify(palette.results[list.currentIndex].kind !== "section")
            }
            palette.close()
            semantic.configure("", "")
            semantic.clear()
        }
        function test_conditionsCompleteAsYouType() {
            verify(researchStore.setDocumentTags(fixtureSource, ["Occlusion Study"]))
            const shelf = researchStore.createCollection("Completion Shelf")
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            const field = palette.queryField, controller = palette.searchController
            // Half a tag offers the matching tags; choosing one completes the condition.
            field.text = "tag:occ"
            tryVerify(function() { return controller.results.length > 0 && controller.results[0].kind === "complete" })
            compare(controller.results[0].title, "Occlusion Study")
            palette.choose(0)
            compare(field.text, 'tag:"Occlusion Study" ')
            compare(palette.visible, true, "completing keeps the search open")
            tryVerify(function() { return controller.results.some(function(r) { return r.kind === "paper" }) })
            // Collections and workspaces complete the same way.
            field.text = "collection:compl"
            tryVerify(function() { return controller.results.length > 0 && controller.results[0].title === "Completion Shelf" })
            field.text = "workspace:"
            tryVerify(function() { return controller.results.every(function(r) { return r.kind === "complete" && r.key === "workspace" }) })
            palette.close(); tryCompare(palette, "visible", false)
            researchStore.deleteCollection(shelf)
        }
        function test_scopeChipsAndTypedLibraryConditions() {
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            waitForPolish(palette.contentItem); wait(30)
            // One row of scopes instead of menus; the chosen one is marked.
            for (const value of ["text", "filename", "notes", "ai", "all"]) {
                const chip = visualChild(palette.contentItem, "searchTarget-" + value)
                verify(chip, value)
                mouseClick(chip)
                compare(palette.searchController.targetFilter, value)
                compare(chip.checked, true)
                verify(Qt.colorEqual(chip.background.color, Theme.selected))
            }
            verify(findChild(palette, "searchTargetFilter") === null)
            verify(findChild(palette, "searchYearFrom") === null)
            // Library conditions are typed: tag:, state:, year: narrow the same search.
            verify(researchStore.setDocumentTags(fixtureSource, ["Occlusion Study"]))
            const tag = researchStore.tags().find(function(t) { return t.name === "Occlusion Study" }).id
            const field = palette.queryField
            field.text = "tag:\"occlusion study\" year:2024"
            const controller = palette.searchController
            compare(controller.libraryFilter.tag, tag)
            compare(controller.libraryFilter.yearFrom, 2024)
            compare(controller.parsed.needle, "")
            compare(findChild(palette, "searchFilterSummary").text, "tag: occlusion study  ·  year: 2024")
            field.text = "tag:\"occlusion study\""
            // Only conditions: the matching papers are listed.
            tryVerify(function() { return palette.results.length === 1 && palette.results[0].kind === "paper" })
            field.text = "occlusion tag:\"occlusion study\""
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "text" }) }, 10000)
            field.text = "occlusion tag:nosuchtag"
            tryVerify(function() { return !controller.waiting })
            wait(300)
            compare(palette.results.filter(function(r) { return r.kind === "text" || r.kind === "paper" }).length, 0)
            field.text = "state:read occlusion"
            compare(controller.libraryFilter.state, "read")
            compare(controller.parsed.needle, "occlusion")
            field.text = ""
            researchStore.setDocumentTags(fixtureSource, [])
        }
        function cleanupTestCase() { workspace.visible = false }
        function canvas() {
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader, "pdfCanvas0")
            tryCompare(c, "ready", true); tryCompare(c, "restoring", false)
            return c
        }
        function test_asyncSearchAndStaleResponse() {
            search.query = "occlusion"; search.refresh()
            const old = search.request
            search.query = "unfindablexyz"
            researchStore.paperIndex.searchFinished(old, [{kind: "text", title: "Stale result"}], "")
            compare(search.results.length, 0)
            search.refresh(); tryCompare(search, "waiting", false)
            compare(search.results.length, 0)
            search.query = "occlu"; search.refresh(); tryCompare(search, "waiting", false)
            verify(search.results.some(function(r) { return r.kind === "text" && r.snippet.length > 0 }))
        }
        function test_paletteTextResultOpensCorrectPageAndReusesTab() {
            workspace.openDocument(fixtureSource, {page: 0, zoom: 1.3}); canvas()
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            palette.searchController.sourceFilter = fixtureSource
            palette.queryField.text = "occlusion"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "text" && Number(r.page) === 3 }) })
            const at = palette.results.findIndex(function(r) { return r.source.toString() === fixtureSource.toString() && Number(r.page) === 3 })
            verify(at >= 0)
            const list = findChild(palette, "searchPaletteResults")
            list.currentIndex = at; list.positionViewAtIndex(at, ListView.Contain)
            testInput.keyClick(palette.queryField, Qt.Key_Return)
            tryCompare(palette, "visible", false)
            tryCompare(workspace.currentReader, "currentPage", 3, 10000)
            const c = canvas(); compare(c.currentPage, 3); fuzzyCompare(c.zoomFactor, 1.3, .01)
            tryVerify(function() { return findChild(c, "pageImage3") !== null })
            tryCompare(findChild(c, "pageImage3"), "status", Image.Ready, 10000)
            compare(Tree.leaves(workspace.documents.tree)[0].tabs.length, 1)
        }
        function test_homeResultsAndIndexControls() {
            // Home has no search box of its own: showing Home puts the cursor in the top bar's field, whose
            // results hang under it.
            const home = findChild(workspace, "homeView"), palette = findChild(workspace, "searchPalette")
            const field = findChild(workspace, "topSearchField")
            verify(findChild(home, "homeSearch") === null)
            workspace.showHome()
            tryVerify(function() { return field.activeFocus || field.focus })
            compare(palette.opened, false)
            palette.open(); tryCompare(palette, "opened", true)
            verify(palette.attached)
            field.text = "occlusion"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "text" }) })
            const result = palette.results.find(function(r) { return r.kind === "text" && r.source.toString() === fixtureSource.toString() && Number(r.page) === 2 })
            verify(result !== undefined)
            palette.choose(palette.results.indexOf(result))
            tryCompare(workspace, "homeVisible", false)
            compare(canvas().currentPage, 2)
            workspace.showHome()
            // On Home the index line shows only while indexing or when PDFs cannot be read; its details
            // (as in Settings › Search) are checked with the line shown.
            const status = findChild(home, "indexStatus")
            status.quiet = false
            waitForPolish(status); wait(30)
            mouseClick(status)
            const details = findChild(status, "indexDetails")
            tryCompare(details, "opened", true)
            mouseClick(findChild(details, "pauseIndex")); compare(researchStore.paperIndex.paused, true)
            mouseClick(findChild(details, "pauseIndex")); compare(researchStore.paperIndex.paused, false)
            // Locate opens the relink dialog for that paper (the list closes).
            let locate = null
            tryVerify(function() { locate = visualChild(findChild(details, "indexDetailsList").contentItem, "locateOriginal-0"); return locate !== null })
            mouseClick(locate)
            const relink = findChild(workspace, "relinkDialog")
            tryCompare(relink, "opened", true)
            compare(relink.source, status.records[0].source)
            tryCompare(details, "visible", false)
            relink.close()
            tryCompare(relink, "visible", false)
            mouseClick(status)
            tryCompare(details, "opened", true)
            details.close()
            // A paper whose PDF is gone can leave the Library from the list.
            const gone = testInput.uniqueFixture("gone.pdf")
            const before = researchStore.libraryDocuments({}).map(function(d) { return d.url.toString() })
            verify(researchStore.addDocuments([gone], "") === 1)
            const kept = researchStore.libraryDocuments({}).find(function(d) { return before.indexOf(d.url.toString()) < 0 })
            verify(kept !== undefined, "a paper of its own")
            tryVerify(function() { return status.records.some(function(d) { return researchStore.sameSource(d.source, kept.url) && d.state === "ready" }) }, 20000)
            verify(testInput.removeFile(kept.url))
            researchStore.paperIndex.retry(kept.url)
            tryVerify(function() { return status.missing.some(function(u) { return researchStore.sameSource(u, kept.url) }) }, 20000)
            mouseClick(status)
            tryCompare(details, "opened", true)
            let remove = null
            tryVerify(function() {
                const at = status.records.findIndex(function(d) { return researchStore.sameSource(d.source, kept.url) })
                if (at >= 0) findChild(details, "indexDetailsList").positionViewAtIndex(at, ListView.Contain)
                remove = at >= 0 ? visualChild(findChild(details, "indexDetailsList").contentItem, "removeMissing-" + at) : null
                return remove !== null && remove.visible
            })
            remove.clicked()
            tryVerify(function() { return !researchStore.libraryDocuments({}).some(function(d) { return researchStore.sameSource(d.url, kept.url) }) })
            tryVerify(function() { return !status.missing.some(function(u) { return researchStore.sameSource(u, kept.url) }) }, 10000)
            details.close()
            status.quiet = true
        }
    }
}
