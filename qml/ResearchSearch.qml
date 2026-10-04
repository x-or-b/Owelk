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
    // Meaning matches (when semantic search is on), shown after the keyword results.
    property var semanticRows: []
    property int semanticRequest: -1
    readonly property var semantic: researchStore.semantic
    property bool namesPending: false
    property bool textPending: false
    readonly property bool waiting: namesPending || textPending
    property string error: ""
    property url sourceFilter: ""
    property string targetFilter: "all"
    // Library conditions typed into the query: tag:, collection:, state:, year:2020 or year:2018-2022,
    // workspace:. Names match case-insensitively; quotes allow spaces (tag:"deep learning").
    readonly property var parsed: parseQuery(query)
    readonly property var libraryFilter: parsed.filter
    readonly property var tokenLabels: parsed.labels
    readonly property bool libraryScoped: Object.keys(libraryFilter).length > 0
    function parseQuery(text) {
        const filter = {}, labels = []
        const pattern = /(^|\s)(tag|collection|state|year|workspace):("([^"]*)"|\S+)/gi
        const lookup = function(list, name) {
            const hit = list.find(function(item) { return item.name.toLowerCase() === name.toLowerCase() })
            return hit ? hit.id : "\u0000missing" // No match narrows to nothing rather than ignoring the condition.
        }
        const needle = text.replace(pattern, function(all, lead, key, raw, quoted) {
            const value = quoted !== undefined ? quoted : raw
            key = key.toLowerCase()
            if (!value.length) return lead
            if (key === "tag") filter.tag = lookup(researchStore.tags(), value)
            else if (key === "collection") filter.collection = lookup(researchStore.collections(), value)
            else if (key === "workspace") filter.workspace = lookup(researchStore.recentWorkspaces, value)
            else if (key === "state") filter.state = ["unread", "reading", "read"].indexOf(value.toLowerCase()) >= 0 ? value.toLowerCase() : "\u0000missing"
            else if (key === "year") {
                const range = value.match(/^(\d{4})(?:-(\d{4}))?$/)
                if (!range) return lead + all.trim()
                filter.yearFrom = Number(range[1]); filter.yearTo = Number(range[2] || range[1])
            }
            labels.push(key + ": " + value)
            return lead
        }).replace(/\s+/g, " ").trim()
        return {needle: needle, filter: filter, labels: labels}
    }
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
        if (result.kind === "section") return true
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
        names = []; textRows = []; semanticRows = []; semanticRequest = -1; results = []; error = ""
    }
    // Saved items come first; publish only once they are known so the selection does not jump.
    function publish() {
        if (namesPending) return
        const shown = names.concat(textRows)
        // Meaning matches not already listed, under their own heading.
        const seen = {}
        shown.forEach(function(r) { seen[r.kind === "text" ? "text|" + r.documentId + "|" + r.page : r.kind + "|" + r.id] = true })
        const extra = semanticRows.filter(function(r) { return !seen[r.kind === "text" ? "text|" + r.documentId + "|" + r.page : r.kind + "|" + r.id] })
        results = extra.length ? shown.concat([{kind: "section", title: "Similar meaning"}]).concat(extra) : shown
    }
    function refresh() {
        delay.stop()
        invalidate()
        if (!active) return
        const needle = parsed.needle
        // Library filters narrow both searches to the same set of papers.
        const scope = libraryScoped ? researchStore.libraryDocuments(libraryFilter) : null
        if (needle.length && offset === 0) {
            namesPending = true
            namesRequest = researchStore.searchKnowledgeAsync(needle, sourceFilter, targetFilter, scope ? scope.map(function(p) { return p.url }) : null)
        } else if (!needle.length && scope && targetFilter !== "text" && targetFilter !== "captures" && targetFilter !== "ai") {
            // Only library conditions (e.g. "tag:slam"): list the papers they match.
            names = scope.slice(0, 40).map(function(p) { return {kind: "paper", title: p.name, source: p.url, position: p.position, authors: p.authors, year: p.year} })
        } else if (!needle.length && showRecent && !sourceFilter.toString().length && targetFilter !== "text" && targetFilter !== "captures") {
            names = researchStore.recentDocuments.map(function(p) { return {kind: "paper", title: p.name, source: p.url, position: p.position, authors: p.authors, year: p.year} })
        }
        publish()
        if (semantic && semantic.enabled && needle.length && offset === 0 && !sourceFilter.toString().length && !libraryScoped
                && (targetFilter === "all" || targetFilter === "text"))
            semanticRequest = semantic.search(needle)
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
    property Connections semanticUpdates: Connections {
        target: root.semantic
        function onFound(id, rows, error) {
            if (!root.active || root.semanticRequest !== id) return
            root.semanticRows = rows; root.publish()
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
