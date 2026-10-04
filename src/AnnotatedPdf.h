#pragma once

#include <QString>
#include <QVariantList>

// Writes a copy of a PDF with Owelk's annotations as standard PDF annotations (Highlight, Text, FreeText,
// Ink, Stamp) that other readers show and can edit. The original file is only read. marks: rows as
// ResearchStore::readPrintMarks gives them (page, rectangles in page-relative 0..1 from the top left,
// color, kind, body, image, drawing). Returns an empty string on success, otherwise the reason.
namespace AnnotatedPdf {
bool available();
QString write(const QString &source, const QString &target, const QVariantList &marks, const QString &password);
}
