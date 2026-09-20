import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    Component { id: restoredWindow; App.Main { visible: false } }
    TestCase {
        name: "WorkspacePanels"
        when: windowShown
        function visualChild(item, name) {
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        function canvas() {
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader, "pdfCanvas0")
            tryCompare(c, "ready", true); tryCompare(c, "restoring", false)
            return c
        }
        function cleanupTestCase() { workspace.visible = false }
        function init() {
            workspace.activeWorkspace = ""; workspace.workspaceName = ""
            workspace.documents.restore({})
            workspace.filesVisible = true; workspace.shelfVisible = true
            workspace.filesSide = "left"; workspace.capturesSide = "right"
            workspace.documentVisible = false; workspace.documentSide = "left"; workspace.navigationMode = 0
            workspace.homeVisible = true
        }
        function test_noPanelCloseButton() {
            compare(findChild(findChild(workspace, "rightDock"), "closePanel"), null)
            workspace.togglePanel("captures")
            compare(workspace.shelfVisible, false)
            workspace.togglePanel("captures")
            compare(workspace.shelfVisible, true)
        }
        function test_contextMenuMovesPanel() {
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-captures")
            mouseClick(icon, 15, 14, Qt.RightButton)
            const menu = findChild(icon, "dockMenu-captures")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "leftDockOption"))
            tryCompare(workspace, "capturesSide", "left")
            workspace.persist()
            compare(researchStore.session.panels.capturesSide, "left")
        }
        function test_iconTogglesClosedPanel() {
            workspace.shelfVisible = false
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-captures")
            mouseClick(icon)
            tryCompare(workspace, "shelfVisible", true)
            mouseClick(icon)
            compare(workspace.shelfVisible, false)
        }
        function test_hiddenPanelMovesWithoutOpening() {
            workspace.shelfVisible = false
            workspace.movePanel("captures", "left")
            compare(workspace.shelfVisible, false)
            compare(workspace.capturesSide, "left")
        }
        function test_homeAndContinue() {
            workspace.openDocument(fixtureSource, {page: 2, y: .2, x: 0, zoom: 1})
            canvas()
            workspace.showHome()
            compare(researchStore.continueReading.position.page, 2)
            waitForPolish(workspace)
            mouseClick(findChild(workspace, "continueReading"))
            compare(workspace.homeVisible, false)
            compare(canvas().currentPage, 2)
        }
        function test_alwaysStartsAtHome() {
            workspace.openDocument(fixtureSource)
            canvas(); workspace.persist()
            compare(workspace.homeVisible, false)
            const restored = createTemporaryObject(restoredWindow, null)
            verify(restored !== null)
            compare(restored.homeVisible, true)
            compare(restored.currentReader.pdfReady, false, "Home startup should defer opening PDF engines")
            compare(Tree.leaves(restored.documents.tree)[0].tabs.length, 1)
        }
        function test_newWorkspaceStartsAtHome() {
            const id = researchStore.createWorkspace("UI test workspace")
            workspace.openWorkspace(id)
            compare(workspace.homeVisible, true)
            workspace.openDocument(fixtureSource, {page: 1, y: .1, x: 0, zoom: 1})
            canvas(); workspace.persist()
            workspace.openWorkspace(researchStore.createWorkspace("Another workspace"))
            workspace.openWorkspace(id)
            compare(canvas().currentPage, 1)
            compare(workspace.homeVisible, false)
        }
        function test_homeSearchOpensWorkspace() {
            const id = researchStore.createWorkspace("Searchable topic 123")
            workspace.showHome()
            const query = findChild(workspace, "homeSearch"), results = findChild(workspace, "homeResults")
            query.text = "Searchable topic 123"
            tryCompare(results, "count", 1)
            testInput.keyClick(query, Qt.Key_Return)
            compare(workspace.activeWorkspace, id)
            query.text = "no such saved object 987"
            tryCompare(results, "count", 0)
            testInput.keyClick(query, Qt.Key_Escape)
            compare(query.text, "")
        }
        function test_panelStateRestores() {
            workspace.movePanel("captures", "left"); workspace.movePanel("files", "right")
            workspace.paperFolder = fixtureFolder
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            workspace.persist()
            const restored = createTemporaryObject(restoredWindow, null)
            compare(restored.capturesSide, "left"); compare(restored.filesSide, "right")
            compare(restored.paperFolder.toString(), fixtureFolder.toString())
        }
        function test_toggleSharedDock() {
            workspace.movePanel("captures", "left")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            workspace.togglePanel("files")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "files")
            workspace.togglePanel("files")
            compare(workspace.filesVisible, false); compare(workspace.shelfVisible, true)
        }
        function test_tabIndependentPositionsAndShortcutClose() {
            const d = workspace.documents
            d.openDocument(fixtureSource, {page: 2, zoom: 1, y: 0, x: 0}, true); canvas()
            const first = d.tree.activeTab
            d.openDocument(fixtureSource, {page: 5, zoom: 1.4, y: 0, x: 0}, true)
            compare(canvas().currentPage, 5)
            const second = d.tree.activeTab
            d.activateTab(first)
            compare(canvas().currentPage, 2)
            d.activateTab(second)
            compare(canvas().currentPage, 5)
            testInput.keyClick(workspace.currentReader, Qt.Key_W, Qt.ControlModifier)
            tryCompare(d.tree, "activeTab", first)
            compare(d.tree.tabs.length, 1)
            d.closeActiveTab()
            compare(workspace.homeVisible, true)
            compare(d.groupCount, 1)
            compare(d.tree.tabs.length, 0)
        }
        function test_multipleSplitsRestoreAndPrune() {
            const d = workspace.documents
            d.openDocument(fixtureSource, {page: 3, y: 0, x: 0, zoom: 1})
            canvas()
            d.duplicateSplit("right"); canvas()
            d.duplicateSplit("bottom"); canvas()
            d.duplicateSplit("left"); canvas()
            compare(d.groupCount, 4)
            const saved = d.snapshot()
            verify(Tree.validate(saved.tree, {}, 0))
            d.restore(saved); canvas()
            compare(d.groupCount, 4)
            compare(canvas().currentPage, 3)
            d.closeActiveTab()
            compare(d.groupCount, 3)
            d.joinAll()
            compare(d.groupCount, 1)
            compare(d.tree.tabs.length, 3)
        }
        function test_dragTabToSplitAndCancel() {
            const d = workspace.documents
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 4, y: 0, x: 0, zoom: 1}, true); canvas()
            const id = d.tree.activeTab, view = d.groupView(d.activeGroup)
            const tab = visualChild(view, "tab-" + id)
            verify(tab !== null)
            const target = view.mapToItem(tab, view.width - 15, view.height / 2)
            mouseDrag(tab, 20, 15, target.x - 20, target.y - 15, Qt.LeftButton, Qt.NoModifier, 40)
            tryCompare(d, "groupCount", 2)
            compare(canvas().currentPage, 4)
            const before = JSON.stringify(d.snapshot().tree)
            d.dragTab(id, -100, -100); d.finishDrag(false)
            compare(JSON.stringify(d.snapshot().tree), before)
            const current = d.groupView(d.activeGroup), point = current.mapToItem(null, 10, current.height / 2)
            d.dragTab(id, point.x, point.y); d.finishDrag(true)
            compare(d.draggedTab, "")
            compare(JSON.stringify(d.snapshot().tree), before)
        }
        function test_moveLastTabIntoGroupAndReorder() {
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true); canvas()
            const firstGroup = d.activeGroup, first = d.tree.activeTab
            d.duplicateSplit("right"); canvas()
            const second = Tree.find(d.tree, d.activeGroup).activeTab
            d.moveTab(second, firstGroup, "center", 0)
            compare(d.groupCount, 1)
            compare(d.tree.tabs[0].id, second)
            d.moveTab(second, firstGroup, "center", 2)
            compare(d.tree.tabs[0].id, first)
            compare(d.tree.tabs[1].id, second)
        }
        function test_resizeSplitPreservesTabs() {
            const d = workspace.documents
            d.openDocument(fixtureSource); canvas()
            workspace.filesVisible = false; workspace.shelfVisible = false
            d.duplicateSplit("right"); canvas()
            const handle = visualChild(d.contentItem, "splitHandle-" + d.tree.id)
            verify(handle !== null)
            mouseDrag(handle, 3, 100, 100, 0, Qt.LeftButton, Qt.NoModifier, 40)
            verify(d.tree.ratio > .5)
            compare(d.groupCount, 2)
            const saved = d.snapshot()
            d.restore(saved)
            compare(d.tree.ratio, saved.tree.ratio)
        }
        function test_failedRestoreKeepsLiveTabs() {
            const d = workspace.documents
            d.openDocument(fixtureSource); canvas()
            const before = JSON.stringify(d.snapshot())
            let failed = false
            try { d.restore({version: 2, tree: {kind: "corrupt"}}) } catch (error) { failed = true }
            verify(failed)
            compare(JSON.stringify(d.snapshot()), before)
        }
        function test_reopenClosedTabKeepsPosition() {
            workspace.openDocument(fixtureSource, {page: 4, y: .15, x: 0, zoom: 1.3})
            canvas()
            workspace.documents.closeActiveTab()
            compare(workspace.homeVisible, true)
            compare(workspace.documents.closedTabs.length, 1)
            testInput.keyClick(findChild(workspace, "homeSearch"), Qt.Key_T, Qt.ControlModifier | Qt.ShiftModifier)
            compare(workspace.homeVisible, false)
            compare(canvas().currentPage, 4)
            compare(canvas().zoomFactor, 1.3)
            compare(workspace.documents.closedTabs.length, 0)
        }
        function test_separatePaletteShortcuts() {
            workspace.openDocument(fixtureSource); canvas()
            testInput.keyClick(workspace.currentReader, Qt.Key_K, Qt.ControlModifier)
            const search = findChild(workspace, "searchPalette"), commands = findChild(workspace, "commandPalette")
            tryCompare(search, "opened", true); compare(commands.visible, false)
            search.close(); tryCompare(search, "visible", false)
            testInput.keyClick(workspace.currentReader, Qt.Key_P, Qt.ControlModifier | Qt.ShiftModifier)
            tryCompare(commands, "opened", true); compare(search.visible, false)
            commands.close()
        }
        function test_navigationFollowsActiveGroupAndPersistsMode() {
            workspace.openDocument(outlineSource); canvas()
            workspace.togglePanel("document")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "document")
            let panel = findChild(workspace, "pdfNavigationPanel")
            verify(panel !== null)
            compare(panel.reader, workspace.currentReader)
            workspace.navigationMode = 1
            workspace.documents.duplicateSplit("right"); canvas()
            workspace.documents.openDocument(fixtureSource); canvas()
            compare(panel.reader.pageCount, 8)
            workspace.movePanel("document", "right")
            tryCompare(findChild(workspace, "rightDock"), "activePanel", "document")
            workspace.persist()
            compare(researchStore.session.panels.documentSide, "right")
            compare(researchStore.session.panels.navigationMode, 1)
            workspace.documents.joinAll()
            while (workspace.documents.hasTabs) workspace.documents.closeActiveTab()
            compare(workspace.homeVisible, true)
            const emptyPanel = findChild(workspace, "pdfNavigationPanel")
            compare(emptyPanel.ready, false)
        }
        function test_removeRecentRequiresConfirmation() {
            researchStore.rememberDocument(fixtureSource)
            workspace.showHome()
            const item = visualChild(findChild(workspace, "homeView"), "recentPaper-" + fixtureSource.toString())
            verify(item !== null)
            mouseClick(item, 30, 20, Qt.RightButton)
            const menu = findChild(item, "recentPaperMenu")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "removeRecentOption"))
            const dialog = findChild(item, "removeRecentDialog")
            tryCompare(dialog, "opened", true)
            dialog.reject()
            verify(researchStore.recentDocuments.some(function(p) { return p.url.toString() === fixtureSource.toString() }))
            dialog.open(); tryCompare(dialog, "opened", true); dialog.accept()
            tryVerify(function() { return !researchStore.recentDocuments.some(function(p) { return p.url.toString() === fixtureSource.toString() }) })
            workspace.openDocument(fixtureSource)
            canvas() // The actual PDF was not removed.
        }
        function test_deleteCaptureRequiresConfirmation() {
            researchStore.captureRegion(fixtureSource, 0, Qt.rect(.1, .1, .4, .2))
            tryCompare(researchStore, "busy", false, 10000)
            verify(researchStore.captures.length > 0)
            const id = researchStore.captures[0].id
            const shelf = findChild(workspace, "captureShelf")
            verify(shelf !== null)
            shelf.requestDelete(id)
            const dialog = findChild(shelf, "deleteCaptureDialog")
            tryCompare(dialog, "opened", true); dialog.reject()
            verify(researchStore.captures.some(function(c) { return c.id === id }))
            shelf.requestDelete(id)
            tryCompare(dialog, "opened", true); dialog.accept()
            tryVerify(function() { return !researchStore.captures.some(function(c) { return c.id === id }) })
        }
    }
}
