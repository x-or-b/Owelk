.pragma library

// What Home shows below Continue Reading, and in what order (Settings › General › Home), kept per computer in the
// setting "home.sections": the names in order, "-" before one turned off. For You and Reading take a row each;
// the small boxes sit two to a row from the left, and one without a partner beside it takes the whole row.
const names = ["foryou", "reading", "collections", "recent", "notes", "threads"]
const wide = ["foryou", "reading"]
// How many rows each small box lists; two side by side list as many as the longer.
const rows = {collections: 7, recent: 7, notes: 5, threads: 5}

// [{name, on}] in the saved order: unknown names dropped, any missing (new in a later version) added at the end, on.
function parse(text) {
    const list = []
    String(text || "").split(",").forEach(function(part) {
        const on = part.charAt(0) !== "-", name = on ? part : part.slice(1)
        if (names.indexOf(name) >= 0 && !list.some(function(s) { return s.name === name })) list.push({name: name, on: on})
    })
    names.forEach(function(name) { if (!list.some(function(s) { return s.name === name })) list.push({name: name, on: true}) })
    return list
}

function format(list) {
    return list.map(function(s) { return (s.on ? "" : "-") + s.name }).join(",")
}

// Where each section turned on goes: {name: {row, column, span, rows}}; one turned off has none.
function places(list) {
    const shown = list.filter(function(s) { return s.on }).map(function(s) { return s.name })
    const result = {}
    let row = 0
    for (let i = 0; i < shown.length; ++i) {
        const name = shown[i], next = shown[i + 1]
        if (wide.indexOf(name) >= 0) {
            result[name] = {row: row++, column: 0, span: 2}
        } else if (next !== undefined && wide.indexOf(next) < 0) {
            const both = Math.max(rows[name], rows[next])
            result[name] = {row: row, column: 0, span: 1, rows: both}
            result[next] = {row: row++, column: 1, span: 1, rows: both}
            ++i
        } else {
            result[name] = {row: row++, column: 0, span: 2, rows: rows[name]}
        }
    }
    return result
}

// How many rows tall each small box placed is ({name: rows}), given how many each has (counts): as many as it lists
// (one when it has none, for its note), or as the box beside it, whichever is more, so the two line up.
function heights(placed, counts) {
    const listed = {}, result = {}
    Object.keys(placed).forEach(function(name) {
        if (placed[name].rows) listed[name] = Math.max(1, Math.min(counts[name] || 0, placed[name].rows))
    })
    Object.keys(listed).forEach(function(name) {
        result[name] = listed[name]
        Object.keys(listed).forEach(function(other) {
            if (placed[other].row === placed[name].row) result[name] = Math.max(result[name], listed[other])
        })
    })
    return result
}

// The list with the section at index moved by one place up (-1) or down (1).
function move(list, index, by) {
    const to = index + by
    if (index < 0 || index >= list.length || to < 0 || to >= list.length) return list
    const moved = list.slice()
    moved.splice(to, 0, moved.splice(index, 1)[0])
    return moved
}

// [[name, …], …]: the rows Home will show, for the preview in Settings.
function preview(list) {
    const placed = places(list), lines = []
    Object.keys(placed).forEach(function(name) {
        const p = placed[name]
        lines[p.row] = lines[p.row] || []
        lines[p.row][p.column] = name
    })
    return lines
}
