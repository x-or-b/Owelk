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
// Engines hidden from the search box's chooser (Settings › Web); the default one always shows.
function hidden(store) {
    try {
        const list = JSON.parse(store.setting("web.hiddenEngines", "[]"))
        return Array.isArray(list) ? list : []
    } catch (e) {
        return []
    }
}
function setHidden(store, template, hide) {
    const list = hidden(store).filter(function(t) { return t !== template })
    if (hide) list.push(template)
    store.setSetting("web.hiddenEngines", JSON.stringify(list))
}
function shown(store) {
    const off = hidden(store), chosen = template(store)
    const list = all(store).filter(function(e) { return e.template === chosen || off.indexOf(e.template) < 0 })
    return list.some(function(e) { return e.template === chosen }) ? list : [current(store)].concat(list)
}

// Search addresses of well-known sites, so typing "google.com" is enough when adding an engine.
var known = {
    "google.com": ["Google", "https://www.google.com/search?q=%s"],
    "scholar.google.com": ["Google Scholar", "https://scholar.google.com/scholar?q=%s"],
    "bing.com": ["Bing", "https://www.bing.com/search?q=%s"],
    "duckduckgo.com": ["DuckDuckGo", "https://duckduckgo.com/?q=%s"],
    "naver.com": ["Naver", "https://search.naver.com/search.naver?query=%s"],
    "search.naver.com": ["Naver", "https://search.naver.com/search.naver?query=%s"],
    "daum.net": ["Daum", "https://search.daum.net/search?q=%s"],
    "arxiv.org": ["arXiv", "https://arxiv.org/search/?query=%s&searchtype=all"],
    "semanticscholar.org": ["Semantic Scholar", "https://www.semanticscholar.org/search?q=%s"],
    "pubmed.ncbi.nlm.nih.gov": ["PubMed", "https://pubmed.ncbi.nlm.nih.gov/?term=%s"],
    "pubmed.gov": ["PubMed", "https://pubmed.ncbi.nlm.nih.gov/?term=%s"],
    "wikipedia.org": ["Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s"],
    "en.wikipedia.org": ["Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s"],
    "ko.wikipedia.org": ["Wikipedia (Korean)", "https://ko.wikipedia.org/w/index.php?search=%s"],
    "youtube.com": ["YouTube", "https://www.youtube.com/results?search_query=%s"],
    "github.com": ["GitHub", "https://github.com/search?q=%s"],
    "dblp.org": ["dblp", "https://dblp.org/search?q=%s"],
    "researchgate.net": ["ResearchGate", "https://www.researchgate.net/search?q=%s"],
    "paperswithcode.com": ["Papers with Code", "https://paperswithcode.com/search?q=%s"],
    "openreview.net": ["OpenReview", "https://openreview.net/search?term=%s"],
    "ieeexplore.ieee.org": ["IEEE Xplore", "https://ieeexplore.ieee.org/search/searchresult.jsp?queryText=%s"],
    "dl.acm.org": ["ACM Digital Library", "https://dl.acm.org/action/doSearch?AllField=%s"],
    "link.springer.com": ["Springer", "https://link.springer.com/search?query=%s"],
    "springer.com": ["Springer", "https://link.springer.com/search?query=%s"],
    "sciencedirect.com": ["ScienceDirect", "https://www.sciencedirect.com/search?qs=%s"],
    "riss.kr": ["RISS", "https://www.riss.kr/search/Search.do?query=%s"],
    "dbpia.co.kr": ["DBpia", "https://www.dbpia.co.kr/search/topSearch?searchOption=all&query=%s"],
    "perplexity.ai": ["Perplexity", "https://www.perplexity.ai/search?q=%s"]
}
function hostOf(text) {
    return String(text).trim().replace(/^https?:\/\//i, "").replace(/^www\./i, "").replace(/[\/?#].*$/, "").toLowerCase()
}
// What a typed address becomes: as typed when it has %s (https:// added), a known site's search address,
// or the site's /search?q=. Empty when it does not look like a site.
function templateFor(text) {
    const value = String(text).trim()
    if (!value.length) return ""
    if (value.indexOf("%s") >= 0) return /^https?:\/\//i.test(value) ? value : "https://" + value
    const host = hostOf(value)
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host)) return ""
    return known[host] ? known[host][1] : "https://" + host + "/search?q=%s"
}
function nameFor(text) {
    const host = hostOf(text)
    if (known[host]) return known[host][0]
    const main = host.split(".").filter(function(part) { return part !== "search" })[0] || host
    return main.length ? main.charAt(0).toUpperCase() + main.slice(1) : ""
}
function setDefault(store, template) { store.setSetting("searchEngine", template) }
// An engine of one's own; false when the name is empty or the address has no %s.
function add(store, name, template) {
    const engine = {name: String(name).trim(), template: String(template).trim()}
    if (!valid(engine) || all(store).some(function(e) { return e.template === engine.template })) return false
    store.setSetting("web.engines", JSON.stringify(custom(store).concat([engine])))
    return true
}
function remove(store, template) {
    setHidden(store, template, false)
    store.setSetting("web.engines", JSON.stringify(custom(store).filter(function(e) { return e.template !== template })))
    if (store.setting("searchEngine", "") === template) setDefault(store, builtIn[0].template)
}
// Where a new web tab starts: the engine's own page (its address without the words).
function home(template) {
    const page = String(template).split("?")[0]
    return /^https?:\/\/[^\/]+/i.test(page) ? page : "https://scholar.google.com/"
}
