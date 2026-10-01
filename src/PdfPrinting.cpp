#include "ResearchStore.h"
#include "PdfPrinting.h"
#include <QApplication>
#include "FileFingerprint.h"
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QPainter>
#include <QPainterPath>
#include <QPdfDocument>
#include <QPrintDialog>
#include <QPrinter>
#include <QProgressDialog>
#include <QSqlQuery>
#include <QtConcurrent>
#include <memory>

void paintPdfAnnotations(QImage &page, const QVariantList &marks, qreal scale)
{
    QPainter p(&page);
    p.setRenderHint(QPainter::Antialiasing);
    for (const auto &entry : marks) {
        const auto mark = entry.toMap();
        const auto kind = mark["kind"].toString();
        const QColor color(mark["color"].toString());
        const auto rectangles = mark["rectangles"].toList();
        for (const auto &value : rectangles) {
            const auto r = value.toMap();
            const QRectF box(r["x"].toDouble() * page.width(), r["y"].toDouble() * page.height(),
                r["width"].toDouble() * page.width(), r["height"].toDouble() * page.height());
            p.save();
            if (kind == "highlight" || kind == "comment") {
                QColor tint = color;
                tint.setAlphaF(kind == "comment" ? .12 : .28);
                p.fillRect(box, tint);
            }
            if (kind == "comment" || (!mark["body"].toString().isEmpty() && kind == "highlight")) {
                p.setBrush(color);
                p.setPen(Qt::NoPen);
                p.drawRoundedRect(QRectF(box.topRight() - QPointF(10 * scale, 0), QSizeF(10 * scale, 8 * scale)),
                    2 * scale, 2 * scale);
            }
            if (kind == "text") {
                p.setPen(color);
                QFont f;
                f.setPixelSize(qRound(14 * scale));
                p.setFont(f);
                p.setClipRect(box);
                p.drawText(box, Qt::TextWordWrap | Qt::AlignLeft | Qt::AlignTop, mark["body"].toString());
            }
            if (kind == "image") {
                QImage asset(mark["image"].toUrl().toLocalFile());
                if (!asset.isNull()) p.drawImage(box, asset);
            }
            if (kind == "draw") {
                // Same midpoint quadratic curve as qml/StrokePath.js, so print matches the screen.
                QList<QPointF> points;
                for (const auto &point : mark["drawing"].toList()) {
                    const auto xy = point.toMap();
                    points.append({xy["x"].toDouble() * page.width(), xy["y"].toDouble() * page.height()});
                }
                QPainterPath path;
                if (!points.isEmpty()) path.moveTo(points.first());
                for (qsizetype i = 1; i + 1 < points.size(); ++i)
                    path.quadTo(points[i], (points[i] + points[i + 1]) / 2);
                if (points.size() > 1) path.lineTo(points.last());
                p.setPen(QPen(color, 2 * scale, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
                p.drawPath(path);
            }
            p.restore();
        }
    }
}

namespace {
struct PrintJob {
    std::unique_ptr<QPrinter> printer = std::make_unique<QPrinter>(QPrinter::HighResolution);
    std::unique_ptr<QPainter> painter;
    QProgressDialog *progress = nullptr;
    QObject *owner = nullptr;
    QThreadPool *pool = nullptr;
    QUrl source;
    QString hash;
    QVariantList marks;
    int page = 0, last = 0, first = 0;
    std::function<void(const QString &)> finished;
};
void finish(const std::shared_ptr<PrintJob> &job, const QString &error)
{
    if (job->painter) {
        job->painter->end();
        job->painter.reset();
    }
    if (job->progress) {
        job->progress->close();
        job->progress->deleteLater();
        job->progress = nullptr;
    }
    job->finished(error);
}
void nextPage(const std::shared_ptr<PrintJob> &job)
{
    if (job->progress->wasCanceled()) {
        job->printer->abort();
        finish(job, "Printing cancelled.");
        return;
    }
    if (job->page > job->last) {
        finish(job, QString());
        return;
    }
    auto *watcher = new QFutureWatcher<QImage>(job->owner);
    QObject::connect(watcher, &QFutureWatcher<QImage>::finished, job->owner, [job, watcher] {
        const auto pixels = watcher->result();
        watcher->deleteLater();
        if (pixels.isNull()) {
            job->printer->abort();
            finish(job, "Printing stopped: the source changed or a page could not be rendered.");
            return;
        }
        if (job->progress->wasCanceled()) {
            job->printer->abort();
            finish(job, "Printing cancelled.");
            return;
        }
        if (!job->painter) {
            job->painter = std::make_unique<QPainter>();
            if (!job->painter->begin(job->printer.get())) {
                finish(job, "Cannot start the print job.");
                return;
            }
        } else if (!job->printer->newPage()) {
            finish(job, "The printer could not create the next page.");
            return;
        }
        const auto area = job->printer->pageLayout().paintRectPixels(job->printer->resolution());
        const auto size = pixels.size().scaled(area.size(), Qt::KeepAspectRatio);
        job->painter->drawImage(
            QRect(QPoint((area.width() - size.width()) / 2, (area.height() - size.height()) / 2), size), pixels);
        job->progress->setValue(job->page - job->first + 1);
        ++job->page;
        nextPage(job);
    });
    watcher->setFuture(QtConcurrent::run(job->pool, [job] {
        if (FileFingerprint::sha256(job->source.toLocalFile()) != job->hash) return QImage();
        QPdfDocument pdf;
        if (pdf.load(job->source.toLocalFile()) != QPdfDocument::Error::None || job->page >= pdf.pageCount())
            return QImage();
        const auto points = pdf.pagePointSize(job->page);
        const qreal scale = qMin(2.0, 4096.0 / qMax(points.width(), points.height()));
        auto image = pdf.render(job->page, QSize(qRound(points.width() * scale), qRound(points.height() * scale)));
        QVariantList marks;
        for (const auto &m : job->marks)
            if (m.toMap()["page"].toInt() == job->page) marks.append(m);
        if (!image.isNull()) paintPdfAnnotations(image, marks, scale);
        if (FileFingerprint::sha256(job->source.toLocalFile()) != job->hash) return QImage();
        return image;
    }));
}
}

void ResearchStore::printDocument(const QUrl &source, const QString &hash, int pages)
{
    if (m_printing) {
        emit message("A print dialog or job is already open. Finish or cancel it first.");
        return;
    }
    if (!source.isLocalFile() || pages < 1) {
        emit message("Open a local PDF before printing.");
        return;
    }
    if (hash.isEmpty()) {
        emit message("PDF verification is not ready. Reopen the PDF and try again.");
        return;
    }
    if (!qobject_cast<QApplication *>(QCoreApplication::instance())) {
        emit message("Printing needs the updated desktop app. Quit Owelk completely and reopen it.");
        return;
    }
    auto job = std::make_shared<PrintJob>();
    job->owner = this;
    job->pool = &m_workers;
    job->source = source;
    job->hash = hash;
    QSqlQuery query(m_database);
    query.prepare("SELECT page,rectangles,color,kind,body,image,drawing FROM highlights WHERE source=? AND sha256=? "
                  "AND deleted_at IS NULL");
    query.addBindValue(source.toString());
    query.addBindValue(hash);
    if (!query.exec()) {
        emit message("Cannot read annotations for printing.");
        return;
    }
    while (query.next())
        job->marks.append(QVariantMap{{"page", query.value(0)},
            {"rectangles", QJsonDocument::fromJson(query.value(1).toByteArray()).toVariant()},
            {"color", query.value(2)}, {"kind", query.value(3)}, {"body", query.value(4)},
            {"image", QUrl::fromLocalFile(m_directory + "/annotations/" + query.value(5).toString())},
            {"drawing", QJsonDocument::fromJson(query.value(6).toByteArray()).toVariant()}});
    m_printing = true;
    emit printingChanged();
    job->finished = [this](const QString &error) {
        m_printing = false;
        emit printingChanged();
        emit message(error.isEmpty() ? "Print job sent. Comments are printed as markers, not full note text." : error);
    };
    auto *dialog = new QPrintDialog(job->printer.get());
    dialog->setMinMax(1, pages);
    dialog->setWindowTitle("Print PDF and annotations");
    connect(dialog, &QDialog::finished, this, [job, dialog, pages](int result) {
        dialog->deleteLater();
        if (result != QDialog::Accepted) {
            job->finished("Printing cancelled.");
            return;
        }
        const QFileInfo output(job->printer->outputFileName()), original(job->source.toLocalFile());
        if (!job->printer->outputFileName().isEmpty()
            && (output.absoluteFilePath() == original.absoluteFilePath()
                || (!output.canonicalFilePath().isEmpty()
                    && output.canonicalFilePath() == original.canonicalFilePath()))) {
            job->finished("Choose a different output file to preserve the original PDF.");
            return;
        }
        job->first = job->page = qMax(0, job->printer->fromPage() - 1);
        job->last = job->printer->toPage() > 0 ? qMin(pages - 1, job->printer->toPage() - 1) : pages - 1;
        job->progress = new QProgressDialog("Printing PDF and annotations…", "Cancel", 0, job->last - job->first + 1);
        job->progress->setWindowModality(Qt::ApplicationModal);
        job->progress->setAutoClose(false);
        job->progress->show();
        nextPage(job);
    });
    dialog->open();
}
