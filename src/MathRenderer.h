#pragma once

#include <QColor>
#include <QImage>
#include <QSize>
#include <QString>

// LaTeX math drawn as images for rich text (AI answers, note previews). MicroTeX lays the formula out
// with TeX fonts; images are made at twice the size so they stay sharp on high-density screens, and
// kept in a small cache that the "math" image provider reads from (src/MathImageProvider.h).
namespace MathRenderer {
// Renders (or finds) the formula and returns its cache key, with the size it should be shown at
// (logical pixels). Empty when the formula cannot be read. GUI thread only (MicroTeX is not thread-safe).
QString render(const QString &latex, bool display, int pixelSize, const QColor &color, QSize *size);
// The image for a key from render(), or a null image when it has left the cache. Any thread.
QImage cached(const QString &key);
}
