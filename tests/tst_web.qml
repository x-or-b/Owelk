import QtQuick
import QtTest
import "../qml" as App
import "../qml/WebSearch.js" as WebSearch
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    SignalSpy { id: downloads; signalName: "downloadStarted" }
    SignalSpy { id: fetches; signalName: "downloadStarted" }
    TestCase {
        name: "WebTabs"
        when: windowShown
        function cleanupTestCase() { workspace.visible = false }
        function init() {
            workspace.width = 1440; workspace.height = 930
            workspace.documents.restore({})
            workspace.homeVisible = true
            researchStore.setSetting("downloadFolder", testInput.temporaryFolder("web downloads"))
        }
        function activeTab() {
            const d = workspace.documents, g = Tree.find(d.tree, d.activeGroup)
            return g.tabs.find(function(t) { return t.id === g.activeTab })
        }
        function webPane() {
            let pane = null
            tryVerify(function() { const v = workspace.documents.groupView(workspace.documents.activeGroup); pane = v ? v.webPane : null; return pane !== null }, 5000)
            return pane
        }
        function test_routerAndHelpers() {
            verify(Tree.validate({kind: "group", id: "g", activeTab: "t", tabs: [Tree.webTab("https://arxiv.org/abs/1")].map(function(t) { t.id = "t"; return t })}, {}, 0))
            verify(!Tree.validate({kind: "group", id: "g", activeTab: "t", tabs: [{id: "t", kind: "web", source: "javascript:alert(1)", position: {page: 0}}]}, {}, 0))
            compare(Tree.addressToUrl("arxiv.org/abs/1706.03762", "S=%s"), "https://arxiv.org/abs/1706.03762")
            compare(Tree.addressToUrl("occlusion mapping", "https://s/?q=%s"), "https://s/?q=occlusion%20mapping")
            compare(Tree.arxivPdf("https://arxiv.org/abs/1706.03762v7"), "https://arxiv.org/pdf/1706.03762v7")
            verify(!workspace.documents.openResource("ftp://example.com/x"))
        }
        function test_webTabTitleSessionAndPdfDownload() {
            const d = workspace.documents
            const page = testInput.webFixture("/page.html")
            verify(d.openResource(page))
            compare(activeTab().kind, "web")
            const pane = webPane()
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000)
            const tabLabel = findChild(d.groupView(d.activeGroup), "tab-" + activeTab().id)
            verify(tabLabel !== null)
            // The session keeps web tabs by address and survives validation.
            const saved = d.snapshot()
            verify(Tree.validate(saved.tree, {}, 0))
            verify(JSON.stringify(saved.tree).indexOf("/page.html") >= 0)
            // A PDF link inside the page downloads into the chosen folder and opens next to the page.
            const webTabId = activeTab().id
            pane.view.runJavaScript("document.getElementById('pdf').click()")
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
            const opened = activeTab()
            verify(opened.source.indexOf("web%20downloads") >= 0 || opened.source.indexOf("web downloads") >= 0, opened.source)
            verify(Tree.owner(d.tree, webTabId) !== undefined && Tree.owner(d.tree, webTabId) !== null) // The page stays open.
            tryVerify(function() { const r = workspace.currentReader; return r && findChild(r, "pdfCanvas0").ready }, 10000)
            // Opening a PDF address directly replaces the tab that only fetched it.
            verify(d.openWeb(testInput.webFixture("/paper.pdf").toString(), true))
            const fetching = activeTab().id
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
            verify(!Tree.owner(d.tree, fetching))
            verify(researchStore.downloadTarget("paper.pdf").fileName !== "paper.pdf") // Never overwrites.
        }
        function test_downloadShowsProgressAndPdfsCanStayInTheTab() {
            const d = workspace.documents
            verify(d.openResource(testInput.webFixture("/page.html")))
            const pane = webPane()
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000)
            // A download announces itself and shows its bar until the reader opens.
            downloads.clear(); downloads.target = pane
            pane.view.runJavaScript("document.getElementById('pdf').click()")
            tryCompare(downloads, "count", 1, 15000)
            verify(downloads.signalArguments[0][0].indexOf(".pdf") > 0)
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
            // Shown in the tab instead: no download until Open in Reader.
            d.activateTab(Tree.leaves(d.tree)[0].tabs.find(function(t) { return t.kind === "web" }).id)
            const again = webPane()
            const fetched = fetches
            fetched.clear(); fetched.target = again
            tryVerify(function() { return again.view.url.toString().indexOf("page.html") > 0 && !again.view.loading }, 15000)
            again.browserPdf = true // Changing the viewer setting reloads the page.
            wait(300)
            tryVerify(function() { return !again.view.loading }, 15000)
            again.view.url = testInput.webFixture("/paper.pdf")
            tryVerify(function() { return again.showsPdf && !again.view.loading }, 15000)
            wait(500)
            compare(fetched.count, 0)
            compare(activeTab().kind, "web")
            const button = findChild(again, "webOpenInReader")
            tryCompare(button, "visible", true)
            const before = Tree.leaves(d.tree)[0].tabs.length
            button.clicked()
            tryCompare(fetched, "count", 1, 15000)
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
            compare(Tree.leaves(d.tree)[0].tabs.length, before + 1) // The web tab stays.
            again.browserPdf = false
        }
        function test_downloadBarFillsWithTheFileSize() {
            const d = workspace.documents
            verify(d.openResource(testInput.webFixture("/page.html")))
            const pane = webPane()
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000)
            downloads.clear(); downloads.target = pane
            pane.view.url = testInput.webFixture("/slow.pdf")
            tryCompare(downloads, "count", 1, 15000)
            const bar = findChild(pane, "webDownloadBar"), track = findChild(pane, "webDownloadProgress")
            const label = findChild(pane, "webDownloadLabel")
            tryCompare(bar, "visible", true)
            // The size is known: a filling bar and the file size, no percentages or running bytes.
            tryCompare(track, "visible", true, 5000)
            tryVerify(function() { return track.progress > 0 && track.progress < 1 }, 5000)
            verify(/· 9\d\d KB$/.test(label.text), label.text)
            verify(label.text.indexOf("%") < 0 && label.text.indexOf(" of ") < 0)
            const first = track.progress
            tryVerify(function() { return track.progress > first }, 5000)
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
        }
        function test_pageWithAFramedPdfOffersBothWays() {
            const d = workspace.documents
            verify(d.openResource(testInput.webFixture("/embed.html")))
            const pane = webPane()
            tryCompare(activeTab(), "title", "getPDF", 15000)
            const notice = findChild(pane, "webPdfNotice")
            tryCompare(notice, "visible", true, 10000)
            verify(pane.embeddedPdf.indexOf("/paper.pdf") > 0)
            compare(findChild(pane, "webShowPdfHere").visible, true)
            // Show Here keeps PDFs in the tab (the page reloads with the viewer on).
            findChild(pane, "webShowPdfHere").clicked()
            compare(pane.browserPdf, true)
            tryVerify(function() { return !pane.view.loading && pane.embeddedPdf.length > 0 }, 15000)
            compare(findChild(pane, "webShowPdfHere").visible, false)
            // Open in Reader fetches the framed PDF through the tab and opens it beside the page.
            const webTab = activeTab().id
            downloads.clear(); downloads.target = pane
            findChild(pane, "webOpenInReader").clicked()
            tryCompare(downloads, "count", 1, 15000)
            tryVerify(function() { return activeTab().kind !== "web" }, 15000)
            verify(Tree.owner(d.tree, webTab) !== null && Tree.owner(d.tree, webTab) !== undefined)
        }
        function test_homeTabSearchesTheWeb() {
            const d = workspace.documents
            const palette = findChild(workspace, "searchPalette"), field = findChild(workspace, "topSearchField")
            const row = findChild(palette, "webSearchRow")
            // Cmd+T opens Home in a tab with the cursor in the top bar's search field (Home has no box of its
            // own); an address chooses the web row, and the page takes the Home tab's place.
            verify(d.openResource(testInput.webFixture("/page.html")))
            tryCompare(activeTab(), "kind", "web")
            d.newHomeTab()
            tryCompare(activeTab(), "kind", "home")
            const homeTab = activeTab().id
            tryVerify(function() { return field.activeFocus || field.focus })
            verify(findChild(d.groupView(d.activeGroup), "homeSearch") === null)
            field.text = testInput.webFixture("/page.html").toString()
            palette.open(); tryCompare(palette, "opened", true)
            tryVerify(function() { return palette.webSelected && row.isAddress })
            testInput.keyClick(field, Qt.Key_Return)
            tryCompare(activeTab(), "kind", "web")
            compare(activeTab().id, homeTab)
            verify(activeTab().source.indexOf("/page.html") > 0)
            compare(field.text, "")
            // Words search with the chosen engine; Cmd+Return goes to the web whatever is chosen.
            researchStore.setSetting("searchEngine", testInput.webFixture("/page.html").toString() + "?q=%s")
            d.newHomeTab()
            tryCompare(activeTab(), "kind", "home")
            field.text = "lidar odometry"
            palette.open(); tryCompare(palette, "opened", true)
            testInput.keyClick(field, Qt.Key_Return, Qt.ControlModifier)
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("q=lidar%20odometry") > 0 })
            // Engines of one's own join the built-in ones; Tab on the web row steps to the next engine.
            const template = testInput.webFixture("/page.html").toString() + "?mine=%s"
            verify(WebSearch.add(researchStore, "Mine", template))
            verify(!WebSearch.add(researchStore, "No words", "https://example.org/search"))
            compare(WebSearch.all(researchStore).map(function(e) { return e.name }), ["Google Scholar", "arXiv", "Google", "DuckDuckGo", "Mine"])
            researchStore.setSetting("searchEngine", "")
            d.newHomeTab()
            tryCompare(activeTab(), "kind", "home")
            field.text = "zzqx radar"
            palette.open(); tryCompare(palette, "opened", true)
            tryVerify(function() { return palette.webSelected && row.visible })
            compare(row.engineName, "Google Scholar")
            for (let i = 0; i < 4; ++i) testInput.keyClick(field, Qt.Key_Tab)
            compare(row.engineName, "Mine")
            // A hidden engine leaves the chooser; the default always stays.
            WebSearch.setHidden(researchStore, "https://www.google.com/search?q=%s", true)
            verify(!row.engines.some(function(e) { return e.name === "Google" }))
            WebSearch.setHidden(researchStore, "https://www.google.com/search?q=%s", false)
            testInput.keyClick(field, Qt.Key_Return, Qt.ControlModifier)
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("mine=zzqx%20radar") > 0 })
            // The default (Settings › Web) is what the search starts with; removing it falls back to Google Scholar.
            WebSearch.setDefault(researchStore, template)
            compare(WebSearch.current(researchStore).name, "Mine")
            WebSearch.remove(researchStore, template)
            compare(WebSearch.current(researchStore).name, "Google Scholar")
            researchStore.setSetting("searchEngine", "")
            // A site is enough to add an engine.
            compare(WebSearch.templateFor("google.com"), "https://www.google.com/search?q=%s")
            compare(WebSearch.nameFor("naver.com"), "Naver")
        }
        function test_searchPaletteSearchesTheWebToo() {
            const d = workspace.documents
            researchStore.setSetting("searchEngine", testInput.webFixture("/page.html").toString() + "?q=%s")
            const palette = findChild(workspace, "searchPalette")
            palette.open()
            tryCompare(palette, "opened", true)
            const box = palette.queryField, row = findChild(palette, "webSearchRow")
            // Nothing saved matches: the web row is chosen and Return searches in a new tab.
            box.text = "qqzz lidar"
            tryVerify(function() { return palette.webSelected && row.visible })
            verify(findChild(row, "webSearchText").text.indexOf("qqzz lidar") > 0)
            const tabs = Tree.leaves(d.tree).reduce(function(n, g) { return n + g.tabs.length }, 0)
            box.forceActiveFocus()
            testInput.keyClick(box, Qt.Key_Return)
            tryCompare(palette, "opened", false)
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("q=qqzz%20lidar") > 0 })
            compare(Tree.leaves(d.tree).reduce(function(n, g) { return n + g.tabs.length }, 0), tabs + 1)
            researchStore.setSetting("searchEngine", "")
        }
        function test_webRegionGoesToTheAi() {
            const d = workspace.documents
            const page = testInput.webFixture("/page.html?region")
            verify(d.openResource(page))
            const pane = webPane()
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000)
            wait(300)
            const ai = findChild(workspace, "aiController")
            ai.images = []
            pane.captureRegion(Qt.rect(0, 0, 300, 120))
            tryVerify(function() { return ai.images.length === 1 }, 10000)
            compare(ai.images[0].name, "Web · Owelk Test Page")
            const image = testInput.imageSize(ai.images[0].url)
            verify(image.width > 50 && image.height > 20, JSON.stringify(image))
            ai.images = []
        }
        function test_shortcutOpensWebTabAndAddressNavigates() {
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true)
            workspace.homeVisible = false
            // A new web tab opens on the default engine's own page (its address without the words).
            researchStore.setSetting("searchEngine", testInput.webFixture("/page.html").toString() + "?q=%s")
            findChild(workspace, "openWebAction").trigger()
            compare(activeTab().kind, "web")
            const pane = webPane()
            const address = findChild(pane, "webAddress")
            tryVerify(function() { return address.focus }) // activeFocus needs the window to be active, which offscreen tests are not.
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000) // Let the start page finish loading first.
            address.text = testInput.webFixture("/page.html?second").toString()
            address.accepted()
            tryVerify(function() { return activeTab().source.indexOf("second") >= 0 }, 15000)
            tryVerify(function() { return pane.view.canGoBack }, 15000)
            mouseClick(findChild(pane, "webBack"))
            tryVerify(function() { return activeTab().source.indexOf("second") < 0 }, 15000)
            researchStore.setSetting("searchEngine", "")
        }
    }
}
