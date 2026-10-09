import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui
import "../qml" as App

Item {
    width: 1000; height: 760
    App.ReaderPane { id: reader; x: 240; width: 760; height: 760; isActive: true }
    App.PdfNavigationPanel { id: panel; width: 230; height: 760; reader: reader; onModeChosen: function(mode) { panel.mode = mode } }
    Component { id: linkSpyComponent; SignalSpy { target: panel; signalName: "linkActivated" } }
    TestCase {
        name: "PdfNavigation"
        when: windowShown
        function init() {
            panel.reader = reader; panel.mode = 0
            reader.openFile(outlineSource)
            tryCompare(reader, "pdfReady", true)
            tryCompare(findChild(reader, "pdfCanvas0"), "restoring", false)
        }
        function test_citationsAreFetchedOnRequestAndKept() {
            verify(researchStore.rememberDocument(outlineSource))
            verify(researchStore.updateDocumentDetails(outlineSource, {title: "Outline Fixture", doi: "10.1/outline"}))
            researchStore.setSetting("citations.baseUrl", testInput.webFixture("/graph/v1").toString())
            const spy = createTemporaryObject(linkSpyComponent, panel)
            mouseClick(findChild(panel, "citationsTab"))
            compare(panel.mode, 4)
            // Nothing is sent until asked.
            const find = findChild(panel, "findCitations")
            tryCompare(find, "visible", true)
            mouseClick(find)
            const list = findChild(panel, "citationList")
            function row(i) { let item = null; tryVerify(function() { list.forceLayout(); item = list.itemAtIndex(i); return item !== null }); return item }
            tryCompare(list, "count", 1, 5000)
            compare(row(0).modelData.title, "Cited Work")
            mouseClick(findChild(panel, "citedByTab"))
            tryCompare(list, "count", 2)
            tryCompare(row(0).modelData, "title", "Later Work") // Most cited first.
            // A paper outside the Library opens its page.
            mouseClick(findChild(panel, "citesTab"))
            tryCompare(list, "count", 1)
            tryVerify(function() { return row(0).modelData.title === "Cited Work" })
            mouseClick(row(0))
            compare(spy.count, 1)
            compare(spy.signalArguments[0][0], "https://arxiv.org/abs/1801.00001")
            // Coming back shows the saved results without asking again.
            mouseClick(findChild(panel, "outlineTab"))
            mouseClick(findChild(panel, "citationsTab"))
            tryCompare(list, "count", 1)
            verify(panel.citations.cached)
            verify(!find.visible)
            mouseClick(findChild(panel, "outlineTab"))
        }
        function test_nestedOutlineAndDestination() {
            const tree = findChild(panel, "pdfOutline")
            tryVerify(function() { return tree.rows >= 2 })
            tree.expandRecursively()
            tryCompare(tree, "rows", 3)
            tree.forceLayout()
            const method = tree.itemAtCell(Qt.point(0, 1))
            verify(method !== null)
            compare(method.title, "Method")
            mouseClick(method, method.width - 20, 15)
            tryCompare(reader, "currentPage", 1)
            const canvas = findChild(reader, "pdfCanvas0")
            tryCompare(canvas, "restoring", false)
            verify(canvas.position().y > .3)
        }
        function test_modesAreIconSegments() {
            const outline = findChild(panel, "outlineTab"), thumbnails = findChild(panel, "thumbnailsTab")
            // The current segment is raised; the others are flat until hovered. Icons say what each is.
            verify(outline.checked && !thumbnails.checked)
            verify(outline.background.color.a > 0)
            compare(thumbnails.background.color.a, 0)
            compare(thumbnails.icon.name, "thumbnails")
            compare(thumbnails.ToolTip.text, "Thumbnails")
            mouseClick(thumbnails)
            compare(panel.mode, 1)
            verify(thumbnails.checked && !outline.checked)
        }
        function test_thumbnailsReuseReaderAndJump() {
            panel.mode = 1
            const list = findChild(panel, "pdfThumbnails")
            tryCompare(list, "count", 3)
            tryVerify(function() { return list.height > 0 })
            list.forceLayout()
            tryVerify(function() { return list.itemAtIndex(0) !== null })
            const first = list.itemAtIndex(0)
            verify(first !== null)
            const image = findChild(first, "thumbnailImage-0")
            compare(image.document, reader.pdfDocument)
            tryCompare(image, "status", Image.Ready, 10000)
            // The page sits on paper; with Dark pages, dark paper and the inverted image.
            const paper = findChild(first, "thumbnailPaper-0")
            verify(Qt.colorEqual(paper.color, Theme.paper))
            if (Theme.canInvertPages) {
                Theme.invertPages = true
                tryVerify(function() { return Qt.colorEqual(paper.color, Theme.paperInverted) })
                verify(image.layer.enabled)
                Theme.invertPages = false
                verify(!image.layer.enabled)
            }
            list.positionViewAtIndex(2, ListView.Contain); list.forceLayout()
            mouseClick(list.itemAtIndex(2))
            tryCompare(reader, "currentPage", 2)
            panel.mode = 0
            tryCompare(list, "count", 0, 5000)
        }
        function test_switchPdfAndNoOutline() {
            reader.openFile(fixtureSource)
            tryCompare(reader, "pageCount", 8)
            const tree = findChild(panel, "pdfOutline")
            tryCompare(tree, "rows", 0)
            const empty = findChild(panel, "emptyOutlineMessage")
            waitForPolish(panel)
            verify(empty.visible && empty.width > 100 && empty.height > 20)
            const center = empty.mapToItem(panel, empty.width / 2, empty.height / 2)
            verify(Math.abs(center.x - panel.width / 2) < 2)
            verify(center.y > panel.height / 3 && center.y < panel.height * .8)
            panel.mode = 1
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 8)
            panel.reader = null
            compare(panel.ready, false)
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 0)
        }
    }
}
