import QtQuick
import QtQuick.Controls
import QtWebEngine
import "WorkspaceTree.js" as Tree
import "UiTheme.js" as Theme

Flickable {
    id: root
    objectName: "documentWorkspace"
    clip: true
    acceptedButtons: Qt.NoButton
    boundsBehavior: Flickable.StopAtBounds
    property var tree: Tree.group([])
    property string activeGroup: tree.id
    property int revision: 0
    property bool syncing: false
    property bool suspended: false
    property string draggedTab: ""
    property var dropTarget: null
    property var closedTabs: []
    readonly property int groupCount: groupRows.count
    readonly property bool hasTabs: { const r = revision; return Tree.leaves(tree).some(function(g) { return g.tabs.length > 0 }) }
    readonly property var currentReader: { const r = revision; const view = groupView(activeGroup); return view && !view.isHome ? view.reader : null }
    property real layoutMinimumWidth: 320
    property real layoutMinimumHeight: 280
    contentWidth: Math.max(width, layoutMinimumWidth)
    contentHeight: Math.max(height, layoutMinimumHeight)
    signal changed()
    signal beforeChange()
    signal empty()
    signal opened()
    signal homeOpenRequested()
    signal homeResultChosen(var result)
    signal homeWorkspaceChosen(string id)
    signal homeWorkspaceManageRequested(string id)
    signal homeWorkspaceCreated(string name)
    // The tab menu's "Organize Tabs with AI…", handled by the window (needs the AI and a dialog).
    signal organizeRequested(string groupId)
    ScrollBar.horizontal: ScrollBar {}
    ScrollBar.vertical: ScrollBar {}
    ListModel { id: groupRows }
    ListModel { id: handleRows }
    function groupView(id) {
        for (let i = 0; i < groups.count; ++i) { const view = groups.itemAt(i); if (view && view.groupId === id) return view }
        return null
    }
    function flush() {
        for (let i = 0; i < groups.count; ++i) {
            const view = groups.itemAt(i)
            if (!view || !view.loadedTab || view.isHome || view.isWeb || view.isLibrary || view.isNote) continue
            const g = Tree.owner(tree, view.loadedTab)
            if (g) g.tabs.find(function(t) { return t.id === view.loadedTab }).position = view.reader.state().position
        }
    }
    function snapshot() { flush(); return {version: 2, tree: Tree.clone(tree), activeGroup: activeGroup} }
    function prepare() { flush(); beforeChange() }
    function restore(state) {
        const restored = Tree.restore(state || {}) // Validate before changing the live layout.
        syncing = true
        groupRows.clear()
        closedTabs = []
        tree = restored.tree
        activeGroup = restored.activeGroup
        syncing = false
        sync()
    }
    function sync() {
        if (syncing) return
        Tree.tidyLabels(tree)
        syncing = true
        const minimum = Tree.minimum(tree)
        layoutMinimumWidth = minimum.width; layoutMinimumHeight = minimum.height
        revision++
        const list = [], handles = []
        Tree.geometry(tree, 0, 0, contentWidth, contentHeight, list, handles)
        const ids = list.map(function(r) { return r.node.id })
        for (let i = groupRows.count - 1; i >= 0; --i) if (ids.indexOf(groupRows.get(i).groupId) < 0) groupRows.remove(i)
        for (let i = 0; i < list.length; ++i) {
            const r = list[i]
            let at = -1
            for (let j = 0; j < groupRows.count; ++j) if (groupRows.get(j).groupId === r.node.id) at = j
            const data = {groupId: r.node.id, encoded: JSON.stringify(r.node), gx: r.x, gy: r.y, gw: r.width, gh: r.height}
            if (at < 0) groupRows.append(data)
            else groupRows.set(at, data)
        }
        // Keep handles alive while dragging; rebuilding them would lose the pointer grab.
        const handleIds = handles.map(function(h) { return h.nodeId })
        for (let i = handleRows.count - 1; i >= 0; --i) if (handleIds.indexOf(handleRows.get(i).nodeId) < 0) handleRows.remove(i)
        for (let i = 0; i < handles.length; ++i) {
            let at = -1
            for (let j = 0; j < handleRows.count; ++j) if (handleRows.get(j).nodeId === handles[i].nodeId) at = j
            if (at < 0) handleRows.append(handles[i]); else handleRows.set(at, handles[i])
        }
        syncing = false
    }
    function activateGroup(id) { if (Tree.find(tree, id)) { activeGroup = id; changed() } }
    // Next/previous tab within the active group, wrapping at the ends.
    function cycleTab(step) {
        const g = Tree.find(tree, activeGroup)
        if (!g || g.tabs.length < 2) return false
        const at = Math.max(0, g.tabs.findIndex(function(t) { return t.id === g.activeTab }))
        activateTab(g.tabs[(at + step + g.tabs.length) % g.tabs.length].id)
        return true
    }
    // Tab by position in the active group; -1 selects the last tab (Cmd+9 convention).
    function selectTabAt(index) {
        const g = Tree.find(tree, activeGroup)
        const t = g ? (index < 0 ? g.tabs[g.tabs.length - 1] : g.tabs[index]) : null
        if (!t) return false
        activateTab(t.id)
        return true
    }
    // Scroll the outer workspace so the active group is visible. Only the workspace scroll moves;
    // the PDF reading position inside the group is untouched.
    function revealGroup(id) {
        const view = groupView(id)
        if (!view || draggedTab.length || syncing) return
        const target = function(start, size, viewport, current, extent) {
            let next = current
            if (start < current) next = start
            else if (start + size > current + viewport) next = Math.min(start, start + size - viewport)
            return Math.max(0, Math.min(extent - viewport, next))
        }
        const x = target(view.x, view.width, width, contentX, contentWidth)
        const y = target(view.y, view.height, height, contentY, contentHeight)
        if (Math.abs(x - contentX) < 1 && Math.abs(y - contentY) < 1) return
        revealX.to = x; revealY.to = y; reveal.restart()
    }
    onActiveGroupChanged: Qt.callLater(function() { root.revealGroup(root.activeGroup) })
    ParallelAnimation {
        id: reveal
        NumberAnimation { id: revealX; target: root; property: "contentX"; duration: 180; easing.type: Easing.OutCubic }
        NumberAnimation { id: revealY; target: root; property: "contentY"; duration: 180; easing.type: Easing.OutCubic }
    }
    function activateTab(id) {
        const g = Tree.owner(tree, id)
        if (!g) return
        prepare(); g.activeTab = id; activeGroup = g.id; sync(); changed(); opened()
    }
    function openDocument(source, position, forceNew) {
        if (!researchStore.rememberDocument(source)) return false
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        let t = !forceNew && g.tabs.find(function(t) { return researchStore.sameSource(t.source, source) })
        if (!t) {
            const home = !forceNew && g.tabs.find(function(t) { return t.id === g.activeTab && t.kind === "home" })
            t = Tree.tab(source, position || researchStore.readingPosition(source))
            // The library's ID travels with the tab, so a moved file is still named in the session.
            t.documentId = researchStore.documentLinkId(source)
            if (home) { t.id = home.id; g.tabs[g.tabs.indexOf(home)] = t }
            else g.tabs.push(t)
        }
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
    }
    // All web tabs share one persistent profile in the data folder (cookies, logins, cache).
    // Qt 6.11 suggests WebEngineProfilePrototype, but instance() hung page loads in offscreen tests;
    // revisit when the plain profile type is actually deprecated.
    readonly property WebEngineProfile webProfile: WebEngineProfile {
        storageName: "owelk"
        offTheRecord: false
        persistentStoragePath: researchStore.dataDirectory + "/web"
        cachePath: researchStore.dataDirectory + "/web/cache"
        httpCacheType: WebEngineProfile.DiskHttpCache
        persistentCookiesPolicy: WebEngineProfile.AllowPersistentCookies
    }
    signal webTabUpdated()
    // Route an address to the right surface: local PDFs open in the reader, web addresses in a web tab
    // (a PDF on the web downloads there and then opens in the reader).
    function openResource(url, forceNew) {
        const value = url.toString()
        if (value.startsWith("file:")) return openDocument(url, null, forceNew)
        if (Tree.isWebAddress(value)) return openWeb(value, forceNew)
        return false
    }
    function openWeb(url, forceNew, title) {
        if (!Tree.isWebAddress(url)) return false
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        const home = !forceNew && g.tabs.find(function(t) { return t.id === g.activeTab && t.kind === "home" })
        const t = Tree.webTab(url, title)
        if (home) { t.id = home.id; g.tabs[g.tabs.indexOf(home)] = t }
        else g.tabs.push(t)
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
    }
    // The page inside a web tab navigated; keep its address and title for the tab label and session.
    function updateWebTab(tabId, url, title) {
        const g = Tree.owner(tree, tabId)
        const t = g ? g.tabs.find(function(tab) { return tab.id === tabId }) : null
        if (!t || t.kind !== "web" || !Tree.isWebAddress(url)) return
        if (t.source === url.toString() && t.title === title) return
        t.source = url.toString(); t.title = title || ""
        sync(); changed(); webTabUpdated()
    }
    // A downloaded PDF replaces the web tab that only existed to fetch it, or opens next to it.
    function openDownloaded(tabId, file, replace) {
        if (!researchStore.rememberDocument(file)) return false
        const g = Tree.owner(tree, tabId)
        if (!g) return openDocument(file)
        prepare()
        const t = Tree.tab(file, researchStore.readingPosition(file))
        const at = g.tabs.findIndex(function(tab) { return tab.id === tabId })
        if (replace && at >= 0) g.tabs[at] = t
        else g.tabs.splice(at + 1, 0, t)
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
    }
    // A note opens once: an existing tab anywhere is focused instead of a second editor.
    function openNote(noteId, forceNew) {
        const row = researchStore.note(noteId)
        if (!row.id || row.deleted) return false
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length; ++i) {
            const existing = list[i].tabs.find(function(t) { return t.kind === "note" && t.noteId === noteId })
            if (existing) { activateTab(existing.id); return true }
        }
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        const home = !forceNew && g.tabs.find(function(t) { return t.id === g.activeTab && t.kind === "home" })
        const t = Tree.noteTab(noteId, row.title)
        if (home) { t.id = home.id; g.tabs[g.tabs.indexOf(home)] = t }
        else g.tabs.push(t)
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
    }
    function newNote(body) {
        const id = researchStore.createNote("", body || "")
        if (!id.length || !openNote(id, true)) return ""
        Qt.callLater(function() { const view = root.groupView(root.activeGroup); if (view) view.focusNoteTitle() })
        return id
    }
    function updateNoteTab(noteId, title) {
        let touched = false
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length; ++i)
            list[i].tabs.forEach(function(t) { if (t.kind === "note" && t.noteId === noteId && t.title !== title) { t.title = title; touched = true } })
        if (touched) { sync(); changed() }
    }
    function closeNoteTabs(noteId) {
        const ids = []
        Tree.leaves(tree).forEach(function(g) { g.tabs.forEach(function(t) { if (t.kind === "note" && t.noteId === noteId) ids.push(t.id) }) })
        ids.forEach(function(id) { root.closeTab(id) })
    }
    // owelk://<kind>/<id> links from notes and backlink lists.
    function openLink(link) {
        const match = /^owelk:\/\/(note|capture|highlight|document|ai)\/([A-Za-z0-9-]+)/.exec(link.toString())
        if (!match) return Tree.isWebAddress(link.toString()) ? openWeb(link.toString(), true) : false
        if (match[1] === "note") return openNote(match[2], true)
        if (match[1] === "capture") { researchStore.openCapture(match[2]); return true }
        if (match[1] === "highlight") { researchStore.openHighlight(match[2]); return true }
        if (match[1] === "ai") { root.aiResponseRequested(match[2]); return true }
        const target = researchStore.linkTarget("document", match[2])
        return target.source ? openDocument(target.source, null, true) : false
    }
    signal aiResponseRequested(string id)
    signal aiRequested(var spec)
    // One library tab per group: reuse it (or the Home tab in front) and apply the filter.
    function openLibrary(filter) {
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        let t = g.tabs.find(function(tab) { return tab.kind === "library" })
        if (t) t.filter = Tree.clone(filter || {})
        else {
            const home = g.tabs.find(function(tab) { return tab.id === g.activeTab && tab.kind === "home" })
            t = Tree.libraryTab(filter)
            if (home) { t.id = home.id; g.tabs[g.tabs.indexOf(home)] = t }
            else g.tabs.push(t)
        }
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
    }
    function setLibraryFilter(tabId, filter) {
        const g = Tree.owner(tree, tabId)
        const t = g ? g.tabs.find(function(tab) { return tab.id === tabId }) : null
        if (!t || t.kind !== "library" || JSON.stringify(t.filter) === JSON.stringify(filter)) return
        t.filter = Tree.clone(filter); changed()
    }
    function newHomeTab() {
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        const t = Tree.homeTab()
        g.tabs.push(t); g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        Qt.callLater(function() { const view = root.groupView(g.id); if (view) view.focusHome() })
    }
    function closeTab(id) {
        const g = Tree.owner(tree, id)
        if (!g) return
        prepare()
        const at = g.tabs.findIndex(function(t) { return t.id === id })
        closedTabs = closedTabs.concat([{groupId: g.id, tab: Tree.clone(g.tabs[at])}]).slice(-20)
        g.tabs.splice(at, 1)
        if (g.activeTab === id) g.activeTab = g.tabs.length ? g.tabs[Math.min(at, g.tabs.length - 1)].id : ""
        tree = Tree.prune(tree) || Tree.group([])
        if (!Tree.find(tree, activeGroup)) activeGroup = Tree.leaves(tree)[0].id
        sync(); changed()
        if (!Tree.leaves(tree).some(function(g) { return g.tabs.length })) empty()
    }
    // --- Named tab groups (inside one tab strip) ---------------------------------------------
    function groupTabs(tabIds, name) {
        const g = tabIds.length ? Tree.owner(tree, tabIds[0]) : null
        if (!g) return ""
        prepare()
        const label = Tree.addLabel(g, name)
        tabIds.forEach(function(id) { if (g.tabs.some(function(t) { return t.id === id })) Tree.setTabLabel(g, id, label.id) })
        sync(); changed()
        return label.id
    }
    function addTabToGroup(tabId, labelId) {
        const g = Tree.owner(tree, tabId)
        if (!g || !(g.labels || []).some(function(l) { return l.id === labelId })) return
        prepare(); Tree.setTabLabel(g, tabId, labelId); sync(); changed()
    }
    function removeTabFromGroup(tabId) {
        const g = Tree.owner(tree, tabId)
        if (!g) return
        prepare(); Tree.setTabLabel(g, tabId, ""); sync(); changed()
    }
    function tabLabel(stripId, labelId) {
        const g = Tree.find(tree, stripId)
        return g && g.labels ? g.labels.find(function(l) { return l.id === labelId }) : null
    }
    function renameTabGroup(stripId, labelId, name) {
        const label = tabLabel(stripId, labelId)
        if (!label || !name.trim().length) return
        prepare(); label.name = name.trim().slice(0, 120); sync(); changed()
    }
    function setTabGroupCollapsed(stripId, labelId, collapsed) {
        const label = tabLabel(stripId, labelId)
        if (!label) return
        prepare(); label.collapsed = collapsed; sync(); changed()
    }
    function tabGroupTabs(stripId, labelId) {
        const g = Tree.find(tree, stripId)
        return g ? g.tabs.filter(function(t) { return t.label === labelId }) : []
    }
    function ungroupTabs(stripId, labelId) {
        const g = Tree.find(tree, stripId)
        if (!g) return
        prepare()
        g.tabs.forEach(function(t) { if (t.label === labelId) delete t.label })
        Tree.pruneLabels(g); sync(); changed()
    }
    function closeTabGroup(stripId, labelId) {
        tabGroupTabs(stripId, labelId).map(function(t) { return t.id }).forEach(function(id) { closeTab(id) })
    }
    // A group worth keeping becomes a workspace (its tabs) or a collection (its papers).
    function saveTabGroupAsWorkspace(stripId, labelId) {
        const label = tabLabel(stripId, labelId)
        if (!label) return ""
        flush()
        const tabs = Tree.clone(tabGroupTabs(stripId, labelId)).map(function(t) { delete t.label; return t })
        const id = researchStore.createWorkspace(label.name)
        if (!id.length) return ""
        const strip = Tree.group(tabs)
        researchStore.saveWorkspace(id, {version: 2, tree: strip, activeGroup: strip.id})
        researchStore.notify("Saved \u201c" + label.name + "\u201d as a workspace.")
        return id
    }
    function saveTabGroupAsCollection(stripId, labelId) {
        const label = tabLabel(stripId, labelId)
        if (!label) return ""
        const id = researchStore.createCollection(label.name)
        if (!id.length) return ""
        tabGroupTabs(stripId, labelId).forEach(function(t) {
            if (!t.kind && t.source.startsWith("file:")) researchStore.setDocumentCollection(t.source, id, true)
        })
        researchStore.notify("Saved the papers of \u201c" + label.name + "\u201d as a collection.")
        return id
    }
    // Suggested groups (AI tab organization), applied only when the reader confirms.
    function applyTabGroups(stripId, groupsToApply) {
        const g = Tree.find(tree, stripId)
        if (!g) return 0
        prepare()
        let applied = 0
        groupsToApply.forEach(function(entry) {
            const ids = entry.tabIds.filter(function(id) { return g.tabs.some(function(t) { return t.id === id }) })
            if (!ids.length) return
            const label = Tree.addLabel(g, entry.name)
            ids.forEach(function(id) { Tree.setTabLabel(g, id, label.id) })
            ++applied
        })
        sync(); changed()
        return applied
    }
    function closeActiveTab() { const g = Tree.find(tree, activeGroup); if (g && g.activeTab) closeTab(g.activeTab) }
    function relinkSource(source, candidate) {
        flush()
        const oldUrl = source.toString(), newUrl = candidate.toString()
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length; ++i)
            for (let j = 0; j < list[i].tabs.length; ++j)
                if (researchStore.sameSource(list[i].tabs[j].source, oldUrl)) list[i].tabs[j].source = newUrl
        closedTabs = closedTabs.map(function(entry) {
            const copy = Tree.clone(entry)
            if (researchStore.sameSource(copy.tab.source, oldUrl)) copy.tab.source = newUrl
            return copy
        })
        // Invalidate only affected live readers, retaining all tab IDs and positions.
        for (let i = 0; i < groups.count; ++i) {
            const view = groups.itemAt(i)
            if (researchStore.sameSource(view.reader.source, oldUrl)) view.loadedTab = ""
        }
        sync(); changed()
    }
    function openAtPage(source, page) {
        let tab = null
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length && !tab; ++i) tab = list[i].tabs.find(function(t) { return researchStore.sameSource(t.source, source) })
        if (tab) activateTab(tab.id)
        else if (!openDocument(source, {page: page, y: 0, x: 0, zoom: 1})) return
        // Reload a reused tab: its cached PDF may predate the newly verified file on disk.
        if (currentReader) {
            const zoom = tab ? tab.position.zoom || 1 : 1
            if (tab) currentReader.restore({})
            currentReader.restore({source: source, position: {page: page, y: 0, x: 0, zoom: zoom}})
        }
        changed()
    }
    function reopenClosedTab() {
        if (!closedTabs.length) return
        const entry = closedTabs[closedTabs.length - 1]
        const previousGroup = activeGroup
        if (Tree.find(tree, entry.groupId)) activeGroup = entry.groupId
        if (entry.tab.kind === "home") { newHomeTab(); closedTabs = closedTabs.slice(0, -1) }
        else if (openDocument(entry.tab.source, entry.tab.position, true)) closedTabs = closedTabs.slice(0, -1)
        else activeGroup = previousGroup
    }
    function duplicateSplit(edge) {
        const g = Tree.find(tree, activeGroup)
        if (!g || !g.activeTab) return
        prepare()
        const original = g.tabs.find(function(t) { return t.id === g.activeTab })
        if (original.kind === "note") return // One editor per note avoids conflicting saves.
        const added = Tree.group([original.kind === "home" ? Tree.homeTab()
            : original.kind === "library" ? Tree.libraryTab(original.filter)
            : original.kind === "web" ? Tree.webTab(original.source, original.title) : Tree.tab(original.source, original.position)])
        tree = Tree.split(tree, g.id, added, edge)
        activeGroup = added.id; sync(); changed(); opened()
    }
    // Move the active tab into a new split beside its group (needs another tab to stay behind).
    function moveActiveTabToSplit(edge) {
        const g = Tree.find(tree, activeGroup)
        if (!g || !g.activeTab || g.tabs.length < 2) return false
        moveTab(g.activeTab, g.id, edge)
        return true
    }
    // Cycle keyboard focus between splits in layout order.
    function focusGroup(step) {
        const list = Tree.leaves(tree)
        if (list.length < 2) return false
        const at = Math.max(0, list.findIndex(function(g) { return g.id === activeGroup }))
        activateGroup(list[(at + step + list.length) % list.length].id)
        return true
    }
    function joinAll() {
        prepare()
        const list = Tree.leaves(tree), active = Tree.find(tree, activeGroup)
        const combined = Tree.group([])
        for (let i = 0; i < list.length; ++i) combined.tabs = combined.tabs.concat(list[i].tabs)
        combined.activeTab = active.activeTab || (combined.tabs.length ? combined.tabs[0].id : "")
        tree = combined; activeGroup = tree.id; sync(); changed()
    }
    function moveTab(id, targetId, edge, index) {
        const source = Tree.owner(tree, id), target = Tree.find(tree, targetId)
        if (!source || !target || target.kind !== "group") return
        if (source === target && edge !== "center" && source.tabs.length === 1) return
        prepare()
        const oldIndex = source.tabs.findIndex(function(t) { return t.id === id })
        const t = source.tabs.splice(oldIndex, 1)[0]
        if (source.activeTab === id) source.activeTab = source.tabs.length ? source.tabs[Math.min(oldIndex, source.tabs.length - 1)].id : ""
        if (edge === "center") {
            let at = index === undefined ? target.tabs.length : index
            if (source === target && at > oldIndex) at--
            target.tabs.splice(Math.max(0, Math.min(target.tabs.length, at)), 0, t)
            target.activeTab = id; activeGroup = target.id
        } else {
            const added = Tree.group([t])
            tree = Tree.split(tree, target.id, added, edge); activeGroup = added.id
        }
        tree = Tree.prune(tree) || Tree.group([])
        sync(); changed()
    }
    // While a tab is dragged within this distance of the viewport edge, the workspace scrolls toward it.
    readonly property real autoScrollMargin: 32
    property var dragPointer: null
    function edgeSpeed(position, size) {
        if (position < autoScrollMargin) return -Math.ceil((autoScrollMargin - Math.max(0, position)) / 2)
        if (position > size - autoScrollMargin) return Math.ceil((position - (size - autoScrollMargin)) / 2)
        return 0
    }
    Timer {
        id: dragScroll
        interval: 16; repeat: true
        running: root.draggedTab.length > 0 && root.dragPointer !== null
        onTriggered: {
            const local = root.mapFromItem(null, root.dragPointer.x, root.dragPointer.y)
            const dx = root.contentWidth > root.width ? root.edgeSpeed(local.x, root.width) : 0
            const dy = root.contentHeight > root.height ? root.edgeSpeed(local.y, root.height) : 0
            if (!dx && !dy) return
            root.contentX = Math.max(0, Math.min(root.contentWidth - root.width, root.contentX + dx))
            root.contentY = Math.max(0, Math.min(root.contentHeight - root.height, root.contentY + dy))
            // Content moved under a still pointer: refresh the drop target.
            root.dragTab(root.draggedTab, root.dragPointer.x, root.dragPointer.y)
        }
    }
    function dragTab(id, x, y) {
        draggedTab = id; dropTarget = null; dragPointer = Qt.point(x, y)
        const local = mapFromItem(null, x, y)
        if (local.x < 0 || local.y < 0 || local.x > width || local.y > height) return
        for (let i = 0; i < groups.count; ++i) {
            const view = groups.itemAt(i), p = view.mapFromItem(null, x, y)
            if (p.x < 0 || p.y < 0 || p.x > view.width || p.y > view.height) continue
            let edge = "center", at = undefined
            if (p.y < 32) at = view.tabIndexAt(p.x)
            else if (p.x < view.width * .22) edge = "left"
            else if (p.x > view.width * .78) edge = "right"
            else if (p.y < view.height * .25) edge = "top"
            else if (p.y > view.height * .75) edge = "bottom"
            const owner = Tree.owner(tree, id)
            if (owner && owner.id === view.groupId && owner.tabs.length === 1 && edge !== "center") return
            dropTarget = {group: view.groupId, edge: edge, index: at}
            break
        }
    }
    function finishDrag(cancelled) {
        const id = draggedTab, target = dropTarget
        draggedTab = ""; dropTarget = null; dragPointer = null
        if (!cancelled && target) Qt.callLater(function() { root.moveTab(id, target.group, target.edge, target.index) })
    }
    function reveal(source, page, region) {
        let t = null
        const list = Tree.leaves(tree)
        // Prefer the current copy when a PDF is open in more than one split.
        const active = Tree.find(tree, activeGroup)
        if (active) t = active.tabs.find(function(tab) { return tab.id === active.activeTab && researchStore.sameSource(tab.source, source) })
        for (let i = 0; i < list.length && !t; ++i) t = list[i].tabs.find(function(t) { return researchStore.sameSource(t.source, source) })
        if (t) activateTab(t.id)
        else {
            if (!openDocument(source, {page: 0, y: 0, x: 0, zoom: 1})) return
            const g = Tree.find(tree, activeGroup)
            t = g.tabs.find(function(tab) { return tab.id === g.activeTab })
        }
        const tabId = t.id, sourceUrl = source.toString()
        Qt.callLater(function() {
            // Bind deferred work to its source/tab, not whichever reader is active later.
            const g = Tree.owner(root.tree, tabId)
            if (!g || g.activeTab !== tabId) return
            const view = root.groupView(g.id)
            if (!view || view.loadedTab !== tabId || !researchStore.sameSource(view.reader.source, sourceUrl)) return
            view.reader.reveal(source, page, region)
        })
    }
    onContentWidthChanged: if (!syncing) Qt.callLater(sync)
    onContentHeightChanged: if (!syncing) Qt.callLater(sync)
    Component.onCompleted: sync()
    Repeater {
        id: groups
        model: groupRows
        delegate: DocumentGroup {
            required property string encoded
            required property real gx
            required property real gy
            required property real gw
            required property real gh
            x: gx; y: gy; width: gw; height: gh
            controller: root
            groupData: JSON.parse(encoded)
        }
    }
    Repeater {
        model: handleRows
        delegate: Rectangle {
            required property var model
            objectName: "splitHandle-" + model.nodeId
            x: model.x; y: model.y; width: model.width; height: model.height
            color: resize.containsMouse || resize.pressed ? Theme.splitterHover : Theme.splitter
            MouseArea {
                id: resize
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: model.horizontal ? Qt.SplitHCursor : Qt.SplitVCursor
                property real origin
                property real ratio
                onPressed: function(mouse) {
                    const p = mapToItem(root.contentItem, mouse.x, mouse.y)
                    origin = model.horizontal ? p.x : p.y
                    ratio = Tree.find(root.tree, model.nodeId).ratio
                    root.prepare()
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    const p = mapToItem(root.contentItem, mouse.x, mouse.y)
                    Tree.find(root.tree, model.nodeId).ratio = Math.max(.01, Math.min(.99, ratio + ((model.horizontal ? p.x : p.y) - origin) / model.span))
                    root.sync()
                }
                onReleased: root.changed()
            }
        }
    }
}
