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
