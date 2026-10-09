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
            panel.reader = reader; panel.mode = 0; panel.setContents("outline"); panel.relatedSide = 0
            reader.openFile(outlineSource)
            tryCompare(reader, "pdfReady", true)
            tryCompare(findChild(reader, "pdfCanvas0"), "restoring", false)
        }
        function test_citationsAreFetchedOnRequestAndKept() {
            verify(researchStore.rememberDocument(outlineSource))
            verify(researchStore.updateDocumentDetails(outlineSource, {title: "Outline Fixture", doi: "10.1/outline"}))
            researchStore.setSetting("citations.baseUrl", testInput.webFixture("/graph/v1").toString())
            const spy = createTemporaryObject(linkSpyComponent, panel)
            mouseClick(findChild(panel, "relatedTab"))
            compare(panel.mode, 3)
            mouseClick(findChild(panel, "citesTab"))
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
            mouseClick(findChild(panel, "contentsTab"))
            mouseClick(findChild(panel, "relatedTab"))
            tryCompare(list, "count", 1)
            verify(panel.citations.cached)
            verify(!find.visible)
            compare(findChild(panel, "citesTab").text, "Cites 1")
            mouseClick(findChild(panel, "contentsTab"))
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
        function test_fourViewsAsIconSegments() {
            const contents = findChild(panel, "contentsTab"), annotations = findChild(panel, "annotationsTab")
            // The current segment is raised; the others are flat until hovered. Icons say what each is.
            verify(contents.checked && !annotations.checked)
            verify(contents.background.color.a > 0)
            compare(annotations.background.color.a, 0)
            compare(annotations.icon.name, "annotations")
            compare(annotations.ToolTip.text, "Annotations")
            compare(findChild(panel, "navigationMode").count, 4)
            // Contents switches between the outline and the pages, and remembers it.
            mouseClick(findChild(panel, "pagesTab"))
            compare(panel.contents, "pages")
            compare(researchStore.setting("document.contents"), "pages")
            mouseClick(findChild(panel, "outlineTab"))
            compare(panel.contents, "outline")
            mouseClick(annotations)
            compare(panel.mode, 1)
            verify(annotations.checked && !contents.checked)
        }
        function test_annotationsShowNotesAboutThePaperAndItsMarks() {
            const spy = createTemporaryObject(linkSpyComponent, panel)
            const paper = researchStore.documentLinkId(outlineSource)
            const note = researchStore.createNote("About the outline", "See " + researchStore.markdownLink("document", paper) + " again")
            mouseClick(findChild(panel, "annotationsTab"))
            // The reader writes new comments into this list while it shows.
            tryVerify(function() { return reader.annotationList !== null })
            compare(reader.annotationList.objectName, "annotationList")
            tryVerify(function() { return findChild(panel, "linkedNote-0") !== null })
            compare(findChild(panel, "linkedNote-0").text, "About the outline")
            mouseClick(findChild(panel, "linkedNote-0"))
            compare(spy.signalArguments[0][0], "owelk://note/" + note)
            // Unlinking keeps the words, without the link.
            verify(researchStore.unlinkNote(note, outlineSource))
            compare(researchStore.note(note).body, "See " + researchStore.displayName(outlineSource) + " again")
            tryVerify(function() { return findChild(panel, "linkedNote-0") === null })
            researchStore.deleteNote(note); researchStore.purgeNote(note)
            // Another view: the reader writes in dialogs again.
            mouseClick(findChild(panel, "contentsTab"))
            tryCompare(reader, "annotationList", null)
        }
        function test_thumbnailsReuseReaderAndJump() {
            panel.setContents("pages")
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
            panel.setContents("outline")
            tryCompare(list, "count", 0, 5000)
        }
        function test_symbolsAreListedWithWhereTheyAreDefined() {
            mouseClick(findChild(panel, "symbolsTab"))
            compare(panel.mode, 2)
            // Nothing is sent until asked; without a key the tab says what is missing.
            const find = findChild(panel, "findSymbols")
            tryCompare(find, "visible", true)
            researchStore.ai.provider = "claude"
            researchStore.ai.clearApiKey("claude")
            mouseClick(find)
            tryCompare(findChild(panel, "symbolsError"), "visible", true)
            // A list: each symbol, its meaning, and its page; a row goes to the defining words.
            panel.symbols = [{symbol: "\\omega_m", meaning: "angular velocity", page: 2, quote: "the angular velocity"},
                             {symbol: "SE_2(3)", meaning: "extended poses", page: 0, quote: ""}]
            const list = findChild(panel, "symbolList")
            tryCompare(list, "count", 2)
            verify(!find.visible)
            const spy = createTemporaryObject(linkSpyComponent, panel)
            tryVerify(function() { return findChild(panel, "symbolRow-0") !== null })
            tryVerify(function() { return list.width > 0 && list.height > 0 })
            mouseClick(findChild(panel, "symbolRow-0"))
            compare(spy.count, 1)
            verify(/^owelk:\/\/document\/[^#]+#page=2&q=the%20angular%20velocity$/.test(spy.signalArguments[0][0]), spy.signalArguments[0][0])
            // Background knowledge has no place in the paper to go to.
            verify(!findChild(panel, "symbolRow-1").enabled)
            panel.symbols = []
            mouseClick(findChild(panel, "contentsTab"))
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
            panel.setContents("pages")
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 8)
            panel.reader = null
            compare(panel.ready, false)
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 0)
        }
    }
}
