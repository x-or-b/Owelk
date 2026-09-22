#pragma once
#include <QImage>
#include <QUrl>

// Bounded decoding shared by the asynchronous preview and annotation import.
QImage readAnnotationImage(const QUrl &source, QString *error = nullptr);
