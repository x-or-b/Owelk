#include "PdfAccess.h"
#include "PaperIndex.h"
#include "FileFingerprint.h"
#include "SchemaMigration.h"
#include "WorkerConnection.h"

#include <QDateTime>
#include <QJsonArray>
#include <algorithm>
#include <QJsonObject>
#include <QJsonDocument>
#include <optional>
#include <cmath>
#include <QSet>
#include <QDir>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QThread>
#include <QUuid>
#include <QTemporaryFile>
#include <QStandardPaths>
#include <QProcess>
#include <QtConcurrent>

namespace {
constexpr int extractorVersion = 1;
using Connection = WorkerConnection;
QString hashFile(const QString &path, const std::shared_ptr<std::atomic_bool> &cancel)
{
    return FileFingerprint::sha256(path, cancel.get());
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
// Text for a page without a text layer (a scan), read by the installed Tesseract. Empty on failure.
QString recognize(
    QPdfDocument &pdf, int page, const PaperIndex::Ocr &ocr, const std::shared_ptr<std::atomic_bool> &cancel)
{
    const auto points = pdf.pagePointSize(page);
    // 300 dpi is what Tesseract reads best; very large pages are capped.
    const qreal scale = qMin(300.0 / 72.0, 4200.0 / qMax(points.width(), points.height()));
    const auto image = pdf.render(page, QSize(qRound(points.width() * scale), qRound(points.height() * scale)));
    if (image.isNull()) return {};
    QTemporaryFile file(QDir::tempPath() + "/owelk-ocr-XXXXXX.png");
    if (!file.open() || !image.save(&file, "PNG")) return {};
    file.close();
    QProcess process;
    QStringList arguments{file.fileName(), "stdout", "-l", ocr.languages};
    if (ocr.program.endsWith(".py")) {
        arguments.prepend(ocr.program);
        process.start(QStandardPaths::findExecutable("python3").isEmpty() ? "python" : "python3", arguments);
    } else
        process.start(ocr.program, arguments);
    if (!process.waitForStarted(5000)) return {};
    // Recognition takes seconds; stop it when the index is paused or closed.
    for (int waited = 0; !process.waitForFinished(200); waited += 200)
        if (cancel->load() || waited > 180000) {
            process.kill();
            process.waitForFinished(1000);
            return {};
        }
    return process.exitCode() == 0 ? QString::fromUtf8(process.readAllStandardOutput()) : QString();
}
struct IndexResult {
    QString error;
    bool cancelled = false;
};
IndexResult indexFile(const QString &dbPath, const QUrl &source, const QString &wantedId,
    const std::shared_ptr<std::atomic_bool> &cancel, const std::shared_ptr<std::atomic_bool> &readerBusy,
    const PaperIndex::Ocr &ocr, const std::function<void(int, int)> &progress)
{
    Connection connection(dbPath);
    auto &db = connection.db;
    if (!db.isOpen()) return {db.lastError().text()};
    QSqlQuery query(db);
    query.prepare("INSERT OR IGNORE INTO documents(id,url,state) VALUES(?,?,'pending')");
    query.addBindValue(wantedId.isEmpty() ? QUuid::createUuid().toString(QUuid::WithoutBraces) : wantedId);
    query.addBindValue(source.toString());
    if (!query.exec()) return {query.lastError().text()};
    if (!wantedId.isEmpty()) {
        // Adopt the library's document ID for an entry created before IDs were shared. The cache row
        // and its pages move together; a stale row already holding that ID is only cache and is dropped.
        const auto run = [&](const QString &sql, const QVariantList &args) {
            QSqlQuery step(db);
            step.prepare(sql);
            for (const auto &arg : args) step.addBindValue(arg);
            return step.exec();
        };
        if (!db.transaction()) return {db.lastError().text()};
        const bool ok = run("DELETE FROM pages WHERE document_id=? AND ?<>(SELECT id FROM documents WHERE url=?)",
                            {wantedId, wantedId, source.toString()})
            && run("DELETE FROM documents WHERE id=? AND url<>?", {wantedId, source.toString()})
            && run("UPDATE pages SET document_id=? WHERE document_id=(SELECT id FROM documents WHERE url=?)",
                {wantedId, source.toString()})
            && run("UPDATE documents SET id=? WHERE url=?", {wantedId, source.toString()});
        if (!ok || !db.commit()) {
            const auto error = db.lastError().text();
            db.rollback();
            return {"Cannot align the search cache with the library: " + error};
        }
        if (!query.exec())
            return {query.lastError().text()}; // Recreate the row if a stale holder of the ID was dropped.
    }
    query.prepare("SELECT id,sha256,version,state,stamp,pages,text_pages,ocr FROM documents WHERE url=?");
    query.addBindValue(source.toString());
    if (!query.exec() || !query.next()) return {"Cannot read search document record."};
    const auto id = query.value(0).toString(), oldHash = query.value(1).toString();
    const int version = query.value(2).toInt();
    const auto state = query.value(3).toString();
    const auto oldStamp = FileFingerprint::Stamp::fromString(query.value(4).toString());
    // Pages without text are read once OCR is available (and only then).
    const bool needsOcr
        = ocr.enabled() && query.value(7).toInt() == 0 && query.value(6).toInt() < query.value(5).toInt();
    query.finish();
    const bool current
        = version == extractorVersion && (state == "ready" || state == "empty") && !oldHash.isEmpty() && !needsOcr;
    // Startup revalidation: an unchanged file stamp proves the indexed bytes are current without reading the PDF.
    const auto startStamp = FileFingerprint::stamp(source.toLocalFile());
    if (current && oldStamp.isValid() && oldStamp == startStamp) {
        FileFingerprint::remember(source.toLocalFile(), startStamp, oldHash);
        return {};
    }
    auto fail = [&](const QString &state, const QString &error) -> IndexResult {
        db.rollback();
        QSqlQuery status(db);
        status.prepare("UPDATE documents SET state=?,error=? WHERE id=?");
        status.addBindValue(state);
        status.addBindValue(error.isEmpty() ? QStringLiteral("") : error);
        status.addBindValue(id);
        if (!status.exec()) return {status.lastError().text()};
        return {error, state == "paused"};
    };
    if (cancel->load()) return fail("paused", {});
    const auto hash = hashFile(source.toLocalFile(), cancel);
    if (cancel->load()) return fail("paused", {});
    if (hash.isEmpty()) return fail("missing", "Cannot read the original PDF. Check its path and permissions.");
    if (hash == oldHash && current) {
        // Same bytes under a new stamp (e.g. copied back or touched): record the stamp so the next start is free.
        query.prepare("UPDATE documents SET stamp=? WHERE id=?");
        query.addBindValue(startStamp.toString());
        query.addBindValue(id);
        if (!query.exec()) return {query.lastError().text()};
        return {};
    }
    query.prepare("UPDATE documents SET state='indexing',error='' WHERE id=?");
    query.addBindValue(id);
    if (!query.exec()) return {query.lastError().text()};
    QPdfDocument pdf;
    const auto loadError = PdfAccess::load(pdf, source.toLocalFile());
    if (loadError != QPdfDocument::Error::None || pdf.status() != QPdfDocument::Status::Ready) {
        const bool locked = loadError == QPdfDocument::Error::IncorrectPassword;
        return fail(locked ? "locked" : "failed",
            locked ? "Locked: open it in Owelk and enter its password to index it."
                   : "Cannot extract text from this PDF.");
    }
    if (!db.transaction()) return fail("failed", db.lastError().text());
    query.prepare("DELETE FROM pages WHERE document_id=?");
    query.addBindValue(id);
    if (!query.exec()) return fail("failed", query.lastError().text());
    query.prepare("DELETE FROM ocr_pages WHERE document_id=?");
    query.addBindValue(id);
    if (!query.exec()) return fail("failed", query.lastError().text());
    int textPages = 0;
    for (int page = 0; page < pdf.pageCount(); ++page) {
        while (readerBusy->load() && !cancel->load()) QThread::msleep(2);
        if (cancel->load()) return fail("paused", {});
        auto text = normalize(pdf.getAllText(page).text());
        bool recognized = false;
        if (text.isEmpty() && ocr.enabled()) {
            text = normalize(recognize(pdf, page, ocr, cancel));
            if (cancel->load()) return fail("paused", {});
            recognized = !text.isEmpty();
        }
        if (recognized) {
            QSqlQuery mark(db);
            mark.prepare("INSERT OR REPLACE INTO ocr_pages(document_id,page) VALUES(?,?)");
            mark.addBindValue(id);
            mark.addBindValue(page);
            if (!mark.exec()) return fail("failed", mark.lastError().text());
        }
        if (!text.isEmpty()) {
            query.prepare("INSERT INTO pages(document_id,page,text) VALUES(?,?,?)");
            query.addBindValue(id);
            query.addBindValue(page);
            query.addBindValue(text);
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
    query.prepare("UPDATE documents SET sha256=?,version=?,state=?,pages=?,text_pages=?,error='',indexed_at=?,stamp=?,"
                  "ocr=? WHERE id=?");
    query.addBindValue(hash);
    query.addBindValue(extractorVersion);
    query.addBindValue(textPages ? "ready" : "empty");
    query.addBindValue(pdf.pageCount());
    query.addBindValue(textPages);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    query.addBindValue(startStamp.toString());
    query.addBindValue(ocr.enabled() ? 1 : 0);
    query.addBindValue(id);
    if (!query.exec()) return fail("failed", query.lastError().text());
    if (!db.commit()) return fail("failed", db.lastError().text());
    return {};
}
struct SearchResult {
    QVariantList rows;
    QString error;
};
// Paper titles live in the library database next to the search cache; without it, file names are shown.
QHash<QString, QString> libraryTitles(const QString &searchPath)
{
    QHash<QString, QString> titles;
    const auto library = QFileInfo(searchPath).absolutePath() + "/owelk.sqlite3";
    if (!QFileInfo::exists(library)) return titles;
    Connection connection(library, true);
    QSqlQuery query(connection.db);
    if (connection.db.isOpen() && query.exec("SELECT url,title FROM documents WHERE title<>''"))
        while (query.next()) titles.insert(query.value(0).toString(), query.value(1).toString());
    return titles;
}
// Per-paper ranking help from the library: the query in the title, recently opened, favorite or being read.
// Added to bm25 (lower is better), so a paper about the words outranks one that only mentions them.
QString libraryBoosts(const QString &searchPath, const QString &input)
{
    QJsonObject boosts;
    const auto library = QFileInfo(searchPath).absolutePath() + "/owelk.sqlite3";
    if (!QFileInfo::exists(library)) return "{}";
    const auto terms = input.simplified().split(' ', Qt::SkipEmptyParts);
    Connection connection(library, true);
    QSqlQuery query(connection.db);
    if (!connection.db.isOpen()
        || !query.exec(
            "SELECT d.id,d.title,d.favorite,d.reading_state,r.opened_at FROM documents d "
            "LEFT JOIN recent_documents r ON r.document_id=d.id ORDER BY r.opened_at IS NULL,r.opened_at DESC"))
        return "{}";
    int rank = 0;
    while (query.next()) {
        const auto title = query.value(1).toString();
        double boost = 0;
        if (!terms.isEmpty() && std::all_of(terms.cbegin(), terms.cend(), [&](const QString &term) {
                return title.contains(term, Qt::CaseInsensitive);
            }))
            boost += 3;
        if (!query.value(4).isNull() && rank++ < 10) boost += 1;
        if (query.value(2).toBool()) boost += .5;
        if (query.value(3).toString() == "reading") boost += .5;
        if (boost > 0) boosts.insert(query.value(0).toString(), boost);
    }
    return QString::fromUtf8(QJsonDocument(boosts).toJson(QJsonDocument::Compact));
}
// limit: when set, only these document IDs (library filters such as a collection or tag) are searched.
SearchResult findGroupedText(
    const QString &path, const QString &input, const QUrl &scope, int offset, const std::optional<QStringList> &limit)
{
    if (limit && limit->isEmpty()) return {};
    const auto match = matchQuery(input);
    if (match.isEmpty()) return {};
    Connection connection(path, true);
    if (!connection.db.isOpen()) return {{}, connection.db.lastError().text()};
    const bool scoped = !scope.isEmpty();
    offset = qMax(0, offset);
    QSqlQuery query(connection.db);
    // Materialize FTS auxiliary values before window functions; limit by document, not global hits.
    const QString sql = QStringLiteral(
        "WITH matches AS MATERIALIZED (SELECT d.id,d.url,d.sha256,pages.page,"
        "snippet(pages.pages,2,'','',' … ',32) AS excerpt,pages.rank AS score,"
        "EXISTS(SELECT 1 FROM ocr_pages o WHERE o.document_id=d.id AND o.page=pages.page) AS ocr "
        "FROM pages JOIN documents d ON d.id=pages.document_id WHERE pages.pages MATCH ? AND d.state='ready' %1 %3),"
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY id ORDER BY score,page) AS hit,"
        "count(*) OVER(PARTITION BY id) AS total,min(score) OVER(PARTITION BY id) AS best FROM matches),"
        // Paper order: the best page's bm25, helped by library boosts and by matching on several pages.
        "adjusted AS (SELECT ranked.*,best-coalesce(b.value,0)-min(total,10)*0.2 AS paper_score FROM ranked "
        "LEFT JOIN json_each(?) b ON b.key=ranked.id),"
        "grouped AS (SELECT *,dense_rank() OVER(ORDER BY paper_score,id) AS paper_rank FROM adjusted) "
        "SELECT id,url,sha256,page,excerpt,total,paper_rank,ocr FROM grouped WHERE %2 ORDER BY paper_rank,hit")
                            .arg(scoped ? "AND d.url=?" : "",
                                scoped ? "hit>? AND hit<=?" : "hit<=3 AND paper_rank>? AND paper_rank<=?",
                                limit ? "AND d.id IN (SELECT value FROM json_each(?))" : "");
    if (!query.prepare(sql)) return {{}, query.lastError().text()};
    query.addBindValue(match);
    if (scoped) query.addBindValue(scope.toString());
    if (limit)
        query.addBindValue(
            QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(*limit)).toJson(QJsonDocument::Compact)));
    query.addBindValue(libraryBoosts(path, input));
    query.addBindValue(offset);
    query.addBindValue(offset + (scoped ? 41 : 21));
    if (!query.exec()) return {{}, query.lastError().text()};
    SearchResult result;
    const auto titles = libraryTitles(path);
    QString lastId;
    QVariantMap lastGroup;
    int pages = 0;
    const auto finishGroup = [&] {
        if (!scoped && lastGroup.value("total").toInt() > 3) {
            auto more = lastGroup;
            more["kind"] = "moreInPaper";
            more["title"] = QString("Show all %1 matching pages in '%2'")
                                .arg(more["total"].toInt())
                                .arg(lastGroup["title"].toString());
            result.rows.append(more);
        }
    };
    while (query.next()) {
        if ((!scoped && query.value(6).toInt() > offset + 20) || (scoped && pages >= 40)) {
            finishGroup();
            result.rows.append(
                QVariantMap{{"kind", "nextResults"}, {"title", scoped ? "Next matching pages →" : "More papers →"},
                    {"offset", offset + (scoped ? 40 : 20)}});
            return result;
        }
        const auto id = query.value(0).toString();
        const auto source = QUrl(query.value(1).toString());
        if (lastId != id) {
            finishGroup();
            lastId = id;
            lastGroup = {{"kind", "paperGroup"},
                {"title", titles.value(source.toString(), QFileInfo(source.toLocalFile()).fileName())},
                {"documentId", id}, {"source", source}, {"total", query.value(5)}};
            result.rows.append(lastGroup);
        }
        result.rows.append(
            QVariantMap{{"kind", "text"}, {"documentId", id}, {"source", source}, {"sha256", query.value(2)},
                {"page", query.value(3)}, {"snippet", query.value(4)}, {"ocr", query.value(7).toBool()},
                {"title", titles.value(source.toString(), QFileInfo(source.toLocalFile()).fileName())}});
        ++pages;
    }
    finishGroup();
    return result;
}
// Words that say what a paper is about: frequent in its first pages, rare in the rest of the library.
QStringList distinctiveTerms(QSqlDatabase &db, const QString &document, int count)
{
    static const QSet<QString> common{"this", "that", "with", "from", "which", "these", "their", "there", "where",
        "have", "were", "been", "also", "such", "into", "than", "then", "they", "them", "when", "each", "more", "most",
        "other", "some", "only", "over", "both", "between", "using", "used", "based", "while", "however", "figure",
        "table", "section", "paper", "results", "method", "methods", "show", "shown", "proposed", "approach", "page"};
    QSqlQuery pages(db);
    pages.prepare("SELECT text FROM pages WHERE document_id=? AND page<3");
    pages.addBindValue(document);
    QHash<QString, int> frequency;
    if (pages.exec())
        while (pages.next())
            for (const auto &word :
                pages.value(0).toString().toLower().split(QRegularExpression("[^\\p{L}\\p{N}]+"), Qt::SkipEmptyParts))
                if (word.size() >= 4 && !common.contains(word) && !word.front().isDigit()) ++frequency[word];
    QSqlQuery total(db);
    const double pagesInLibrary
        = total.exec("SELECT count(*) FROM pages") && total.next() ? std::max(1, total.value(0).toInt()) : 1;
    QList<std::pair<double, QString>> scored;
    QSqlQuery spread(db);
    spread.prepare("SELECT doc FROM pages_vocab WHERE term=?");
    for (auto it = frequency.cbegin(); it != frequency.cend(); ++it) {
        if (it.value() < 2) continue;
        spread.addBindValue(it.key());
        const int pagesWithWord = spread.exec() && spread.next() ? spread.value(0).toInt() : 1;
        // Words on most pages of the library say nothing about this paper.
        if (pagesInLibrary > 20 && pagesWithWord > pagesInLibrary * .3) continue;
        scored.append({it.value() * std::log(1 + pagesInLibrary / pagesWithWord), it.key()});
    }
    std::sort(scored.begin(), scored.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    QStringList terms;
    for (const auto &entry : scored)
        if (terms.size() < count) terms << entry.second;
    return terms;
}

SearchResult findRelated(const QString &path, const QString &document, int limit)
{
    Connection connection(path, true);
    if (!connection.db.isOpen()) return {{}, connection.db.lastError().text()};
    const auto terms = distinctiveTerms(connection.db, document, 8);
    if (terms.isEmpty()) return {};
    QStringList quoted;
    for (const auto &term : terms) quoted << '"' + term + '"';
    // Papers sharing the most of these words, by their summed bm25 over matching pages.
    QSqlQuery query(connection.db);
    query.prepare("SELECT d.id,d.url,sum(pages.rank) AS score FROM pages JOIN documents d ON d.id=pages.document_id "
                  "WHERE pages.pages MATCH ? AND d.id<>? AND d.state='ready' GROUP BY d.id ORDER BY score LIMIT ?");
    query.addBindValue(quoted.join(" OR "));
    query.addBindValue(document);
    query.addBindValue(limit);
    if (!query.exec()) return {{}, query.lastError().text()};
    SearchResult result;
    const auto titles = libraryTitles(path);
    while (query.next()) {
        const QUrl source(query.value(1).toString());
        result.rows.append(QVariantMap{{"kind", "paper"}, {"documentId", query.value(0)}, {"source", source},
            {"title", titles.value(source.toString(), QFileInfo(source.toLocalFile()).fileName())}});
    }
    // The words also find related notes in the library.
    result.rows.append(QVariantMap{{"kind", "terms"}, {"terms", terms}});
    return result;
}

SearchResult findText(const QString &path, const QString &input)
{
    const auto match = matchQuery(input);
    if (match.isEmpty()) return {};
    Connection connection(path, true);
    if (!connection.db.isOpen()) return {{}, connection.db.lastError().text()};
    QSqlQuery query(connection.db);
    if (!query.prepare("SELECT d.id,d.url,d.sha256,pages.page,snippet(pages.pages,2,'','',' … ',32) "
                       "FROM pages JOIN documents d ON d.id=pages.document_id "
                       "WHERE pages.pages MATCH ? AND d.state='ready' ORDER BY pages.rank LIMIT 40"))
        return {{}, query.lastError().text()};
    query.addBindValue(match);
    if (!query.exec()) return {{}, query.lastError().text()};
    SearchResult result;
    const auto titles = libraryTitles(path);
    while (query.next()) {
        const auto source = QUrl(query.value(1).toString());
        result.rows.append(QVariantMap{{"kind", "text"}, {"documentId", query.value(0)}, {"source", source},
            {"sha256", query.value(2)}, {"page", query.value(3)}, {"snippet", query.value(4)},
            {"title", titles.value(source.toString(), QFileInfo(source.toLocalFile()).fileName())}});
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
    m_indexWorkers.waitForDone();
    m_searchWorkers.waitForDone();
    m_database.close();
    m_database = {};
    QSqlDatabase::removeDatabase(m_connection);
}
bool PaperIndex::initialize(QString *error)
{
    m_database = QSqlDatabase::addDatabase("QSQLITE", m_connection);
    m_database.setDatabaseName(m_path);
    if (!m_database.open()) {
        *error = m_database.lastError().text();
        return false;
    }
    for (const auto &pragma : {"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=3000"}) {
        QSqlQuery query(m_database);
        if (!query.exec(pragma)) {
            *error = query.lastError().text();
            return false;
        }
    }
    const QList<SchemaStep> steps = {
        {1,
            {"CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,url TEXT UNIQUE NOT NULL,sha256 TEXT NOT NULL "
             "DEFAULT '',"
             "version INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',pages INTEGER NOT "
             "NULL DEFAULT 0,"
             "text_pages INTEGER NOT NULL DEFAULT 0,indexed_at TEXT)",
                "CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(document_id UNINDEXED,page UNINDEXED,text,"
                "tokenize='unicode61 remove_diacritics 2')"}},
        {2, {"ALTER TABLE documents ADD COLUMN stamp TEXT NOT NULL DEFAULT ''"}},
        // Word statistics over the page text (no extra storage), for "related papers".
        {3, {"CREATE VIRTUAL TABLE IF NOT EXISTS pages_vocab USING fts5vocab(pages, 'row')"}},
        // Scanned pages read by OCR (search only: they have no text layer to select).
        {4,
            {"ALTER TABLE documents ADD COLUMN ocr INTEGER NOT NULL DEFAULT 0",
                "CREATE TABLE IF NOT EXISTS ocr_pages(document_id TEXT NOT NULL,page INTEGER NOT NULL,"
                "PRIMARY KEY(document_id,page))"}},
    };
    if (!migrateSchema(m_database, steps, error)) return false;
    // Revalidate persisted sources after every restart, including interrupted documents.
    // Known hashes are seeded first so opening a PDF does not wait for its own revalidation.
    QSqlQuery query(m_database);
    query.exec("SELECT url,sha256,stamp FROM documents");
    while (query.next()) {
        const QUrl url(query.value(0).toString());
        if (url.isLocalFile())
            FileFingerprint::remember(url.toLocalFile(), FileFingerprint::Stamp::fromString(query.value(2).toString()),
                query.value(1).toString());
        enqueue(url);
    }
    return true;
}
QVariantList PaperIndex::documents() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec("SELECT id,url,state,error,pages,text_pages FROM documents ORDER BY url");
    while (query.next()) {
        const auto url = QUrl(query.value(1).toString());
        rows.append(QVariantMap{{"id", query.value(0)}, {"source", url},
            {"title", QFileInfo(url.toLocalFile()).fileName()}, {"state", query.value(2)}, {"error", query.value(3)},
            {"pages", query.value(4)}, {"textPages", query.value(5)}});
    }
    return rows;
}
QUrl PaperIndex::resolvedSource(const QUrl &input) const
{
    QString url = input.toString();
    for (int i = 0; i < m_redirects.size() && m_redirects.contains(url); ++i) url = m_redirects.value(url);
    return QUrl(url);
}
QString PaperIndex::knownHash(const QUrl &source) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT sha256 FROM documents WHERE url=?");
    query.addBindValue(source.toString());
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}
void PaperIndex::relocateSource(const QUrl &source, const QUrl &candidate)
{
    if (source == candidate) return;
    m_redirects.insert(source.toString(), candidate.toString());
    ++m_relocating;
    m_cancel->store(true);
    emit changed();
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, candidate] {
        const auto error = watcher->result();
        watcher->deleteLater();
        --m_relocating;
        if (!error.isEmpty())
            emit message("Source references were saved, but the search cache needs repair. Restart to retry: " + error);
        emit changed();
        emit contentsChanged();
        enqueue(candidate);
        startNext();
    });
    watcher->setFuture(QtConcurrent::run(&m_indexWorkers, [path = m_path, source, candidate] {
        Connection connection(path);
        auto &db = connection.db;
        if (!db.isOpen() || !db.transaction()) return db.lastError().text();
        auto run = [&](const QString &sql, const QVariantList &args) {
            QSqlQuery query(db);
            query.prepare(sql);
            for (const auto &arg : args) query.addBindValue(arg);
            return query.exec() ? QString() : query.lastError().text();
        };
        QSqlQuery old(db);
        old.prepare("SELECT id FROM documents WHERE url=?");
        old.addBindValue(source.toString());
        if (!old.exec()) {
            db.rollback();
            return old.lastError().text();
        }
        if (!old.next()) {
            old.finish();
            db.commit();
            return QString();
        }
        const auto id = old.value(0).toString();
        old.finish();
        // Both copies may have been indexed. Keep the original ID; the target is only a rebuildable cache.
        QString error = run(
            "DELETE FROM pages WHERE document_id IN (SELECT id FROM documents WHERE url=?)", {candidate.toString()});
        if (error.isEmpty()) error = run("DELETE FROM documents WHERE url=?", {candidate.toString()});
        if (error.isEmpty()) error = run("UPDATE documents SET url=? WHERE id=?", {candidate.toString(), id});
        if (!error.isEmpty()) {
            db.rollback();
            return error;
        }
        if (!db.commit()) {
            error = db.lastError().text();
            db.rollback();
            return error;
        }
        return QString();
    }));
}
void PaperIndex::enqueue(const QUrl &input)
{
    const auto source = resolvedSource(input);
    if (!source.isLocalFile() || m_scheduled.contains(source.toString())) return;
    if (m_excluded && m_excluded(source)) return;
    m_queue.enqueue(source);
    m_scheduled.insert(source.toString());
    startNext();
    emit changed();
}
void PaperIndex::remove(const QUrl &input)
{
    // Drop a document's pages from the cache; the PDF and library record stay.
    const auto source = resolvedSource(input);
    m_queue.removeAll(source);
    m_scheduled.remove(source.toString());
    ++m_relocating;
    auto *watcher = new QFutureWatcher<void>(this);
    connect(watcher, &QFutureWatcher<void>::finished, this, [this, watcher] {
        watcher->deleteLater();
        --m_relocating;
        emit changed();
        emit contentsChanged();
        startNext();
    });
    watcher->setFuture(QtConcurrent::run(&m_indexWorkers, [path = m_path, source] {
        Connection connection(path);
        QSqlQuery query(connection.db);
        query.prepare("DELETE FROM pages WHERE document_id IN (SELECT id FROM documents WHERE url=?)");
        query.addBindValue(source.toString());
        query.exec();
        query.prepare("DELETE FROM documents WHERE url=?");
        query.addBindValue(source.toString());
        query.exec();
    }));
}
void PaperIndex::setOcr(const Ocr &ocr)
{
    const bool turnedOn = ocr.enabled() && !m_ocr.enabled();
    m_ocr = ocr;
    if (!turnedOn) return;
    // Papers indexed before OCR was available, with pages that had no text, are read again.
    QSqlQuery query(m_database);
    query.exec("SELECT url FROM documents WHERE ocr=0 AND text_pages<pages AND state IN ('ready','empty')");
    while (query.next()) enqueue(QUrl(query.value(0).toString()));
}
void PaperIndex::retry(const QUrl &source)
{
    enqueue(source);
}
void PaperIndex::setReaderInteracting(QObject *reader, bool active)
{
    if (!reader) return;
    if (!m_readers.contains(reader)) {
        m_readers.insert(reader);
        connect(reader, &QObject::destroyed, this, [this, reader] {
            m_readers.remove(reader);
            m_interactingReaders.remove(reader);
            m_readerBusy->store(!m_interactingReaders.isEmpty());
        });
    }
    if (active)
        m_interactingReaders.insert(reader);
    else
        m_interactingReaders.remove(reader);
    m_readerBusy->store(!m_interactingReaders.isEmpty());
}
void PaperIndex::setPaused(bool paused)
{
    if (m_paused == paused) return;
    m_paused = paused;
    if (paused)
        m_cancel->store(true);
    else
        startNext();
    emit changed();
}
void PaperIndex::startNext()
{
    if (m_active || m_paused || m_relocating > 0 || m_queue.isEmpty()) return;
    const auto queued = m_queue.dequeue();
    const auto source = resolvedSource(queued);
    m_scheduled.remove(queued.toString());
    m_scheduled.insert(source.toString());
    m_active = true;
    m_cancel = std::make_shared<std::atomic_bool>(false);
    const auto cancel = m_cancel;
    const auto documentId = m_resolver ? m_resolver(source) : QString();
    m_progress = "Checking " + QFileInfo(source.toLocalFile()).fileName();
    emit changed();
    auto *watcher = new QFutureWatcher<IndexResult>(this);
    connect(watcher, &QFutureWatcher<IndexResult>::finished, this, [this, watcher, source] {
        const auto result = watcher->result();
        watcher->deleteLater();
        m_active = false;
        if (result.cancelled)
            m_queue.prepend(source);
        else
            m_scheduled.remove(source.toString());
        m_progress.clear();
        if (!result.error.isEmpty()) emit message("Search index: " + result.error);
        emit changed();
        emit contentsChanged();
        startNext();
    });
    watcher->setFuture(QtConcurrent::run(
        &m_indexWorkers, [this, path = m_path, source, documentId, cancel, readerBusy = m_readerBusy, ocr = m_ocr] {
            return indexFile(path, source, documentId, cancel, readerBusy, ocr, [this, source](int page, int total) {
                QMetaObject::invokeMethod(
                    this,
                    [this, source, page, total] {
                        m_progress = QString("Indexing %1 · %2/%3")
                                         .arg(QFileInfo(source.toLocalFile()).fileName())
                                         .arg(page)
                                         .arg(total);
                        emit changed();
                    },
                    Qt::QueuedConnection);
            });
        }));
}
int PaperIndex::search(const QString &text)
{
    const int request = ++m_request;
    auto *watcher = new QFutureWatcher<SearchResult>(this);
    connect(watcher, &QFutureWatcher<SearchResult>::finished, this, [this, watcher, request] {
        const auto result = watcher->result();
        watcher->deleteLater();
        emit searchFinished(request, result.rows, result.error);
    });
    watcher->setFuture(QtConcurrent::run(&m_searchWorkers, [path = m_path, text] { return findText(path, text); }));
    return request;
}
int PaperIndex::searchGrouped(const QString &text, const QUrl &source, int offset, const QVariant &scopeIds)
{
    std::optional<QStringList> limit;
    if (scopeIds.isValid() && !scopeIds.isNull()) limit = scopeIds.toStringList();
    const int request = ++m_request;
    auto *watcher = new QFutureWatcher<SearchResult>(this);
    connect(watcher, &QFutureWatcher<SearchResult>::finished, this, [this, watcher, request] {
        const auto result = watcher->result();
        watcher->deleteLater();
        emit searchFinished(request, result.rows, result.error);
    });
    watcher->setFuture(QtConcurrent::run(&m_searchWorkers,
        [path = m_path, text, source, offset, limit] { return findGroupedText(path, text, source, offset, limit); }));
    return request;
}
QString PaperIndex::openingText(const QString &documentId, int characters) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT text FROM pages WHERE document_id=? AND page<2 ORDER BY page");
    query.addBindValue(documentId);
    QString text;
    if (query.exec())
        while (query.next() && text.size() < characters) text += query.value(0).toString().simplified() + ' ';
    return text.left(characters).trimmed();
}

int PaperIndex::related(const QString &documentId, int limit)
{
    const int request = ++m_request;
    auto *watcher = new QFutureWatcher<SearchResult>(this);
    connect(watcher, &QFutureWatcher<SearchResult>::finished, this, [this, watcher, request] {
        const auto result = watcher->result();
        watcher->deleteLater();
        emit searchFinished(request, result.rows, result.error);
    });
    watcher->setFuture(QtConcurrent::run(
        &m_searchWorkers, [path = m_path, documentId, limit] { return findRelated(path, documentId, limit); }));
    return request;
}
void PaperIndex::openResult(const QString &documentId, int page, const QString &hash)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT url,sha256,pages,state FROM documents WHERE id=?");
    query.addBindValue(documentId);
    if (!query.exec() || !query.next() || query.value(1).toString() != hash || query.value(3) != "ready" || page < 0
        || page >= query.value(2).toInt()) {
        emit message("This search result is no longer current. Search again after indexing finishes.");
        return;
    }
    const auto source = QUrl(query.value(0).toString());
    auto *watcher = new QFutureWatcher<bool>(this);
    connect(watcher, &QFutureWatcher<bool>::finished, this, [this, watcher, source, page] {
        const bool valid = watcher->result();
        watcher->deleteLater();
        if (valid)
            emit resultReady(source, page);
        else {
            emit message("The original PDF changed or is missing. Updating its search index; please search again.");
            enqueue(source);
        }
    });
    watcher->setFuture(QtConcurrent::run(&m_searchWorkers, [source, hash] {
        return !hash.isEmpty() && hashFile(source.toLocalFile(), std::make_shared<std::atomic_bool>(false)) == hash;
    }));
}
