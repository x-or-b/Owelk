import QtQuick

QtObject {
    id: root
    property string query: ""
    property bool active: true
    property bool showRecent: false
    property var results: []
    property var names: []
    property int request: -1
    property int namesRequest: -1
    property var textRows: []
    property bool namesPending: false
    property bool textPending: false
    readonly property bool waiting: namesPending || textPending
    property string error: ""
    property url sourceFilter: ""
    property string targetFilter: "all"
    property int offset: 0
    property var history: []
    property bool changing: false
    property int preferredIndex: 0
    function resetFilters() {
        changing = true; sourceFilter = ""; targetFilter = "all"; offset = 0; history = []; preferredIndex = 0; changing = false
        refresh()
    }
    function filtersChanged() {
        if (changing) return
        offset = 0; history = []; preferredIndex = 0; invalidate(); if (active) delay.restart()
    }
    onSourceFilterChanged: filtersChanged()
    onTargetFilterChanged: filtersChanged()
    function choose(result) {
        if (["paperGroup", "moreInPaper", "nextResults"].indexOf(result.kind) < 0) return false
        if (result.kind === "paperGroup" && researchStore.sameSource(sourceFilter, result.source)) return true
        history = history.concat([{source: sourceFilter.toString(), target: targetFilter, offset: offset, index: results.indexOf(result)}])
        preferredIndex = 0
        changing = true
        if (result.kind === "nextResults") offset = result.offset
        else { sourceFilter = result.source; targetFilter = "text"; offset = 0 }
        changing = false; refresh(); return true
    }
    function selectionIndex() {
        if (!results.length) return -1
        return Math.min(preferredIndex > 0 ? preferredIndex : Math.max(0, results.findIndex(function(r) { return r.kind !== "paperGroup" })), results.length - 1)
    }
    function back() {
        if (!history.length) return
        const previous = history[history.length - 1]
        history = history.slice(0, -1); changing = true
        sourceFilter = previous.source; targetFilter = previous.target; offset = previous.offset
        preferredIndex = Math.max(0, previous.index || 0)
        changing = false; refresh()
    }
    function invalidate() {
        request = -1; namesRequest = -1; namesPending = false; textPending = false
        names = []; textRows = []; results = []; error = ""
    }
    // Saved items come first; publish only once they are known so the selection does not jump.
    function publish() { if (!namesPending) results = names.concat(textRows) }
    function refresh() {
        delay.stop()
        invalidate()
        if (!active) return
        const needle = query.trim()
        if (needle.length && offset === 0) {
            namesPending = true; namesRequest = researchStore.searchKnowledgeAsync(needle, sourceFilter, targetFilter)
        } else if (!needle.length && showRecent && !sourceFilter.toString().length && targetFilter !== "text" && targetFilter !== "captures") {
            names = researchStore.recentDocuments.map(function(p) { return {kind: "paper", title: p.name, source: p.url, position: p.position} })
        }
        publish()
        if (needle.length && (targetFilter === "all" || targetFilter === "text")) {
            textPending = true; request = researchStore.paperIndex.searchGrouped(needle, sourceFilter, offset)
        }
    }
    onQueryChanged: { offset = 0; history = []; preferredIndex = 0; invalidate(); if (active) delay.restart() }
    onActiveChanged: { if (active) refresh(); else { delay.stop(); invalidate() } }
    property Timer delay: Timer { interval: 150; onTriggered: root.refresh() }
    property Connections storeUpdates: Connections {
        target: researchStore
        function onHomeChanged() { if (root.active) root.delay.restart() }
        function onKnowledgeFound(id, rows) {
            if (!root.active || root.namesRequest !== id) return
            root.names = rows; root.namesPending = false; root.publish()
        }
    }
    property Connections indexUpdates: Connections {
        target: researchStore.paperIndex
        function onContentsChanged() { if (root.active && root.query.trim().length) root.delay.restart() }
        function onSearchFinished(id, rows, error) {
            if (!root.active || root.request !== id) return
            root.textPending = false; root.error = error
            root.textRows = rows; root.publish()
        }
    }
}
