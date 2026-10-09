#include "ResearchStore.h"
#include "PaperIndex.h"
#include "FileFingerprint.h"
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>
#include <QtConcurrent>

namespace {
QString hashFile(const QString &path)
{
    return FileFingerprint::sha256(path);
}
QVariant rewrite(const QVariant &value, const std::function<QString(const QString &)> &resolve)
{
    if (value.metaType().id() == QMetaType::QVariantMap) {
        auto map = value.toMap();
        for (auto it = map.begin(); it != map.end(); ++it) {
            if (it.key() == "source")
                it.value() = resolve(it.value().toString());
            else
                it.value() = rewrite(it.value(), resolve);
        }
        return map;
    }
    if (value.metaType().id() == QMetaType::QVariantList) {
        auto list = value.toList();
        for (auto &item : list) item = rewrite(item, resolve);
        return list;
    }
    return value;
}
}

QUrl ResearchStore::resolvedSource(const QUrl &source) const
{
    QString current = source.toString();
    QSet<QString> visited;
    while (m_relinks.contains(current) && !visited.contains(current)) {
        visited.insert(current);
        current = m_relinks.value(current);
    }
    return QUrl(current);
}
QVariantMap ResearchStore::canonicalState(const QVariantMap &state) const
{
    return rewrite(state, [this](const QString &source) { return resolvedSource(QUrl(source)).toString(); }).toMap();
}
void ResearchStore::requestRelink(const QUrl &source)
{
    if (source.isLocalFile()) emit relinkRequested(resolvedSource(source));
}
void ResearchStore::relinkSource(const QUrl &input, const QUrl &candidate)
{
    auto reject = [this](const QString &error) { emit relinkFinished(false, error); };
    if (m_relinking || busy()) {
        reject("Wait for the current source verification to finish.");
        return;
    }
    const auto source = resolvedSource(input);
    if (!source.isLocalFile() || !candidate.isLocalFile() || source == candidate) {
        reject("Choose a different local PDF path.");
        return;
    }
    if (m_relinks.contains(candidate.toString())) {
        reject("This path was previously redirected. Choose a new path to avoid a redirect cycle.");
        return;
    }
    QSet<QString> hashes;
    QSqlQuery annotations(m_database);
    annotations.prepare("SELECT DISTINCT sha256 FROM highlights WHERE document_id=?");
    annotations.addBindValue(findDocument(source));
    if (!annotations.exec()) {
        reject(annotations.lastError().text());
        return;
    }
    while (annotations.next())
        if (!annotations.value(0).toString().isEmpty()) hashes.insert(annotations.value(0).toString());
    const auto indexedHash = m_index->knownHash(source);
    if (!indexedHash.isEmpty()) hashes.insert(indexedHash);
    QSqlQuery previous(m_database);
    previous.prepare("SELECT sha256 FROM source_relinks WHERE new_url=?");
    previous.addBindValue(source.toString());
    if (!previous.exec()) {
        reject(previous.lastError().text());
        return;
    }
    while (previous.next()) hashes.insert(previous.value(0).toString());
    if (hashes.size() > 1) {
        reject("This path has records from different PDF versions. Nothing was changed; version-specific relinking is "
               "not supported yet.");
        return;
    }
    const auto expected = hashes.isEmpty() ? QString() : *hashes.cbegin();
    m_relinking = true;
    emit relinkingChanged();
    auto *watcher = new QFutureWatcher<QPair<QString, QString>>(this);
    connect(watcher, &QFutureWatcher<QPair<QString, QString>>::finished, this, [this, watcher, source, candidate] {
        const auto result = watcher->result();
        watcher->deleteLater();
        QString error = result.second;
        bool success = error.isEmpty() && applyRelink(source, candidate, result.first, &error);
        if (success) {
            m_relinks.insert(source.toString(), candidate.toString());
            m_index->relocateSource(source, candidate);
            // Update live tabs before a pending UI save can reintroduce an old path.
            emit sourceRelinked(source, candidate);
            loadDocumentNames(); // Titles are cached by URL.
            announceDocumentsChanged();
            emit highlightsChanged();
            emit recentDocumentsChanged();
            emit homeChanged();
        }
        m_relinking = false;
        emit relinkingChanged();
        emit relinkFinished(
            success, success ? "PDF source reconnected. Reading positions and annotations were preserved." : error);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, candidate, expected] {
        const auto original = expected.isEmpty() ? hashFile(source.toLocalFile()) : expected;
        if (original.isEmpty())
            return qMakePair(QString(),
                QString("No saved fingerprint is available and the old file is missing. Exact identity cannot be "
                        "verified; open the new PDF separately."));
        const auto candidateHash = hashFile(candidate.toLocalFile());
        if (candidateHash.isEmpty()) return qMakePair(QString(), QString("Cannot read the selected file."));
        if (candidateHash != original)
            return qMakePair(QString(),
                QString("The selected file is not byte-for-byte identical to the original PDF. Nothing was changed."));
        return qMakePair(candidateHash, QString());
    }));
}

bool ResearchStore::applyRelink(const QUrl &source, const QUrl &candidate, const QString &hash, QString *error)
{
    const auto oldUrl = source.toString(), newUrl = candidate.toString();
    if (!m_database.transaction()) {
        *error = m_database.lastError().text();
        return false;
    }
    auto run = [&](const QString &sql, const QVariantList &args) {
        QSqlQuery query(m_database);
        if (!query.prepare(sql)) {
            *error = query.lastError().text();
            return false;
        }
        for (const auto &arg : args) query.addBindValue(arg);
        if (!query.exec()) {
            *error = query.lastError().text();
            return false;
        }
        return true;
    };
    auto abort = [&] {
        m_database.rollback();
        return false;
    };
    const auto documentFor = [&](const QString &url) {
        QSqlQuery query(m_database);
        query.prepare("SELECT id FROM documents WHERE url=?");
        query.addBindValue(url);
        return query.exec() && query.next() ? query.value(0).toString() : QString();
    };
    // All saved data hangs off the document ID, so the move is one URL update. If the new path was
    // already opened on its own, fold that duplicate entry into the original one.
    const auto original = documentFor(oldUrl), duplicate = documentFor(newUrl);
    if (!original.isEmpty() && !duplicate.isEmpty() && duplicate != original) {
        // The original's reading position and details win; memberships and annotations are merged.
        if (!run("INSERT INTO recent_documents(document_id,opened_at) SELECT ?,opened_at FROM recent_documents "
                 "WHERE document_id=? ON CONFLICT(document_id) DO UPDATE SET "
                 "opened_at=MAX(opened_at,excluded.opened_at)",
                {original, duplicate})
            || !run("INSERT OR IGNORE INTO reading_positions(document_id,position) SELECT ?,position "
                    "FROM reading_positions WHERE document_id=?",
                {original, duplicate})
            || !run(
                "UPDATE documents SET (title,authors,year,doi,arxiv,metadata_origin,metadata_sha256)="
                "(SELECT title,authors,year,doi,arxiv,metadata_origin,metadata_sha256 FROM documents WHERE id=?) "
                "WHERE id=? AND metadata_origin<>'user' AND (SELECT metadata_origin FROM documents WHERE id=?)='user'",
                {duplicate, original, duplicate})
            || !run(
                "UPDATE OR REPLACE links SET from_id=? WHERE from_kind='document' AND from_id=?", {original, duplicate})
            || !run("UPDATE OR REPLACE links SET to_id=? WHERE to_kind='document' AND to_id=?", {original, duplicate}))
            return abort();
        for (const auto *table : {"highlights", "collection_documents", "document_tags"})
            if (!run(QStringLiteral("UPDATE OR REPLACE %1 SET document_id=? WHERE document_id=?").arg(table),
                    {original, duplicate}))
                return abort();
        for (const auto *table : {"recent_documents", "reading_positions"})
            if (!run(QStringLiteral("DELETE FROM %1 WHERE document_id=?").arg(table), {duplicate})) return abort();
        if (!run("DELETE FROM documents WHERE id=?", {duplicate})) return abort();
    }
    if (!original.isEmpty() && !run("UPDATE documents SET url=? WHERE id=?", {newUrl, original})) return abort();
    auto updateStates = [&](const QString &select, const QString &update) {
        QSqlQuery query(m_database);
        if (!query.exec(select)) {
            *error = query.lastError().text();
            return false;
        }
        QList<QPair<QString, QString>> changes;
        while (query.next()) {
            const auto bytes = query.value(1).toByteArray();
            QJsonParseError parse;
            const auto doc = QJsonDocument::fromJson(bytes, &parse);
            if (parse.error != QJsonParseError::NoError || !doc.isObject()) {
                *error = "The saved session is invalid. Relinking was cancelled without changing it.";
                return false;
            }
            if (doc.object().contains("version") && doc.object()["version"].toInt() != 1
                && doc.object()["version"].toInt() != 2) {
                *error = "An unsupported saved layout version was found. Nothing was changed.";
                return false;
            }
            const auto updated = rewrite(doc.object().toVariantMap(), [&](const QString &url) {
                return url == oldUrl ? newUrl : url;
            }).toMap();
            changes.append({query.value(0).toString(),
                QString::fromUtf8(QJsonDocument::fromVariant(updated).toJson(QJsonDocument::Compact))});
        }
        query.finish();
        for (const auto &change : changes)
            if (!run(update, {change.second, change.first})) return false;
        return true;
    };
    if (!updateStates("SELECT key,value FROM settings WHERE key='session'", "UPDATE settings SET value=? WHERE key=?")
        || !run("INSERT INTO source_relinks(old_url,new_url,sha256) VALUES(?,?,?)", {oldUrl, newUrl, hash}))
        return abort();
    if (!m_database.commit()) {
        *error = m_database.lastError().text();
        return abort();
    }
    return true;
}
