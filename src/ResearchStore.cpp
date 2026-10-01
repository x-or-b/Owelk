#include "ResearchStore.h"
#include "FileFingerprint.h"
#include "SchemaMigration.h"
#include "PaperIndex.h"
#include "SelectionGeometry.h"

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
    QString id, path, hash, error;
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
      m_index(new PaperIndex(directory, this))
{
    m_workers.setMaxThreadCount(1);
    m_verifiers.setMaxThreadCount(2);
    m_metadataWorkers.setMaxThreadCount(1);
    m_metadataWorkers.setThreadPriority(QThread::LowPriority);
    connect(m_index, &PaperIndex::message, this, &ResearchStore::message);
}

QObject *ResearchStore::paperIndex() const
{
    return m_index;
}

QStringList ResearchStore::annotationColors()
{
    return {"#426b9a", "#e0b83f", "#54a878", "#d87797", "#9274c3"};
}

ResearchStore::~ResearchStore()
{
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
    };
    if (!migrateSchema(m_database, steps, error, m_directory + "/backups")) return false;
    loadDocumentNames();
    reloadCaptures();
    QSqlQuery links(m_database);
    links.exec("SELECT old_url,new_url FROM source_relinks");
    while (links.next()) m_relinks.insert(links.value(0).toString(), links.value(1).toString());
    // The search cache adopts the same document IDs, so a result names the same paper everywhere.
    m_index->setDocumentResolver([this](const QUrl &url) { return ensureDocument(url); });
    if (!m_index->initialize(error)) return false;
    // Durable redirects also replay any search-cache update interrupted by process exit.
    for (auto it = m_relinks.cbegin(); it != m_relinks.cend(); ++it)
        m_index->relocateSource(QUrl(it.key()), resolvedSource(QUrl(it.value())));
    QSqlQuery known(m_database);
    known.exec("SELECT id,url,metadata_origin FROM documents");
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
    refreshMetadata(document, resolvedSource(url), false);
    emit recentDocumentsChanged();
    emit homeChanged();
    m_index->enqueue(url);
    return true;
}

QVariantList ResearchStore::recentDocuments() const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec("SELECT d.url FROM recent_documents r JOIN documents d ON d.id=r.document_id "
               "ORDER BY r.opened_at DESC LIMIT 12");
    while (query.next()) {
        const auto url = QUrl(query.value(0).toString());
        results.append(QVariantMap{
            {"url", url}, {"name", displayName(url)}, {"fileName", fileName(url)}, {"position", readingPosition(url)}});
    }
    return results;
}

QVariantList ResearchStore::readCaptures(bool trashed) const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec(QStringLiteral(
        "SELECT c.id,doc.url,c.page,c.image,c.created_at,t.text,t.capture_id,n.body,n.updated_at,d.deleted_at "
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
                {"kind", query.value(6).isNull() ? "region" : "text"}, {"text", query.value(5).toString()},
                {"note", query.value(7).toString()}, {"noteUpdatedAt", query.value(8).toString()},
                {"image", imagePath.isEmpty() ? QUrl() : QUrl::fromLocalFile(imagePath)},
                {"imageAvailable",
                    !imagePath.isEmpty() && QFileInfo(imagePath).isFile() && !QFileInfo(imagePath).isSymLink()},
                {"createdAt", query.value(4)}, {"deletedAt", query.value(9)}});
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
        query.prepare("INSERT INTO captures(id,document_id,sha256,page,x,y,width,height,image,created_at) "
                      "VALUES(?,?,?,?,?,?,?,?,?,?)");
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
        if (result.hash.isEmpty() || document.load(path) != QPdfDocument::Error::None || page >= document.pageCount()) {
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
        if (anchor.hash.isEmpty() || document.load(path) != QPdfDocument::Error::None || page >= document.pageCount()) {
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

void ResearchStore::openCapture(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT d.url,c.sha256,c.page,c.x,c.y,c.width,c.height FROM captures c "
        "JOIN documents d ON d.id=c.document_id WHERE c.id=? AND c.id NOT IN (SELECT id FROM deleted_captures)");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return;
    const auto url = QUrl(query.value(0).toString());
    const auto expectedHash = query.value(1).toString();
    const int page = query.value(2).toInt();
    const QRectF rect(
        query.value(3).toDouble(), query.value(4).toDouble(), query.value(5).toDouble(), query.value(6).toDouble());
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, id, url, expectedHash, page, rect] {
        const auto hash = watcher->result();
        watcher->deleteLater();
        QSqlQuery deleted(m_database);
        deleted.prepare("SELECT d.url FROM captures c JOIN documents d ON d.id=c.document_id "
                        "WHERE c.id=? AND c.id NOT IN (SELECT id FROM deleted_captures)");
        deleted.addBindValue(id);
        if (!deleted.exec() || !deleted.next()) return;
        if (QUrl(deleted.value(0).toString()) != url) {
            openCapture(id);
            return;
        }
        if (hash.isEmpty()) {
            emit message(tr("Source file not found. The saved capture is preserved."));
            emit relinkRequested(url);
        } else if (hash != expectedHash)
            emit message(
                tr("The source PDF has changed. Its location cannot be verified; the saved capture is preserved."));
        else
            emit sourceReady(url, page, rect);
    });
    watcher->setFuture(QtConcurrent::run(&m_verifiers, [url] { return fingerprint(url.toLocalFile()); }));
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
    emit message(tr("Capture restored with its note and workspace links."));
    return true;
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
