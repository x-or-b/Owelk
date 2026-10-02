import QtQuick
import QtTest
import "../qml" as App
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
        function test_homeTabSearchesTheWeb() {
            const d = workspace.documents
            // Cmd+T opens Home in a tab; its web field opens a web tab in place of that Home tab.
            verify(d.openResource(testInput.webFixture("/page.html")))
            tryCompare(activeTab(), "kind", "web")
            d.newHomeTab()
            tryCompare(activeTab(), "kind", "home")
            const homeTab = activeTab().id
            let home = null
            tryVerify(function() { const v = d.groupView(d.activeGroup); home = v ? findChild(v, "homeView") : null; return home !== null && home.visible })
            const field = findChild(home, "homeWebSearch")
            verify(field.placeholderText.indexOf("Search the web") === 0)
            field.text = testInput.webFixture("/page.html").toString()
            field.forceActiveFocus()
            testInput.keyClick(field, Qt.Key_Return)
            tryCompare(activeTab(), "kind", "web")
            compare(activeTab().id, homeTab)
            verify(activeTab().source.indexOf("/page.html") > 0)
            // Words search with the chosen engine.
            researchStore.setSetting("searchEngine", testInput.webFixture("/page.html").toString() + "?q=%s")
            d.newHomeTab()
            tryVerify(function() { const v = d.groupView(d.activeGroup); home = v ? findChild(v, "homeView") : null; return home !== null && home.visible && activeTab().kind === "home" })
            verify(home.searchWeb("lidar odometry"))
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("q=lidar%20odometry") > 0 })
            researchStore.setSetting("searchEngine", "")
        }
        function test_webCaptureKeepsPageAndReopensIt() {
            const d = workspace.documents
            const page = testInput.webFixture("/page.html?capture")
            verify(d.openResource(page))
            const pane = webPane()
            tryCompare(activeTab(), "title", "Owelk Test Page", 15000)
            wait(300)
            const before = researchStore.captures.length
            pane.captureRegion(Qt.rect(0, 0, 300, 120))
            tryVerify(function() { return researchStore.captures.length === before + 1 }, 10000)
            const capture = researchStore.captures[0]
            compare(capture.kind, "web")
            compare(capture.name, "Owelk Test Page")
            verify(capture.imageAvailable)
            const image = testInput.imageSize(capture.image)
            verify(image.width > 50 && image.height > 20, JSON.stringify(image))
            // Opening it brings back the page, not a PDF check.
            d.openNote(researchStore.createNote("placeholder", ""), true)
            researchStore.openCapture(capture.id)
            tryVerify(function() { return activeTab().kind === "web" && activeTab().source.indexOf("capture") >= 0 }, 5000)
            researchStore.deleteCapture(capture.id); researchStore.purgeCapture(capture.id)
        }
        function test_shortcutOpensWebTabAndAddressNavigates() {
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true)
            workspace.homeVisible = false
            researchStore.setSetting("startPage", testInput.webFixture("/page.html").toString())
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
            researchStore.setSetting("startPage", "")
        }
    }
}
