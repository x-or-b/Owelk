#pragma once
#include <QColor>
#include <QFont>
#include <QPainter>
#include <QPdfWriter>

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

