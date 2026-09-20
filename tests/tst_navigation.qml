import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 1000; height: 760
    App.ReaderPane { id: reader; x: 240; width: 760; height: 760; isActive: true }
    App.PdfNavigationPanel { id: panel; width: 230; height: 760; reader: reader; onModeChosen: function(mode) { panel.mode = mode } }
    TestCase {
        name: "PdfNavigation"
        when: windowShown
        function init() {
            panel.reader = reader; panel.mode = 0
            reader.openFile(outlineSource)
            tryCompare(reader, "pdfReady", true)
            tryCompare(findChild(reader, "pdfCanvas0"), "restoring", false)
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
            panel.mode = 1
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 8)
            panel.reader = null
            compare(panel.ready, false)
            tryCompare(findChild(panel, "pdfThumbnails"), "count", 0)
        }
    }
}
