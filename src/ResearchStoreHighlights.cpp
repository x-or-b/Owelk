#include "ResearchStore.h"
#include <QCryptographicHash>
#include <QDateTime>
#include <QFile>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QSqlQuery>
#include <QtConcurrent>

namespace {
QString fingerprint(const QUrl &source)
{
    QFile file(source.toLocalFile());
    if (!source.isLocalFile() || !file.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    return hash.addData(&file) ? QString::fromLatin1(hash.result().toHex()) : QString();
}
}

int ResearchStore::loadHighlights(const QUrl &source)
{
    const int request = ++m_highlightRequest;
    QVariantList rows;
    QSqlQuery query(m_database);
    query.prepare("SELECT id,page,text,rectangles,sha256 FROM highlights WHERE source=? AND deleted_at IS NULL ORDER BY created_at,id");
    query.addBindValue(source.toString());
    const bool queried = query.exec();
    while (queried && query.next()) rows.append(QVariantMap{{"id", query.value(0)}, {"page", query.value(1)},
        {"text", query.value(2)}, {"rectangles", QJsonDocument::fromJson(query.value(3).toByteArray()).toVariant()}, {"sha256", query.value(4)}});
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, source, request, rows, queried] {
        const auto hash = watcher->result(); watcher->deleteLater();
        QVariantList verified;
        bool mismatch = false;
        for (const auto &row : rows) {
            if (!hash.isEmpty() && row.toMap()["sha256"].toString() == hash) verified.append(row);
            else mismatch = true;
        }
        emit highlightsLoaded(request, source, verified, !queried ? "Cannot load highlights."
            : mismatch ? "Some highlights are hidden because the original PDF is missing or changed." : QString());
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, empty = rows.isEmpty()] { return empty ? QString() : fingerprint(source); }));
    return request;
}

bool ResearchStore::removeHighlight(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE highlights SET deleted_at=? WHERE id=? AND deleted_at IS NULL");
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)); query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) { emit message("Cannot remove this highlight."); return false; }
    emit highlightsChanged(); emit homeChanged();
    emit message("Highlight removed. The source PDF was kept.");
    return true;
}

void ResearchStore::openHighlight(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT source,sha256,page,rectangles FROM highlights WHERE id=? AND deleted_at IS NULL"); query.addBindValue(id);
    if (!query.exec() || !query.next()) return;
    const QUrl source(query.value(0).toString());
    const auto expected = query.value(1).toString(); const int page = query.value(2).toInt();
    QRectF bounds;
    for (const auto &value : QJsonDocument::fromJson(query.value(3).toByteArray()).toVariant().toList()) {
        const auto r = value.toMap();
        bounds = bounds.united(QRectF(r["x"].toDouble(), r["y"].toDouble(), r["width"].toDouble(), r["height"].toDouble()));
    }
    if (bounds.isEmpty()) return;
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, id, source, expected, page, bounds] {
        const auto hash = watcher->result(); watcher->deleteLater();
        QSqlQuery current(m_database);
        current.prepare("SELECT source FROM highlights WHERE id=? AND deleted_at IS NULL"); current.addBindValue(id);
        if (!current.exec() || !current.next()) return;
        if (QUrl(current.value(0).toString()) != source) { openHighlight(id); return; }
        if (hash.isEmpty()) { emit message("Original PDF not found. The highlight is preserved."); emit relinkRequested(source); }
        else if (hash != expected) emit message("The PDF changed. Highlight navigation was cancelled.");
        else emit sourceReady(source, page, bounds);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source] { return fingerprint(source); }));
}
