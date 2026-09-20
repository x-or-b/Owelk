.pragma library
function terms(query) { return query.trim().toLowerCase().split(/\s+/).filter(function(t) { return t.length }) }
function matches(title, query) { const text = title.toLowerCase(); return terms(query).every(function(t) { return text.indexOf(t) >= 0 }) }
function escape(text) { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") }
function highlight(title, query) {
    const lower = title.toLowerCase(), marked = new Array(title.length).fill(false)
    terms(query).forEach(function(term) {
        let at = lower.indexOf(term)
        while (at >= 0) {
            for (let i = at; i < at + term.length; ++i) marked[i] = true
            at = lower.indexOf(term, at + 1)
        }
    })
    let result = "", active = false
    for (let i = 0; i < title.length; ++i) {
        if (marked[i] !== active) { result += marked[i] ? '<span style="color:#426b9a;font-weight:600">' : '</span>'; active = marked[i] }
        result += escape(title[i])
    }
    return result + (active ? '</span>' : '')
}
