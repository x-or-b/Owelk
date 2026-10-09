#pragma once

#include "MathRenderer.h"

#include <QQuickImageProvider>

// "image://math/<key>": formulas that ResearchStore::markdownHtml drew with MathRenderer.
class MathImageProvider final : public QQuickImageProvider {
public:
    MathImageProvider() : QQuickImageProvider(QQuickImageProvider::Image) { }
    // The text gives each formula its shown size, so the double-size image is returned as is and
    // stays sharp on high-density screens.
    QImage requestImage(const QString &id, QSize *size, const QSize &) override
    {
        auto image = MathRenderer::cached(id);
        if (image.isNull()) {
            image = QImage(1, 1, QImage::Format_ARGB32_Premultiplied);
            image.fill(Qt::transparent);
        }
        if (size) *size = image.size();
        return image;
    }
};
