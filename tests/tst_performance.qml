import QtQuick
import QtTest
import "../qml" as App

Item {
    id: root
    width: 1200; height: 850
    property int readerCount: 1
    Repeater {
        id: readers
        model: root.readerCount
        App.ReaderPane {
            required property int index
            x: root.readerCount === 1 ? 0 : (index % 2) * 600
            y: root.readerCount === 1 ? 0 : Math.floor(index / 2) * 425
            width: root.readerCount === 1 ? 1200 : 600
            height: root.readerCount === 1 ? 850 : 425
            managed: true
        }
    }
    TestCase {
        name: "ReaderPerformance"
        when: windowShown
        function images(item) {
            let result = /^pageImage\d+$/.test(item.objectName) ? [item] : []
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) result = result.concat(images(children[i]))
            return result
        }
        function ready(reader, page) {
            tryCompare(reader, "pdfReady", true, 10000)
            const canvas = findChild(reader, "pdfCanvas0")
            tryCompare(canvas, "restoring", false, 10000)
            tryVerify(function() { return findChild(canvas, "pageImage" + page) !== null })
            tryCompare(findChild(canvas, "pageImage" + page), "status", Image.Ready, 10000)
            return canvas
        }
        function test_baseline() {
            const start = Date.now()
            readers.itemAt(0).openFile(longSource)
            const canvas = ready(readers.itemAt(0), 0)
            const firstPageMs = Date.now() - start
            compare(canvas.pageCount, 120)
            const loaded = images(canvas).length
            verify(loaded < 12, "A long PDF must not instantiate every page")
            const point = Qt.point(canvas.width / 2, 220)
            const indexingAtPinchStart = researchStore.paperIndex.busy
            verify(canvas.beginPinch(point))
            const pinchStart = Date.now()
            for (let i = 1; i <= 60; ++i) canvas.updatePinch(1 + i / 100, point)
            const pinchUpdatesMs = Date.now() - pinchStart
            canvas.endPinch()
            const splitStart = Date.now()
            root.readerCount = 4
            for (let i = 0; i < 4; ++i) readers.itemAt(i).openFile(longSource)
            for (let i = 0; i < 4; ++i) ready(readers.itemAt(i), 0)
            const fourReadersMs = Date.now() - splitStart
            const totalImages = images(root).length
            verify(totalImages < 32)
            console.log("PERF " + JSON.stringify({pages: 120, firstPageMs: firstPageMs, initialPageItems: loaded,
                pinch60UpdatesMs: pinchUpdatesMs, fourReadersMs: fourReadersMs, fourReaderPageItems: totalImages,
                indexingAtPinchStart: indexingAtPinchStart}))
        }
    }
}
