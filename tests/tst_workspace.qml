import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 1440
    height: 930
    App.Main { id: workspace }
    Component { id: restoredWindow; App.Main { visible: false } }
    TestCase {
        name: "WorkspacePanels"
        when: windowShown
        function visualChild(item, name) {
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) {
                const found = visualChild(children[i], name)
                if (found) return found
            }
            return null
        }
        function cleanupTestCase() { workspace.visible = false }
        function init() {
            workspace.filesVisible = true
            workspace.shelfVisible = true
            workspace.filesSide = "left"
            workspace.capturesSide = "right"
        }
        function test_closeAndReopen() {
            const dock = findChild(workspace, "rightDock")
            const close = findChild(dock, "closePanel")
            verify(close !== null)
            mouseClick(close)
            compare(workspace.shelfVisible, false)
            compare(dock.visible, false)
            workspace.shelfVisible = true
            compare(dock.visible, true)
        }
        function test_moveAndPersist() {
            workspace.movePanel("captures", "left")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            compare(workspace.leftPanels.length, 2)
            compare(workspace.rightPanels.length, 0)
            workspace.persist()
            const saved = researchStore.session.panels
            compare(saved.filesSide, "left")
            compare(saved.capturesSide, "left")
            compare(saved.leftActive, "captures")
        }
        function test_dragToOppositeSide() {
            const handle = visualChild(findChild(workspace, "statusBar"), "dockIcon-captures")
            verify(handle !== null)
            const start = handle.mapToItem(null, handle.width / 2, handle.height / 2)
            mouseDrag(handle, handle.width / 2, handle.height / 2, 80 - start.x, 0, Qt.LeftButton, Qt.NoModifier, 40)
            tryCompare(workspace, "capturesSide", "left")
            compare(workspace.draggingPanel, "")
        }
        function test_cancelKeepsSide() {
            const bar = findChild(workspace, "statusBar")
            const y = bar.mapToItem(null, 0, bar.height / 2).y
            workspace.dragPanel("captures", 80, y)
            compare(workspace.dragSide, "left")
            workspace.dropPanel("captures", 80, y, true)
            compare(workspace.capturesSide, "right")
            compare(workspace.draggingPanel, "")
        }
        function test_iconTogglesClosedPanel() {
            workspace.shelfVisible = false
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-captures")
            verify(icon.visible)
            mouseClick(icon)
            tryCompare(workspace, "shelfVisible", true)
            mouseClick(icon)
            compare(workspace.shelfVisible, false)
        }
        function test_dropOutsideFooterDoesNotMove() {
            workspace.dragPanel("captures", 80, 100)
            compare(workspace.dragSide, "")
            workspace.dropPanel("captures", 80, 100, false)
            compare(workspace.capturesSide, "right")
        }
        function test_hiddenPanelMovesWithoutOpening() {
            workspace.shelfVisible = false
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-captures")
            const start = icon.mapToItem(null, icon.width / 2, icon.height / 2)
            mouseDrag(icon, icon.width / 2, icon.height / 2, 80 - start.x, 0, Qt.LeftButton, Qt.NoModifier, 40)
            tryCompare(workspace, "capturesSide", "left")
            compare(workspace.shelfVisible, false)
        }
        function test_homeAndContinue() {
            workspace.activePane = 0
            workspace.openDocument(fixtureSource, {page: 2, y: .2, x: 0, zoom: 1})
            const canvas = findChild(workspace, "pdfCanvas0")
            tryCompare(canvas, "ready", true)
            tryCompare(canvas, "restoring", false)
            compare(workspace.homeVisible, false)
            workspace.showHome()
            compare(workspace.homeVisible, true)
            compare(researchStore.continueReading.position.page, 2)
            const button = findChild(workspace, "continueReading")
            mouseClick(button)
            compare(workspace.homeVisible, false)
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 2)
        }
        function test_newWorkspaceStartsAtHome() {
            const id = researchStore.createWorkspace("UI test workspace")
            workspace.openWorkspace(id)
            compare(workspace.homeVisible, true)
            compare(workspace.activeWorkspace, id)
            compare(findChild(workspace, "pdfCanvas0").source.toString(), "")
            workspace.openDocument(fixtureSource, {page: 1, y: .1, x: 0, zoom: 1})
            const canvas = findChild(workspace, "pdfCanvas0")
            tryCompare(canvas, "ready", true)
            tryCompare(canvas, "restoring", false)
            workspace.persist()
            workspace.openWorkspace(researchStore.createWorkspace("Another workspace"))
            workspace.openWorkspace(id)
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 1)
            compare(workspace.homeVisible, false)
        }
        function test_homeSearchOpensWorkspace() {
            const id = researchStore.createWorkspace("Searchable topic 123")
            workspace.showHome()
            const query = findChild(workspace, "homeSearch")
            const results = findChild(workspace, "homeResults")
            query.text = "Searchable topic 123"
            tryCompare(results, "count", 1)
            compare(results.model[0].kind, "workspace")
            testInput.keyClick(query, Qt.Key_Return)
            compare(workspace.activeWorkspace, id)
            compare(workspace.homeVisible, true)
            query.text = "no such saved object 987"
            tryCompare(results, "count", 0)
            testInput.keyClick(query, Qt.Key_Escape)
            compare(query.text, "")
        }
        function test_homeStateRestores() {
            workspace.showHome()
            workspace.persist()
            const restored = createTemporaryObject(restoredWindow, null)
            verify(restored !== null)
            compare(restored.homeVisible, true)
        }
        function test_panelStateRestores() {
            workspace.movePanel("captures", "left")
            workspace.movePanel("files", "right")
            workspace.paperFolder = fixtureFolder
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            workspace.persist()
            const restored = createTemporaryObject(restoredWindow, null)
            verify(restored !== null)
            compare(restored.capturesSide, "left")
            compare(restored.filesSide, "right")
            compare(restored.paperFolder.toString(), fixtureFolder.toString())
            compare(findChild(restored, "leftDock").activePanel, "captures")
        }
        function test_toggleSharedDock() {
            workspace.movePanel("captures", "left")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            workspace.togglePanel("files")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "files")
            workspace.togglePanel("files")
            compare(workspace.filesVisible, false)
            compare(workspace.shelfVisible, true)
        }
    }
}
