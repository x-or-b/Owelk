import QtQuick

QtObject {
    id: root
    property string query: ""
    property bool active: true
    property bool showRecent: false
    property var results: []
    property var names: []
    property int request: -1
    property bool waiting: false
    property string error: ""
    function invalidate() { request = -1; waiting = false; results = []; error = "" }
    function refresh() {
        delay.stop()
        invalidate()
        if (!active) return
        const needle = query.trim()
        names = needle.length ? researchStore.searchKnowledge(needle)
            : showRecent ? researchStore.recentDocuments.map(function(p) { return {kind: "paper", title: p.name, source: p.url, position: p.position} }) : []
        results = names
        if (needle.length) { waiting = true; request = researchStore.paperIndex.search(needle) }
    }
    onQueryChanged: { invalidate(); if (active) delay.restart() }
    onActiveChanged: { if (active) refresh(); else { delay.stop(); invalidate() } }
    property Timer delay: Timer { interval: 150; onTriggered: root.refresh() }
    property Connections storeUpdates: Connections {
        target: researchStore
        function onHomeChanged() { if (root.active) root.delay.restart() }
    }
    property Connections indexUpdates: Connections {
        target: researchStore.paperIndex
        function onContentsChanged() { if (root.active && root.query.trim().length) root.delay.restart() }
        function onSearchFinished(id, rows, error) {
            if (!root.active || root.request !== id) return
            root.waiting = false; root.error = error
            root.results = root.names.concat(rows)
        }
    }
}
