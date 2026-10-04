#pragma once
#include <QColor>
#include <QFont>
#include <QPainter>
#include <QPdfWriter>
#include <QFile>

inline void writeFixture(const QString &path, const QString &title = "A Small Research Reader", int pages = 8)
{
    QPdfWriter writer(path);
    writer.setTitle(title);
    writer.setCreator("Owelk test fixture generator");
    writer.setPageSize(QPageSize(QPageSize::A4));
    writer.setResolution(72);
    QPainter painter(&writer);
    for (int page = 0; page < pages; ++page) {
        if (page) writer.newPage();
        painter.setPen(QColor("#217871"));
        painter.setFont(QFont("Helvetica", 10));
        painter.drawText(35, 42, "OWELK  /  READING FIXTURE");
        painter.setPen(QColor("#223b35"));
        painter.setFont(QFont("Helvetica", 24, QFont::Bold));
        painter.drawText(QRectF(35, 68, 490, 70), Qt::TextWordWrap, title);
        painter.setFont(QFont("Helvetica", 12));
        painter.drawText(35, 150, QString("Section %1 — Remember the evidence").arg(page + 1));
        painter.setFont(QFont("Helvetica", 11));
        for (int line = 0; line < 11; ++line) {
            painter.drawText(35, 189 + line * 20,
                QString("Research finding %1.%2: occlusion links observation to context.").arg(page + 1).arg(line + 1));
        }
        painter.fillRect(QRect(35, 430, 490, 165), QColor("#e5eee4"));
        painter.fillRect(QRect(70, 468, 105, 90), QColor("#217871"));
        painter.fillRect(QRect(205, 492, 105, 66), QColor("#90b4a3"));
        painter.fillRect(QRect(340, 451, 105, 107), QColor("#dfb665"));
        painter.setPen(QColor("#223b35"));
        painter.drawText(35, 623, QString("Figure %1. Capture this chart and return to its source.").arg(page + 1));
        painter.drawText(35, 678, "This PDF is synthetic test material, not a scientific publication.");
        painter.drawText(35, 706, "Select text, search for occlusion, and compare two pages side by side.");
        painter.drawText(35, 750, QString("Page %1 / %2").arg(page + 1).arg(pages));
    }
}

// One page per string, plain text: for search tests that need specific words.
inline void writeTextFixture(const QString &path, const QStringList &pages)
{
    QPdfWriter writer(path);
    writer.setResolution(72);
    QPainter painter(&writer);
    painter.setFont(QFont("Helvetica", 12));
    for (int p = 0; p < pages.size(); ++p) {
        if (p) writer.newPage();
        painter.drawText(QRectF(35, 40, 480, 700), Qt::TextWordWrap, pages[p]);
    }
}

// Minimal, deterministic PDF with a nested outline; used only by automated tests.
inline bool writeOutlineFixture(const QString &path)
{
    QList<QByteArray> objects;
    objects << "<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R >>"
            << "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>";
    for (int page = 0; page < 3; ++page) {
        objects << QByteArray("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 12 0 R "
                              ">> >> /Contents ")
                + QByteArray::number(4 + page * 2) + " 0 R >>";
        const auto content
            = QByteArray("BT /F1 20 Tf 60 700 Td (Outline fixture page ") + QByteArray::number(page + 1) + ") Tj ET";
        objects << QByteArray("<< /Length ") + QByteArray::number(content.size()) + " >>\nstream\n" + content
                + "\nendstream";
    }
    objects << "<< /Type /Outlines /First 10 0 R /Last 13 0 R /Count 3 >>"
            << "<< /Title (Introduction) /Parent 9 0 R /Dest [3 0 R /XYZ 0 792 0] /First 11 0 R /Last 11 0 R /Count 1 "
               "/Next 13 0 R >>"
            << "<< /Title (Method) /Parent 10 0 R /Dest [5 0 R /XYZ 0 500 0] >>"
            << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            << "<< /Title (Results) /Parent 9 0 R /Prev 10 0 R /Dest [7 0 R /XYZ 0 792 0] >>";
    QByteArray pdf("%PDF-1.4\n");
    QList<qsizetype> offsets;
    for (qsizetype i = 0; i < objects.size(); ++i) {
        offsets << pdf.size();
        pdf += QByteArray::number(i + 1) + " 0 obj\n" + objects[i] + "\nendobj\n";
    }
    const auto start = pdf.size();
    pdf += "xref\n0 14\n0000000000 65535 f \n";
    for (const auto offset : offsets) pdf += QByteArray::number(offset).rightJustified(10, '0') + " 00000 n \n";
    pdf += "trailer\n<< /Size 14 /Root 1 0 R >>\nstartxref\n" + QByteArray::number(start) + "\n%%EOF\n";
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(pdf) == pdf.size();
}

// Three pages; page 1 has an internal link (60,600)-(300,640) in PDF points that jumps to page 3 at y=400.
inline bool writeLinkFixture(const QString &path)
{
    QList<QByteArray> objects;
    objects << "<< /Type /Catalog /Pages 2 0 R >>"
            << "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>";
    for (int page = 0; page < 3; ++page) {
        objects << QByteArray("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R "
                              ">> >> /Contents ")
                + QByteArray::number(4 + page * 2) + " 0 R" + (page == 0 ? " /Annots [10 0 R]" : "") + " >>";
        const auto content
            = QByteArray("BT /F1 20 Tf 60 610 Td (") + (page == 0 ? "See reference [3]" : "Link page") + ") Tj ET";
        objects << QByteArray("<< /Length ") + QByteArray::number(content.size()) + " >>\nstream\n" + content
                + "\nendstream";
    }
    objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            << "<< /Type /Annot /Subtype /Link /Rect [60 600 300 640] /Border [0 0 0] /Dest [7 0 R /XYZ 0 400 0] >>";
    QByteArray pdf("%PDF-1.4\n");
    QList<qsizetype> offsets;
    for (qsizetype i = 0; i < objects.size(); ++i) {
        offsets << pdf.size();
        pdf += QByteArray::number(i + 1) + " 0 obj\n" + objects[i] + "\nendobj\n";
    }
    const auto start = pdf.size();
    pdf += "xref\n0 " + QByteArray::number(objects.size() + 1) + "\n0000000000 65535 f \n";
    for (const auto offset : offsets) pdf += QByteArray::number(offset).rightJustified(10, '0') + " 00000 n \n";
    pdf += "trailer\n<< /Size " + QByteArray::number(objects.size() + 1) + " /Root 1 0 R >>\nstartxref\n"
        + QByteArray::number(start) + "\n%%EOF\n";
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(pdf) == pdf.size();
}
