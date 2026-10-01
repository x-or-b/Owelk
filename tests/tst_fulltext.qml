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
        function test_filterHoverAndSelectionContrast() {
            const palette = findChild(workspace, "searchPalette")
            palette.open(); tryCompare(palette, "opened", true)
            const filters = findChild(palette, "searchFiltersButton")
            if (!filters.checked) mouseClick(filters)
            // Expanding adds two filter rows and the palette re-centres; click once the layout settles.
            waitForPolish(palette.contentItem); wait(50)
            const picker = findChild(palette, "searchTargetFilter")
            compare(picker.contentItem.color.toString(), "#333333")
            tryCompare(picker, "height", 32)
            compare(findChild(palette, "currentPdfFilter").height, picker.height)
            compare(filters.height, picker.height)
            for (let i = 0; i < 4; ++i) {
                mouseClick(picker)
                tryCompare(picker.popup, "opened", true)
                tryVerify(function() { return picker.popup.contentItem.itemAtIndex(i) !== null })
                const option = picker.popup.contentItem.itemAtIndex(i)
                verify(option !== null)
                waitForPolish(picker.popup.contentItem)
                tryVerify(function() { return picker.popup.height >= option.height + 2 })
                mouseMove(option, 20, option.height / 2)
                compare(option.contentItem.color.toString(), "#333333")
                verify(option.background.color.toString() !== "#ffffff")
                mouseClick(option)
                tryCompare(picker, "currentIndex", i)
                compare(picker.contentItem.color.toString(), "#333333")
                compare(palette.searchController.targetFilter, picker.values[i])
            }
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
