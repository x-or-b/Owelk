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
    // Library scope: collection, tag, state, workspace, yearFrom, yearTo (see researchStore.libraryDocuments).
    property var libraryFilter: ({})
    readonly property bool libraryScoped: Object.keys(libraryFilter).length > 0
    function setLibraryFilter(key, value) {
        const empty = value === "" || value === undefined || value === null
        // Unchanged values (e.g. a year field losing focus) must not restart the search.
        if (empty ? !(key in libraryFilter) : libraryFilter[key] === value) return
        const next = Object.assign({}, libraryFilter)
        if (value === "" || value === undefined || value === null) delete next[key]
        else next[key] = value
        libraryFilter = next
    }
    property int offset: 0
    property var history: []
    property bool changing: false
    property int preferredIndex: 0
    function resetFilters() {
        changing = true; sourceFilter = ""; targetFilter = "all"; libraryFilter = ({}); offset = 0; history = []; preferredIndex = 0; changing = false
        refresh()
    }
    function filtersChanged() {
        if (changing) return
        offset = 0; history = []; preferredIndex = 0; invalidate(); if (active) delay.restart()
    }
    onSourceFilterChanged: filtersChanged()
    onTargetFilterChanged: filtersChanged()
    onLibraryFilterChanged: filtersChanged()
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
        // Library filters narrow both searches to the same set of papers.
        const scope = libraryScoped ? researchStore.libraryDocuments(libraryFilter) : null
        if (needle.length && offset === 0) {
            namesPending = true
            namesRequest = researchStore.searchKnowledgeAsync(needle, sourceFilter, targetFilter, scope ? scope.map(function(p) { return p.url }) : null)
        } else if (!needle.length && showRecent && !sourceFilter.toString().length && targetFilter !== "text" && targetFilter !== "captures") {
            names = researchStore.recentDocuments.map(function(p) { return {kind: "paper", title: p.name, source: p.url, position: p.position, authors: p.authors, year: p.year} })
        }
        publish()
        if (needle.length && (targetFilter === "all" || targetFilter === "text")) {
            textPending = true
            request = researchStore.paperIndex.searchGrouped(needle, sourceFilter, offset, scope ? scope.map(function(p) { return p.id }) : null)
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
