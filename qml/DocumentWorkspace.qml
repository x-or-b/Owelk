import QtQuick
import QtQuick.Controls
import "WorkspaceTree.js" as Tree

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
    readonly property var currentReader: { const r = revision; const view = groupView(activeGroup); return view ? view.reader : null }
    property real layoutMinimumWidth: 320
    property real layoutMinimumHeight: 280
    contentWidth: Math.max(width, layoutMinimumWidth)
    contentHeight: Math.max(height, layoutMinimumHeight)
    signal changed()
    signal beforeChange()
    signal empty()
    signal opened()
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
            if (!view || !view.loadedTab) continue
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
    function activateTab(id) {
        const g = Tree.owner(tree, id)
        if (!g) return
        prepare(); g.activeTab = id; activeGroup = g.id; sync(); changed(); opened()
    }
    function openDocument(source, position, forceNew) {
        if (!researchStore.rememberDocument(source)) return false
        prepare()
        const g = Tree.find(tree, activeGroup) || Tree.leaves(tree)[0]
        let t = !forceNew && g.tabs.find(function(t) { return t.source === source.toString() })
        if (!t) { t = Tree.tab(source, position || researchStore.readingPosition(source)); g.tabs.push(t) }
        g.activeTab = t.id; activeGroup = g.id
        sync(); changed(); opened()
        return true
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
    function closeActiveTab() { const g = Tree.find(tree, activeGroup); if (g && g.activeTab) closeTab(g.activeTab) }
    function relinkSource(source, candidate) {
        flush()
        const oldUrl = source.toString(), newUrl = candidate.toString()
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length; ++i)
            for (let j = 0; j < list[i].tabs.length; ++j)
                if (list[i].tabs[j].source === oldUrl) list[i].tabs[j].source = newUrl
        closedTabs = closedTabs.map(function(entry) {
            const copy = Tree.clone(entry)
            if (copy.tab.source === oldUrl) copy.tab.source = newUrl
            return copy
        })
        // Invalidate only affected live readers, retaining all tab IDs and positions.
        for (let i = 0; i < groups.count; ++i) {
            const view = groups.itemAt(i)
            if (view.reader.source.toString() === oldUrl) view.loadedTab = ""
        }
        sync(); changed()
    }
    function openAtPage(source, page) {
        let tab = null
        const list = Tree.leaves(tree)
        for (let i = 0; i < list.length && !tab; ++i) tab = list[i].tabs.find(function(t) { return t.source === source.toString() })
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
        if (openDocument(entry.tab.source, entry.tab.position, true)) closedTabs = closedTabs.slice(0, -1)
        else activeGroup = previousGroup
    }
    function duplicateSplit(edge) {
        const g = Tree.find(tree, activeGroup)
        if (!g || !g.activeTab) return
        prepare()
        const original = g.tabs.find(function(t) { return t.id === g.activeTab })
        const added = Tree.group([Tree.tab(original.source, original.position)])
        tree = Tree.split(tree, g.id, added, edge)
        activeGroup = added.id; sync(); changed(); opened()
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
    function dragTab(id, x, y) {
        draggedTab = id; dropTarget = null
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
        draggedTab = ""; dropTarget = null
        if (!cancelled && target) Qt.callLater(function() { root.moveTab(id, target.group, target.edge, target.index) })
    }
    function reveal(source, page, region) {
        let t = null
        const list = Tree.leaves(tree)
        // Prefer the current copy when a PDF is open in more than one split.
        const active = Tree.find(tree, activeGroup)
        if (active) t = active.tabs.find(function(tab) { return tab.id === active.activeTab && tab.source === source.toString() })
        for (let i = 0; i < list.length && !t; ++i) t = list[i].tabs.find(function(t) { return t.source === source.toString() })
        if (t) activateTab(t.id)
        else {
            if (!openDocument(source, {page: page, y: region.y, x: 0, zoom: 1})) return
            const g = Tree.find(tree, activeGroup)
            t = g.tabs.find(function(tab) { return tab.id === g.activeTab })
        }
        const tabId = t.id, sourceUrl = source.toString()
        Qt.callLater(function() {
            // Bind deferred work to its source/tab, not whichever reader is active later.
            const g = Tree.owner(root.tree, tabId)
            if (!g || g.activeTab !== tabId) return
            const view = root.groupView(g.id)
            if (!view || view.loadedTab !== tabId || view.reader.source.toString() !== sourceUrl) return
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
            color: resize.containsMouse || resize.pressed ? "#bbbbbb" : "#e3e3e3"
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
