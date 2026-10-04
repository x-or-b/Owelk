#include "ResearchStore.h"

#include <QDir>
#include "FileFingerprint.h"
#include "PaperMetadata.h"

#include <QDateTime>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QRegularExpression>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>
#include <QTimer>
#include <QUuid>
#include <QtConcurrent>

namespace {
bool run(QSqlDatabase &db, const QString &sql, QString *error)
{
    QSqlQuery query(db);
    if (query.exec(sql)) return true;
    *error = query.lastError().text() + " (" + sql.left(80) + ")";
    return false;
}

// A null QString binds as SQL NULL; detail columns are NOT NULL and use '' for unknown.
QString text(const QString &value)
{
    return value.isNull() ? QStringLiteral("") : value;
}

int count(QSqlDatabase &db, const QString &table)
{
    QSqlQuery query(db);
    return query.exec("SELECT count(*) FROM " + table) && query.next() ? query.value(0).toInt() : -1;
}

// Replace a URL-keyed table with a document-keyed copy. Every row must survive the join.
bool rebuild(QSqlDatabase &db, const QString &table, const QString &create, const QString &copy, QString *error)
{
    const auto next = table + "_v3";
    if (!run(db, create.arg(next), error) || !run(db, copy.arg(next), error)) return false;
    if (count(db, table) != count(db, next)) {
        *error = QStringLiteral("Upgrading %1 would lose rows. Nothing was changed.").arg(table);
        return false;
    }
    return run(db, "DROP TABLE " + table, error) && run(db, "ALTER TABLE " + next + " RENAME TO " + table, error);
}
}

bool ResearchStore::adoptDocumentIds(QSqlDatabase &db, QString *error)
{
    if (!run(db,
            "CREATE TABLE documents (id TEXT PRIMARY KEY, url TEXT NOT NULL UNIQUE, added_at TEXT NOT NULL, "
            "title TEXT NOT NULL DEFAULT '', authors TEXT NOT NULL DEFAULT '', year TEXT NOT NULL DEFAULT '', "
            "doi TEXT NOT NULL DEFAULT '', arxiv TEXT NOT NULL DEFAULT '', "
            // '' not read yet, 'pdf' read from the file, 'user' edited and never overwritten.
            "metadata_origin TEXT NOT NULL DEFAULT '', metadata_sha256 TEXT NOT NULL DEFAULT '')",
            error))
        return false;
    QStringList urls;
    {
        QSqlQuery query(db);
        if (!query.exec("SELECT url FROM recent_documents UNION SELECT url FROM reading_positions "
                        "UNION SELECT url FROM workspace_documents UNION SELECT url FROM workspace_document_exclusions "
                        "UNION SELECT source FROM captures UNION SELECT source FROM highlights")) {
            *error = query.lastError().text();
            return false;
        }
        while (query.next()) urls.append(query.value(0).toString());
    }
    const auto now = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
    for (const auto &url : urls) {
        QSqlQuery insert(db);
        insert.prepare("INSERT INTO documents(id,url,added_at) VALUES(?,?,?)");
        insert.addBindValue(QUuid::createUuid().toString(QUuid::WithoutBraces));
        insert.addBindValue(url);
        insert.addBindValue(now);
        if (!insert.exec()) {
            *error = insert.lastError().text();
            return false;
        }
    }
    const auto color = defaultAnnotationColor();
    return rebuild(db, "recent_documents",
               "CREATE TABLE %1 (document_id TEXT PRIMARY KEY REFERENCES documents(id), opened_at TEXT NOT NULL)",
               "INSERT INTO %1 SELECT d.id,r.opened_at FROM recent_documents r JOIN documents d ON d.url=r.url", error)
        && rebuild(db, "reading_positions",
            "CREATE TABLE %1 (document_id TEXT PRIMARY KEY REFERENCES documents(id), position TEXT NOT NULL)",
            "INSERT INTO %1 SELECT d.id,r.position FROM reading_positions r JOIN documents d ON d.url=r.url", error)
        && rebuild(db, "workspace_documents",
            "CREATE TABLE %1 (workspace_id TEXT NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id), "
            "PRIMARY KEY(workspace_id,document_id))",
            "INSERT INTO %1 SELECT w.workspace_id,d.id FROM workspace_documents w JOIN documents d ON d.url=w.url",
            error)
        && rebuild(db, "workspace_document_exclusions",
            "CREATE TABLE %1 (workspace_id TEXT NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id), "
            "PRIMARY KEY(workspace_id,document_id))",
            "INSERT INTO %1 SELECT w.workspace_id,d.id FROM workspace_document_exclusions w "
            "JOIN documents d ON d.url=w.url",
            error)
        && rebuild(db, "captures",
            "CREATE TABLE %1 (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id), "
            "sha256 TEXT NOT NULL, page INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, "
            "width REAL NOT NULL, height REAL NOT NULL, image TEXT NOT NULL, created_at TEXT NOT NULL)",
            "INSERT INTO %1 SELECT c.id,d.id,c.sha256,c.page,c.x,c.y,c.width,c.height,c.image,c.created_at "
            "FROM captures c JOIN documents d ON d.url=c.source",
            error)
        && rebuild(db, "highlights",
            QStringLiteral(
                "CREATE TABLE %1 (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id), "
                "sha256 TEXT NOT NULL, page INTEGER NOT NULL, text TEXT NOT NULL, rectangles TEXT NOT NULL, "
                "start_index INTEGER NOT NULL, end_index INTEGER NOT NULL, created_at TEXT NOT NULL, deleted_at TEXT, "
                "color TEXT NOT NULL DEFAULT '%2', kind TEXT NOT NULL DEFAULT 'highlight', body TEXT NOT NULL DEFAULT "
                "'', "
                "image TEXT NOT NULL DEFAULT '', drawing TEXT NOT NULL DEFAULT '[]')")
                .arg("%1", color),
            "INSERT INTO %1 SELECT h.id,d.id,h.sha256,h.page,h.text,h.rectangles,h.start_index,h.end_index,"
            "h.created_at,h.deleted_at,h.color,h.kind,h.body,h.image,h.drawing FROM highlights h "
            "JOIN documents d ON d.url=h.source",
            error)
        && run(db, "CREATE INDEX highlights_document ON highlights(document_id)", error)
        && run(db, "CREATE INDEX highlights_live ON highlights(deleted_at, created_at)", error)
        && run(db, "CREATE INDEX captures_document ON captures(document_id)", error);
}

QString ResearchStore::findDocument(const QUrl &source) const
{
    const auto url = resolvedSource(source);
    if (!url.isLocalFile() && url.scheme() != "http" && url.scheme() != "https") return {};
    QSqlQuery query(m_database);
    query.prepare("SELECT id FROM documents WHERE url=?");
    query.addBindValue(url.toString());
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

QString ResearchStore::ensureDocument(const QUrl &source)
{
    const auto existing = findDocument(source);
    if (!existing.isEmpty()) return existing;
    const auto url = resolvedSource(source);
    if (!url.isLocalFile()) return {}; // Web pages are added explicitly by ensureWebDocument.
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO documents(id,url,added_at) VALUES(?,?,?)");
    query.addBindValue(id);
    query.addBindValue(url.toString());
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!query.exec()) return {};
    refreshMetadata(id, url, false);
    return id;
}

QString ResearchStore::ensureWebDocument(const QUrl &page, const QString &title)
{
    if (page.scheme() != "http" && page.scheme() != "https") return {};
    auto id = findDocument(page);
    QSqlQuery query(m_database);
    if (id.isEmpty()) {
        id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        query.prepare("INSERT INTO documents(id,url,added_at,kind,metadata_origin) VALUES(?,?,?,'web','web')");
        query.addBindValue(id);
        query.addBindValue(page.toString());
        query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        if (!query.exec()) return {};
    }
    // The page title is its name; user-edited details win.
    const auto name = title.simplified().left(300);
    if (!name.isEmpty()) {
        query.prepare("UPDATE documents SET title=? WHERE id=? AND metadata_origin<>'user'");
        query.addBindValue(name);
        query.addBindValue(id);
        if (query.exec() && query.numRowsAffected() == 1) rememberTitle(page, name);
    }
    return id;
}

void ResearchStore::loadDocumentNames()
{
    m_titles.clear();
    QSqlQuery query(m_database);
    query.exec("SELECT url,title FROM documents WHERE title<>''");
    while (query.next()) m_titles.insert(query.value(0).toString(), query.value(1).toString());
}

void ResearchStore::rememberTitle(const QUrl &url, const QString &title)
{
    if (title.isEmpty())
        m_titles.remove(url.toString());
    else
        m_titles.insert(url.toString(), title);
}

QString ResearchStore::localPath(const QUrl &url) const
{
    return url.isLocalFile() ? QDir::toNativeSeparators(url.toLocalFile()) : url.toString();
}

QUrl ResearchStore::fileUrl(const QString &path) const
{
    return QUrl::fromLocalFile(QDir::fromNativeSeparators(path));
}

QString ResearchStore::displayName(const QUrl &source) const
{
    const auto url = resolvedSource(source);
    const auto title = m_titles.value(url.toString());
    if (!title.isEmpty()) return title;
    return url.isLocalFile() ? fileName(url) : url.host() + url.path();
}

QVariantMap ResearchStore::documentDetails(const QUrl &source) const
{
    const auto url = resolvedSource(source);
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT title,authors,year,doi,arxiv,metadata_origin,reading_state,favorite FROM documents WHERE url=?");
    query.addBindValue(url.toString());
    QVariantMap details{{"source", url}, {"fileName", fileName(url)}};
    if (!query.exec() || !query.next()) return details;
    details.insert({{"title", query.value(0)}, {"authors", query.value(1)}, {"year", query.value(2)},
        {"doi", query.value(3)}, {"arxiv", query.value(4)}, {"origin", query.value(5)},
        {"readingState", query.value(6)}, {"favorite", query.value(7).toBool()}});
    return details;
}

bool ResearchStore::updateDocumentDetails(const QUrl &source, const QVariantMap &input)
{
    const auto value = [&](const char *key) { return input.value(key).toString().simplified(); };
    const auto title = value("title"), authors = value("authors"), year = value("year"), doi = value("doi"),
               arxiv = value("arxiv");
    static const QRegularExpression yearFormat("^(\\d{4})?$");
    if (title.size() > 300 || authors.size() > 1000 || doi.size() > 200 || arxiv.size() > 40
        || !yearFormat.match(year).hasMatch()) {
        emit message("Check the details: title up to 300 characters, year as four digits.");
        return false;
    }
    const auto id = ensureDocument(source);
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET title=?,authors=?,year=?,doi=?,arxiv=?,metadata_origin='user' WHERE id=?");
    for (const auto &field : {title, authors, year, doi, arxiv}) query.addBindValue(text(field));
    query.addBindValue(id);
    if (id.isEmpty() || !query.exec() || query.numRowsAffected() != 1) {
        emit message("Cannot save paper details.");
        return false;
    }
    rememberTitle(resolvedSource(source), title);
    announceDocumentsChanged();
    return true;
}

void ResearchStore::resetDocumentDetails(const QUrl &source)
{
    const auto id = findDocument(source);
    if (id.isEmpty()) return;
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET metadata_origin='',metadata_sha256='' WHERE id=?");
    query.addBindValue(id);
    if (query.exec()) refreshMetadata(id, resolvedSource(source), true);
}

void ResearchStore::refreshMetadata(const QString &id, const QUrl &url, bool force, bool checkDuplicate)
{
    if (id.isEmpty() || !url.isLocalFile()) return;
    if (checkDuplicate) m_duplicateChecks.insert(id);
    if (m_metadataPending.contains(id)) return;
    QSqlQuery query(m_database);
    query.prepare("SELECT metadata_origin,metadata_sha256 FROM documents WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return;
    const bool userDetails = query.value(0).toString() == "user";
    const auto known = query.value(0).toString() == "pdf" && !force ? query.value(1).toString() : QString();
    m_metadataPending.insert(id);
    struct Result {
        QString hash;
        bool extracted = false;
        PaperMetadata metadata;
    };
    auto *watcher = new QFutureWatcher<Result>(this);
    connect(watcher, &QFutureWatcher<Result>::finished, this, [this, watcher, id, url] {
        const auto result = watcher->result();
        watcher->deleteLater();
        m_metadataPending.remove(id);
        const bool duplicateCheck = m_duplicateChecks.remove(id);
        if (result.hash.isEmpty()) return;
        // The file hash identifies duplicates; it is kept current even for user-edited details.
        QSqlQuery hash(m_database);
        hash.prepare("UPDATE documents SET sha256=? WHERE id=? AND url=?");
        hash.addBindValue(result.hash);
        hash.addBindValue(id);
        hash.addBindValue(url.toString());
        hash.exec();
        if (result.extracted) {
            const auto &m = result.metadata;
            QSqlQuery update(m_database);
            // The URL guard drops results for a document relinked while it was being read; user edits always win.
            update.prepare("UPDATE documents SET title=?,authors=?,year=?,doi=?,arxiv=?,metadata_origin='pdf',"
                           "metadata_sha256=? WHERE id=? AND url=? AND metadata_origin<>'user'");
            for (const auto &field : {m.title, m.authors, m.year, m.doi, m.arxiv, result.hash})
                update.addBindValue(text(field));
            update.addBindValue(id);
            update.addBindValue(url.toString());
            if (update.exec() && update.numRowsAffected() == 1) {
                rememberTitle(url, m.title);
                announceDocumentsChanged();
            }
        }
        if (duplicateCheck) reportDuplicate(id, url, result.hash);
    });
    watcher->setFuture(QtConcurrent::run(&m_metadataWorkers, [url, known, userDetails] {
        Result result;
        result.hash = FileFingerprint::sha256(url.toLocalFile());
        // Same bytes as last time, or details the user owns: keep them without reopening the PDF.
        if (result.hash.isEmpty() || userDetails || result.hash == known) return result;
        result.metadata = extractPaperMetadata(url.toLocalFile());
        result.extracted = true;
        return result;
    }));
}

void ResearchStore::reportDuplicate(const QString &id, const QUrl &url, const QString &hash)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT d.url FROM documents d WHERE d.sha256=? AND d.id<>? AND "
                  "(SELECT duplicate_ack FROM documents WHERE id=?)<>? ORDER BY d.added_at");
    query.addBindValue(hash);
    query.addBindValue(id);
    query.addBindValue(id);
    query.addBindValue(hash);
    if (!query.exec()) return;
    while (query.next()) {
        const QUrl other(query.value(0).toString());
        // Only an existing copy is a useful alternative; a moved original is handled by relinking.
        if (other.isLocalFile() && QFileInfo(other.toLocalFile()).isFile()) {
            emit duplicateFound(url, other, displayName(other));
            return;
        }
    }
}

bool ResearchStore::keepDuplicate(const QUrl &source)
{
    // "Keep both": stop asking for this file version; a changed file is checked again.
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET duplicate_ack=sha256 WHERE id=?");
    query.addBindValue(findDocument(source));
    return query.exec() && query.numRowsAffected() == 1;
}

bool ResearchStore::useExistingCopy(const QUrl &duplicate, const QUrl &existing)
{
    if (!rememberDocument(existing)) return false;
    QSqlQuery query(m_database);
    query.prepare("DELETE FROM recent_documents WHERE document_id=?");
    query.addBindValue(findDocument(duplicate));
    query.exec();
    emit recentDocumentsChanged();
    emit homeChanged();
    return true;
}

bool ResearchStore::setReadingState(const QUrl &source, const QString &state)
{
    if (!QStringList{"unread", "reading", "read"}.contains(state)) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET reading_state=? WHERE id=?");
    query.addBindValue(state);
    query.addBindValue(ensureDocument(source));
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    announceDocumentsChanged();
    return true;
}

bool ResearchStore::setFavorite(const QUrl &source, bool favorite)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET favorite=? WHERE id=?");
    query.addBindValue(favorite ? 1 : 0);
    query.addBindValue(ensureDocument(source));
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    announceDocumentsChanged();
    return true;
}

void ResearchStore::announceDocumentsChanged()
{
    // Startup extraction finishes many documents in a row; refresh lists once per burst.
    if (m_documentsChangePending) return;
    m_documentsChangePending = true;
    QTimer::singleShot(50, this, [this] {
        m_documentsChangePending = false;
        ++m_documentsRevision;
        reloadCaptures();
        emit documentsChanged();
        emit recentDocumentsChanged();
        emit homeChanged();
    });
}
