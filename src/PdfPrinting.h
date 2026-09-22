#pragma once
#include <QImage>
#include <QVariantList>

// Pure image composition, shared by asynchronous printing and offscreen tests.
void paintPdfAnnotations(QImage &page, const QVariantList &annotations, qreal pointScale);
