#include "PdfAccess.h"
#include "ResearchStore.h"
#include "SemanticIndex.h"
#include "FileFingerprint.h"
#include "SchemaMigration.h"
#include "PaperIndex.h"
#include "ReferenceFinder.h"
#include "MetadataLookup.h"
#include "AiService.h"
#include "SelectionGeometry.h"
#include "LibrarySync.h"

#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QSaveFile>
#include <QSqlError>
#include <QSqlQuery>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUuid>
#include <QtConcurrent>
#include <cmath>

namespace {
void collectTabs(const QVariantMap &node, QVariantList &tabs)
{
    if (node.value("kind") == "group")
        tabs.append(node.value("tabs").toList());
    else if (node.value("kind") == "split") {
        collectTabs(node.value("first").toMap(), tabs);
        collectTabs(node.value("second").toMap(), tabs);
    }
}
QVariantMap activeTab(const QVariantMap &node, const QString &group)
{
    if (node.value("kind") == "group" && node.value("id") == group) {
        for (const auto &tab : node.value("tabs").toList())
            if (tab.toMap().value("id") == node.value("activeTab")) return tab.toMap();
    } else if (node.value("kind") == "split") {
        auto tab = activeTab(node.value("first").toMap(), group);
        return tab.isEmpty() ? activeTab(node.value("second").toMap(), group) : tab;
    }
    return {};
}
QVariantList readers(const QVariantMap &state)
{
    QVariantList result;
    if (state.value("version").toInt() == 2) {
        collectTabs(state.value("tree").toMap(), result);
        const auto active = activeTab(state.value("tree").toMap(), state.value("activeGroup").toString());
        if (!active.isEmpty())
            result.append(active); // Last write owns recent position, not other copies of the same PDF.
    } else {
        const bool right = state.value("active").toInt() == 1 && state.value("split").toBool();
        result << state.value(right ? "left" : "right") << state.value(right ? "right" : "left");
    }
    return result;
}
QString fingerprint(const QString &path)
{
    return FileFingerprint::sha256(path);
}

struct CaptureResult {
    QString id, path, hash, error, caption;
    QUrl source;
    int page = 0;
    QRectF region;
};
struct TextCaptureResult {
    CaptureResult anchor;
    QString text, prefix, suffix;
    int start = -1, end = -1;
    QVariantList rectangles;
};
}

ResearchStore::ResearchStore(const QString &directory, QObject *parent)
    : QObject(parent), m_directory(directory), m_connection(QUuid::createUuid().toString()),
      m_index(new PaperIndex(directory, this)), m_references(new ReferenceFinder(m_index->readerBusyFlag(), this)),
      m_lookup(new MetadataLookup(this)), m_ai(new AiService(this, this)), m_sync(new LibrarySync(directory, this))
{
    connect(m_sync, &LibrarySync::received, this, &ResearchStore::syncReceived);
    m_workers.setMaxThreadCount(1);
    m_verifiers.setMaxThreadCount(2);
    // A new capture can be undone (it moves to the trash).
    connect(this, &ResearchStore::captureSaved, this, [this](const QString &id) { recordCapture(id, false); });
    m_metadataWorkers.setMaxThreadCount(1);
    m_metadataWorkers.setThreadPriority(QThread::LowPriority);
    connect(m_index, &PaperIndex::message, this, &ResearchStore::message);
}

QObject *ResearchStore::semantic() const
{
    return m_semantic;
}

QObject *ResearchStore::sync() const
{
    return m_sync;
}

QObject *ResearchStore::paperIndex() const
{
    return m_index;
}

QObject *ResearchStore::references() const
{
    return m_references;
}

QStringList ResearchStore::annotationColors()
{
    return {"#426b9a", "#e0b83f", "#54a878", "#d87797", "#9274c3", "#1d3a5c"};
}

ResearchStore::~ResearchStore()
{
    m_sync->finish();
    if (m_database.isOpen()) markStopped();
    m_workers.waitForDone();
    m_verifiers.waitForDone();
    m_metadataWorkers.waitForDone();
    m_database.close();
    m_database = QSqlDatabase();
    QSqlDatabase::removeDatabase(m_connection);
}

bool ResearchStore::initialize(QString *error)
{
    if (!QDir().mkpath(m_directory + "/captures")) {
        *error = tr("Cannot create data folder: %1").arg(m_directory);
        return false;
    }
    // A restore chosen in Settings is applied now, before the database is opened.
    applyPendingRestore(m_directory, &m_startupMessage);
    QDir().mkpath(m_directory + "/captures");
    m_database = QSqlDatabase::addDatabase("QSQLITE", m_connection);
    m_database.setDatabaseName(m_directory + "/owelk.sqlite3");
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
    // Append new steps; never edit a released step. Step 1 is the idempotent pre-versioning baseline.
    const QList<SchemaStep> steps = {
        {1,
            {"CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS recent_documents (url TEXT PRIMARY KEY, opened_at TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS reading_positions (url TEXT PRIMARY KEY, position TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, state TEXT NOT NULL, "
                "opened_at TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS workspace_documents (workspace_id TEXT NOT NULL, url TEXT NOT NULL, "
                "PRIMARY KEY(workspace_id,url))",
                "CREATE TABLE IF NOT EXISTS workspace_document_exclusions (workspace_id TEXT NOT NULL, url TEXT NOT "
                "NULL, "
                "PRIMARY KEY(workspace_id,url))",
                "CREATE TABLE IF NOT EXISTS workspace_captures (workspace_id TEXT NOT NULL, capture_id TEXT NOT NULL, "
                "PRIMARY KEY(workspace_id,capture_id))",
                "CREATE TABLE IF NOT EXISTS deleted_workspaces (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS deleted_captures (id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS source_relinks (old_url TEXT PRIMARY KEY,new_url TEXT NOT NULL,sha256 TEXT "
                "NOT NULL)",
                "CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY, source TEXT NOT NULL, "
                "sha256 TEXT NOT NULL, page INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, "
                "width REAL NOT NULL, height REAL NOT NULL, image TEXT NOT NULL, created_at TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS text_captures (capture_id TEXT PRIMARY KEY, text TEXT NOT NULL, "
                "start_index INTEGER NOT NULL, end_index INTEGER NOT NULL, prefix TEXT NOT NULL, suffix TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS capture_notes (capture_id TEXT PRIMARY KEY, body TEXT NOT NULL, updated_at "
                "TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS highlights (id TEXT PRIMARY KEY, source TEXT NOT NULL, sha256 TEXT NOT "
                "NULL, "
                "page INTEGER NOT NULL,text TEXT NOT NULL,rectangles TEXT NOT NULL,start_index INTEGER NOT NULL, "
                "end_index INTEGER NOT NULL,created_at TEXT NOT NULL,deleted_at TEXT)",
                "CREATE INDEX IF NOT EXISTS highlights_source ON highlights(source)"},
            [](QSqlDatabase &db, QString *error) {
                // Annotation columns were added before versioning; add only the ones an older file lacks.
                QSet<QString> present;
                QSqlQuery columns(db);
                if (!columns.exec("PRAGMA table_info(highlights)")) {
                    *error = columns.lastError().text();
                    return false;
                }
                while (columns.next()) present.insert(columns.value(1).toString());
                columns.finish();
                const QList<QPair<QString, QString>> additions{
                    {"color",
                        QStringLiteral("TEXT NOT NULL DEFAULT '%1'").arg(ResearchStore::defaultAnnotationColor())},
                    {"kind", "TEXT NOT NULL DEFAULT 'highlight'"}, {"body", "TEXT NOT NULL DEFAULT ''"},
                    {"image", "TEXT NOT NULL DEFAULT ''"}, {"drawing", "TEXT NOT NULL DEFAULT '[]'"}};
                for (const auto &column : additions) {
                    if (present.contains(column.first)) continue;
                    QSqlQuery change(db);
                    if (!change.exec("ALTER TABLE highlights ADD COLUMN " + column.first + " " + column.second)) {
                        *error = change.lastError().text();
                        return false;
                    }
                }
                return true;
            }},
        {2,
            {// Search and capture lists filter by these columns on every query.
                "CREATE INDEX IF NOT EXISTS highlights_live ON highlights(deleted_at, created_at)",
                "CREATE INDEX IF NOT EXISTS captures_source ON captures(source)"}},
        // Saved data moves from file URLs to document IDs; the file is backed up first.
        {3, {}, [](QSqlDatabase &db, QString *error) { return adoptDocumentIds(db, error); }, true},
        {4,
            {"ALTER TABLE documents ADD COLUMN reading_state TEXT NOT NULL DEFAULT 'unread'",
                "ALTER TABLE documents ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE documents ADD COLUMN sha256 TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE documents ADD COLUMN duplicate_ack TEXT NOT NULL DEFAULT ''",
                // Papers opened before reading states existed are already being read.
                "UPDATE documents SET reading_state='reading' WHERE id IN "
                "(SELECT document_id FROM recent_documents UNION SELECT document_id FROM reading_positions)",
                "UPDATE documents SET sha256=metadata_sha256", "CREATE INDEX documents_sha256 ON documents(sha256)"},
            {}, true},
        {5,
            {"CREATE TABLE collections (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, created_at TEXT NOT "
             "NULL)",
                "CREATE TABLE collection_documents (collection_id TEXT NOT NULL, document_id TEXT NOT NULL, "
                "PRIMARY KEY(collection_id,document_id))",
                "CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE)",
                "CREATE TABLE document_tags (document_id TEXT NOT NULL, tag_id TEXT NOT NULL, PRIMARY "
                "KEY(document_id,tag_id))",
                "ALTER TABLE documents ADD COLUMN excluded_from_index INTEGER NOT NULL DEFAULT 0"},
            {}, true},
        {6,
            {"CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT "
             "NULL, "
             "updated_at TEXT NOT NULL, deleted_at TEXT)",
                // Directed links between knowledge objects: note, capture, highlight, document, ai.
                "CREATE TABLE links (from_kind TEXT NOT NULL, from_id TEXT NOT NULL, to_kind TEXT NOT NULL, "
                "to_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(from_kind,from_id,to_kind,to_id))",
                "CREATE INDEX links_target ON links(to_kind,to_id)",
                "ALTER TABLE captures ADD COLUMN caption TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE captures ADD COLUMN anchor_kind TEXT NOT NULL DEFAULT 'pdf'"},
            {}, true},
        // Web pages become documents only when something is saved from them (web captures).
        {7, {"ALTER TABLE documents ADD COLUMN kind TEXT NOT NULL DEFAULT 'pdf'"}, {}, true},
        // Saved AI answers are knowledge objects: searchable, linkable, never sent anywhere again.
        {8,
            {"CREATE TABLE ai_responses (id TEXT PRIMARY KEY, provider TEXT NOT NULL, model TEXT NOT NULL, "
             "prompt TEXT NOT NULL, answer TEXT NOT NULL, context_json TEXT NOT NULL, created_at TEXT NOT NULL)"},
            {}, true},
        // Conversations: each thread keeps its turns so follow-up questions carry the earlier ones.
        {9,
            {"CREATE TABLE ai_threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, provider TEXT NOT NULL, model TEXT "
             "NOT NULL, "
             "source TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
                // content is exactly what was sent (with attached material); display is what the reader typed.
                "CREATE TABLE ai_messages (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL, content "
                "TEXT NOT NULL, "
                "display TEXT NOT NULL, context_json TEXT NOT NULL, model TEXT NOT NULL, created_at TEXT NOT NULL)",
                "CREATE INDEX ai_messages_thread ON ai_messages(thread_id, created_at)",
                // Saved answers become one-turn threads with the same ID, so existing links keep working.
                "INSERT INTO ai_threads SELECT "
                "id,prompt,provider,model,coalesce(json_extract(context_json,'$.source'),''),"
                "created_at,created_at FROM ai_responses",
                "INSERT INTO ai_messages SELECT id || "
                "'-q',id,'user',coalesce(json_extract(context_json,'$.prompt'),prompt),"
                "coalesce(nullif(json_extract(context_json,'$.question'),''),prompt),context_json,model,created_at "
                "FROM ai_responses",
                "INSERT INTO ai_messages SELECT id || '-a',id,'assistant',answer,'','{}',model,"
                "strftime('%Y-%m-%dT%H:%M:%f',created_at,'+0.001 seconds') || 'Z' FROM ai_responses"},
            {}, true},
        // Papers removed from the Library are hidden, not deleted: opening the file again restores them
        // with their annotations and captures.
        {10, {"ALTER TABLE documents ADD COLUMN removed_at TEXT"}},
        // A text box's font size in PDF points (0: older boxes, drawn at the former 14 pt).
        {11, {"ALTER TABLE highlights ADD COLUMN font_size REAL NOT NULL DEFAULT 0"}},
    };
    if (!migrateSchema(m_database, steps, error, m_directory + "/backups")) return false;
    loadDocumentNames();
    reloadCaptures();
    QSqlQuery links(m_database);
    links.exec("SELECT old_url,new_url FROM source_relinks");
    while (links.next()) m_relinks.insert(links.value(0).toString(), links.value(1).toString());
    // The search cache adopts the same document IDs, so a result names the same paper everywhere.
    m_index->setDocumentResolver([this](const QUrl &url) { return ensureDocument(url); });
    m_index->setExclusionCheck([this](const QUrl &url) { return excludedFromIndex(url); });
    PdfAccess::setKeyDirectory(m_directory);
    if (!m_index->initialize(error)) return false;
    // Meaning search follows changes to indexed text and saved items, only while it is turned on.
    m_semantic = new SemanticIndex(this, m_index, m_directory, this);
    for (const auto signal : {&ResearchStore::notesChanged, &ResearchStore::highlightsChanged,
             &ResearchStore::capturesChanged, &ResearchStore::aiThreadsChanged})
        connect(this, signal, m_semantic, &SemanticIndex::sync);
    connect(m_index, &PaperIndex::contentsChanged, m_semantic, &SemanticIndex::sync);
    m_semantic->sync();
    configureOcr();
    markRunning();
    scheduleAutomaticBackup();
    m_sync->start();
    // Durable redirects also replay any search-cache update interrupted by process exit.
    for (auto it = m_relinks.cbegin(); it != m_relinks.cend(); ++it)
        m_index->relocateSource(QUrl(it.key()), resolvedSource(QUrl(it.value())));
    QSqlQuery known(m_database);
    known.exec("SELECT id,url,metadata_origin FROM documents WHERE removed_at IS NULL");
    while (known.next()) {
        const QUrl url(known.value(1).toString());
        m_index->enqueue(url);
        // Details are read once per file version; unread documents catch up in the background.
        if (known.value(2).toString().isEmpty()) refreshMetadata(known.value(0).toString(), url, false);
    }
    return true;
}

QVariantMap ResearchStore::session() const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT value FROM settings WHERE key='session'");
    if (!query.exec() || !query.next()) return {};
    const auto json = QJsonDocument::fromJson(query.value(0).toByteArray());
    return json.object().toVariantMap();
}

bool ResearchStore::saveSession(const QVariantMap &input)
{
    const auto state = canonicalState(input);
    if (!m_database.transaction()) {
        emit message(tr("Cannot begin saving reading state."));
        return false;
    }
    const QByteArray json = QJsonDocument(QJsonObject::fromVariantMap(state)).toJson(QJsonDocument::Compact);
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES('session',?)");
    query.addBindValue(QString::fromUtf8(json));
    if (!query.exec()) {
        m_database.rollback();
        emit message(tr("Cannot save reading position: %1").arg(query.lastError().text()));
        return false;
    }
    for (const auto &value : readers(state)) {
        const auto reader = value.toMap();
        const auto source = QUrl(reader.value("source").toString());
        if (!source.isLocalFile()) continue;
        const auto document = ensureDocument(source);
        if (document.isEmpty()) continue;
        QSqlQuery position(m_database);
        position.prepare("INSERT OR REPLACE INTO reading_positions(document_id,position) VALUES(?,?)");
        position.addBindValue(document);
        position.addBindValue(
            QString::fromUtf8(QJsonDocument::fromVariant(reader.value("position")).toJson(QJsonDocument::Compact)));
        if (!position.exec()) {
            m_database.rollback();
            emit message(tr("Cannot save document position: %1").arg(position.lastError().text()));
            return false;
        }
    }
    if (!m_database.commit()) {
        m_database.rollback();
        emit message(tr("Cannot save reading state."));
        return false;
    }
    emit homeChanged();
    emit recentDocumentsChanged();
    return true;
}

QString ResearchStore::fileName(const QUrl &url) const
{
    return QFileInfo(url.toLocalFile()).fileName();
}

bool ResearchStore::rememberDocument(const QUrl &url)
{
    const QFileInfo info(url.toLocalFile());
    if (!url.isLocalFile() || !info.isFile() || !info.isReadable()) {
        emit message(tr("Cannot open this file. Check its location and permissions."));
        if (url.isLocalFile()) emit relinkRequested(resolvedSource(url));
        return false;
    }
    const auto document = ensureDocument(url);
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO recent_documents(document_id,opened_at) VALUES(?,?)");
    query.addBindValue(document);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (document.isEmpty() || !query.exec()) {
        emit message(tr("Cannot record this document: %1").arg(query.lastError().text()));
        return false;
    }
    QSqlQuery restore(m_database);
    restore.prepare("UPDATE documents SET removed_at=NULL WHERE id=? AND removed_at IS NOT NULL");
    restore.addBindValue(document);
    if (restore.exec() && restore.numRowsAffected() > 0) announceDocumentsChanged();
    QSqlQuery reading(m_database);
    reading.prepare("UPDATE documents SET reading_state='reading' WHERE id=? AND reading_state='unread'");
    reading.addBindValue(document);
    reading.exec();
    refreshMetadata(document, resolvedSource(url), false, true);
    emit recentDocumentsChanged();
    emit homeChanged();
    m_index->enqueue(url);
    return true;
}

QVariantList ResearchStore::recentDocuments() const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec("SELECT d.url,d.reading_state,d.favorite,d.authors,d.year FROM recent_documents r JOIN documents d ON "
               "d.id=r.document_id "
               "ORDER BY r.opened_at DESC LIMIT 12");
    while (query.next()) {
        const auto url = QUrl(query.value(0).toString());
        results.append(QVariantMap{{"url", url}, {"name", displayName(url)}, {"fileName", fileName(url)},
            {"position", readingPosition(url)}, {"readingState", query.value(1)}, {"favorite", query.value(2).toBool()},
            {"authors", query.value(3).toString()}, {"year", query.value(4).toString()}});
    }
    return results;
}

QVariantList ResearchStore::readCaptures(bool trashed) const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec(QStringLiteral(
        "SELECT "
        "c.id,doc.url,c.page,c.image,c.created_at,t.text,t.capture_id,n.body,n.updated_at,d.deleted_at,c.caption,"
        "c.anchor_kind "
        "FROM captures c LEFT JOIN documents doc ON doc.id=c.document_id "
        "LEFT JOIN text_captures t ON t.capture_id=c.id "
        "LEFT JOIN capture_notes n ON n.capture_id=c.id "
        "LEFT JOIN deleted_captures d ON d.id=c.id WHERE d.id IS %1 NULL "
        "ORDER BY %2 DESC,c.id DESC")
            .arg(trashed ? "NOT" : "", trashed ? "d.deleted_at" : "c.created_at"));
    while (query.next()) {
        const auto url = QUrl(query.value(1).toString());
        const auto image = query.value(3).toString();
        // Never expose arbitrary stored paths to an image loader, including the trash preview.
        const auto imagePath = !QUuid(query.value(0).toString()).isNull() && image == query.value(0).toString() + ".png"
            ? m_directory + (trashed ? "/captures/trash/" : "/captures/") + image
            : QString();
        results.append(
            QVariantMap{{"id", query.value(0)}, {"source", url}, {"name", displayName(url)}, {"page", query.value(2)},
                {"kind",
                    query.value(11).toString() == "web" ? "web"
                        : query.value(6).isNull()       ? "region"
                                                        : "text"},
                {"text", query.value(5).toString()}, {"note", query.value(7).toString()},
                {"noteUpdatedAt", query.value(8).toString()},
                {"image", imagePath.isEmpty() ? QUrl() : QUrl::fromLocalFile(imagePath)},
                {"imageAvailable",
                    !imagePath.isEmpty() && QFileInfo(imagePath).isFile() && !QFileInfo(imagePath).isSymLink()},
                {"createdAt", query.value(4)}, {"deletedAt", query.value(9)}, {"caption", query.value(10).toString()}});
    }
    return results;
}

void ResearchStore::reloadCaptures()
{
    m_captures = readCaptures(false);
    m_trashedCaptures = readCaptures(true);
    emit capturesChanged();
    emit homeChanged();
}

// Rows from another computer: in-memory lists are read again and the views told.
void ResearchStore::syncReceived(const QSet<QString> &tables, const QStringList &sources)
{
    loadDocumentNames();
    for (const auto &source : sources) m_index->enqueue(QUrl(source));
    announceDocumentsChanged(); // Captures, recent papers and Home too.
    const auto touched = [&](std::initializer_list<const char *> names) {
        return std::any_of(names.begin(), names.end(), [&](const char *name) { return tables.contains(name); });
    };
    if (touched({"highlights"})) emit highlightsChanged();
    if (touched({"notes", "links"})) {
        emit notesChanged();
        emit linksChanged();
    }
    if (touched({"ai_threads", "ai_messages", "ai_responses"})) emit aiThreadsChanged();
}

bool ResearchStore::saveCaptureNote(const QString &id, const QString &body)
{
    if (body.size() > 10000) {
        emit message("Notes can contain up to 10,000 characters.");
        return false;
    }
    QSqlQuery query(m_database);
    // One statement: never attach a note to a missing or trashed capture.
    query.prepare("INSERT INTO capture_notes(capture_id,body,updated_at) "
                  "SELECT id,?,? FROM captures WHERE id=? AND id NOT IN (SELECT id FROM deleted_captures) "
                  "ON CONFLICT(capture_id) DO UPDATE SET body=excluded.body,updated_at=excluded.updated_at");
    query.addBindValue(body.trimmed().isEmpty() ? QStringLiteral("") : body);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) {
        emit message("Cannot save note. Check storage and whether this capture still exists.");
        return false;
    }
    reloadCaptures();
    return true;
}

QVariantMap ResearchStore::readingPosition(const QUrl &source) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT r.position FROM reading_positions r JOIN documents d ON d.id=r.document_id WHERE d.url=?");
    query.addBindValue(resolvedSource(source).toString());
    if (!query.exec() || !query.next()) return {};
    return QJsonDocument::fromJson(query.value(0).toByteArray()).object().toVariantMap();
}

QVariantMap ResearchStore::continueReading() const
{
    const auto state = session();
    if (state.value("version").toInt() == 2) {
        auto tab = activeTab(state.value("tree").toMap(), state.value("activeGroup").toString());
        if (!QUrl(tab.value("source").toString()).isLocalFile()) {
            const auto all = readers(state);
            for (auto it = all.crbegin(); it != all.crend(); ++it) {
                if (QUrl(it->toMap().value("source").toString()).isLocalFile()) {
                    tab = it->toMap();
                    break;
                }
            }
        }
        const QUrl source(tab.value("source").toString());
        if (!source.isLocalFile()) return {};
        tab.insert("name", displayName(source));
        return tab;
    }
    const QString preferred = state.value("active").toInt() == 1 && state.value("split").toBool() ? "right" : "left";
    auto reader = state.value(preferred).toMap();
    if (reader.value("source").toString().isEmpty())
        reader = state.value(preferred == "left" ? "right" : "left").toMap();
    const QUrl source(reader.value("source").toString());
    if (!source.isLocalFile()) return {};
    reader.insert("name", displayName(source));
    return reader;
}

QVariantList ResearchStore::recentWorkspaces() const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec(
        "SELECT w.id,w.name,(SELECT count(*) FROM workspace_documents d WHERE d.workspace_id=w.id) "
        "FROM workspaces w WHERE w.id NOT IN (SELECT id FROM deleted_workspaces) ORDER BY w.opened_at DESC LIMIT 12");
    while (query.next())
        results.append(QVariantMap{{"id", query.value(0)}, {"name", query.value(1)}, {"papers", query.value(2)}});
    return results;
}

QString ResearchStore::createWorkspace(const QString &name)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty() || trimmed.size() > 120) {
        emit message(tr("Enter a workspace name (1–120 characters)."));
        return {};
    }
    const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO workspaces VALUES(?,?,?,?)");
    query.addBindValue(id);
    query.addBindValue(trimmed);
    query.addBindValue("{}");
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!query.exec()) {
        emit message(query.lastError().text());
        return {};
    }
    emit homeChanged();
    return id;
}

QVariantMap ResearchStore::loadWorkspace(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT name,state FROM workspaces WHERE id=? AND id NOT IN (SELECT id FROM deleted_workspaces)");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) {
        emit message(tr("Workspace not found."));
        return {};
    }
    auto state = QJsonDocument::fromJson(query.value(1).toByteArray()).object().toVariantMap();
    state.insert("workspace", id);
    state.insert("workspaceName", query.value(0));
    QSqlQuery touch(m_database);
    touch.prepare("UPDATE workspaces SET opened_at=? WHERE id=?");
    touch.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    touch.addBindValue(id);
    touch.exec();
    emit homeChanged();
    return state;
}

bool ResearchStore::saveWorkspace(const QString &id, const QVariantMap &input)
{
    const auto state = canonicalState(input);
    if (id.isEmpty()) return true;
    if (!m_database.transaction()) {
        emit message(tr("Cannot begin saving workspace."));
        return false;
    }
    QSqlQuery query(m_database);
    query.prepare("UPDATE workspaces SET state=? WHERE id=? AND id NOT IN (SELECT id FROM deleted_workspaces)");
    query.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(state).toJson(QJsonDocument::Compact)));
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) {
        m_database.rollback();
        emit message(tr("Cannot save this workspace."));
        return false;
    }
    for (const auto &value : readers(state)) {
        const auto source = ensureDocument(QUrl(value.toMap().value("source").toString()));
        if (source.isEmpty()) continue;
        QSqlQuery link(m_database);
        link.prepare("INSERT OR IGNORE INTO workspace_documents(workspace_id,document_id) SELECT ?,? WHERE NOT EXISTS "
                     "(SELECT 1 FROM workspace_document_exclusions WHERE workspace_id=? AND document_id=?)");
        link.addBindValue(id);
        link.addBindValue(source);
        link.addBindValue(id);
        link.addBindValue(source);
        if (!link.exec()) {
            m_database.rollback();
            emit message(link.lastError().text());
            return false;
        }
    }
    if (!m_database.commit()) {
        m_database.rollback();
        emit message(tr("Cannot save workspace."));
        return false;
    }
    emit homeChanged();
    return true;
}

void ResearchStore::captureRegion(const QUrl &source, int page, const QRectF &requested)
{
    if (m_relinking) {
        emit message("Please wait until source verification finishes before capturing.");
        return;
    }
    if (!source.isLocalFile() || page < 0 || !std::isfinite(requested.x()) || !std::isfinite(requested.y())
        || !std::isfinite(requested.width()) || !std::isfinite(requested.height())) {
        emit message(tr("Invalid capture region."));
        return;
    }
    const QRectF region = requested.normalized().intersected(QRectF(0, 0, 1, 1));
    if (region.width() < .002 || region.height() < .002) {
        emit message(tr("Select a larger region."));
        return;
    }
    if (m_pending >= 4) {
        emit message(tr("Saving captures. Please try again shortly."));
        return;
    }
    ++m_pending;
    emit busyChanged();
    const QString directory = m_directory;
    auto *watcher = new QFutureWatcher<CaptureResult>(this);
    connect(watcher, &QFutureWatcher<CaptureResult>::finished, this, [this, watcher] {
        const CaptureResult result = watcher->result();
        watcher->deleteLater();
        --m_pending;
        emit busyChanged();
        if (!result.error.isEmpty()) {
            emit message(result.error);
            return;
        }
        const auto document = ensureDocument(result.source);
        QSqlQuery query(m_database);
        query.prepare("INSERT INTO captures(id,document_id,sha256,page,x,y,width,height,image,created_at,caption) "
                      "VALUES(?,?,?,?,?,?,?,?,?,?,?)");
        query.addBindValue(result.id);
        query.addBindValue(document);
        query.addBindValue(result.hash);
        query.addBindValue(result.page);
        query.addBindValue(result.region.x());
        query.addBindValue(result.region.y());
        query.addBindValue(result.region.width());
        query.addBindValue(result.region.height());
        query.addBindValue(QFileInfo(result.path).fileName());
        query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        query.addBindValue(result.caption.isNull() ? QStringLiteral("") : result.caption);
        if (document.isEmpty() || !query.exec()) {
            emit message(tr("Image saved, but source metadata could not be recorded: %1").arg(result.path));
            return;
        }
        reloadCaptures();
        emit captureSaved(result.id);
        emit message(tr("Capture and source location saved."));
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, page, region, directory] {
        CaptureResult result;
        result.source = source;
        result.page = page;
        result.region = region;
        const QString path = source.toLocalFile();
        const QFileInfo before(path);
        result.hash = fingerprint(path);
        QPdfDocument document;
        if (result.hash.isEmpty() || PdfAccess::load(document, path) != QPdfDocument::Error::None
            || page >= document.pageCount()) {
            result.error = tr("Cannot read the source PDF for this capture.");
            return result;
        }
        const QSizeF points = document.pagePointSize(page);
        const qreal scale = std::min(2.0, 4096.0 / std::max(points.width(), points.height()));
        const QSize pixels(qMax(1, qRound(points.width() * scale)), qMax(1, qRound(points.height() * scale)));
        const QImage rendered = document.render(page, pixels);
        if (rendered.isNull()) {
            result.error = tr("Cannot render this PDF page.");
            return result;
        }
        const QRect crop = QRectF(region.x() * pixels.width(), region.y() * pixels.height(),
            region.width() * pixels.width(), region.height() * pixels.height())
                               .toAlignedRect()
                               .intersected(rendered.rect());
        result.caption = ResearchStore::figureCaption(document, page, region);
        const QFileInfo after(path);
        if (before.size() != after.size() || before.lastModified() != after.lastModified()) {
            result.error = tr("The source PDF changed during capture. Please reopen it.");
            return result;
        }
        result.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        result.path = directory + "/captures/" + result.id + ".png";
        QSaveFile file(result.path);
        if (!file.open(QIODevice::WriteOnly) || !rendered.copy(crop).save(&file, "PNG") || !file.commit())
            result.error = tr("Cannot save capture image. Check storage and permissions.");
        return result;
    }));
}

void ResearchStore::captureWebImage(
    const QUrl &page, const QString &title, const QImage &image, const QRectF &requested)
{
    if (page.scheme() != "http" && page.scheme() != "https") {
        emit message(tr("Only web pages can be captured this way."));
        return;
    }
    const QRectF region = requested.normalized().intersected(QRectF(0, 0, 1, 1));
    if (image.isNull() || region.width() < .002 || region.height() < .002) {
        emit message(tr("Select a larger region."));
        return;
    }
    const auto document = ensureWebDocument(page, title);
    if (document.isEmpty()) {
        emit message(tr("Cannot record this web page."));
        return;
    }
    ++m_pending;
    emit busyChanged();
    const QString directory = m_directory;
    auto *watcher = new QFutureWatcher<CaptureResult>(this);
    connect(watcher, &QFutureWatcher<CaptureResult>::finished, this, [this, watcher, document] {
        const auto result = watcher->result();
        watcher->deleteLater();
        --m_pending;
        emit busyChanged();
        if (!result.error.isEmpty()) {
            emit message(result.error);
            return;
        }
        QSqlQuery query(m_database);
        query.prepare("INSERT INTO captures(id,document_id,sha256,page,x,y,width,height,image,created_at,anchor_kind) "
                      "VALUES(?,?,'',0,?,?,?,?,?,?,'web')");
        query.addBindValue(result.id);
        query.addBindValue(document);
        query.addBindValue(result.region.x());
        query.addBindValue(result.region.y());
        query.addBindValue(result.region.width());
        query.addBindValue(result.region.height());
        query.addBindValue(QFileInfo(result.path).fileName());
        query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        if (!query.exec()) {
            emit message(tr("Image saved, but the capture could not be recorded: %1").arg(result.path));
            return;
        }
        reloadCaptures();
        emit captureSaved(result.id);
        emit message(tr("Web capture saved with its page address."));
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [image, region, directory] {
        CaptureResult result;
        result.region = region;
        const QRect crop = QRectF(region.x() * image.width(), region.y() * image.height(),
            region.width() * image.width(), region.height() * image.height())
                               .toAlignedRect()
                               .intersected(image.rect());
        result.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        result.path = directory + "/captures/" + result.id + ".png";
        QSaveFile file(result.path);
        if (crop.isEmpty() || !file.open(QIODevice::WriteOnly) || !image.copy(crop).save(&file, "PNG")
            || !file.commit())
            result.error = tr("Cannot save capture image. Check storage and permissions.");
        return result;
    }));
}

QString ResearchStore::figureCaption(QPdfDocument &document, int page, const QRectF &region)
{
    // A figure's caption usually sits just below it and a table's just above: take the nearest line within
    // 12% of the page that starts with "Figure/Fig./Table N", plus up to two following lines of the caption.
    const auto size = document.pagePointSize(page);
    if (size.isEmpty()) return {};
    SelectionGeometry geometry;
    QList<QRectF> lines;
    for (const auto &value : geometry.lineRectangles(document.getAllText(page).bounds())) lines << value.toRectF();
    const QRectF area(region.x() * size.width(), region.y() * size.height(), region.width() * size.width(),
        region.height() * size.height());
    static const QRegularExpression label(
        "^(fig(ure|\\.)?|table|tab\\.)\\s*[0-9IVX]+", QRegularExpression::CaseInsensitiveOption);
    const auto textOf = [&](const QRectF &line) {
        const qreal middle = line.center().y();
        return document.getSelection(page, QPointF(line.left() + .5, middle), QPointF(line.right() - .5, middle))
            .text()
            .simplified();
    };
    qreal best = size.height() * .12;
    qsizetype found = -1;
    for (qsizetype i = 0; i < lines.size(); ++i) {
        const auto &line = lines[i];
        if (line.right() < area.left() - 20 || line.left() > area.right() + 20) continue;
        const qreal below = line.top() - area.bottom(), above = area.top() - line.bottom();
        const qreal distance = below >= -2 ? below : above >= -2 ? above : -1;
        if (distance < 0 || distance > best) continue;
        if (!textOf(line).contains(label)) continue;
        best = distance;
        found = i;
    }
    if (found < 0) return {};
    QStringList parts{textOf(lines[found])};
    for (qsizetype i = found + 1; i < lines.size() && parts.size() < 3; ++i) {
        if (lines[i].top() - lines[i - 1].bottom() > lines[i - 1].height()) break;
        if (lines[i].right() < area.left() - 20 || lines[i].left() > area.right() + 20) continue;
        parts << textOf(lines[i]);
    }
    return parts.join(' ').left(600);
}

void ResearchStore::captureTextSegments(const QUrl &source, const QVariantList &segments)
{
    // One excerpt spanning pages: every page's part is verified against the PDF like a one-page excerpt.
    if (segments.isEmpty() || segments.size() > 50) {
        emit message("Select text in a PDF before saving an excerpt.");
        return;
    }
    if (segments.size() == 1) {
        const auto one = segments[0].toMap();
        captureText(source, one["page"].toInt(), one["from"].toPointF(), one["to"].toPointF(), one["text"].toString());
        return;
    }
    if (m_relinking || !source.isLocalFile() || m_pending >= 4) {
        emit message("Saving captures. Please try again shortly.");
        return;
    }
    ++m_pending;
    emit busyChanged();
    auto *watcher = new QFutureWatcher<TextCaptureResult>(this);
    connect(watcher, &QFutureWatcher<TextCaptureResult>::finished, this, [this, watcher] {
        const auto result = watcher->result();
        const auto &anchor = result.anchor;
        watcher->deleteLater();
        --m_pending;
        emit busyChanged();
        if (!anchor.error.isEmpty()) {
            emit message(anchor.error);
            return;
        }
        const auto document = ensureDocument(anchor.source);
        if (document.isEmpty() || !m_database.transaction()) {
            emit message("Cannot save excerpt. Check storage and permissions.");
            return;
        }
        QSqlQuery base(m_database);
        base.prepare("INSERT INTO captures(id,document_id,sha256,page,x,y,width,height,image,created_at) "
                     "VALUES(?,?,?,?,?,?,?,?,'',?)");
        base.addBindValue(anchor.id);
        base.addBindValue(document);
        base.addBindValue(anchor.hash);
        base.addBindValue(anchor.page);
        base.addBindValue(anchor.region.x());
        base.addBindValue(anchor.region.y());
        base.addBindValue(anchor.region.width());
        base.addBindValue(anchor.region.height());
        base.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        QSqlQuery quote(m_database);
        quote.prepare("INSERT INTO text_captures VALUES(?,?,?,?,'','')");
        quote.addBindValue(anchor.id);
        quote.addBindValue(result.text);
        quote.addBindValue(result.start);
        quote.addBindValue(result.end);
        if (!base.exec() || !quote.exec() || !m_database.commit()) {
            m_database.rollback();
            emit message("Cannot save excerpt and source location. Check storage and permissions.");
            return;
        }
        reloadCaptures();
        emit captureSaved(anchor.id);
        emit message("Text excerpt across pages saved with its source location.");
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, segments] {
        TextCaptureResult result;
        auto &anchor = result.anchor;
        anchor.source = source;
        const auto path = source.toLocalFile();
        anchor.hash = fingerprint(path);
        QPdfDocument document;
        if (anchor.hash.isEmpty() || PdfAccess::load(document, path) != QPdfDocument::Error::None) {
            anchor.error = "Cannot read the source PDF for this excerpt.";
            return result;
        }
        QStringList parts;
        for (qsizetype i = 0; i < segments.size(); ++i) {
            const auto segment = segments[i].toMap();
            const int page = segment["page"].toInt();
            if (page < 0 || page >= document.pageCount()) {
                anchor.error = "The selection could not be verified. Select the text again.";
                return result;
            }
            const auto selection = document.getSelection(page, segment["from"].toPointF(), segment["to"].toPointF());
            if (!selection.isValid() || selection.text() != segment["text"].toString()) {
                anchor.error = "The selection could not be verified. Reopen the PDF and select the text again.";
                return result;
            }
            parts << selection.text();
            if (i == 0) {
                // The excerpt is anchored where it starts.
                const auto size = document.pagePointSize(page);
                const auto rect = selection.boundingRectangle();
                anchor.page = page;
                anchor.region = QRectF(rect.x() / size.width(), rect.y() / size.height(), rect.width() / size.width(),
                    rect.height() / size.height())
                                    .intersected(QRectF(0, 0, 1, 1));
                result.start = selection.startIndex();
                result.end = selection.endIndex();
            }
        }
        result.text = parts.join("\n");
        if (anchor.region.isEmpty() || fingerprint(path) != anchor.hash) {
            anchor.error = "The source PDF changed during capture. Please reopen it.";
            return result;
        }
        anchor.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        return result;
    }));
}

void ResearchStore::captureText(
    const QUrl &source, int page, const QPointF &from, const QPointF &to, const QString &expectedText)
{
    saveTextSelection(source, page, from, to, expectedText, false);
}

void ResearchStore::highlightText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, const QString &color)
{
    saveTextSelection(source, page, from, to, expectedText, true, color);
}

void ResearchStore::commentText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, const QString &body, const QString &color)
{
    if (body.trimmed().isEmpty() || body.size() > 10000) {
        emit message("Enter a comment (up to 10,000 characters).");
        emit annotationFinished(false, "");
        return;
    }
    saveTextSelection(source, page, from, to, expectedText, true, color, "comment", body);
}

void ResearchStore::saveTextSelection(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, bool asHighlight, const QString &color, const QString &kind, const QString &body)
{
    if (asHighlight && !annotationColors().contains(color)) {
        emit message("Choose a supported highlight color.");
        emit annotationFinished(false, "");
        return;
    }
    if (m_relinking) {
        emit message("Please wait until source verification finishes before capturing.");
        if (asHighlight) emit annotationFinished(false, "");
        return;
    }
    if (!source.isLocalFile() || page < 0 || expectedText.trimmed().isEmpty() || expectedText.size() > 100000
        || !std::isfinite(from.x()) || !std::isfinite(from.y()) || !std::isfinite(to.x()) || !std::isfinite(to.y())) {
        emit message("Select text in a PDF before saving an excerpt.");
        if (asHighlight) emit annotationFinished(false, "");
        return;
    }
    if (m_pending >= 4) {
        emit message("Saving captures. Please try again shortly.");
        if (asHighlight) emit annotationFinished(false, "");
        return;
    }
    ++m_pending;
    emit busyChanged();
    auto *watcher = new QFutureWatcher<TextCaptureResult>(this);
    connect(
        watcher, &QFutureWatcher<TextCaptureResult>::finished, this, [this, watcher, asHighlight, color, kind, body] {
            const auto result = watcher->result();
            const auto &anchor = result.anchor;
            watcher->deleteLater();
            --m_pending;
            emit busyChanged();
            if (!anchor.error.isEmpty()) {
                emit message(anchor.error);
                if (asHighlight) emit annotationFinished(false, "");
                return;
            }
            const auto document = ensureDocument(anchor.source);
            if (document.isEmpty()) {
                emit message("Cannot record the source document. Check storage and permissions.");
                if (asHighlight) emit annotationFinished(false, "");
                return;
            }
            if (asHighlight) {
                // Repeated clicks must not stack opaque copies of the same annotation.
                QSqlQuery existing(m_database);
                existing.prepare("SELECT id,body FROM highlights WHERE document_id=? AND sha256=? AND page=? AND "
                                 "start_index=? AND end_index=? AND kind=? AND deleted_at IS NULL");
                existing.addBindValue(document);
                existing.addBindValue(anchor.hash);
                existing.addBindValue(anchor.page);
                existing.addBindValue(result.start);
                existing.addBindValue(result.end);
                existing.addBindValue(kind);
                if (!existing.exec()) {
                    emit message("Cannot check existing highlights.");
                    emit annotationFinished(false, "");
                    return;
                }
                if (kind == "highlight" && existing.next()) {
                    const auto id = existing.value(0).toString();
                    const auto preservedBody = body.isNull() ? existing.value(1).toString() : body;
                    existing.finish();
                    const bool success = updateHighlight(id, color, preservedBody);
                    if (success) {
                        emit highlightSaved(id, anchor.source);
                        emit annotationSaved(id);
                    }
                    emit annotationFinished(success, id);
                    return;
                }
                QSqlQuery mark(m_database);
                mark.prepare("INSERT INTO "
                             "highlights(id,document_id,sha256,page,text,rectangles,start_index,end_index,created_at,"
                             "color,kind,body) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)");
                mark.addBindValue(anchor.id);
                mark.addBindValue(document);
                mark.addBindValue(anchor.hash);
                mark.addBindValue(anchor.page);
                mark.addBindValue(result.text);
                mark.addBindValue(
                    QString::fromUtf8(QJsonDocument::fromVariant(result.rectangles).toJson(QJsonDocument::Compact)));
                mark.addBindValue(result.start);
                mark.addBindValue(result.end);
                mark.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
                mark.addBindValue(color);
                mark.addBindValue(kind);
                mark.addBindValue(body.isNull() ? QStringLiteral("") : body);
                if (!mark.exec()) {
                    emit message("Cannot save annotation. Check storage and permissions.");
                    emit annotationFinished(false, "");
                    return;
                }
                recordAnnotation(anchor.id, {}, "");
                emit highlightsChanged();
                emit homeChanged();
                emit highlightSaved(anchor.id, anchor.source);
                emit annotationSaved(anchor.id);
                emit annotationFinished(true, anchor.id);
                emit message("Annotation saved. The original PDF was not modified.");
                return;
            }
            if (!m_database.transaction()) {
                emit message("Cannot save excerpt. Check storage and permissions.");
                return;
            }
            QSqlQuery base(m_database);
            base.prepare("INSERT INTO captures(id,document_id,sha256,page,x,y,width,height,image,created_at) "
                         "VALUES(?,?,?,?,?,?,?,?,?,?)");
            base.addBindValue(anchor.id);
            base.addBindValue(document);
            base.addBindValue(anchor.hash);
            base.addBindValue(anchor.page);
            base.addBindValue(anchor.region.x());
            base.addBindValue(anchor.region.y());
            base.addBindValue(anchor.region.width());
            base.addBindValue(anchor.region.height());
            base.addBindValue(QStringLiteral(""));
            base.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
            QSqlQuery quote(m_database);
            quote.prepare("INSERT INTO text_captures VALUES(?,?,?,?,?,?)");
            quote.addBindValue(anchor.id);
            quote.addBindValue(result.text);
            quote.addBindValue(result.start);
            quote.addBindValue(result.end);
            quote.addBindValue(result.prefix);
            quote.addBindValue(result.suffix);
            if (!base.exec() || !quote.exec() || !m_database.commit()) {
                m_database.rollback();
                emit message("Cannot save excerpt and source metadata. Check storage and permissions.");
                return;
            }
            reloadCaptures();
            emit captureSaved(anchor.id);
            emit message("Text excerpt and source location saved.");
        });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, page, from, to, expectedText, asHighlight] {
        TextCaptureResult result;
        auto &anchor = result.anchor;
        anchor.source = source;
        anchor.page = page;
        const auto path = source.toLocalFile();
        anchor.hash = fingerprint(path);
        QPdfDocument document;
        if (anchor.hash.isEmpty() || PdfAccess::load(document, path) != QPdfDocument::Error::None
            || page >= document.pageCount()) {
            anchor.error = "Cannot read the source PDF for this excerpt.";
            return result;
        }
        const auto selection = document.getSelection(page, from, to);
        const auto size = document.pagePointSize(page);
        if (!selection.isValid() || selection.text() != expectedText || size.isEmpty()
            || selection.boundingRectangle().isEmpty() || selection.startIndex() < 0
            || selection.endIndex() < selection.startIndex()) {
            anchor.error = "The selection could not be verified. Reopen the PDF and select the text again.";
            return result;
        }
        result.text = selection.text();
        result.start = selection.startIndex();
        result.end = selection.endIndex();
        if (asHighlight) {
            SelectionGeometry geometry;
            const auto lines = geometry.lineRectangles(document.getAllText(page).bounds());
            const auto rectangles = geometry.stableRectangles(selection.bounds(), lines);
            for (const auto &value : rectangles) {
                const auto r = value.toRectF().intersected(QRectF(QPointF(), size));
                if (!r.isEmpty())
                    result.rectangles.append(QVariantMap{{"x", r.x() / size.width()}, {"y", r.y() / size.height()},
                        {"width", r.width() / size.width()}, {"height", r.height() / size.height()}});
            }
            if (result.rectangles.isEmpty()) {
                anchor.error = "This selection has no highlight geometry.";
                return result;
            }
        }
        const auto all = document.getAllText(page).text();
        // Context is a fallback hint, never permission to jump to an unverified PDF version.
        result.prefix = QStringLiteral("");
        result.suffix = QStringLiteral("");
        // PDF character indices need not equal QString offsets for every encoding.
        // Keep context only when that mapping is demonstrably exact.
        if (result.start >= 0 && all.mid(result.start, result.text.size()) == result.text) {
            result.prefix += all.mid(qMax(0, result.start - 80), qMin(80, result.start));
            result.suffix += all.mid(result.start + result.text.size(), 80);
        }
        const auto rect = selection.boundingRectangle();
        anchor.region = QRectF(rect.x() / size.width(), rect.y() / size.height(), rect.width() / size.width(),
            rect.height() / size.height())
                            .intersected(QRectF(0, 0, 1, 1));
        if (anchor.region.isEmpty()) {
            anchor.error = "The selection has no usable source location. Select the text again.";
            return result;
        }
        if (fingerprint(path) != anchor.hash) {
            anchor.error = "The source PDF changed during capture. Please reopen it.";
            return result;
        }
        anchor.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        return result;
    }));
}

void ResearchStore::copyText(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
}

bool ResearchStore::removeRecentDocument(const QUrl &url)
{
    QSqlQuery query(m_database);
    query.prepare("DELETE FROM recent_documents WHERE document_id=?");
    query.addBindValue(findDocument(url));
    if (!query.exec()) {
        emit message(query.lastError().text());
        return false;
    }
    emit recentDocumentsChanged();
    emit homeChanged();
    emit message(tr("Removed from Recent Papers. The original PDF and open tabs were kept."));
    return true;
}

bool ResearchStore::deleteCapture(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT image,EXISTS(SELECT 1 FROM text_captures WHERE capture_id=captures.id) "
                  "FROM captures WHERE id=? AND id NOT IN (SELECT id FROM deleted_captures)");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return false;
    const QString image = query.value(0).toString();
    const bool textCapture = query.value(1).toBool();
    // Only an app-generated single PNG file may be moved, never an arbitrary stored path.
    if (QUuid(id).isNull() || (textCapture ? !image.isEmpty() : image != id + ".png")) {
        emit message(tr("Invalid capture image path."));
        return false;
    }
    const QString original = m_directory + "/captures/" + image;
    const QString archived = m_directory + "/captures/trash/" + image;
    if (!QDir().mkpath(m_directory + "/captures/trash") || !m_database.transaction()) {
        emit message(tr("Cannot prepare local capture trash. Check storage and permissions."));
        return false;
    }
    const bool exists = !textCapture && QFileInfo::exists(original);
    if (exists && !QFile::rename(original, archived)) {
        m_database.rollback();
        emit message(tr("Cannot move capture to local trash."));
        return false;
    }
    QSqlQuery mark(m_database);
    mark.prepare("INSERT INTO deleted_captures VALUES(?,?)");
    mark.addBindValue(id);
    mark.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!mark.exec() || !m_database.commit()) {
        m_database.rollback();
        if (exists) QFile::rename(archived, original);
        emit message(tr("Cannot delete capture."));
        return false;
    }
    reloadCaptures();
    recordCapture(id, true);
    emit message(tr("Capture moved to local trash. The source PDF was kept."));
    return true;
}

bool ResearchStore::restoreCapture(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT image,EXISTS(SELECT 1 FROM text_captures WHERE capture_id=captures.id) "
                  "FROM captures WHERE id=? AND id IN (SELECT id FROM deleted_captures)");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) {
        emit message(tr("This capture is no longer in trash."));
        return false;
    }
    const QString image = query.value(0).toString();
    const bool textCapture = query.value(1).toBool();
    query.finish();
    if (QUuid(id).isNull() || (textCapture ? !image.isEmpty() : image != id + ".png")) {
        emit message(tr("Invalid capture image path. Nothing was restored."));
        return false;
    }
    const QString original = m_directory + "/captures/" + image;
    const QString archived = m_directory + "/captures/trash/" + image;
    if (!textCapture) {
        const QFileInfo stored(archived), destination(original);
        if (!stored.isFile() || !stored.isReadable() || stored.isSymLink()) {
            emit message(
                tr("The capture image is missing or unreadable in local trash. The capture remains in trash."));
            return false;
        }
        if (destination.exists() || destination.isSymLink()) {
            emit message(tr("A file already exists at the restore location. Nothing was overwritten; the capture "
                            "remains in trash."));
            return false;
        }
    }
    if (!m_database.transaction()) {
        emit message(tr("Cannot start capture restore. Please try again."));
        return false;
    }
    if (!textCapture && !QFile::rename(archived, original)) {
        m_database.rollback();
        emit message(tr("Cannot restore the capture image. Check storage and permissions."));
        return false;
    }
    QSqlQuery unmark(m_database);
    unmark.prepare("DELETE FROM deleted_captures WHERE id=?");
    unmark.addBindValue(id);
    if (!unmark.exec() || unmark.numRowsAffected() != 1 || !m_database.commit()) {
        m_database.rollback();
        if (!textCapture && !QFile::rename(original, archived)) {
            emit message(tr("Restore failed and the image could not be returned to trash. It is preserved at %1. "
                            "Please keep it for recovery.")
                    .arg(original));
        } else {
            emit message(tr("Cannot restore capture. It remains in local trash."));
        }
        return false;
    }
    // Only remove the deletion marker; original anchors, notes and workspace links stay intact.
    reloadCaptures();
    recordCapture(id, false);
    emit message(tr("Capture restored with its note and workspace links."));
    return true;
}

QString ResearchStore::setting(const QString &key, const QString &fallback) const
{
    if (key == "session") return fallback; // The session has its own API.
    QSqlQuery query(m_database);
    query.prepare("SELECT value FROM settings WHERE key=?");
    query.addBindValue("pref." + key);
    return query.exec() && query.next() ? query.value(0).toString() : fallback;
}

bool ResearchStore::setSetting(const QString &key, const QString &value)
{
    if (key.isEmpty() || key.size() > 64 || value.size() > 4096) return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)");
    query.addBindValue("pref." + key);
    query.addBindValue(value.isNull() ? QStringLiteral("") : value);
    if (!query.exec()) return false;
    emit settingsChanged();
    return true;
}

QVariantMap ResearchStore::downloadTarget(const QString &suggestedName, bool pdf) const
{
    auto directory = setting("downloadFolder");
    if (directory.isEmpty() || !QFileInfo(directory).isDir())
        directory = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (pdf && keepsPdfs() && QDir().mkpath(papersFolder())) directory = papersFolder();
    // Keep only a plain file name; never let a server choose the folder.
    auto name = QFileInfo(suggestedName).fileName().remove(QRegularExpression("[\\x00-\\x1f/\\\\:]")).trimmed();
    if (name.isEmpty() || name.startsWith('.')) name = "download.pdf";
    const QFileInfo base(name);
    const auto stem = base.completeBaseName(), suffix = base.suffix().isEmpty() ? QString() : "." + base.suffix();
    for (int n = 1; QFileInfo::exists(directory + "/" + name) && n < 1000; ++n)
        name = QStringLiteral("%1 (%2)%3").arg(stem).arg(n).arg(suffix);
    return {{"directory", directory}, {"fileName", name}, {"url", QUrl::fromLocalFile(directory + "/" + name)}};
}

bool ResearchStore::purgeCapture(const QString &id)
{
    return purgeTrashedCaptures({id}) == 1;
}

int ResearchStore::emptyCaptureTrash()
{
    QStringList ids;
    for (const auto &entry : m_trashedCaptures) ids.append(entry.toMap().value("id").toString());
    return ids.isEmpty() ? 0 : purgeTrashedCaptures(ids);
}

int ResearchStore::purgeTrashedCaptures(const QStringList &ids)
{
    // Rows go first in one transaction; image files are removed only after the commit, so a failure
    // can at worst leave an unreferenced PNG behind, never a capture whose image is gone.
    if (!m_database.transaction()) {
        emit message(tr("Cannot start deleting from trash. Please try again."));
        return 0;
    }
    QStringList images;
    const auto fail = [this] {
        m_database.rollback();
        emit message(tr("Cannot delete from trash. Nothing was removed."));
        return 0;
    };
    for (const auto &id : ids) {
        QSqlQuery query(m_database);
        query.prepare("SELECT c.image FROM captures c JOIN deleted_captures d ON d.id=c.id WHERE c.id=?");
        query.addBindValue(id);
        if (QUuid(id).isNull() || !query.exec() || !query.next()) return fail();
        const auto image = query.value(0).toString();
        query.finish();
        // Only an app-generated PNG named after the capture may be deleted.
        if (!image.isEmpty() && image != id + ".png") return fail();
        if (!image.isEmpty()) images.append(m_directory + "/captures/trash/" + image);
        for (const auto *sql : {"DELETE FROM workspace_captures WHERE capture_id=?",
                 "DELETE FROM capture_notes WHERE capture_id=?", "DELETE FROM text_captures WHERE capture_id=?",
                 "DELETE FROM captures WHERE id=?", "DELETE FROM deleted_captures WHERE id=?"}) {
            QSqlQuery remove(m_database);
            remove.prepare(sql);
            remove.addBindValue(id);
            if (!remove.exec()) return fail();
        }
    }
    if (!m_database.commit()) return fail();
    int leftover = 0;
    for (const auto &path : images) {
        const QFileInfo file(path);
        if (file.exists() && (file.isSymLink() || !QFile::remove(path))) ++leftover;
    }
    reloadCaptures();
    emit message(leftover
            ? tr("Deleted permanently. %1 image file(s) could not be removed from local trash.").arg(leftover)
            : ids.size() == 1 ? tr("Capture deleted permanently. The original PDF was kept.")
                              : tr("Trash emptied. The original PDFs were kept."));
    return ids.size();
}

int ResearchStore::listFolder(const QUrl &folder)
{
    struct Result {
        QVariantList entries;
        QString error;
    };
    const int requestId = ++m_folderRequest;
    auto *watcher = new QFutureWatcher<Result>(this);
    connect(watcher, &QFutureWatcher<Result>::finished, this, [this, watcher, folder, requestId] {
        const auto result = watcher->result();
        watcher->deleteLater();
        emit folderLoaded(requestId, folder, result.entries, result.error);
    });
    watcher->setFuture(QtConcurrent::run(&m_verifiers, [folder] {
        Result result;
        const QFileInfo info(folder.toLocalFile());
        if (!folder.isLocalFile() || !info.isDir() || !info.isReadable()) {
            result.error = tr("Cannot read this folder. Check its location and permissions.");
            return result;
        }
        const auto entries
            = QDir(info.absoluteFilePath())
                  .entryInfoList(QDir::Dirs | QDir::Files | QDir::Readable | QDir::NoDotAndDotDot | QDir::NoSymLinks,
                      QDir::DirsFirst | QDir::Name | QDir::IgnoreCase);
        for (const auto &entry : entries) {
            if (!entry.isDir() && entry.suffix().compare("pdf", Qt::CaseInsensitive) != 0) continue;
            result.entries.append(QVariantMap{{"name", entry.fileName()},
                {"url", QUrl::fromLocalFile(entry.absoluteFilePath()).toString()}, {"directory", entry.isDir()}});
        }
        return result;
    }));
    return requestId;
}
