#include "ResearchStore.h"

#include <QClipboard>
#include <QCryptographicHash>
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
#include <QSaveFile>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <QtConcurrent>
#include <cmath>

namespace {
QString fingerprint(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file)) return {};
    return QString::fromLatin1(hash.result().toHex());
}

struct CaptureResult {
    QString id, path, hash, error;
    QUrl source;
    int page = 0;
    QRectF region;
};
}

ResearchStore::ResearchStore(const QString &directory, QObject *parent)
    : QObject(parent), m_directory(directory), m_connection(QUuid::createUuid().toString())
{
    m_workers.setMaxThreadCount(1);
}

ResearchStore::~ResearchStore()
{
    m_workers.waitForDone();
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
    const QStringList statements = {
        "PRAGMA journal_mode=WAL",
        "PRAGMA busy_timeout=3000",
        "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS recent_documents (url TEXT PRIMARY KEY, opened_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS reading_positions (url TEXT PRIMARY KEY, position TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, state TEXT NOT NULL, opened_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS workspace_documents (workspace_id TEXT NOT NULL, url TEXT NOT NULL, PRIMARY KEY(workspace_id,url))",
        "CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY, source TEXT NOT NULL, "
        "sha256 TEXT NOT NULL, page INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL, "
        "width REAL NOT NULL, height REAL NOT NULL, image TEXT NOT NULL, created_at TEXT NOT NULL)"
    };
    for (const auto &sql : statements) {
        QSqlQuery query(m_database);
        if (!query.exec(sql)) {
            *error = query.lastError().text();
            return false;
        }
    }
    reloadCaptures();
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

bool ResearchStore::saveSession(const QVariantMap &state)
{
    if (!m_database.transaction()) { emit message(tr("Cannot begin saving reading state.")); return false; }
    const QByteArray json = QJsonDocument(QJsonObject::fromVariantMap(state)).toJson(QJsonDocument::Compact);
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES('session',?)");
    query.addBindValue(QString::fromUtf8(json));
    if (!query.exec()) {
        m_database.rollback();
        emit message(tr("Cannot save reading position: %1").arg(query.lastError().text()));
        return false;
    }
    const QStringList order = state.value("active").toInt() == 1 && state.value("split").toBool()
        ? QStringList{"left", "right"} : QStringList{"right", "left"};
    for (const auto &key : order) {
        const auto reader = state.value(key).toMap();
        const auto source = QUrl(reader.value("source").toString());
        if (!source.isLocalFile()) continue;
        QSqlQuery position(m_database);
        position.prepare("INSERT OR REPLACE INTO reading_positions VALUES(?,?)");
        position.addBindValue(source.toString());
        position.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(reader.value("position")).toJson(QJsonDocument::Compact)));
        if (!position.exec()) {
            m_database.rollback();
            emit message(tr("Cannot save document position: %1").arg(position.lastError().text()));
            return false;
        }
    }
    if (!m_database.commit()) { m_database.rollback(); emit message(tr("Cannot save reading state.")); return false; }
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
        return false;
    }
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO recent_documents(url,opened_at) VALUES(?,?)");
    query.addBindValue(url.toString());
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!query.exec()) {
        emit message(query.lastError().text());
        return false;
    }
    emit recentDocumentsChanged();
    emit homeChanged();
    return true;
}

QVariantList ResearchStore::recentDocuments() const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec("SELECT url FROM recent_documents ORDER BY opened_at DESC LIMIT 12");
    while (query.next()) {
        const auto url = QUrl(query.value(0).toString());
        results.append(QVariantMap{{"url", url}, {"name", fileName(url)}, {"position", readingPosition(url)}});
    }
    return results;
}

void ResearchStore::reloadCaptures()
{
    m_captures.clear();
    QSqlQuery query(m_database);
    query.exec("SELECT id,source,page,image,created_at FROM captures ORDER BY created_at DESC");
    while (query.next()) {
        const auto url = QUrl(query.value(1).toString());
        m_captures.append(QVariantMap{
            {"id", query.value(0)}, {"source", url}, {"name", fileName(url)},
            {"page", query.value(2)},
            {"image", QUrl::fromLocalFile(m_directory + "/captures/" + query.value(3).toString())},
            {"createdAt", query.value(4)}
        });
    }
    emit capturesChanged();
    emit homeChanged();
}

QVariantMap ResearchStore::readingPosition(const QUrl &source) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT position FROM reading_positions WHERE url=?");
    query.addBindValue(source.toString());
    if (!query.exec() || !query.next()) return {};
    return QJsonDocument::fromJson(query.value(0).toByteArray()).object().toVariantMap();
}

QVariantMap ResearchStore::continueReading() const
{
    const auto state = session();
    const QString preferred = state.value("active").toInt() == 1 && state.value("split").toBool() ? "right" : "left";
    auto reader = state.value(preferred).toMap();
    if (reader.value("source").toString().isEmpty()) reader = state.value(preferred == "left" ? "right" : "left").toMap();
    const QUrl source(reader.value("source").toString());
    if (!source.isLocalFile()) return {};
    reader.insert("name", fileName(source));
    return reader;
}

QVariantList ResearchStore::recentWorkspaces() const
{
    QVariantList results;
    QSqlQuery query(m_database);
    query.exec("SELECT w.id,w.name,(SELECT count(*) FROM workspace_documents d WHERE d.workspace_id=w.id) "
               "FROM workspaces w ORDER BY w.opened_at DESC LIMIT 12");
    while (query.next()) results.append(QVariantMap{{"id", query.value(0)}, {"name", query.value(1)}, {"papers", query.value(2)}});
    return results;
}

QString ResearchStore::createWorkspace(const QString &name)
{
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty() || trimmed.size() > 120) { emit message(tr("Enter a workspace name (1–120 characters).")); return {}; }
    const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO workspaces VALUES(?,?,?,?)");
    query.addBindValue(id);
    query.addBindValue(trimmed);
    query.addBindValue("{}");
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    if (!query.exec()) { emit message(query.lastError().text()); return {}; }
    emit homeChanged();
    return id;
}

QVariantMap ResearchStore::loadWorkspace(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT name,state FROM workspaces WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) { emit message(tr("Workspace not found.")); return {}; }
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

bool ResearchStore::saveWorkspace(const QString &id, const QVariantMap &state)
{
    if (id.isEmpty()) return true;
    if (!m_database.transaction()) { emit message(tr("Cannot begin saving workspace.")); return false; }
    QSqlQuery query(m_database);
    query.prepare("UPDATE workspaces SET state=? WHERE id=?");
    query.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(state).toJson(QJsonDocument::Compact)));
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) { m_database.rollback(); emit message(tr("Cannot save this workspace.")); return false; }
    for (const auto &key : {"left", "right"}) {
        const auto source = state.value(key).toMap().value("source").toString();
        if (source.isEmpty()) continue;
        QSqlQuery link(m_database);
        link.prepare("INSERT OR IGNORE INTO workspace_documents VALUES(?,?)");
        link.addBindValue(id);
        link.addBindValue(source);
        if (!link.exec()) { m_database.rollback(); emit message(link.lastError().text()); return false; }
    }
    if (!m_database.commit()) { m_database.rollback(); emit message(tr("Cannot save workspace.")); return false; }
    emit homeChanged();
    return true;
}

QVariantList ResearchStore::searchKnowledge(const QString &queryText) const
{
    const auto needle = queryText.trimmed();
    if (needle.isEmpty()) return {};
    QVariantList results;
    QSqlQuery papers(m_database);
    papers.exec("SELECT url FROM recent_documents ORDER BY opened_at DESC");
    int count = 0;
    while (papers.next() && count < 20) {
        const QUrl url(papers.value(0).toString());
        const QString title = fileName(url);
        if (!title.contains(needle, Qt::CaseInsensitive)) continue;
        results.append(QVariantMap{{"kind", "paper"}, {"title", title}, {"source", url}, {"position", readingPosition(url)}});
        ++count;
    }
    count = 0;
    for (const auto &value : m_captures) {
        const auto capture = value.toMap();
        const auto title = capture.value("name").toString() + " · p. " + QString::number(capture.value("page").toInt() + 1);
        if (!title.contains(needle, Qt::CaseInsensitive)) continue;
        results.append(QVariantMap{{"kind", "capture"}, {"title", title}, {"id", capture.value("id")}});
        if (++count >= 20) break;
    }
    QSqlQuery workspaces(m_database);
    workspaces.exec("SELECT id,name FROM workspaces ORDER BY opened_at DESC");
    count = 0;
    while (workspaces.next() && count < 20) {
        if (!workspaces.value(1).toString().contains(needle, Qt::CaseInsensitive)) continue;
        results.append(QVariantMap{{"kind", "workspace"}, {"title", workspaces.value(1)}, {"id", workspaces.value(0)}});
        ++count;
    }
    return results;
}

void ResearchStore::captureRegion(const QUrl &source, int page, const QRectF &requested)
{
    if (!source.isLocalFile() || page < 0 || !std::isfinite(requested.x())
        || !std::isfinite(requested.y()) || !std::isfinite(requested.width())
        || !std::isfinite(requested.height())) {
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
        QSqlQuery query(m_database);
        query.prepare("INSERT INTO captures VALUES(?,?,?,?,?,?,?,?,?,?)");
        query.addBindValue(result.id);
        query.addBindValue(result.source.toString());
        query.addBindValue(result.hash);
        query.addBindValue(result.page);
        query.addBindValue(result.region.x());
        query.addBindValue(result.region.y());
        query.addBindValue(result.region.width());
        query.addBindValue(result.region.height());
        query.addBindValue(QFileInfo(result.path).fileName());
        query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
        if (!query.exec()) {
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
        if (result.hash.isEmpty() || document.load(path) != QPdfDocument::Error::None
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
                                .toAlignedRect().intersected(rendered.rect());
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

void ResearchStore::openCapture(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("SELECT source,sha256,page,x,y,width,height FROM captures WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return;
    const auto url = QUrl(query.value(0).toString());
    const auto expectedHash = query.value(1).toString();
    const int page = query.value(2).toInt();
    const QRectF rect(query.value(3).toDouble(), query.value(4).toDouble(),
                      query.value(5).toDouble(), query.value(6).toDouble());
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, url, expectedHash, page, rect] {
        const auto hash = watcher->result();
        watcher->deleteLater();
        if (hash.isEmpty())
            emit message(tr("Source file not found. The saved capture image is preserved."));
        else if (hash != expectedHash)
            emit message(tr("The source PDF has changed. Its location cannot be verified; the saved capture is preserved."));
        else
            emit sourceReady(url, page, rect);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [url] { return fingerprint(url.toLocalFile()); }));
}

void ResearchStore::copyText(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
}

int ResearchStore::listFolder(const QUrl &folder)
{
    struct Result { QVariantList entries; QString error; };
    const int requestId = ++m_folderRequest;
    auto *watcher = new QFutureWatcher<Result>(this);
    connect(watcher, &QFutureWatcher<Result>::finished, this, [this, watcher, folder, requestId] {
        const auto result = watcher->result();
        watcher->deleteLater();
        emit folderLoaded(requestId, folder, result.entries, result.error);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [folder] {
        Result result;
        const QFileInfo info(folder.toLocalFile());
        if (!folder.isLocalFile() || !info.isDir() || !info.isReadable()) {
            result.error = tr("Cannot read this folder. Check its location and permissions.");
            return result;
        }
        const auto entries = QDir(info.absoluteFilePath()).entryInfoList(
            QDir::Dirs | QDir::Files | QDir::Readable | QDir::NoDotAndDotDot | QDir::NoSymLinks,
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
