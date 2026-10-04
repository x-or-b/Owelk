import QtQuick
import QtTest
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
            const field = findChild(palette, "searchPaletteQuery")
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
            findChild(palette, "searchPaletteQuery").text = "hidden view"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "section" }) }, 10000)
            tryVerify(function() { return !palette.searchController.waiting }, 10000)
            wait(200)
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
        function test_scopeChipsAndTypedLibraryConditions() {
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            waitForPolish(palette.contentItem); wait(30)
            // One row of scopes instead of menus; the chosen one is marked.
            for (const value of ["text", "filename", "captures", "ai", "all"]) {
                const chip = visualChild(palette.contentItem, "searchTarget-" + value)
                verify(chip, value)
                mouseClick(chip)
                compare(palette.searchController.targetFilter, value)
                compare(chip.checked, true)
                compare(chip.contentItem.color.toString(), "#333333")
            }
            verify(findChild(palette, "searchTargetFilter") === null)
            verify(findChild(palette, "searchYearFrom") === null)
            // Library conditions are typed: tag:, state:, year: narrow the same search.
            verify(researchStore.setDocumentTags(fixtureSource, ["Occlusion Study"]))
            const tag = researchStore.tags().find(function(t) { return t.name === "Occlusion Study" }).id
            const field = findChild(palette, "searchPaletteQuery")
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
            findChild(palette, "searchPaletteQuery").text = "occlusion"
            tryVerify(function() { return palette.results.some(function(r) { return r.kind === "text" && Number(r.page) === 3 }) })
            const at = palette.results.findIndex(function(r) { return r.source.toString() === fixtureSource.toString() && Number(r.page) === 3 })
            verify(at >= 0)
            const list = findChild(palette, "searchPaletteResults")
            list.currentIndex = at; list.positionViewAtIndex(at, ListView.Contain)
            testInput.keyClick(findChild(palette, "searchPaletteQuery"), Qt.Key_Return)
            tryCompare(palette, "visible", false)
            tryCompare(workspace.currentReader, "currentPage", 3, 10000)
            const c = canvas(); compare(c.currentPage, 3); fuzzyCompare(c.zoomFactor, 1.3, .01)
            tryVerify(function() { return findChild(c, "pageImage3") !== null })
            tryCompare(findChild(c, "pageImage3"), "status", Image.Ready, 10000)
            compare(Tree.leaves(workspace.documents.tree)[0].tabs.length, 1)
        }
        function test_homeResultsAndIndexControls() {
            const home = findChild(workspace, "homeView")
            findChild(home, "homeSearch").text = "occlusion"
            tryVerify(function() { return home.results.some(function(r) { return r.kind === "text" }) })
            const result = home.results.find(function(r) { return r.kind === "text" && r.source.toString() === fixtureSource.toString() && Number(r.page) === 2 })
            verify(result !== undefined)
            home.resultChosen(result)
            tryCompare(workspace, "homeVisible", false)
            compare(canvas().currentPage, 2)
            workspace.showHome()
            const status = findChild(home, "indexStatus")
            mouseClick(status)
            const details = findChild(status, "indexDetails")
            tryCompare(details, "opened", true)
            mouseClick(findChild(details, "pauseIndex")); compare(researchStore.paperIndex.paused, true)
            mouseClick(findChild(details, "pauseIndex")); compare(researchStore.paperIndex.paused, false)
            details.close()
        }
    }
}
