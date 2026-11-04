import QtQuick
import QtTest
import Owelk.Ui
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
        function visualChild(item, name) {
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        // An iPad held upright: a side panel covers the pages instead of narrowing them, a press on the pages puts
        // it away (doing nothing else there), and held sideways again the panels open before come back.
        function test_tallTouchScreenPanelsCoverThePages() {
            app.width = 1440; app.height = 930
            app.documents.restore({})
            app.filesVisible = true; app.filesSide = "right"; app.aiVisible = false; app.documentVisible = false; app.threadsVisible = false
            app.homeVisible = true
            app.openDocument(fixtureSource)
            app.homeVisible = false
            tryCompare(app.currentReader, "pdfReady", true)
            Theme.touch = true
            try {
                const layer = visualChild(app.contentItem.parent, "panelLayer"), dock = visualChild(app.contentItem.parent, "rightDock")
                const row = dock.parent
                app.width = 820; app.height = 1180
                tryCompare(app, "panelsOver", true)
                compare(app.filesVisible, false)
                app.togglePanel("files")
                tryCompare(dock, "visible", true)
                compare(dock.parent, layer)
                tryVerify(function() { return Math.abs(dock.x + dock.width - layer.width) < 1 && dock.width >= 160 })
                tryVerify(function() { return app.documents.width >= layer.width - 1 }, 2000, "pages " + app.documents.width + " of " + layer.width)
                const list = findChild(app.currentReader.pdfCanvas, "pageList"), before = list.contentY
                mouseClick(layer, 40, layer.height / 2)
                tryCompare(app, "filesVisible", false)
                compare(list.contentY, before)
                // Opened while upright, AI chat goes when the window turns; the Library open before comes back.
                app.togglePanel("ai")
                app.width = 1440; app.height = 930
                tryCompare(app, "panelsOver", false)
                compare(app.filesVisible, true)
                compare(app.aiVisible, false)
                compare(dock.parent, row)
                tryVerify(function() { return app.documents.width < 1440 - 150 })
            } finally {
                Theme.touch = false
                app.width = 1440; app.height = 930
            }
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
