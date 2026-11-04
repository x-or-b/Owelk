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
                // Upright, AI chat floats over the pages beside the Library and stays while the pages are tapped;
                // its bar moves it.
                const float = visualChild(app.contentItem.parent, "aiFloat"), leftDock = visualChild(app.contentItem.parent, "leftDock")
                app.togglePanel("ai")
                tryCompare(float, "visible", true)
                verify(float.width >= 280 && float.height >= 240)
                verify(float.x + float.width <= layer.width && float.y >= 0)
                compare(leftDock.visible, false)
                app.togglePanel("files")
                tryCompare(app, "filesVisible", true)
                compare(app.aiVisible, true)
                mouseClick(layer, 40, layer.height * .8)
                tryCompare(app, "filesVisible", false)
                compare(app.aiVisible, true)
                verify(float.visible)
                const bar = findChild(float, "floatingPanelBar"), x0 = float.x
                mouseDrag(bar, 20, bar.height / 2, -120, 0)
                tryVerify(function() { return float.x < x0 - 60 })
                verify(researchStore.setting("ai.floatPlace", "").split(" ").length === 4)
                // Turned sideways, the chat goes back to its dock and the Library open before comes back beside it.
                app.togglePanel("files"); app.togglePanel("files")
                app.width = 1440; app.height = 930
                tryCompare(app, "panelsOver", false)
                compare(app.aiVisible, true)
                compare(float.visible, false)
                tryCompare(leftDock, "visible", true)
                compare(leftDock.activePanel, "ai")
                compare(dock.parent, row)
                tryVerify(function() { return app.documents.width < 1440 - 150 })
                // Upright again: it floats where it was left; its close button puts it away.
                app.width = 820; app.height = 1180
                tryCompare(float, "visible", true)
                verify(float.x < x0 - 60)
                mouseClick(findChild(float, "floatingPanelClose"))
                tryCompare(app, "aiVisible", false)
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
