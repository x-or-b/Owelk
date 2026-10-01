.pragma library

// Freehand strokes are quadratic segments through the midpoints of sampled points.
// paintPdfAnnotations (C++) builds the same curve so screen and print match.
function trace(c, points, mapX, mapY) {
    if (!points.length) return
    c.moveTo(mapX(points[0]), mapY(points[0]))
    if (points.length === 1) { c.lineTo(mapX(points[0]) + .01, mapY(points[0])); return }
    for (let i = 1; i < points.length - 1; ++i) {
        const p = points[i], q = points[i + 1]
        c.quadraticCurveTo(mapX(p), mapY(p), (mapX(p) + mapX(q)) / 2, (mapY(p) + mapY(q)) / 2)
    }
    const last = points[points.length - 1]
    c.lineTo(mapX(last), mapY(last))
}

// Distance in item pixels from (x, y) to the sampled stroke, used so only the ink itself is clickable.
function distance(points, x, y, mapX, mapY) {
    let best = Infinity
    for (let i = 0; i < points.length; ++i) {
        const ax = mapX(points[i]), ay = mapY(points[i])
        const b = points[Math.min(i + 1, points.length - 1)], bx = mapX(b), by = mapY(b)
        const dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
        const t = length > 0 ? Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / length)) : 0
        best = Math.min(best, Math.hypot(x - ax - t * dx, y - ay - t * dy))
    }
    return best
}
