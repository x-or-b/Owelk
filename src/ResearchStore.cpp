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

// A verified text selection on a PDF page, for a highlight or a comment.
struct SelectionResult {
    QString id, hash, error, text;
    QUrl source;
    int page = 0, start = -1, end = -1;
    QVariantList rectangles;
};
}

ResearchStore::ResearchStore(const QString &directory, QObject *parent)
    : QObject(parent), m_directory(directory), m_connection(QUuid::createUuid().toString()),
      m_index(new PaperIndex(directory, this)), m_references(new ReferenceFinder(m_index->readerBusyFlag(), this)),
      m_lookup(new MetadataLookup(this)), m_ai(new AiService(this, this)), m_sync(new LibrarySync(directory, this))
{
    m_papers = defaultPapersFolder(directory);
    m_sync->setPapersFolder(m_papers);
    connect(m_sync, &LibrarySync::received, this, &ResearchStore::syncReceived);
    m_workers.setMaxThreadCount(1);
    m_verifiers.setMaxThreadCount(2);
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
    if (!QDir().mkpath(m_directory)) {
        *error = tr("Cannot create data folder: %1").arg(m_directory);
        return false;
    }
    // A restore chosen in Settings is applied now, before the database is opened.
    applyPendingRestore(m_directory, &m_startupMessage);
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
        // Papers in Owelk's Trash (also hidden like removed papers until restored or deleted for good).
        {12, {"ALTER TABLE documents ADD COLUMN trashed_at TEXT"}},
        // AI conversations in the Trash (hidden from the list until restored or deleted for good).
        {13, {"ALTER TABLE ai_threads ADD COLUMN trashed_at TEXT"}},
        // Workspaces are gone: each one with papers becomes a collection of its name (joining a
        // top-level collection already called that), and their tables go.
        {14,
            {"INSERT OR IGNORE INTO collections(id,name,parent_id,created_at) SELECT w.id,w.name,NULL,w.opened_at "
             "FROM workspaces w WHERE w.id NOT IN (SELECT id FROM deleted_workspaces) "
             "AND EXISTS(SELECT 1 FROM workspace_documents d WHERE d.workspace_id=w.id) "
             "AND NOT EXISTS(SELECT 1 FROM collections c WHERE c.parent_id IS NULL AND c.name=w.name)",
                "INSERT OR IGNORE INTO collection_documents(collection_id,document_id) "
                "SELECT (SELECT c.id FROM collections c WHERE c.parent_id IS NULL AND c.name=w.name "
                "ORDER BY c.id=w.id DESC LIMIT 1),d.document_id FROM workspace_documents d "
                "JOIN workspaces w ON w.id=d.workspace_id WHERE w.id NOT IN (SELECT id FROM deleted_workspaces)",
                "DROP TABLE workspace_captures", "DROP TABLE workspace_document_exclusions",
                "DROP TABLE workspace_documents", "DROP TABLE deleted_workspaces", "DROP TABLE workspaces"},
            {}, true},
        // Captures are gone: a text excerpt becomes a highlight and a region an area annotation (same ID,
        // note as its comment, trash as deletion); a web clip becomes a note with its image. Links and
        // note links follow; the capture tables go.
        {15,
            {"INSERT OR IGNORE INTO highlights(id,document_id,sha256,page,text,rectangles,start_index,end_index,"
             "created_at,deleted_at,kind,body) SELECT c.id,c.document_id,c.sha256,c.page,coalesce(t.text,c.caption),"
             "json_array(json_object('x',c.x,'y',c.y,'width',c.width,'height',c.height)),"
             "coalesce(t.start_index,-1),coalesce(t.end_index,-1),c.created_at,"
             "(SELECT d.deleted_at FROM deleted_captures d WHERE d.id=c.id),"
             "CASE WHEN t.capture_id IS NULL THEN 'area' ELSE 'highlight' END,"
             "coalesce((SELECT n.body FROM capture_notes n WHERE n.capture_id=c.id),'') "
             "FROM captures c LEFT JOIN text_captures t ON t.capture_id=c.id WHERE c.anchor_kind<>'web'"},
            [directory = m_directory](QSqlDatabase &db, QString *error) {
                const auto run = [&](const QString &sql, const QVariantList &args = {}) {
                    QSqlQuery query(db);
                    query.prepare(sql);
                    for (const auto &arg : args) query.addBindValue(arg);
                    if (query.exec()) return true;
                    *error = query.lastError().text();
                    return false;
                };
                QSqlQuery captures(db);
                if (!captures.exec("SELECT c.id,c.anchor_kind,c.image,c.caption,c.created_at,d.url,d.title,"
                                   "coalesce((SELECT n.body FROM capture_notes n WHERE n.capture_id=c.id),''),"
                                   "(SELECT d.deleted_at FROM deleted_captures d WHERE d.id=c.id) FROM captures c "
                                   "JOIN documents d ON d.id=c.document_id")) {
                    *error = captures.lastError().text();
                    return false;
                }
                QList<QVariantList> rows;
                while (captures.next()) {
                    QVariantList row;
                    for (int i = 0; i < 9; ++i) row << captures.value(i);
                    rows << row;
                }
                captures.finish();
                for (const auto &row : std::as_const(rows)) {
                    const auto id = row[0].toString();
                    const bool web = row[1].toString() == "web";
                    const QString kind = web ? "note" : "highlight";
                    if (web) {
                        // The clip's image moves to the annotation images (backed up); the note
                        // refers to it relative to the data folder, which works on every computer.
                        QString image;
                        const auto name = QFileInfo(row[2].toString()).fileName();
                        const auto copy = directory + "/annotations/" + name;
                        if (!name.isEmpty() && QDir().mkpath(directory + "/annotations")
                            && (QFileInfo::exists(copy) || QFile::copy(directory + "/captures/" + name, copy)
                                || QFile::copy(directory + "/captures/trash/" + name, copy)))
                            image = "![](annotations/" + name + ")\n\n";
                        const auto page = row[6].toString().isEmpty() ? row[5].toString() : row[6].toString();
                        auto title = row[3].toString().simplified();
                        if (title.isEmpty()) title = "Clip · " + page;
                        const auto body = image + (row[7].toString().isEmpty() ? QString() : row[7].toString() + "\n\n")
                            + "[" + page + "](" + row[5].toString() + ")\n";
                        // A clip in the trash becomes a note in the trash.
                        if (!run("INSERT OR IGNORE INTO notes(id,title,body,created_at,updated_at,deleted_at) "
                                 "VALUES(?,?,?,?,?,?)",
                                {id, title.left(160), body, row[4], row[4], row[8]}))
                            return false;
                    }
                    for (const auto *side : {"from", "to"})
                        if (!run(QStringLiteral(
                                     "UPDATE OR REPLACE links SET %1_kind=? WHERE %1_kind='capture' AND %1_id=?")
                                     .arg(side),
                                {kind, id}))
                            return false;
                    if (!run("UPDATE notes SET body=replace(body,?,?) WHERE instr(body,?)>0",
                            {"owelk://capture/" + id, "owelk://" + kind + "/" + id, "owelk://capture/" + id}))
                        return false;
                }
                // Links to captures deleted for good point nowhere now.
                if (!run("DELETE FROM links WHERE from_kind='capture' OR to_kind='capture'")) return false;
                for (const auto *table : {"text_captures", "capture_notes", "deleted_captures", "captures"})
                    if (!run(QStringLiteral("DROP TABLE %1").arg(table))) return false;
                return true;
            },
            true},
        // When notes, AI conversations and collections were last opened on this computer (Home's order).
        {16,
            {"CREATE TABLE IF NOT EXISTS recent_items (kind TEXT NOT NULL, id TEXT NOT NULL, opened_at TEXT NOT NULL, "
             "PRIMARY KEY(kind,id))"}},
    };
    if (!migrateSchema(m_database, steps, error, m_directory + "/backups")) return false;
    loadDocumentNames();
    QSqlQuery links(m_database);
    links.exec("SELECT old_url,new_url FROM source_relinks");
    while (links.next()) m_relinks.insert(links.value(0).toString(), links.value(1).toString());
    // The search cache adopts the same document IDs, so a result names the same paper everywhere.
    m_index->setDocumentResolver([this](const QUrl &url) { return ensureDocument(url); });
    m_index->setExclusionCheck([this](const QUrl &url) { return excludedFromIndex(url); });
    PdfAccess::setKeyDirectory(m_directory);
    if (!m_index->initialize(error)) return false;
    // A folder chosen in the settings table wins over the default (tests use it too).
    if (const auto chosen = setting("library.folder"); !chosen.isEmpty()) m_papers = QDir(chosen).absolutePath();
    m_sync->setPapersFolder(m_papers);
    relocatePapers();
    // Meaning search follows changes to indexed text and saved items, only while it is turned on.
    m_semantic = new SemanticIndex(this, m_index, m_directory, this);
    for (const auto signal :
        {&ResearchStore::notesChanged, &ResearchStore::highlightsChanged, &ResearchStore::aiThreadsChanged})
        connect(this, signal, m_semantic, &SemanticIndex::sync);
    connect(m_index, &PaperIndex::contentsChanged, m_semantic, &SemanticIndex::sync);
    m_semantic->sync();
    configureOcr();
    markRunning();
    scheduleAutomaticBackup();
    m_sync->start();
    // Papers past their days in the Trash go a little after start, not while the window opens.
    QTimer::singleShot(20000, this, &ResearchStore::purgeExpired);
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
    restore.prepare("UPDATE documents SET removed_at=NULL,trashed_at=NULL WHERE id=? AND removed_at IS NOT NULL");
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

// Rows from another computer: in-memory lists are read again and the views told.
void ResearchStore::syncReceived(const QSet<QString> &tables, const QStringList &sources)
{
    loadDocumentNames();
    for (const auto &source : sources) m_index->enqueue(QUrl(source));
    announceDocumentsChanged(); // Recent papers and Home too.
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

void ResearchStore::highlightText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, const QString &color)
{
    saveTextSelection(source, page, from, to, expectedText, color);
}

void ResearchStore::commentText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, const QString &body, const QString &color)
{
    if (body.trimmed().isEmpty() || body.size() > 10000) {
        emit message("Enter a comment (up to 10,000 characters).");
        emit annotationFinished(false, "");
        return;
    }
    saveTextSelection(source, page, from, to, expectedText, color, "comment", body);
}

void ResearchStore::saveTextSelection(const QUrl &source, int page, const QPointF &from, const QPointF &to,
    const QString &expectedText, const QString &color, const QString &kind, const QString &body)
{
    const auto fail = [this](const QString &error) {
        emit message(error);
        emit annotationFinished(false, "");
    };
    if (!annotationColors().contains(color)) return fail("Choose a supported highlight color.");
    if (m_relinking) return fail("Please wait until source verification finishes.");
    if (!source.isLocalFile() || page < 0 || expectedText.trimmed().isEmpty() || expectedText.size() > 100000
        || !std::isfinite(from.x()) || !std::isfinite(from.y()) || !std::isfinite(to.x()) || !std::isfinite(to.y()))
        return fail("Select text in a PDF first.");
    if (m_pending >= 4) return fail("Saving annotations. Please try again shortly.");
    ++m_pending;
    emit busyChanged();
    auto *watcher = new QFutureWatcher<SelectionResult>(this);
    connect(watcher, &QFutureWatcher<SelectionResult>::finished, this, [this, watcher, color, kind, body, fail] {
        const auto result = watcher->result();
        watcher->deleteLater();
        --m_pending;
        emit busyChanged();
        if (!result.error.isEmpty()) return fail(result.error);
        const auto document = ensureDocument(result.source);
        if (document.isEmpty()) return fail("Cannot record the source document. Check storage and permissions.");
        // Repeated clicks must not stack opaque copies of the same annotation.
        QSqlQuery existing(m_database);
        existing.prepare("SELECT id,body FROM highlights WHERE document_id=? AND sha256=? AND page=? AND "
                         "start_index=? AND end_index=? AND kind=? AND deleted_at IS NULL");
        for (const QVariant &value : {QVariant(document), QVariant(result.hash), QVariant(result.page),
                 QVariant(result.start), QVariant(result.end), QVariant(kind)})
            existing.addBindValue(value);
        if (!existing.exec()) return fail("Cannot check existing highlights.");
        if (kind == "highlight" && existing.next()) {
            const auto id = existing.value(0).toString();
            const auto preservedBody = body.isNull() ? existing.value(1).toString() : body;
            existing.finish();
            const bool success = updateHighlight(id, color, preservedBody);
            if (success) {
                emit highlightSaved(id, result.source);
                emit annotationSaved(id);
            }
            emit annotationFinished(success, id);
            return;
        }
        QSqlQuery mark(m_database);
        mark.prepare("INSERT INTO "
                     "highlights(id,document_id,sha256,page,text,rectangles,start_index,end_index,created_at,"
                     "color,kind,body) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)");
        for (const QVariant &value : {QVariant(result.id), QVariant(document), QVariant(result.hash),
                 QVariant(result.page), QVariant(result.text),
                 QVariant(
                     QString::fromUtf8(QJsonDocument::fromVariant(result.rectangles).toJson(QJsonDocument::Compact))),
                 QVariant(result.start), QVariant(result.end),
                 QVariant(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)), QVariant(color), QVariant(kind),
                 QVariant(body.isNull() ? QStringLiteral("") : body)})
            mark.addBindValue(value);
        if (!mark.exec()) return fail("Cannot save annotation. Check storage and permissions.");
        recordAnnotation(result.id, {}, "");
        emit highlightsChanged();
        emit homeChanged();
        emit highlightSaved(result.id, result.source);
        emit annotationSaved(result.id);
        emit annotationFinished(true, result.id);
        emit message("Annotation saved. The original PDF was not modified.");
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, page, from, to, expectedText] {
        SelectionResult result;
        result.source = source;
        result.page = page;
        const auto path = source.toLocalFile();
        result.hash = fingerprint(path);
        QPdfDocument document;
        if (result.hash.isEmpty() || PdfAccess::load(document, path) != QPdfDocument::Error::None
            || page >= document.pageCount()) {
            result.error = "Cannot read the source PDF.";
            return result;
        }
        const auto selection = document.getSelection(page, from, to);
        const auto size = document.pagePointSize(page);
        if (!selection.isValid() || selection.text() != expectedText || size.isEmpty()
            || selection.boundingRectangle().isEmpty() || selection.startIndex() < 0
            || selection.endIndex() < selection.startIndex()) {
            result.error = "The selection could not be verified. Reopen the PDF and select the text again.";
            return result;
        }
        result.text = selection.text();
        result.start = selection.startIndex();
        result.end = selection.endIndex();
        SelectionGeometry geometry;
        const auto lines = geometry.lineRectangles(document.getAllText(page).bounds());
        for (const auto &value : geometry.stableRectangles(selection.bounds(), lines)) {
            const auto r = value.toRectF().intersected(QRectF(QPointF(), size));
            if (!r.isEmpty())
                result.rectangles.append(QVariantMap{{"x", r.x() / size.width()}, {"y", r.y() / size.height()},
                    {"width", r.width() / size.width()}, {"height", r.height() / size.height()}});
        }
        if (result.rectangles.isEmpty()) {
            result.error = "This selection has no highlight geometry.";
            return result;
        }
        if (fingerprint(path) != result.hash) {
            result.error = "The source PDF changed while saving. Please reopen it.";
            return result;
        }
        result.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
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
