import QtQuick
import QtTest
import "../qml/WorkspaceTree.js" as Tree

TestCase {
    name: "WorkspaceTree"
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
