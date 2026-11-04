import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 1440; height: 930
    App.Main { id: app }
    TestCase {
        name: "SwipeNavigation"
        when: windowShown
        function cleanupTestCase() { app.visible = false }
        // In the whole window too (tabs, panels and window-wide handlers around the reader), a finger scrolls.
        function test_fingerScrollsTheOpenPdf() {
            app.width = 1440; app.height = 930
            app.documents.restore({})
            app.filesVisible = false; app.aiVisible = false; app.documentVisible = false
            app.homeVisible = true
            app.openDocument(fixtureSource)
            app.homeVisible = false
            const reader = app.currentReader
            tryCompare(reader, "pdfReady", true)
            const canvas = reader.pdfCanvas
            tryCompare(canvas, "restoring", false)
            canvas.jump(0, 0, 0)
            tryCompare(canvas, "restoring", false)
            wait(300)
            const list = findChild(canvas, "pageList")
            const before = list.contentY
            const x = canvas.width / 2, from = canvas.height * 0.75
            const touch = touchEvent(canvas)
            touch.press(0, canvas, x, from).commit()
            for (let i = 1; i <= 12; ++i) {
                touch.move(0, canvas, x, from - i * 30).commit()
                wait(16)
            }
            touch.release(0, canvas, x, from - 360).commit()
            tryVerify(function() { return list.contentY > before + 150 }, 3000, "contentY " + list.contentY + " from " + before)
            compare(canvas.selectedText, "")
        }
        function test_pdfScrollBoundaries() {
            app.width = 1440; app.height = 930
            app.documents.restore({})
            app.filesVisible = false; app.aiVisible = false; app.documentVisible = false
            app.homeVisible = true
            app.openDocument(fixtureSource)
            app.homeVisible = false
            const reader = app.currentReader
            tryCompare(reader, "pdfReady", true)
            const canvas = reader.pdfCanvas
            tryCompare(canvas, "restoring", false)
            canvas.fitWidth()
            tryCompare(canvas, "restoring", false)
            wait(300)
            verify(!canvas.canScrollAcross(true))
            verify(!canvas.canScrollAcross(false))
            canvas.zoom(2)
            tryCompare(canvas, "restoring", false)
            wait(300)
            verify(canvas.canScrollAcross(true) || canvas.canScrollAcross(false))
            const point = canvas.mapToItem(null, canvas.width / 2, canvas.height / 2)
            const towardLeft = canvas.canScrollAcross(true)
            verify(!swipeNavigation.allowed(point.x, point.y, true, towardLeft))
            // A point in the side panel never starts navigation.
            verify(!swipeNavigation.allowed(-10, -10, true, true))
        }
    }
}
