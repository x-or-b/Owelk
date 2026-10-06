.pragma library

// Serializable model. PDF paths identify sources; tab IDs identify independent views.
var serial = 0
function id(prefix) { return prefix + "-" + Date.now().toString(36) + "-" + (++serial) + "-" + Math.random().toString(36).slice(2, 8) }
function clone(value) { return JSON.parse(JSON.stringify(value)) }
function group(tabs) { return {kind: "group", id: id("group"), tabs: tabs || [], activeTab: tabs && tabs.length ? tabs[0].id : ""} }
function tab(source, position) { return {id: id("tab"), source: source.toString(), position: Object.assign({page: 0, y: 0, x: 0, zoom: 1}, clone(position || {}))} }
// Web pages are tabs too; their source is the current http(s) address.
function webTab(url, title) { return {id: id("tab"), kind: "web", source: url.toString(), title: title || "", position: {page: 0, y: 0, x: 0, zoom: 1}} }
function isWebAddress(url) { return /^https?:\/\/[^\s]+$/i.test(url.toString()) }
// A typed address becomes a URL; anything else is a search with the given template ("…?q=%s").
function addressToUrl(text, searchTemplate) {
    const value = text.trim()
    if (!value.length) return ""
    if (/^https?:\/\//i.test(value)) return value
    if (!/\s/.test(value) && /^[^\/]+\.[a-z]{2,}(\/|:|$)/i.test(value)) return "https://" + value
    if (/^arxiv:\s*\d{4}\.\d{4,5}/i.test(value)) return "https://arxiv.org/abs/" + value.replace(/^arxiv:\s*/i, "")
    return searchTemplate.replace("%s", encodeURIComponent(value))
}
// arxiv.org/abs/<id> → its PDF address; empty for other pages.
function arxivPdf(url) {
    const match = /^https?:\/\/(www\.)?arxiv\.org\/abs\/([^?#]+)/i.exec(url.toString())
    return match ? "https://arxiv.org/pdf/" + match[2] : ""
}
// The library view is a tab without a source; its filter travels with the tab.
// A standalone note; the note itself lives in the store, the tab only names it.
function noteTab(noteId, title) { return {id: id("tab"), kind: "note", source: "", noteId: noteId, title: title || "", position: {page: 0, y: 0, x: 0, zoom: 1}} }
function libraryTab(filter) { return {id: id("tab"), kind: "library", source: "", filter: clone(filter || {}), position: {page: 0, y: 0, x: 0, zoom: 1}} }
function homeTab() { return {id: id("tab"), kind: "home", source: "", position: {page: 0, y: 0, x: 0, zoom: 1}} }
// Named tab groups inside one tab strip. Tabs of a group are kept next to each other.
function addLabel(groupNode, name, color) {
    const label = {id: id("label"), name: name.trim().slice(0, 120) || "Group", collapsed: false}
    if (color) label.color = color
    groupNode.labels = (groupNode.labels || []).concat([label])
    return label
}
function setTabLabel(groupNode, tabId, labelId) {
    const at = groupNode.tabs.findIndex(function(t) { return t.id === tabId })
    if (at < 0) return
    const t = groupNode.tabs.splice(at, 1)[0]
    if (labelId) t.label = labelId; else delete t.label
    // Place it after the group's last tab (or back where it was when leaving a group).
    let insert = at
    if (labelId) {
        for (let i = groupNode.tabs.length - 1; i >= 0; --i)
            if (groupNode.tabs[i].label === labelId) { insert = i + 1; break }
    }
    groupNode.tabs.splice(Math.min(insert, groupNode.tabs.length), 0, t)
    pruneLabels(groupNode)
}
// Labels without tabs disappear; a strip without labels has no labels field.
function pruneLabels(groupNode) {
    if (!groupNode.labels) return
    groupNode.labels = groupNode.labels.filter(function(l) { return groupNode.tabs.some(function(t) { return t.label === l.id }) })
    if (!groupNode.labels.length) delete groupNode.labels
}
// A group's tabs stay together. After a tab moved inside a strip: a tab that landed inside another
// group goes to that group's end; a grouped tab that landed away from its group leaves it.
function keepGroupsTogether(groupNode, movedId) {
    const tabs = groupNode.tabs
    let at = tabs.findIndex(function(t) { return t.id === movedId })
    if (at < 0) return
    const moved = tabs[at], prev = tabs[at - 1], next = tabs[at + 1]
    if (prev && next && prev.label && prev.label === next.label && moved.label !== prev.label) {
        tabs.splice(at, 1)
        let last = -1
        for (let i = 0; i < tabs.length; ++i) if (tabs[i].label === prev.label) last = i
        tabs.splice(last + 1, 0, moved)
        at = last + 1
    }
    if (moved.label) {
        const before = tabs[at - 1], after = tabs[at + 1]
        const others = tabs.some(function(t) { return t !== moved && t.label === moved.label })
        if (others && !(before && before.label === moved.label) && !(after && after.label === moved.label)) delete moved.label
    }
    pruneLabels(groupNode)
}
// After tabs move between strips: drop labels a strip does not have, and empty labels.
function tidyLabels(node) {
    leaves(node).forEach(function(g) {
        const known = {}
        ;(g.labels || []).forEach(function(l) { known[l.id] = true })
        g.tabs.forEach(function(t) { if (t.label !== undefined && !known[t.label]) delete t.label })
        pruneLabels(g)
    })
}
// The tabs the bar shows: everything except tabs of a collapsed group (the active tab always shows).
function visibleTabs(groupNode) {
    const collapsed = {}
    ;(groupNode.labels || []).forEach(function(l) { if (l.collapsed) collapsed[l.id] = true })
    return groupNode.tabs.filter(function(t) { return !t.label || !collapsed[t.label] || t.id === groupNode.activeTab })
}
function leaves(node) { return node.kind === "group" ? [node] : leaves(node.first).concat(leaves(node.second)) }
function find(node, key) { if (node.id === key) return node; return node.kind === "split" ? find(node.first, key) || find(node.second, key) : null }
function owner(node, tabId) { return leaves(node).find(function(g) { return g.tabs.some(function(t) { return t.id === tabId }) }) }
function replace(node, key, replacement) {
    if (node.id === key) return replacement
    if (node.kind === "split") { node.first = replace(node.first, key, replacement); node.second = replace(node.second, key, replacement) }
    return node
}
function prune(node) {
    if (node.kind === "group") return node.tabs.length ? node : null
    node.first = prune(node.first); node.second = prune(node.second)
    return !node.first ? node.second : !node.second ? node.first : node
}
function split(node, target, added, edge) {
    const old = find(node, target)
    const before = edge === "left" || edge === "top"
    return replace(node, target, {kind: "split", id: id("split"), axis: edge === "top" || edge === "bottom" ? "vertical" : "horizontal",
        ratio: .5, first: before ? added : old, second: before ? old : added})
}
function minimum(node) {
    if (node.kind === "group") return {width: 440, height: 280}
    const a = minimum(node.first), b = minimum(node.second)
    return node.axis === "horizontal" ? {width: a.width + b.width + 6, height: Math.max(a.height, b.height)}
        : {width: Math.max(a.width, b.width), height: a.height + b.height + 6}
}
function geometry(node, x, y, width, height, groups, handles) {
    if (node.kind === "group") { groups.push({node: node, x: x, y: y, width: width, height: height}); return }
    const horizontal = node.axis === "horizontal"
    const a = minimum(node.first), b = minimum(node.second)
    const span = (horizontal ? width : height) - 6
    const first = Math.max(horizontal ? a.width : a.height, Math.min(span - (horizontal ? b.width : b.height), span * node.ratio))
    handles.push({nodeId: node.id, horizontal: horizontal, x: x + (horizontal ? first : 0), y: y + (horizontal ? 0 : first),
        width: horizontal ? 6 : width, height: horizontal ? height : 6, span: span})
    geometry(node.first, x, y, horizontal ? first : width, horizontal ? height : first, groups, handles)
    geometry(node.second, x + (horizontal ? first + 6 : 0), y + (horizontal ? 0 : first + 6), horizontal ? span - first : width, horizontal ? height : span - first, groups, handles)
}
function validate(node, ids, depth) {
    if (!node || depth > 128 || typeof node.id !== "string" || !node.id || ids[node.id]) return false
    ids[node.id] = true
    if (node.kind === "split") return ["horizontal", "vertical"].indexOf(node.axis) >= 0 && Number.isFinite(node.ratio) && node.ratio > 0 && node.ratio < 1 && validate(node.first, ids, depth + 1) && validate(node.second, ids, depth + 1)
    if (node.kind !== "group" || !Array.isArray(node.tabs)) return false
    for (let i = 0; i < node.tabs.length; ++i) {
        const t = node.tabs[i]
        if (!t || typeof t.id !== "string" || !t.id || ids[t.id] || typeof t.source !== "string") return false
        if (t.kind === "note" && (typeof t.noteId !== "string" || !t.noteId.length)) return false
        if (t.kind === "home" || t.kind === "library" || t.kind === "note" ? t.source !== ""
            : t.kind === "web" ? !isWebAddress(t.source) : !t.source.startsWith("file:")) return false
        ids[t.id] = true
        if (!t.position || !Number.isFinite(t.position.page) || t.position.page < 0) return false
        if (t.documentId !== undefined && typeof t.documentId !== "string") return false
    }
    // Named tab groups (optional): labels on the strip, a tab names its label.
    if (node.labels !== undefined) {
        if (!Array.isArray(node.labels) || node.labels.length > 64) return false
        const labelIds = {}
        for (let i = 0; i < node.labels.length; ++i) {
            const l = node.labels[i]
            if (!l || typeof l.id !== "string" || !l.id || labelIds[l.id] || typeof l.name !== "string" || l.name.length > 120) return false
            if (l.color !== undefined && typeof l.color !== "string") return false
            labelIds[l.id] = true
        }
        if (node.tabs.some(function(t) { return t.label !== undefined && !labelIds[t.label] })) return false
    } else if (node.tabs.some(function(t) { return t.label !== undefined })) return false
    return node.tabs.length ? node.tabs.some(function(t) { return t.id === node.activeTab }) : node.activeTab === ""
}
function restore(state) {
    if (state.version === 2) {
        const tree = clone(state.tree)
        if (!validate(tree, {}, 0)) throw new Error("Invalid saved tab layout. The saved data has not been overwritten.")
        const list = leaves(tree)
        return {tree: tree, activeGroup: list.some(function(g) { return g.id === state.activeGroup }) ? state.activeGroup : list[0].id}
    }
    if (state.version && state.version !== 1) throw new Error("This session needs a newer Owelk version. Saved data has not been overwritten.")
    const a = group(state.left && state.left.source ? [tab(state.left.source, state.left.position)] : [])
    const b = group(state.right && state.right.source ? [tab(state.right.source, state.right.position)] : [])
    let tree = a
    // A hidden legacy right pane is preserved as a background tab, never discarded.
    if (state.split && b.tabs.length) tree = {kind: "split", id: id("split"), axis: "horizontal", ratio: .5, first: a, second: b}
    else if (b.tabs.length) a.tabs = a.tabs.concat(b.tabs)
    if (!a.activeTab && a.tabs.length) a.activeTab = a.tabs[0].id
    return {tree: tree, activeGroup: state.split && state.active === 1 && b.tabs.length ? b.id : a.id}
}
