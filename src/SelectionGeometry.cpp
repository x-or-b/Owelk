#include "SelectionGeometry.h"
#include <algorithm>
#include <cmath>
#include <limits>

QVariantList SelectionGeometry::stableRectangles(const QList<QPolygonF> &selection, const QVariantList &pageLines) const
{
    auto selected = lineRectangles(selection);
    for (auto &value : selected) {
        auto rect = value.toRectF();
        QRectF best;
        qreal distance = std::numeric_limits<qreal>::max();
        for (const auto &lineValue : pageLines) {
            const auto line = lineValue.toRectF();
            if (line.right() <= rect.left() || line.left() >= rect.right()) continue;
            if (line.bottom() <= rect.top() || line.top() >= rect.bottom()) continue;
            const qreal delta = std::abs(line.center().y() - rect.center().y());
            if (delta < distance) { best = line; distance = delta; }
        }
        if (!best.isEmpty()) { rect.setTop(best.top()); rect.setBottom(best.bottom()); }
        value = rect;
    }
    return selected;
}

QVariantList SelectionGeometry::lineRectangles(const QList<QPolygonF> &polygons) const
{
    // Keep QPolygonF conversion in C++: QML exposes these as opaque values.
    QList<QRectF> boxes;
    for (const auto &polygon : polygons) {
        const auto box = polygon.boundingRect();
        if (!box.isEmpty() && std::isfinite(box.x() + box.y() + box.width() + box.height()))
            boxes.append(box);
    }
    std::sort(boxes.begin(), boxes.end(), [](const auto &a, const auto &b) {
        return a.y() == b.y() ? a.x() < b.x() : a.y() < b.y();
    });
    struct Line { QRectF bounds; QList<QRectF> boxes; };
    QList<Line> lines;
    for (const auto &box : boxes) {
        Line *line = nullptr;
        for (auto it = lines.rbegin(); it != lines.rend(); ++it) {
            const auto &candidate = it->bounds;
            const qreal overlap = std::min(candidate.bottom(), box.bottom())
                                - std::max(candidate.top(), box.top());
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
        std::sort(line.boxes.begin(), line.boxes.end(), [](const auto &a, const auto &b) {
            return a.x() < b.x();
        });
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
    QVariantList padded;
    for (const auto &value : result) {
        const auto rect = value.toRectF();
        const qreal padding = std::clamp(rect.height() * .18, 1.0, 3.0);
        qreal above = std::min(padding, std::max(0.0, rect.top()));
        qreal below = padding;
        for (const auto &otherValue : result) {
            const auto other = otherValue.toRectF();
            if (other.right() <= rect.left() || other.left() >= rect.right()) continue;
            // Neighboring selected lines share the available gap without overlap.
            if (other.bottom() <= rect.top()) above = std::min(above, (rect.top() - other.bottom()) / 2);
            if (other.top() >= rect.bottom()) below = std::min(below, (other.top() - rect.bottom()) / 2);
        }
        padded.append(rect.adjusted(0, -above, 0, below));
    }
    return padded;
}
