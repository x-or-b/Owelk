import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    Component { id: restoredWindow; App.Main { visible: false } }
    SignalSpy { id: closingSpy; target: workspace; signalName: "closing" }
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
        function test_pdfScrollBarsTakeClicksOnTheirWholeHandle() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader, "pdfCanvas0")
            tryCompare(c, "ready", true); tryCompare(c, "restoring", false)
            c.zoom(2.5)
            for (const name of ["pdfVerticalScrollBar", "pdfHorizontalScrollBar"]) {
                const bar = findChild(c, name)
                tryVerify(function() { return bar.size > 0 && bar.size < 1 })
                // A press anywhere on the handle, also at its outer edge, takes it (nothing lies over it).
                const h = bar.contentItem, vertical = name === "pdfVerticalScrollBar"
                for (const p of [Qt.point(h.x + h.width / 2, h.y + h.height / 2),
                                 vertical ? Qt.point(h.x + h.width - 1, h.y + h.height / 2) : Qt.point(h.x + h.width / 2, h.y + h.height - 1)]) {
                    mousePress(bar, p.x, p.y)
                    verify(bar.pressed, name + " at " + p.x + "," + p.y)
                    mouseRelease(bar, p.x, p.y)
                }
            }
            c.zoom(1 / 2.5)
        }
        function test_pdfOpenedFromFinderOpensInATab() {
            const paper = testInput.copyFixture("from finder.pdf")
            workspace.homeVisible = true
            testInput.finderOpen(paper)
            tryVerify(function() { return Tree.leaves(workspace.documents.tree).some(function(g) { return g.tabs.some(function(t) { return researchStore.sameSource(t.source, paper) }) }) })
            compare(workspace.homeVisible, false)
        }
        function test_backAndForwardShortcuts() {
            workspace.openDocument(fixtureSource); const c = canvas()
            workspace.homeVisible = false
            c.jump(1, 0, 0); tryCompare(c, "restoring", false); wait(250)
            c.jumpRemembering(5, 0, 0); tryCompare(c, "restoring", false)
            compare(c.currentPage, 5)
            testInput.keyClick(workspace.contentItem, Qt.Key_Left, Qt.AltModifier)
            tryCompare(c, "currentPage", 1)
            tryCompare(c, "restoring", false)
            testInput.keyClick(workspace.contentItem, Qt.Key_Right, Qt.AltModifier)
            tryCompare(c, "currentPage", 5)
        }
        function test_closeShortcutEndsWithTheWindow() {
            const d = workspace.documents
            workspace.openDocument(fixtureSource); canvas()
            const action = findChild(workspace, "closeTabAction")
            // Home shown over open tabs: Close goes back to them.
            workspace.homeVisible = true
            action.trigger()
            compare(workspace.homeVisible, false)
            verify(d.hasTabs)
            for (let i = 0; i < 10 && d.hasTabs; ++i) action.trigger()
            verify(!d.hasTabs)
            // Nothing left to close: the window closes, as in other Mac apps.
            compare(action.text, "Close Window")
            closingSpy.clear()
            action.trigger()
            compare(closingSpy.count, 1)
            tryCompare(workspace, "visible", false)
            workspace.visible = true
            waitForRendering(workspace.contentItem)
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
        function test_oneOpenPanelPerDock() {
            workspace.filesVisible = true; workspace.filesSide = "left"
            workspace.documentVisible = false; workspace.documentSide = "left"
            workspace.togglePanel("document")
            compare(workspace.documentVisible, true)
            compare(workspace.filesVisible, false)
            compare(workspace.leftPanels, ["document"])
            compare(findChild(workspace, "leftDock").activePanel, "document")
            // Its dock icon shows it open with the accent colour, without a fill.
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-document")
            verify(Qt.colorEqual(icon.tint, Theme.accent))
            verify(!icon.checked)
            workspace.togglePanel("files")
            compare(workspace.documentVisible, false)
            compare(workspace.leftPanels, ["files"])
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
        function test_movingAnOpenPanelIntoADockReplacesItsPanel() {
            workspace.filesVisible = true; workspace.filesSide = "left"; workspace.shelfVisible = true
            workspace.movePanel("captures", "left")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "captures")
            compare(workspace.filesVisible, false)
            workspace.togglePanel("files")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "files")
            compare(workspace.shelfVisible, false)
            workspace.togglePanel("files")
            compare(workspace.filesVisible, false); compare(workspace.shelfVisible, false)
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
            // At rest the close button is invisible on the tab; hover uses the shared hover fill.
            compare(button.background.color.a, 0)
            compare(button.height, button.width)
            compare(button.y, (button.parent.height - button.height) / 2)
            waitForPolish(workspace)
            wait(50)
            mouseMove(button, button.width / 2, button.height / 2)
            tryCompare(button, "hovered", true)
            verify(Qt.colorEqual(button.background.color, Theme.hover))
            compare(button.ToolTip.text, "Close tab")
            mouseClick(button)
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
        function test_idleHomeTabsCloseAndOneLibrary() {
            const d = workspace.documents
            d.restore({})
            workspace.openDocument(fixtureSource); canvas()
            const paper = d.tree.activeTab
            // New tabs left unused do not pile up.
            d.newHomeTab(); d.newHomeTab(); d.newHomeTab()
            const homes = function() { return Tree.leaves(d.tree).reduce(function(n, g) { return n + g.tabs.filter(function(t) { return t.kind === "home" }).length }, 0) }
            compare(homes(), 1)
            d.activateTab(paper)
            compare(homes(), 0)
            // A Home tab used to open something becomes that tab.
            d.newHomeTab()
            d.openDocument(fixtureSource, {page: 3, y: 0, x: 0, zoom: 1}, true); canvas()
            compare(homes(), 0)
            // The Library opens once in the window, even from another split.
            d.openLibrary({})
            const library = d.tree.activeTab
            d.duplicateSplit("right") // not for the Library
            compare(d.groupCount, 1)
            d.activateTab(paper)
            d.moveActiveTabToSplit("right")
            compare(d.groupCount, 2)
            d.openLibrary({favorite: true})
            const libraries = Tree.leaves(d.tree).reduce(function(n, g) { return n + g.tabs.filter(function(t) { return t.kind === "library" }).length }, 0)
            compare(libraries, 1)
            compare(Tree.find(d.tree, d.activeGroup).activeTab, library)
            compare(Tree.owner(d.tree, library).tabs.find(function(t) { return t.id === library }).filter.favorite, true)
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
            // Cmd/Ctrl+9 is the last tab and nothing else claims it.
            verify(d.selectTabAt(0))
            keyClick(Qt.Key_9, Qt.ControlModifier)
            tryCompare(d.tree, "activeTab", tabs[2])
            compare(canvas().currentPage, 3) // Switching tabs keeps each tab's own reading position.
            findChild(workspace, "previousTabAction").trigger()
            compare(d.tree.activeTab, tabs[1])
            compare(canvas().currentPage, 2)
            findChild(workspace, "nextTabAction").trigger()
            compare(d.tree.activeTab, tabs[2])
            // Cmd+Shift+[ / ] as key events cycle tabs without turning the reader's pages (Cmd+[ / ]).
            const reader = canvas(), page = reader.currentPage
            testInput.keyClick(workspace.contentItem, Qt.Key_BracketLeft, Qt.ControlModifier | Qt.ShiftModifier)
            compare(d.tree.activeTab, tabs[1])
            testInput.keyClick(workspace.contentItem, Qt.Key_BracketRight, Qt.ControlModifier | Qt.ShiftModifier)
            compare(d.tree.activeTab, tabs[2])
            compare(reader.currentPage, page)
        }
        function test_splitShortcuts() {
            const d = workspace.documents
            const mac = Qt.platform.os === "osx"
            workspace.homeVisible = false
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            d.openDocument(fixtureSource, {page: 5, y: 0, x: 0, zoom: 1}, true); canvas()
            const moved = d.tree.activeTab
            // Move to right split (mac: Cmd+Shift+Opt+Right, others: Ctrl+Shift+Alt+.).
            testInput.keyClick(workspace.contentItem, mac ? Qt.Key_Right : Qt.Key_Period,
                Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier)
            tryCompare(d, "groupCount", 2)
            compare(Tree.find(d.tree, d.activeGroup).activeTab, moved)
            compare(canvas().currentPage, 5)
            const right = d.activeGroup
            // Move focus between splits (mac: Cmd+Opt+Up/Down, others: Ctrl+Alt+,/.).
            testInput.keyClick(workspace.contentItem, mac ? Qt.Key_Up : Qt.Key_Comma, Qt.ControlModifier | Qt.AltModifier)
            verify(d.activeGroup !== right)
            testInput.keyClick(
                workspace.contentItem, mac ? Qt.Key_Down : Qt.Key_Period, Qt.ControlModifier | Qt.AltModifier)
            compare(d.activeGroup, right)
            // Cmd+\ duplicates the active tab to the right; below: Cmd+Opt+\ (others: Ctrl+Shift+\).
            testInput.keyClick(workspace.contentItem, Qt.Key_Backslash, Qt.ControlModifier)
            tryCompare(d, "groupCount", 3)
            testInput.keyClick(workspace.contentItem, Qt.Key_Backslash, Qt.ControlModifier | (mac ? Qt.AltModifier : Qt.ShiftModifier))
            tryCompare(d, "groupCount", 4)
            compare(canvas().currentPage, 5)
            // A single-tab group cannot be moved out of itself.
            verify(!d.moveActiveTabToSplit("right"))
            // Next-tab shortcut as a key event too (mac: Cmd+Opt+Right, others: Ctrl+PgDown).
            d.joinAll()
            const before = d.tree.activeTab
            testInput.keyClick(workspace.contentItem, mac ? Qt.Key_Right : Qt.Key_PageDown,
                mac ? (Qt.ControlModifier | Qt.AltModifier) : Qt.ControlModifier)
            verify(d.tree.activeTab !== before)
        }
        function test_duplicateCopyOffersExisting() {
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true); canvas()
            const copy = testInput.copyFixture("duplicate copy.pdf")
            workspace.openDocument(copy)
            const bar = findChild(workspace, "duplicateBar")
            // Earlier tests leave identical copies, so fixture.pdf itself may be reported first.
            tryVerify(function() { return bar.opened && researchStore.sameSource(bar.source, copy) }, 10000)
            // Any earlier identical copy is a valid offer (other tests also copy the fixture).
            const existing = bar.existing
            verify(existing.toString().length > 0 && !researchStore.sameSource(existing, copy))
            mouseClick(findChild(bar, "openExistingCopy"))
            tryCompare(bar, "opened", false)
            tryVerify(function() { return researchStore.sameSource(Tree.find(d.tree, d.activeGroup).tabs.find(function(t) { return t.id === Tree.find(d.tree, d.activeGroup).activeTab }).source, existing) })
            verify(!researchStore.recentDocuments.some(function(p) { return researchStore.sameSource(p.url, copy) }))
        }
        function test_dragNearEdgeScrollsWorkspace() {
            const d = workspace.documents
            workspace.width = 900
            d.openDocument(fixtureSource, null, true); canvas()
            d.openDocument(fixtureSource, {page: 2, y: 0, x: 0, zoom: 1}, true); canvas()
            for (let i = 0; i < 3; ++i) { d.duplicateSplit("right"); canvas() }
            tryVerify(function() { return d.contentWidth > d.width + 10 })
            d.activateGroup(Tree.leaves(d.tree)[0].id)
            tryCompare(d, "contentX", 0)
            const tab = Tree.leaves(d.tree)[0].tabs[0].id
            const edge = d.mapToItem(null, d.width - 6, d.height / 2)
            d.dragTab(tab, edge.x, edge.y)
            tryVerify(function() { return d.contentX > 100 }, 3000)
            verify(d.contentX <= d.contentWidth - d.width)
            d.finishDrag(true)
            const stopped = d.contentX
            wait(100)
            compare(d.contentX, stopped)
            // Away from the edges nothing scrolls.
            const middle = d.mapToItem(null, d.width / 2, d.height / 2)
            d.dragTab(tab, middle.x, middle.y); wait(100)
            compare(d.contentX, stopped)
            d.finishDrag(true)
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
        function test_areasAreSlicesWithHairlineEdges() {
            // Panels and documents are square slices; a resize edge is 1px with a wider grab area.
            workspace.filesVisible = true
            const left = findChild(workspace, "leftDock")
            tryCompare(left, "visible", true)
            compare(left.radius, 0)
            const grip = findChild(workspace, "leftDockResize")
            compare(grip.parent.width, 1)
            verify(grip.width >= 7)
            workspace.documents.openDocument(fixtureSource); canvas()
            const group = findChild(workspace.documents, "group-" + workspace.documents.activeGroup)
            compare(group.radius, 0)
            compare(workspace.currentReader.radius, 0)
            // Resizing only moves the groups: tab lists and readers are not rebuilt at every step.
            const revision = workspace.documents.revision
            for (let i = 0; i < 5; ++i) { workspace.leftDockWidth += 12; wait(20) }
            compare(workspace.documents.revision, revision)
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
        function test_dragTabsLikeABrowserAndGroupByHolding() {
            workspace.documents.restore({})
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true); canvas()
            d.openDocument(outlineSource, null, true); canvas()
            d.openDocument(longSource, null, true); canvas()
            const strip = Tree.leaves(d.tree)[0], view = d.groupView(strip.id)
            const [a, b, c] = strip.tabs.map(function(t) { return t.id })
            waitForPolish(workspace); wait(50)
            const tabA = visualChild(view, "tab-" + a), tabC = visualChild(view, "tab-" + c)
            // Dragging the first tab past the last opens a gap there; nothing says "Move tab here".
            d.dragTitle = "dragged"
            const end = tabC.mapToItem(null, tabC.width * .9, tabC.height / 2)
            d.dragTab(a, end.x, end.y)
            compare(d.dropTarget.index, 3)
            verify(view.shiftFor(view.strip.findIndex(function(e) { return e.type === "tab" && e.tab.id === c })) < 0, "the others step aside")
            compare(tabA.opacity, 0)
            verify(findChild(workspace, "dragGhost").visible, "the tab follows the pointer")
            d.finishDrag(false)
            tryVerify(function() { return Tree.leaves(d.tree)[0].tabs[2].id === a })
            // Holding a tab over the middle of another makes a group, and its name field opens.
            waitForPolish(workspace); wait(50)
            const target = visualChild(view, "tab-" + b)
            const middle = target.mapToItem(null, target.width / 2, target.height / 2)
            d.dragTitle = "dragged"
            d.dragTab(c, middle.x, middle.y)
            compare(d.dropTarget.over, b)
            wait(600)
            d.dragTab(c, middle.x + 1, middle.y)
            compare(d.dropTarget.join, b)
            d.finishDrag(false)
            tryVerify(function() { const g = Tree.leaves(d.tree)[0]; return (g.labels || []).length === 1 })
            const group = Tree.leaves(d.tree)[0]
            verify(group.tabs.filter(function(t) { return t.label === group.labels[0].id }).length === 2)
            tryCompare(view, "editingLabel", group.labels[0].id)
            // (This window is not the active one in the test run, so check the focus request.)
            tryVerify(function() { const f = visualChild(view, "tabGroupNameField"); return f && f.visible && f.focus })
            const field = visualChild(view, "tabGroupNameField")
            field.text = "Methods"
            field.accepted()
            tryCompare(d.tabLabel(group.id, group.labels[0].id), "name", "Methods")
            // The label folds and unfolds its tabs.
            tryVerify(function() { return visualChild(view, "tabGroupHeader-Methods") !== null })
            waitForPolish(workspace); wait(50)
            mouseClick(visualChild(visualChild(view, "tabGroupHeader-Methods"), "tabGroupLabel"))
            tryVerify(function() { return d.tabLabel(group.id, group.labels[0].id).collapsed })
            // The strip is rebuilt; find the label again.
            tryVerify(function() { return visualChild(view, "tabGroupHeader-Methods") !== null })
            waitForPolish(workspace); wait(50)
            mouseClick(visualChild(visualChild(view, "tabGroupHeader-Methods"), "tabGroupLabel"))
            tryVerify(function() { return !d.tabLabel(group.id, group.labels[0].id).collapsed })
            // An outside tab dropped between two grouped tabs lands after the group, not inside it.
            const grouped = Tree.leaves(d.tree)[0]
            const members = grouped.tabs.filter(function(t) { return t.label === grouped.labels[0].id }).map(function(t) { return t.id })
            const outsider = grouped.tabs.find(function(t) { return !t.label }).id
            waitForPolish(workspace); wait(50)
            const second = visualChild(view, "tab-" + members[1])
            const between = second.mapToItem(null, 4, second.height / 2)
            d.dragTitle = "dragged"
            d.dragTab(outsider, between.x, between.y)
            d.finishDrag(false)
            tryVerify(function() {
                const ids = Tree.leaves(d.tree)[0].tabs.map(function(t) { return t.id })
                return Math.abs(ids.indexOf(members[0]) - ids.indexOf(members[1])) === 1
            })
            // A second group gets another color.
            const other = d.newTabGroup([a])
            verify(d.tabLabel(group.id, other).color !== d.tabLabel(group.id, group.labels[0].id).color)
            view.editingLabel = ""
        }
        function test_tabStripMenuSortsClosesDuplicatesAndSwitchesLayout() {
            workspace.documents.restore({})
            const d = workspace.documents
            d.openDocument(outlineSource, null, true); canvas()
            d.openDocument(fixtureSource, null, true); canvas()
            d.openDocument(outlineSource, null, true); canvas()
            const strip = Tree.leaves(d.tree)[0], view = d.groupView(strip.id)
            // Right-click on the bar's empty space.
            waitForPolish(workspace); wait(50)
            const bar = visualChild(view, "tabBar")
            mouseClick(bar, bar.width - 20, bar.height / 2, Qt.RightButton)
            const menu = findChild(view, "tabStripMenu")
            tryCompare(menu, "opened", true)
            findChild(menu, "stripCloseDuplicates").triggered()
            tryCompare(Tree.leaves(d.tree)[0].tabs, "length", 2)
            findChild(menu, "stripSortTitle").triggered()
            tryVerify(function() {
                const titles = Tree.leaves(d.tree)[0].tabs.map(function(t) { return Tree.tabTitle(t, researchStore.displayName) })
                return titles[0].toLowerCase() <= titles[1].toLowerCase()
            })
            menu.close()
            // The layout can be switched from there too.
            findChild(menu, "stripVertical").triggered()
            compare(Theme.verticalTabs, true)
            findChild(menu, "stripHorizontal").triggered()
            compare(Theme.verticalTabs, false)
        }
        function test_verticalTabsPanelResizes() {
            Theme.verticalTabs = true
            workspace.setTabsPanel(true)
            const panel = findChild(workspace, "tabsPanel")
            tryCompare(panel, "visible", true)
            waitForPolish(workspace); wait(50)
            const handle = findChild(panel, "tabsPanelResize")
            const before = panel.width
            mouseDrag(handle, 3, 200, 80, 0)
            tryVerify(function() { return panel.width > before + 40 })
            compare(Number(researchStore.setting("tabs.panelWidth")), Math.round(panel.openWidth))
            mouseDrag(handle, 3, 200, -1000, 0)
            tryCompare(panel, "openWidth", 180)
            researchStore.setSetting("tabs.panelWidth", "240"); panel.openWidth = 240
            Theme.verticalTabs = false
        }
        function test_verticalTabs() {
            workspace.documents.restore({})
            const d = workspace.documents
            d.openDocument(fixtureSource, null, true); canvas()
            d.openDocument(outlineSource, null, true); canvas()
            d.openDocument(longSource, null, true); canvas()
            Theme.verticalTabs = true
            workspace.setTabsPanel(true)
            const panel = findChild(workspace, "tabsPanel")
            tryCompare(panel, "visible", true)
            const strip = Tree.leaves(d.tree)[0], view = d.groupView(strip.id)
            compare(view.stripHeight, 0, "the bar above the split is gone")
            const [a, b, c] = strip.tabs.map(function(t) { return t.id })
            tryVerify(function() { return visualChild(panel, "verticalTab-" + a) !== null })
            waitForPolish(workspace); wait(50)
            // Clicking a row switches to that tab.
            mouseClick(visualChild(panel, "verticalTab-" + a), 60, 10)
            tryCompare(Tree.leaves(d.tree)[0], "activeTab", a)
            // Dragging a row below another moves the tab; the rows step aside meanwhile.
            const rowC = visualChild(panel, "verticalTab-" + c)
            const below = rowC.mapToItem(null, 60, rowC.height * .9)
            d.dragTitle = "dragged"
            d.dragTab(a, below.x, below.y)
            compare(d.dropTarget.index, 3)
            verify(panel.shiftFor(panel.rows.findIndex(function(r) { return r.type === "tab" && r.tab.id === c })) < 0)
            d.finishDrag(false)
            tryVerify(function() { return Tree.leaves(d.tree)[0].tabs[2].id === a })
            // Holding a row over the middle of another makes a group, named in the list.
            waitForPolish(workspace); wait(50)
            const rowB = visualChild(panel, "verticalTab-" + b)
            const middle = rowB.mapToItem(null, 60, rowB.height / 2)
            d.dragTitle = "dragged"
            d.dragTab(c, middle.x, middle.y)
            compare(d.dropTarget.over, b)
            wait(600)
            d.dragTab(c, middle.x, middle.y + 1)
            d.finishDrag(false)
            tryVerify(function() { return (Tree.leaves(d.tree)[0].labels || []).length === 1 })
            const label = Tree.leaves(d.tree)[0].labels[0]
            tryCompare(panel, "editingLabel", label.id)
            const field = visualChild(panel, "verticalGroupNameField")
            tryVerify(function() { return field && field.visible })
            field.text = "Odometry"; field.accepted()
            tryCompare(d.tabLabel(strip.id, label.id), "name", "Odometry")
            // The group's row folds it.
            tryVerify(function() { return visualChild(panel, "verticalGroup-Odometry") !== null })
            waitForPolish(workspace); wait(50)
            mouseClick(visualChild(visualChild(panel, "verticalGroup-Odometry"), "verticalGroupLabel"))
            tryVerify(function() { return d.tabLabel(strip.id, label.id).collapsed })
            // Closed, the panel is a thin rail.
            workspace.setTabsPanel(false)
            tryVerify(function() { return panel.width < 60 })
            workspace.setTabsPanel(true)
            Theme.verticalTabs = false
            tryCompare(panel, "visible", false)
            compare(view.stripHeight, Theme.barHeight)
        }
        function test_tabGroupsCollapsePersistAndSave() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource); canvas()
            workspace.documents.openDocument(outlineSource, null, true); canvas()
            const d = workspace.documents
            const strip = Tree.leaves(d.tree)[0]
            const ids = strip.tabs.map(function(t) { return t.id })
            const label = d.groupTabs(ids, "Reading list")
            verify(label.length > 0)
            const view = d.groupView(strip.id)
            tryVerify(function() { return visualChild(view, "tabGroupHeader-Reading list") !== null })
            // Collapsing hides the members except the active one.
            d.setTabGroupCollapsed(strip.id, label, true)
            compare(view.shownTabs.length, 1)
            d.setTabGroupCollapsed(strip.id, label, false)
            compare(view.shownTabs.length, 2)
            // The group survives a save and restore.
            workspace.persist()
            const saved = researchStore.session
            d.restore(saved)
            const restored = Tree.leaves(d.tree)[0]
            compare(restored.labels.length, 1)
            compare(restored.labels[0].name, "Reading list")
            verify(restored.tabs.every(function(t) { return t.label === restored.labels[0].id }))
            verify(restored.tabs.every(function(t) { return typeof t.documentId === "string" && t.documentId.length > 0 }))
            // Saved as a workspace and as a collection.
            const before = researchStore.collections().length
            verify(d.saveTabGroupAsWorkspace(restored.id, restored.labels[0].id).length > 0)
            verify(d.saveTabGroupAsCollection(restored.id, restored.labels[0].id).length > 0)
            compare(researchStore.collections().length, before + 1)
            // Moving a member to another split leaves the group behind.
            d.moveActiveTabToSplit("right")
            Tree.leaves(d.tree).forEach(function(g) { verify(Tree.validate(g, {}, 0)) })
            d.ungroupTabs(Tree.leaves(d.tree)[0].id, restored.labels[0].id)
            verify(Tree.leaves(d.tree).every(function(g) { return g.labels === undefined }))
        }
        function test_recordedShortcutReplacesTheDefault() {
            const settings = findChild(workspace, "settingsDialog")
            settings.openPage("shortcuts"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "shortcut-newTab") !== null })
            const button = visualChild(settings.contentItem, "shortcut-newTab")
            verify(button)
            button.clicked()
            testInput.keyClick(button, Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier)
            compare(JSON.parse(researchStore.setting("shortcuts")).newTab, "Ctrl+Shift+Y")
            compare(workspace.keys("newTab"), "Ctrl+Shift+Y")
            settings.close(); tryCompare(settings, "visible", false)
            // The menu action now answers the new keys.
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource); canvas()
            const before = Tree.leaves(workspace.documents.tree)[0].tabs.length
            testInput.keyClick(workspace.currentReader, Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier)
            tryCompare(Tree.leaves(workspace.documents.tree)[0].tabs, "length", before + 1)
            researchStore.setSetting("shortcuts", "{}")
            compare(workspace.keys("newTab"), "Ctrl+T")
        }
        function test_relatedTabAsksOnlyWhenShown() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource); canvas()
            workspace.togglePanel("document")
            const panel = findChild(workspace, "pdfNavigationPanel")
            tryVerify(function() { return panel !== null && panel.ready })
            workspace.navigationMode = 0
            compare(panel.relatedRequest, -1) // Nothing is computed while another tab shows.
            workspace.navigationMode = 3
            verify(panel.relatedRequest > 0)
            tryCompare(panel, "relatedLoading", false, 10000)
            verify(findChild(panel, "relatedView").visible)
            workspace.navigationMode = 0
            workspace.togglePanel("document")
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
            const emptyPanel = findChild(findChild(workspace, "rightDock"), "pdfNavigationPanel")
            compare(emptyPanel.ready, false)
        }
        function test_tabMenuFollowsTheTabAndClosesOthers() {
            workspace.openDocument(fixtureSource); canvas()
            workspace.documents.openLibrary({})
            const view = workspace.documents.groupView(workspace.documents.activeGroup)
            tryVerify(function() { return view.groupData.tabs.length >= 2 })
            const pdfTab = view.groupData.tabs.find(function(t) { return !t.kind })
            const item = findChild(view, "tab-" + pdfTab.id)
            waitForPolish(workspace); wait(50)
            mouseClick(item, 30, item.height / 2, Qt.RightButton)
            const menu = findChild(view, "tabMenu")
            tryCompare(menu, "opened", true)
            compare(menu.kind, "pdf")
            verify(menu.path.length > 0, "a paper tab offers its file")
            findChild(menu, "closeOtherTabsOption").triggered()
            tryVerify(function() {
                const tabs = Tree.leaves(workspace.documents.snapshot().tree).reduce(function(all, g) { return all.concat(g.tabs) }, [])
                return tabs.length === 1 && tabs[0].id === pdfTab.id
            })
        }
        function test_removeRecentRequiresConfirmation() {
            researchStore.rememberDocument(fixtureSource)
            workspace.showHome()
            const item = visualChild(findChild(workspace, "homeView"), "recentPaper-" + fixtureSource.toString())
            verify(item !== null)
            tryVerify(function() { return item.width > 100 && item.height > 0 })
            waitForPolish(findChild(workspace, "homeView")); wait(50)
            mouseClick(item, 30, 12, Qt.RightButton)
            // Home's one paper menu, the same as in the Library, with Remove for recents.
            const menu = findChild(findChild(workspace, "homeView"), "recentPaperMenu").menu
            tryCompare(menu, "opened", true)
            verify(findChild(menu, "paperOpenOption") !== null && findChild(menu, "copyBibtex") !== null)
            const remove = findChild(menu, "removeRecentOption")
            // Destructive items come last: Remove from Recent Papers, then Delete Paper.
            compare(menu.itemAt(menu.count - 2), remove)
            compare(menu.itemAt(menu.count - 1), findChild(menu, "deletePaperOption"))
            remove.triggered()
            tryVerify(function() { return findChild(findChild(workspace, "homeView"), "recentPaperMenu").removeDialog !== null })
            const dialog = findChild(findChild(workspace, "homeView"), "recentPaperMenu").removeDialog
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
