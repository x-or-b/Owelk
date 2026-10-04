#include "PdfAccess.h"
#include "ResearchStore.h"
#include "AnnotationImage.h"
#include "FileFingerprint.h"
#include <QDateTime>
#include <QFile>
#include <QDir>
#include <QFileInfo>
#include <QImageReader>
#include <QPdfDocument>
#include <QSaveFile>
#include <QUuid>
#include <cmath>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QSqlQuery>
#include <QtConcurrent>

namespace {
QString fingerprint(const QUrl &source)
{
    return source.isLocalFile() ? FileFingerprint::sha256(source.toLocalFile()) : QString();
}
}

int ResearchStore::loadHighlights(const QUrl &source)
{
    const int request = ++m_highlightRequest;
    QVariantList rows;
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT id,page,text,rectangles,sha256,color,kind,body,image,drawing FROM highlights WHERE document_id=? "
        "AND deleted_at IS NULL ORDER BY created_at,id");
    query.addBindValue(findDocument(source));
    const bool queried = query.exec();
    while (queried && query.next())
        rows.append(QVariantMap{{"id", query.value(0)}, {"page", query.value(1)}, {"text", query.value(2)},
            {"rectangles", QJsonDocument::fromJson(query.value(3).toByteArray()).toVariant()},
            {"sha256", query.value(4)}, {"color", query.value(5)}, {"kind", query.value(6)}, {"body", query.value(7)},
            {"image",
                query.value(8).toString().isEmpty()
                        || QFileInfo(query.value(8).toString()).fileName() != query.value(8).toString()
                    ? QUrl()
                    : QUrl::fromLocalFile(m_directory + "/annotations/" + query.value(8).toString())},
            {"drawing", QJsonDocument::fromJson(query.value(9).toByteArray()).toVariant()}});
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, source, request, rows, queried] {
        const auto hash = watcher->result();
        watcher->deleteLater();
        QVariantList verified;
        bool mismatch = false;
        for (const auto &row : rows) {
            if (!hash.isEmpty() && row.toMap()["sha256"].toString() == hash)
                verified.append(row);
            else
                mismatch = true;
        }
        emit highlightsLoaded(request, source, verified,
            !queried       ? "Cannot load highlights."
                : mismatch ? "Some annotations are hidden because the original PDF is missing or changed."
                           : QString(),
            hash);
    });
    watcher->setFuture(QtConcurrent::run(&m_verifiers, [source] { return fingerprint(source); }));
    return request;
}

bool ResearchStore::updateHighlight(const QString &id, const QString &color, const QString &body)
{
    if (body.size() > 10000 || !annotationColors().contains(color)) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE highlights SET color=?,body=? WHERE id=? AND deleted_at IS NULL");
    query.addBindValue(color);
    query.addBindValue(body.isNull() ? QStringLiteral("") : body);
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) {
        emit message("Cannot update annotation.");
        return false;
    }
    emit highlightsChanged();
    emit homeChanged();
    return true;
}

void ResearchStore::saveAnnotation(const QUrl &source, int page, const QVariantMap &input)
{
    auto fail = [this](const QString &error) {
        emit message(error);
        emit annotationFinished(false, "");
    };
    const auto kind = input.value("kind").toString(), body = input.value("body").toString();
    const auto color = input.value("color", defaultAnnotationColor()).toString();
    if (m_relinking || busy() || !source.isLocalFile() || page < 0) {
        fail("Wait for the current operation and choose a PDF page.");
        return;
    }
    if (!QStringList{"comment", "text", "image", "draw"}.contains(kind) || body.size() > 10000
        || ((kind == "comment" || kind == "text") && body.trimmed().isEmpty()) || !annotationColors().contains(color)) {
        fail("Invalid annotation content or color.");
        return;
    }
    const auto rects = input.value("rectangles").toList();
    if (rects.size() != 1) {
        fail("Choose an annotation area on the page.");
        return;
    }
    const auto r = rects[0].toMap();
    const QRectF rect(
        r.value("x").toDouble(), r.value("y").toDouble(), r.value("width").toDouble(), r.value("height").toDouble());
    if (!std::isfinite(rect.x() + rect.y() + rect.width() + rect.height()) || rect.isEmpty() || rect.x() < 0
        || rect.y() < 0 || rect.right() > 1.00001 || rect.bottom() > 1.00001) {
        fail("Annotation coordinates must stay inside the page.");
        return;
    }
    const auto points = input.value("drawing").toList();
    if (kind == "draw" && (points.size() < 2 || points.size() > 5000)) {
        fail("Draw a stroke of up to 5,000 points.");
        return;
    }
    for (const auto &p : points) {
        const auto m = p.toMap();
        const double x = m.value("x").toDouble(), y = m.value("y").toDouble();
        if (!std::isfinite(x + y) || x < 0 || x > 1 || y < 0 || y > 1) {
            fail("Invalid drawing coordinates.");
            return;
        }
    }
    const auto document = ensureDocument(source);
    if (document.isEmpty()) {
        fail("Cannot record the source document. Check storage and permissions.");
        return;
    }
    QString id = input.value("id").toString(), expected = input.value("sha256").toString(), oldImage;
    const bool editing = !id.isEmpty();
    if (editing) {
        QSqlQuery old(m_database);
        old.prepare(
            "SELECT sha256,image FROM highlights WHERE id=? AND document_id=? AND kind=? AND start_index=-1 AND "
            "deleted_at IS NULL");
        old.addBindValue(id);
        old.addBindValue(document);
        old.addBindValue(kind);
        if (!old.exec() || !old.next()) {
            fail("This annotation cannot be edited here.");
            return;
        }
        expected = old.value(0).toString();
        oldImage = old.value(1).toString();
    } else
        id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    if (expected.isEmpty()) {
        fail("Wait for PDF source verification to finish.");
        return;
    }
    const QUrl imageSource(input.value("imageSource").toString());
    const QString assetDirectory = m_directory + "/annotations";
    struct Result {
        QString error, asset, newPath;
    };
    ++m_pending;
    emit busyChanged();
    auto *watcher = new QFutureWatcher<Result>(this);
    connect(watcher, &QFutureWatcher<Result>::finished, this, [=, this] {
        const auto result = watcher->result();
        watcher->deleteLater();
        --m_pending;
        emit busyChanged();
        auto reject = [&](const QString &error) {
            if (!result.newPath.isEmpty()) QFile::remove(result.newPath); // Only the fresh, task-owned asset.
            fail(error);
        };
        if (!result.error.isEmpty()) {
            reject(result.error);
            return;
        }
        QSqlQuery save(m_database);
        if (editing)
            save.prepare(
                "UPDATE highlights SET rectangles=?,body=?,color=?,image=?,drawing=? WHERE id=? AND document_id=? "
                "AND deleted_at IS NULL");
        else
            save.prepare(
                "INSERT INTO "
                "highlights(rectangles,body,color,image,drawing,id,document_id,sha256,page,kind,text,start_index,"
                "end_index,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,'',-1,-1,?)");
        save.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(rects).toJson(QJsonDocument::Compact)));
        save.addBindValue(body.isNull() ? QStringLiteral("") : body);
        save.addBindValue(color);
        save.addBindValue(result.asset.isNull() ? QStringLiteral("") : result.asset);
        save.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(points).toJson(QJsonDocument::Compact)));
        save.addBindValue(id);
        save.addBindValue(document);
        if (!editing) {
            save.addBindValue(expected);
            save.addBindValue(page);
            save.addBindValue(kind);
            save.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        }
        if (!save.exec() || save.numRowsAffected() != 1) {
            reject("Cannot save annotation. The previous version was kept.");
            return;
        }
        emit highlightsChanged();
        emit homeChanged();
        emit annotationSaved(id);
        emit annotationFinished(true, id);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [=] {
        Result result;
        result.asset = oldImage;
        if (fingerprint(source) != expected) {
            result.error = "The PDF changed. Reopen it before adding annotations.";
            return result;
        }
        QPdfDocument pdf;
        if (PdfAccess::load(pdf, source.toLocalFile()) != QPdfDocument::Error::None || page >= pdf.pageCount()) {
            result.error = "Cannot read this PDF page.";
            return result;
        }
        if (kind == "image" && !imageSource.isEmpty()) {
            const auto pixels = readAnnotationImage(imageSource, &result.error);
            if (pixels.isNull()) return result;
            if (pixels.isNull() || !QDir().mkpath(assetDirectory)) {
                result.error = "Cannot read or store this image.";
                return result;
            }
            result.asset = QUuid::createUuid().toString(QUuid::WithoutBraces) + ".png";
            result.newPath = assetDirectory + "/" + result.asset;
            QSaveFile output(result.newPath);
            if (!output.open(QIODevice::WriteOnly) || !pixels.save(&output, "PNG") || !output.commit()) {
                result.error = "Cannot save annotation image.";
                return result;
            }
        }
        if (kind == "image" && result.asset.isEmpty()) result.error = "Choose an image first.";
        if (fingerprint(source) != expected) result.error = "The PDF changed while saving. Nothing was attached.";
        return result;
    }));
}

bool ResearchStore::removeHighlight(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE highlights SET deleted_at=? WHERE id=? AND deleted_at IS NULL");
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) {
        emit message("Cannot remove this highlight.");
        return false;
    }
    emit highlightsChanged();
    emit homeChanged();
    emit message("Highlight removed. The source PDF was kept.");
    return true;
}
