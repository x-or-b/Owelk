#include "PaperIndex.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QThread>
#include <QUuid>
#include <QtConcurrent>

namespace {
constexpr int extractorVersion = 1;
struct Connection {
    QString name = QUuid::createUuid().toString();
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
    explicit Connection(const QString &path) {
        db.setDatabaseName(path);
        db.setConnectOptions("QSQLITE_BUSY_TIMEOUT=3000");
        db.open();
    }
    ~Connection() { db.close(); db = {}; QSqlDatabase::removeDatabase(name); }
};
QString hashFile(const QString &path, const std::shared_ptr<std::atomic_bool> &cancel)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    while (!file.atEnd()) {
        if (cancel->load()) return {};
        const auto chunk = file.read(1024 * 1024);
        if (chunk.isEmpty() && file.error() != QFile::NoError) return {};
        hash.addData(chunk);
    }
    return QString::fromLatin1(hash.result().toHex());
}
QString normalize(QString text)
{
    // Join alphabetic words split by a line-end hyphen; retain ordinary compound hyphens.
    text.remove(QChar(0x00ad));
    // Qt/PDFium emits U+FFFE for a discretionary line-end hyphen in extracted text.
    text.remove(QChar(0xfffe));
    text.replace(QRegularExpression("(\\p{L})-[ \\t]*\\r?\\n[ \\t]*(?=\\p{L})"), "\\1");
    return text.normalized(QString::NormalizationForm_KC).simplified();
}
QString matchQuery(const QString &input)
{
    // Never pass user input as FTS syntax. All terms are literal tokens, combined with AND.
    static const QRegularExpression word("[\\p{L}\\p{N}]+");
    auto matches = word.globalMatch(input.left(512).normalized(QString::NormalizationForm_KC));
    QStringList parts;
    while (matches.hasNext() && parts.size() < 12) parts << '"' + matches.next().captured() + "\"*";
    return parts.join(" AND ");
}
struct IndexResult { QString error; bool cancelled = false; };
IndexResult indexFile(const QString &dbPath, const QUrl &source,
                      const std::shared_ptr<std::atomic_bool> &cancel,
                      const std::shared_ptr<std::atomic_bool> &readerBusy,
                      const std::function<void(int, int)> &progress)
{
    Connection connection(dbPath);
    auto &db = connection.db;
    if (!db.isOpen()) return {db.lastError().text()};
    QSqlQuery query(db);
    query.prepare("INSERT OR IGNORE INTO documents(id,url,state) VALUES(?,?,'pending')");
    query.addBindValue(QUuid::createUuid().toString(QUuid::WithoutBraces));
    query.addBindValue(source.toString());
    if (!query.exec()) return {query.lastError().text()};
    query.prepare("SELECT id,sha256,version,state FROM documents WHERE url=?");
    query.addBindValue(source.toString());
    if (!query.exec() || !query.next()) return {"Cannot read search document record."};
    const auto id = query.value(0).toString(), oldHash = query.value(1).toString();
    const int version = query.value(2).toInt();
    const auto state = query.value(3).toString();
    query.finish();
    auto fail = [&](const QString &state, const QString &error) -> IndexResult {
        db.rollback();
        QSqlQuery status(db);
        status.prepare("UPDATE documents SET state=?,error=? WHERE id=?");
        status.addBindValue(state); status.addBindValue(error.isEmpty() ? QStringLiteral("") : error); status.addBindValue(id);
        if (!status.exec()) return {status.lastError().text()};
        return {error, state == "paused"};
    };
    if (cancel->load()) return fail("paused", {});
    const auto hash = hashFile(source.toLocalFile(), cancel);
    if (cancel->load()) return fail("paused", {});
    if (hash.isEmpty()) return fail("missing", "Cannot read the original PDF. Check its path and permissions.");
    if (hash == oldHash && version == extractorVersion && (state == "ready" || state == "empty")) return {};
    query.prepare("UPDATE documents SET state='indexing',error='' WHERE id=?");
    query.addBindValue(id);
    if (!query.exec()) return {query.lastError().text()};
    QPdfDocument pdf;
    const auto loadError = pdf.load(source.toLocalFile());
    if (loadError != QPdfDocument::Error::None || pdf.status() != QPdfDocument::Status::Ready) {
        const bool locked = loadError == QPdfDocument::Error::IncorrectPassword;
        return fail(locked ? "locked" : "failed", locked ? "Password-protected PDFs are not indexed yet." : "Cannot extract text from this PDF.");
    }
    if (!db.transaction()) return fail("failed", db.lastError().text());
    query.prepare("DELETE FROM pages WHERE document_id=?"); query.addBindValue(id);
    if (!query.exec()) return fail("failed", query.lastError().text());
    int textPages = 0;
    for (int page = 0; page < pdf.pageCount(); ++page) {
        while (readerBusy->load() && !cancel->load()) QThread::msleep(2);
        if (cancel->load()) return fail("paused", {});
        const auto text = normalize(pdf.getAllText(page).text());
        if (!text.isEmpty()) {
            query.prepare("INSERT INTO pages(document_id,page,text) VALUES(?,?,?)");
            query.addBindValue(id); query.addBindValue(page); query.addBindValue(text);
            if (!query.exec()) return fail("failed", query.lastError().text());
            ++textPages;
        }
        if (page % 8 == 0 || page + 1 == pdf.pageCount()) progress(page + 1, pdf.pageCount());
        // Give interactive PDF rendering regular opportunities to acquire the PDF engine.
        QThread::msleep(1);
    }
    const auto finalHash = hashFile(source.toLocalFile(), cancel);
    if (cancel->load()) return fail("paused", {});
    if (finalHash != hash) return fail("failed", "The PDF changed during indexing. Retry when the file is stable.");
    query.prepare("UPDATE documents SET sha256=?,version=?,state=?,pages=?,text_pages=?,error='',indexed_at=? WHERE id=?");
    query.addBindValue(hash); query.addBindValue(extractorVersion); query.addBindValue(textPages ? "ready" : "empty");
    query.addBindValue(pdf.pageCount()); query.addBindValue(textPages);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)); query.addBindValue(id);
    if (!query.exec()) return fail("failed", query.lastError().text());
    if (!db.commit()) return fail("failed", db.lastError().text());
    return {};
}
struct SearchResult { QVariantList rows; QString error; };
SearchResult findText(const QString &path, const QString &input)
{
    const auto match = matchQuery(input);
    if (match.isEmpty()) return {};
    Connection connection(path);
    if (!connection.db.isOpen()) return {{}, connection.db.lastError().text()};
    QSqlQuery query(connection.db);
    if (!query.prepare("SELECT d.id,d.url,d.sha256,pages.page,snippet(pages.pages,2,'','',' … ',32) "
                  "FROM pages JOIN documents d ON d.id=pages.document_id "
                  "WHERE pages.pages MATCH ? AND d.state='ready' ORDER BY pages.rank LIMIT 40"))
        return {{}, query.lastError().text()};
    query.addBindValue(match);
    if (!query.exec()) return {{}, query.lastError().text()};
    SearchResult result;
    while (query.next()) {
        const auto source = QUrl(query.value(1).toString());
        result.rows.append(QVariantMap{{"kind", "text"}, {"documentId", query.value(0)}, {"source", source},
            {"sha256", query.value(2)}, {"page", query.value(3)}, {"snippet", query.value(4)},
            {"title", QFileInfo(source.toLocalFile()).fileName()}});
    }
    return result;
}
}

PaperIndex::PaperIndex(const QString &directory, QObject *parent)
    : QObject(parent), m_path(directory + "/search.sqlite3"), m_connection(QUuid::createUuid().toString())
{
    m_indexWorkers.setMaxThreadCount(1);
    m_indexWorkers.setThreadPriority(QThread::LowPriority);
    m_searchWorkers.setMaxThreadCount(1);
}
PaperIndex::~PaperIndex()
{
    m_cancel->store(true);
    m_indexWorkers.waitForDone(); m_searchWorkers.waitForDone();
    m_database.close(); m_database = {}; QSqlDatabase::removeDatabase(m_connection);
}
bool PaperIndex::initialize(QString *error)
{
    m_database = QSqlDatabase::addDatabase("QSQLITE", m_connection);
    m_database.setDatabaseName(m_path);
    if (!m_database.open()) { *error = m_database.lastError().text(); return false; }
    const QStringList statements = {
        "PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=3000",
        "CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,url TEXT UNIQUE NOT NULL,sha256 TEXT NOT NULL DEFAULT '',"
        "version INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',pages INTEGER NOT NULL DEFAULT 0,"
        "text_pages INTEGER NOT NULL DEFAULT 0,indexed_at TEXT)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(document_id UNINDEXED,page UNINDEXED,text,tokenize='unicode61 remove_diacritics 2')"
    };
    for (const auto &sql : statements) {
        QSqlQuery query(m_database);
        if (!query.exec(sql)) { *error = query.lastError().text(); return false; }
    }
    // Revalidate persisted sources after every restart, including interrupted documents.
    QSqlQuery query(m_database);
    query.exec("SELECT url FROM documents");
    while (query.next()) enqueue(QUrl(query.value(0).toString()));
    return true;
}
QVariantList PaperIndex::documents() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec("SELECT id,url,state,error,pages,text_pages FROM documents ORDER BY url");
    while (query.next()) {
        const auto url = QUrl(query.value(1).toString());
        rows.append(QVariantMap{{"id", query.value(0)}, {"source", url}, {"title", QFileInfo(url.toLocalFile()).fileName()},
            {"state", query.value(2)}, {"error", query.value(3)}, {"pages", query.value(4)}, {"textPages", query.value(5)}});
    }
    return rows;
}
void PaperIndex::enqueue(const QUrl &source)
{
    if (!source.isLocalFile() || m_scheduled.contains(source.toString())) return;
    m_queue.enqueue(source); m_scheduled.insert(source.toString());
    startNext(); emit changed();
}
void PaperIndex::retry(const QUrl &source) { enqueue(source); }
void PaperIndex::setReaderInteracting(QObject *reader, bool active)
{
    if (!reader) return;
    if (!m_readers.contains(reader)) {
        m_readers.insert(reader);
        connect(reader, &QObject::destroyed, this, [this, reader] {
            m_readers.remove(reader); m_interactingReaders.remove(reader);
            m_readerBusy->store(!m_interactingReaders.isEmpty());
        });
    }
    if (active) m_interactingReaders.insert(reader); else m_interactingReaders.remove(reader);
    m_readerBusy->store(!m_interactingReaders.isEmpty());
}
void PaperIndex::setPaused(bool paused)
{
    if (m_paused == paused) return;
    m_paused = paused;
    if (paused) m_cancel->store(true);
    else startNext();
    emit changed();
}
void PaperIndex::startNext()
{
    if (m_active || m_paused || m_queue.isEmpty()) return;
    const auto source = m_queue.dequeue();
    m_active = true;
    m_cancel = std::make_shared<std::atomic_bool>(false);
    const auto cancel = m_cancel;
    m_progress = "Checking " + QFileInfo(source.toLocalFile()).fileName();
    emit changed();
    auto *watcher = new QFutureWatcher<IndexResult>(this);
    connect(watcher, &QFutureWatcher<IndexResult>::finished, this, [this, watcher, source] {
        const auto result = watcher->result(); watcher->deleteLater();
        m_active = false;
        if (result.cancelled) m_queue.prepend(source);
        else m_scheduled.remove(source.toString());
        m_progress.clear();
        if (!result.error.isEmpty()) emit message("Search index: " + result.error);
        emit changed(); emit contentsChanged(); startNext();
    });
    watcher->setFuture(QtConcurrent::run(&m_indexWorkers, [this, path = m_path, source, cancel, readerBusy = m_readerBusy] {
        return indexFile(path, source, cancel, readerBusy, [this, source](int page, int total) {
            QMetaObject::invokeMethod(this, [this, source, page, total] {
                m_progress = QString("Indexing %1 · %2/%3").arg(QFileInfo(source.toLocalFile()).fileName()).arg(page).arg(total);
                emit changed();
            }, Qt::QueuedConnection);
        });
    }));
}
int PaperIndex::search(const QString &text)
{
    const int request = ++m_request;
    auto *watcher = new QFutureWatcher<SearchResult>(this);
    connect(watcher, &QFutureWatcher<SearchResult>::finished, this, [this, watcher, request] {
        const auto result = watcher->result(); watcher->deleteLater();
        emit searchFinished(request, result.rows, result.error);
    });
    watcher->setFuture(QtConcurrent::run(&m_searchWorkers, [path = m_path, text] { return findText(path, text); }));
    return request;
}
void PaperIndex::openResult(const QString &documentId, int page, const QString &hash)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT url,sha256,pages,state FROM documents WHERE id=?"); query.addBindValue(documentId);
    if (!query.exec() || !query.next() || query.value(1).toString() != hash || query.value(3) != "ready"
        || page < 0 || page >= query.value(2).toInt()) {
        emit message("This search result is no longer current. Search again after indexing finishes."); return;
    }
    const auto source = QUrl(query.value(0).toString());
    auto *watcher = new QFutureWatcher<bool>(this);
    connect(watcher, &QFutureWatcher<bool>::finished, this, [this, watcher, source, page] {
        const bool valid = watcher->result(); watcher->deleteLater();
        if (valid) emit resultReady(source, page);
        else { emit message("The original PDF changed or is missing. Updating its search index; please search again."); enqueue(source); }
    });
    watcher->setFuture(QtConcurrent::run(&m_searchWorkers, [source, hash] {
        return !hash.isEmpty() && hashFile(source.toLocalFile(), std::make_shared<std::atomic_bool>(false)) == hash;
    }));
}
