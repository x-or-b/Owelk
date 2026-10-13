.pragma library

// Web search engines: the built-in ones, then the reader's own (Settings › Web), each {name, template}
// where %s stands for the words. The default one is the "searchEngine" setting (its template).
var builtIn = [
    {name: "Google Scholar", template: "https://scholar.google.com/scholar?q=%s"},
    {name: "arXiv", template: "https://arxiv.org/search/?query=%s&searchtype=all"},
    {name: "Google", template: "https://www.google.com/search?q=%s"},
    {name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"}
]

function valid(engine) {
    return !!engine && typeof engine.name === "string" && engine.name.trim().length > 0
        && typeof engine.template === "string" && /^https?:\/\/\S+$/i.test(engine.template) && engine.template.indexOf("%s") >= 0
}
function custom(store) {
    try {
        const list = JSON.parse(store.setting("web.engines", "[]"))
        return Array.isArray(list) ? list.filter(valid) : []
    } catch (e) {
        return []
    }
}
function all(store) { return builtIn.concat(custom(store)) }
function isBuiltIn(template) { return builtIn.some(function(e) { return e.template === template }) }
// The default engine; a template set some other way (an older setting) still counts, named by its site.
function current(store) {
    const template = store.setting("searchEngine", builtIn[0].template)
    const known = all(store).find(function(e) { return e.template === template })
    if (known) return known
    if (valid({name: "x", template: template})) return {name: template.replace(/^https?:\/\/(www\.)?/i, "").replace(/[\/?#].*$/, ""), template: template}
    return builtIn[0]
}
function template(store) { return current(store).template }
function setDefault(store, template) { store.setSetting("searchEngine", template) }
// An engine of one's own; false when the name is empty or the address has no %s.
function add(store, name, template) {
    const engine = {name: String(name).trim(), template: String(template).trim()}
    if (!valid(engine) || all(store).some(function(e) { return e.template === engine.template })) return false
    store.setSetting("web.engines", JSON.stringify(custom(store).concat([engine])))
    return true
}
function remove(store, template) {
    store.setSetting("web.engines", JSON.stringify(custom(store).filter(function(e) { return e.template !== template })))
    if (store.setting("searchEngine", "") === template) setDefault(store, builtIn[0].template)
}
// Where a new web tab starts: the engine's own page (its address without the words).
function home(template) {
    const page = String(template).split("?")[0]
    return /^https?:\/\/[^\/]+/i.test(page) ? page : "https://scholar.google.com/"
}
