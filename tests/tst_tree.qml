import QtQuick
import QtTest
import "../qml/WorkspaceTree.js" as Tree
import "../qml/Platform.js" as Platform
import "../qml/Shortcuts.js" as Shortcuts

TestCase {
    name: "WorkspaceTree"
    function test_shortcutRegistry() {
        // Linux/Windows defaults avoid desktop and AltGr combinations.
        compare(Shortcuts.defaultKeys("nextTab", "osx"), "Ctrl+Alt+Right")
        compare(Shortcuts.defaultKeys("nextTab", "linux"), "Ctrl+PgDown")
        compare(Shortcuts.defaultKeys("splitDown", "windows"), "Ctrl+Shift+\\")
        verify(Shortcuts.actions.every(function(a) { return a.other.indexOf("Ctrl+Alt+Left") < 0 && a.other.indexOf("Ctrl+Alt+Right") < 0 && a.other.indexOf("Ctrl+Alt+\\") < 0 }))
        // No clashes among the defaults on any platform.
        compare(Object.keys(Shortcuts.conflicts({}, "osx")).length, 0)
        compare(Object.keys(Shortcuts.conflicts({}, "linux")).length, 0)
        const mine = {newTab: "Ctrl+K", closeTab: ""}
        compare(Shortcuts.keys("newTab", mine, "linux"), "Ctrl+K")
        compare(Shortcuts.keys("closeTab", mine, "linux"), "")
        compare(Shortcuts.conflicts(mine, "linux")["Ctrl+K"].length, 2)
        compare(Shortcuts.parse("not json"), {})
        compare(Shortcuts.fromEvent(Qt.Key_Y, Qt.ControlModifier | Qt.ShiftModifier, "Y"), "Ctrl+Shift+Y")
        compare(Shortcuts.fromEvent(Qt.Key_Shift, Qt.ShiftModifier, ""), "")
        compare(Shortcuts.fromEvent(Qt.Key_Y, 0, "y"), "") // A plain letter is typing, not a shortcut.
        compare(Shortcuts.fromEvent(Qt.Key_F5, 0, ""), "F5")
    }
    function test_shortcutHintsFollowThePlatform() {
        if (Qt.platform.os === "osx") {
            compare(Platform.keys("Ctrl+Shift+L"), "⇧⌘L")
            compare(Platform.keys("Ctrl+Alt+\\"), "⌥⌘\\")
            compare(Platform.keys("Ctrl+["), "⌘[")
        } else {
            compare(Platform.keys("Ctrl+Shift+L"), "Ctrl+Shift+L")
        }
    }
    function test_namedTabGroups() {
        const strip = Tree.group([Tree.tab("file:///a.pdf"), Tree.webTab("https://x.org"), Tree.tab("file:///b.pdf")])
        const [a, web, b] = strip.tabs
        const label = Tree.addLabel(strip, "  Radar  ")
        compare(label.name, "Radar")
        Tree.setTabLabel(strip, a.id, label.id)
        Tree.setTabLabel(strip, b.id, label.id)
        // Members sit next to each other.
        compare(strip.tabs.map(function(t) { return t.id }), [a.id, b.id, web.id])
        verify(Tree.validate(strip, {}, 0))
        label.collapsed = true
        strip.activeTab = web.id
        compare(Tree.visibleTabs(strip).map(function(t) { return t.id }), [web.id])
        strip.activeTab = b.id // The active tab shows even in a collapsed group.
        compare(Tree.visibleTabs(strip).map(function(t) { return t.id }), [b.id, web.id])
        // A label the strip does not know is invalid in saved data and dropped by tidyLabels.
        const other = Tree.group([Tree.clone(a)])
        verify(!Tree.validate(other, {}, 0))
        Tree.tidyLabels(other)
        verify(other.tabs[0].label === undefined && other.labels === undefined)
        verify(Tree.validate(other, {}, 0))
        // Leaving the last member removes the group.
        Tree.setTabLabel(strip, a.id, "")
        Tree.setTabLabel(strip, b.id, "")
        verify(strip.labels === undefined)
        verify(Tree.validate(strip, {}, 0))
        // Bad label data is rejected rather than half-restored.
        verify(!Tree.validate({kind: "group", id: "g", activeTab: "", tabs: [], labels: [{id: "", name: "x"}]}, {}, 0))
    }
    function test_migrateLegacy() {
        const state = {version: 1, left: {source: "file:///a.pdf", position: {page: 3, zoom: 1.4}},
            right: {source: "file:///a.pdf", position: {page: 7, zoom: 1}}, split: true, active: 1}
        const migrated = Tree.restore(state)
        const groups = Tree.leaves(migrated.tree)
        compare(groups.length, 2)
        compare(groups[0].tabs[0].position.page, 3)
        compare(groups[1].tabs[0].position.page, 7)
        verify(groups[0].tabs[0].id !== groups[1].tabs[0].id)
        compare(migrated.activeGroup, groups[1].id)
        verify(Tree.validate(migrated.tree, {}, 0))
        state.split = false
        const hidden = Tree.restore(state)
        compare(Tree.leaves(hidden.tree).length, 1)
        compare(hidden.tree.tabs.length, 2)
    }
    function test_invalidRestoreDoesNotMutateInput() {
        const input = {version: 2, tree: {kind: "group", id: "g", activeTab: "missing", tabs: []}}
        const before = JSON.stringify(input)
        let failed = false
        try { Tree.restore(input) } catch (error) { failed = true }
        verify(failed)
        compare(JSON.stringify(input), before)
        failed = false
        try { Tree.restore({version: 99}) } catch (error) { failed = true }
        verify(failed)
    }
    function test_splitGeometryAndRoundTrip() {
        let tree = Tree.group([Tree.tab("file:///a.pdf")])
        for (let i = 0; i < 8; ++i) tree = Tree.split(tree, Tree.leaves(tree)[0].id, Tree.group([Tree.tab("file:///b.pdf")]), i % 2 ? "bottom" : "right")
        const size = Tree.minimum(tree), groups = [], handles = []
        Tree.geometry(tree, 0, 0, size.width, size.height, groups, handles)
        compare(groups.length, 9); compare(handles.length, 8)
        for (let i = 0; i < groups.length; ++i) { verify(groups[i].width >= 440); verify(groups[i].height >= 280) }
        const restored = Tree.restore({version: 2, tree: tree, activeGroup: groups[5].node.id})
        compare(JSON.stringify(restored.tree), JSON.stringify(tree))
        compare(restored.activeGroup, groups[5].node.id)
    }
}
