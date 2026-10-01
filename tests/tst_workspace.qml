import QtQuick
import QtQuick.Controls
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
            // Sessions saved by other test files restore a different window size; geometry tests need the default.
            workspace.width = 1440; workspace.height = 930
            workspace.leftDockWidth = 224; workspace.rightDockWidth = 224
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
        function test_resizeDocks() {
            workspace.leftDockWidth = 224; workspace.rightDockWidth = 224
            const left = findChild(workspace, "leftDockResize")
            const right = findChild(workspace, "rightDockResize")
            wait(50)
            let start = left.mapToItem(workspace.contentItem, 3, 100)
            testInput.pointerDrag(workspace.contentItem, start, Qt.point(start.x + 70, start.y), false)
            fuzzyCompare(workspace.leftDockWidth, workspace.dockWidth(294), 2)
            start = right.mapToItem(workspace.contentItem, 3, 100)
            testInput.pointerDrag(workspace.contentItem, start, Qt.point(start.x - 60, start.y), false)
            fuzzyCompare(workspace.rightDockWidth, workspace.dockWidth(284), 2)
            workspace.persist()
            compare(researchStore.session.panels.leftWidth, workspace.leftDockWidth)
            compare(researchStore.session.panels.rightWidth, workspace.rightDockWidth)
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
        function test_newHomeTabShortcutAndRestore() {
            const d = workspace.documents
            workspace.openDocument(fixtureSource, {page: 3, y: .2, x: 0, zoom: 1})
            canvas()
            const pdfTab = d.tree.activeTab
            testInput.keyClick(workspace.currentReader, Qt.Key_T, Qt.ControlModifier)
            tryCompare(d.tree.tabs, "length", 2)
            compare(workspace.homeVisible, false)
            const homeTab = d.tree.activeTab
            compare(d.tree.tabs[1].kind, "home")
            const view = d.groupView(d.activeGroup)
            tryVerify(function() { return findChild(view, "homeSearch") !== null })
            compare(workspace.currentReader, null)
            workspace.persist()
            verify(Tree.validate(Tree.clone(researchStore.session.tree), {}, 0), JSON.stringify(researchStore.session.tree))
            compare(researchStore.continueReading.position.page, 3)
            d.restore(d.snapshot())
            compare(d.tree.activeTab, homeTab)
            testInput.keyClick(findChild(d.groupView(d.activeGroup), "homeSearch"), Qt.Key_W, Qt.ControlModifier)
            tryCompare(d.tree, "activeTab", pdfTab)
            compare(canvas().currentPage, 3)
            d.reopenClosedTab()
            compare(d.tree.tabs.length, 2)
            compare(d.tree.tabs[1].kind, "home")
            // Opening from Home replaces only that Home tab, preserving the existing PDF.
            d.openDocument(outlineSource)
            canvas()
            compare(d.tree.tabs.length, 2)
            compare(d.tree.tabs[0].id, pdfTab)
            verify(!d.tree.tabs[1].kind)
            compare(workspace.currentReader.source.toString(), outlineSource.toString())
        }
        function test_closeButtonBlendsWithTab() {
            workspace.openDocument(fixtureSource); canvas()
            const view = workspace.documents.groupView(workspace.documents.activeGroup)
            const id = view.groupData.activeTab
            const button = findChild(view, "closeTabButton-" + id)
            verify(button !== null)
            compare(button.background.color, button.parent.color)
            compare(button.width, 24)
            compare(button.height, button.width)
            compare(button.y, (button.parent.height - button.height) / 2)
            waitForPolish(workspace)
            wait(50)
            mouseMove(button, 12, 16)
            tryCompare(button, "hovered", true)
            compare(button.background.color, button.parent.color)
            compare(button.background.border.color.toString(), "#426b9a")
            mouseClick(button, 12, 12)
            tryCompare(workspace.documents, "hasTabs", false)
        }
        function test_workspaceManagerLinksRenameDelete() {
            workspace.width = 1440
            const id = researchStore.createWorkspace("Managed topic")
            workspace.openWorkspace(id)
            workspace.openDocument(fixtureSource); canvas()
            workspace.manageWorkspace(id)
            const manager = findChild(workspace, "workspaceManager")
            tryCompare(manager, "opened", true)
            const remove = findChild(manager, "deleteWorkspaceButton")
            const close = findChild(manager, "closeWorkspaceButton")
            waitForPolish(manager.contentItem)
            fuzzyCompare(remove.mapToItem(manager.contentItem, 0, 0).y, close.mapToItem(manager.contentItem, 0, 0).y, 1)
            compare(manager.details.documents.length, 1)
            manager.linkDocument(fixtureSource, false)
            workspace.persist()
            compare(manager.details.documents.length, 0)
            compare(workspace.documents.hasTabs, true)
            manager.linkDocument(fixtureSource, true)
            compare(manager.details.documents.length, 1)
            findChild(manager, "workspaceNameEditor").text = "Updated topic"
            mouseClick(findChild(manager, "renameWorkspaceButton"))
            compare(workspace.workspaceName, "Updated topic")
            researchStore.captureRegion(fixtureSource, 0, Qt.rect(.1, .1, .3, .2))
            tryCompare(researchStore, "busy", false, 10000)
            const capture = researchStore.captures[0]
            manager.mode = 1
            manager.linkCapture(capture.id, true)
            compare(manager.details.captures.length, 1)
            manager.linkCapture(capture.id, false)
            compare(manager.details.captures.length, 0)
            verify(researchStore.captures.some(function(c) { return c.id === capture.id }))
            mouseClick(findChild(manager, "deleteWorkspaceButton"))
            const confirmation = findChild(manager, "deleteWorkspaceDialog")
            tryCompare(confirmation, "opened", true)
            waitForPolish(confirmation.contentItem)
            verify(confirmation.contentItem.width <= confirmation.availableWidth)
            verify(confirmation.contentItem.implicitHeight <= confirmation.contentItem.height + 1)
            compare(confirmation.footer.alignment, Qt.AlignRight)
            const cancel = confirmation.standardButton(Dialog.Cancel)
            verify(cancel.mapToItem(confirmation.footer, cancel.width, 0).x > confirmation.footer.width / 2)
            confirmation.reject()
            compare(workspace.activeWorkspace, id)
            mouseClick(findChild(manager, "deleteWorkspaceButton"))
            tryCompare(confirmation, "opened", true); confirmation.accept()
            tryCompare(manager, "visible", false)
            compare(workspace.activeWorkspace, "")
            compare(workspace.documents.hasTabs, true)
            compare(workspace.currentReader.pdfReady, true)
        }
        function test_newTabButtonUsesClickedGroup() {
            // A restored window is clamped to the offscreen 800px display; make both groups visible.
            workspace.width = 1440
            const d = workspace.documents
            workspace.openDocument(fixtureSource); canvas()
            const left = d.activeGroup
            d.duplicateSplit("right"); canvas()
            const right = d.activeGroup
            waitForPolish(workspace)
            wait(50)
            const button = findChild(d.groupView(left), "newTabButton")
            // Send the click to this ApplicationWindow, not another test's QtTest window.
            testInput.pointerDrag(button, Qt.point(16, 16), Qt.point(16, 16), false)
            tryCompare(d, "activeGroup", left)
            compare(Tree.find(d.tree, left).tabs.length, 2)
            compare(Tree.find(d.tree, left).tabs[1].kind, "home")
            compare(Tree.find(d.tree, right).tabs.length, 1)
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
        function test_tabCyclingAndNumberedTabs() {
            const d = workspace.documents
            d.openDocument(fixtureSource, {page: 1, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 3, y: 0, x: 0, zoom: 1}, true); canvas()
            const tabs = d.tree.tabs.map(function(t) { return t.id })
            compare(d.tree.activeTab, tabs[2])
            verify(d.cycleTab(1)); compare(d.tree.activeTab, tabs[0]) // wraps forward
            verify(d.cycleTab(-1)); compare(d.tree.activeTab, tabs[2]) // wraps backward
            verify(d.selectTabAt(1)); compare(d.tree.activeTab, tabs[1])
            verify(d.selectTabAt(-1)); compare(d.tree.activeTab, tabs[2])
            verify(!d.selectTabAt(7))
            compare(canvas().currentPage, 3) // Switching tabs keeps each tab's own reading position.
            findChild(workspace, "previousTabAction").trigger()
            compare(d.tree.activeTab, tabs[1])
            compare(canvas().currentPage, 2)
            findChild(workspace, "nextTabAction").trigger()
            compare(d.tree.activeTab, tabs[2])
            // Cmd+Shift+[ / ] as key events cycle tabs without touching reader history (Cmd+[ / ]).
            const reader = canvas()
            testInput.keyClick(workspace.contentItem, Qt.Key_BracketLeft, Qt.ControlModifier | Qt.ShiftModifier)
            compare(d.tree.activeTab, tabs[1])
            testInput.keyClick(workspace.contentItem, Qt.Key_BracketRight, Qt.ControlModifier | Qt.ShiftModifier)
            compare(d.tree.activeTab, tabs[2])
            verify(!canvas().canGoBack)
        }
        function test_splitShortcuts() {
            const d = workspace.documents
            workspace.homeVisible = false
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 5, y: 0, x: 0, zoom: 1}, true); canvas()
            const moved = d.tree.activeTab
            // Cmd+Shift+Opt+Right moves the active tab into a new split on the right.
            testInput.keyClick(workspace.contentItem, Qt.Key_Right, Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier)
            tryCompare(d, "groupCount", 2)
            compare(Tree.find(d.tree, d.activeGroup).activeTab, moved)
            compare(canvas().currentPage, 5)
            const right = d.activeGroup
            // Cmd+Opt+Up / Down move focus between splits.
            testInput.keyClick(workspace.contentItem, Qt.Key_Up, Qt.ControlModifier | Qt.AltModifier)
            verify(d.activeGroup !== right)
            testInput.keyClick(workspace.contentItem, Qt.Key_Down, Qt.ControlModifier | Qt.AltModifier)
            compare(d.activeGroup, right)
            // Cmd+\ duplicates the active tab to the right; Cmd+Opt+\ below.
            testInput.keyClick(workspace.contentItem, Qt.Key_Backslash, Qt.ControlModifier)
            tryCompare(d, "groupCount", 3)
            testInput.keyClick(workspace.contentItem, Qt.Key_Backslash, Qt.ControlModifier | Qt.AltModifier)
            tryCompare(d, "groupCount", 4)
            compare(canvas().currentPage, 5)
            // A single-tab group cannot be moved out of itself.
            verify(!d.moveActiveTabToSplit("right"))
            // Cmd+Opt+Right cycles tabs as a key event too.
            d.joinAll()
            const before = d.tree.activeTab
            testInput.keyClick(workspace.contentItem, Qt.Key_Right, Qt.ControlModifier | Qt.AltModifier)
            verify(d.tree.activeTab !== before)
        }
        function test_duplicateCopyOffersExisting() {
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true); canvas()
            const copy = testInput.copyFixture("duplicate copy.pdf")
            workspace.openDocument(copy)
            const bar = findChild(workspace, "duplicateBar")
            tryCompare(bar, "opened", true, 10000)
            compare(bar.existing.toString(), fixtureSource.toString())
            mouseClick(findChild(bar, "openExistingCopy"))
            tryCompare(bar, "opened", false)
            tryVerify(function() { return researchStore.sameSource(Tree.find(d.tree, d.activeGroup).tabs.find(function(t) { return t.id === Tree.find(d.tree, d.activeGroup).activeTab }).source, fixtureSource) })
            verify(!researchStore.recentDocuments.some(function(p) { return researchStore.sameSource(p.url, copy) }))
        }
        function test_activeGroupIsRevealed() {
            const d = workspace.documents
            workspace.width = 900
            d.openDocument(fixtureSource, {page: 4, y: 0, x: 0, zoom: 1}, true); canvas()
            for (let i = 0; i < 3; ++i) { d.duplicateSplit("right"); canvas() }
            tryVerify(function() { return d.contentWidth > d.width + 10 }) // Splits overflow the viewport.
            const groups = Tree.leaves(d.tree).map(function(g) { return g.id })
            d.activateGroup(groups[0])
            tryVerify(function() { const v = d.groupView(groups[0]); return v.x >= d.contentX - 1 })
            d.activateGroup(groups[groups.length - 1])
            // A group wider than the viewport is aligned to its left edge; otherwise it is shown whole.
            tryVerify(function() {
                const v = d.groupView(groups[groups.length - 1])
                const expected = v.width > d.width ? v.x : v.x + v.width - d.width
                return Math.abs(d.contentX - Math.min(expected, d.contentWidth - d.width)) < 2
            }, 2000)
            compare(canvas().currentPage, 4) // Only the workspace scroll moved, not the PDF position.
        }
        function test_dragTabToSplitAndCancel() {
            const d = workspace.documents
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 4, y: 0, x: 0, zoom: 1}, true); canvas()
            const id = d.tree.activeTab, view = d.groupView(d.activeGroup)
            const tab = visualChild(view, "tab-" + id)
            verify(tab !== null)
            const target = view.mapToItem(tab, view.width - 15, view.height / 2)
            // QtTest's mouseDrag can reach another test's window in a full run; target this window explicitly.
            testInput.pointerDrag(tab, Qt.point(20, 15), target, false)
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
