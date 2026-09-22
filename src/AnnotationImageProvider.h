#pragma once
#include "AnnotationImage.h"
#include <QQuickImageProvider>

class AnnotationImageProvider final : public QQuickImageProvider
{
public:
    AnnotationImageProvider() : QQuickImageProvider(QQuickImageProvider::Image, QQmlImageProviderBase::ForceAsynchronousImageLoading) {}
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override {
        const auto source = QUrl::fromEncoded(QByteArray::fromBase64(id.toLatin1(), QByteArray::Base64UrlEncoding));
        QString error;
        auto image = readAnnotationImage(source, &error);
        if (image.isNull()) qWarning() << "Annotation preview:" << error;
        if (size) *size = image.size();
        if (!image.isNull()) {
            if (requestedSize.width() > 0 && requestedSize.height() > 0)
                image = image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            else if (requestedSize.width() > 0)
                image = image.scaledToWidth(requestedSize.width(), Qt::SmoothTransformation);
            else if (requestedSize.height() > 0)
                image = image.scaledToHeight(requestedSize.height(), Qt::SmoothTransformation);
        }
        return image;
    }
};
