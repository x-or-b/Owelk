#include "SelectionGeometry.h"
#include <algorithm>
#include <functional>
#include <cmath>
#include <limits>

namespace {
// Bands of different lines meet halfway between them: halfway across the gap, or halfway through the strip where
// their boxes overlap (many PDFs give each line its font's full height, taller than the line spacing), so
// neighbouring bands never cover each other. Only lines of comparable height count: a fraction bar or an accent
// (thin), or a bracket spanning two lines (tall), cuts no line. limit: how far beyond its box a band may reach.
QList<QRectF> meetHalfway(const QList<QRectF> &bands, const std::function<qreal(const QRectF &)> &limit)
{
    QList<QRectF> result;
    for (const auto &rect : bands) {
        const qreal reach = limit(rect);
        qreal top = rect.top() - std::min(reach, std::max(0.0, rect.top()));
        qreal bottom = rect.bottom() + reach;
        for (const auto &other : bands) {
            if (other.right() <= rect.left() || other.left() >= rect.right()) continue;
            if (other.height() < rect.height() * .5 || other.height() > rect.height() * 2) continue;
            const qreal apart = other.center().y() - rect.center().y();
            if (std::abs(apart) <= std::min(other.height(), rect.height()) * .5) continue; // The same line.
            if (apart > 0)
                bottom = std::min(bottom, (rect.bottom() + other.top()) / 2);
            else
                top = std::max(top, (other.bottom() + rect.top()) / 2);
        }
        if (bottom > top) result.append(QRectF(rect.left(), top, rect.width(), bottom - top));
    }
    return result;
}
}

QVariantList SelectionGeometry::stableRectangles(const QList<QPolygonF> &selection, const QVariantList &pageLines) const
{
    QList<QRectF> lines;
    for (const auto &value : pageLines) lines.append(value.toRectF());
    QList<QRectF> bands;
    for (const auto &glyphs : glyphRuns(selection)) {
        const qreal padding = std::clamp(glyphs.height() * .18, 1.0, 3.0);
        auto rect = glyphs.adjusted(0, -padding, 0, padding);
        // A selected part of a line takes the whole line's height, so the band does not change with the letters
        // chosen (x-height or capitals). Only from the same text line: about as tall (some PDFs report blocks of
        // two lines, or both columns), and covering nearly all of the part's own band.
        QRectF best;
        qreal distance = std::numeric_limits<qreal>::max();
        for (const auto &line : std::as_const(lines)) {
            if (line.right() <= rect.left() || line.left() >= rect.right()) continue;
            if (line.height() > rect.height() * 2.5) continue;
            const qreal delta = std::abs(line.center().y() - rect.center().y());
            if (delta > rect.height() * .35) continue;
            const qreal covered = std::min(line.bottom(), rect.bottom()) - std::max(line.top(), rect.top());
            if (covered < rect.height() * .8) continue;
            // A block of two lines holds the middle of another line of the page.
            const bool block = std::any_of(lines.begin(), lines.end(), [&](const QRectF &other) {
                return other != line && other.right() > line.left() && other.left() < line.right()
                    && other.height() < line.height() * .8 && other.center().y() > line.top()
                    && other.center().y() < line.bottom()
                    && std::abs(other.center().y() - line.center().y()) > other.height() * .5;
            });
            if (block) continue;
            if (delta < distance) {
                best = line;
                distance = delta;
            }
        }
        // The line's band, and whatever of the selected glyphs reaches beyond it (a subscript, a tall bracket).
        if (!best.isEmpty()) {
            rect.setTop(std::min(best.top(), glyphs.top()));
            rect.setBottom(std::max(best.bottom(), glyphs.bottom()));
        }
        bands.append(rect);
    }
    // Pieces of one line (a bracket, a fraction bar, a subscript beside it) join that line's band instead of
    // being drawn over it a second time: a band whose middle lies inside a taller-or-equal band it touches.
    std::sort(bands.begin(), bands.end(), [](const QRectF &a, const QRectF &b) { return a.height() > b.height(); });
    QList<QRectF> rows;
    for (const auto &band : std::as_const(bands)) {
        auto row = std::find_if(rows.begin(), rows.end(), [&](const QRectF &r) {
            return band.center().y() > r.top() && band.center().y() < r.bottom() && band.left() <= r.right() + 1
                && band.right() >= r.left() - 1 && band.height() <= r.height() * 1.6;
        });
        if (row != rows.end()) {
            row->setLeft(std::min(row->left(), band.left()));
            row->setRight(std::max(row->right(), band.right()));
        } else {
            rows.append(band);
        }
    }
    QVariantList result;
    for (const auto &band : meetHalfway(rows, [](const QRectF &) { return 0.0; })) result.append(band);
    return result;
}

QList<QRectF> SelectionGeometry::glyphRuns(const QList<QPolygonF> &polygons)
{
    // Keep QPolygonF conversion in C++: QML exposes these as opaque values.
    QList<QRectF> boxes;
    for (const auto &polygon : polygons) {
        const auto box = polygon.boundingRect();
        if (!box.isEmpty() && std::isfinite(box.x() + box.y() + box.width() + box.height())) boxes.append(box);
    }
    std::sort(boxes.begin(), boxes.end(),
        [](const auto &a, const auto &b) { return a.y() == b.y() ? a.x() < b.x() : a.y() < b.y(); });
    struct Line {
        QRectF bounds;
        QList<QRectF> boxes;
    };
    QList<qreal> heights;
    for (const auto &box : boxes) heights.append(box.height());
    std::nth_element(heights.begin(), heights.begin() + heights.size() / 2, heights.end());
    const qreal typical = heights.isEmpty() ? 0 : heights[heights.size() / 2];
    // A rotated margin stamp (e.g. arXiv's) or a tall glyph spans many lines; it must stay on its own
    // rather than merge every line beside it into one page-tall "line".
    const auto oversized = [typical](const QRectF &box) {
        return typical > 0 && box.height() > typical * 2.5 && box.height() > box.width() * 1.5;
    };
    QList<Line> lines;
    for (const auto &box : boxes) {
        Line *line = nullptr;
        if (!oversized(box))
            for (auto it = lines.rbegin(); it != lines.rend(); ++it) {
                const auto &candidate = it->bounds;
                if (candidate.height() > box.height() * 2.5 && oversized(candidate)) continue;
                const qreal overlap = std::min(candidate.bottom(), box.bottom()) - std::max(candidate.top(), box.top());
                if (overlap >= std::min(candidate.height(), box.height()) * .5) {
                    line = &*it;
                    break;
                }
            }
        if (!line) {
            lines.append({box, {}});
            line = &lines.last();
        }
        line->bounds = line->bounds.united(box);
        line->boxes.append(box);
    }
    QVariantList result;
    for (auto &line : lines) {
        std::sort(line.boxes.begin(), line.boxes.end(), [](const auto &a, const auto &b) { return a.x() < b.x(); });
        QRectF run;
        for (const auto &box : line.boxes) {
            // Join glyph/word gaps, but don't bridge a distant second column.
            if (run.isEmpty() || box.left() - run.right() > line.bounds.height() * 1.5) {
                if (!run.isEmpty()) result.append(run);
                run = QRectF(box.x(), line.bounds.y(), box.width(), line.bounds.height());
            } else {
                run.setRight(std::max(run.right(), box.right()));
            }
        }
        if (!run.isEmpty()) result.append(run);
    }
    QList<QRectF> runs;
    for (const auto &value : result) runs.append(value.toRectF());
    return runs;
}

QVariantList SelectionGeometry::lineRectangles(const QList<QPolygonF> &polygons) const
{
    // A little room above and below the glyphs, up to halfway to the next line.
    QVariantList padded;
    for (const auto &band :
        meetHalfway(glyphRuns(polygons), [](const QRectF &rect) { return std::clamp(rect.height() * .18, 1.0, 3.0); }))
        padded.append(band);
    return padded;
}
