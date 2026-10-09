#include "ResearchStore.h"
#include "WorkerConnection.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlQuery>
#include <QTimer>
#include <QtConcurrent>
#include <algorithm>

// Backups are plain folders: a consistent copy of the library database (VACUUM INTO), the annotation
// images, and a small manifest. The search index and meaning vectors are rebuilt from
// the PDFs, so they are not copied. Restoring is staged and applied on the next start, after the
// current data is moved aside, so nothing is ever overwritten in place.
namespace {
const QStringList copiedFolders{"annotations"};
// A backup from before schema step 15 also holds capture images; they come back too, for the step to convert.
const QStringList restoredFolders{"annotations", "captures"};

bool copyFolder(const QString &from, const QString &to)
{
    if (!QFileInfo(from).isDir()) return true;
    QDirIterator it(from, QDir::Files | QDir::NoDotAndDotDot | QDir::Hidden, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const auto file = it.next();
        const auto target = to + "/" + QDir(from).relativeFilePath(file);
        if (!QDir().mkpath(QFileInfo(target).absolutePath()) || !QFile::copy(file, target)) return false;
    }
    return true;
}

int schemaVersion(const QString &database)
{
    WorkerConnection db(database, true);
    QSqlQuery query(db.db);
    return db.db.isOpen() && query.exec("PRAGMA user_version") && query.next() ? query.value(0).toInt() : -1;
}

struct BackupResult {
    bool ok = false;
    QString path, message;
};

BackupResult makeBackup(const QString &directory, const QString &parent, int keep)
{
    const auto name = "Owelk backup " + QDateTime::currentDateTime().toString("yyyy-MM-dd HHmmss");
    const auto target = parent + "/" + name;
    if (!QDir().mkpath(target)) return {false, {}, "Cannot create the backup folder."};
    {
        WorkerConnection db(directory + "/owelk.sqlite3", true);
        QSqlQuery query(db.db);
        query.prepare("VACUUM INTO ?");
        query.addBindValue(target + "/owelk.sqlite3");
        if (!db.db.isOpen() || !query.exec()) {
            QDir(target).removeRecursively();
            return {false, {}, "Cannot copy the library database."};
        }
    }
    for (const auto &folder : copiedFolders)
        if (!copyFolder(directory + "/" + folder, target + "/" + folder)) {
            QDir(target).removeRecursively();
            return {false, {}, "Cannot copy the " + folder + " folder."};
        }
    QFile manifest(target + "/owelk-backup.json");
    if (!manifest.open(QIODevice::WriteOnly)) return {false, {}, "Cannot write the backup manifest."};
    manifest.write(QJsonDocument(QJsonObject{{"app", "Owelk"}, {"schema", schemaVersion(target + "/owelk.sqlite3")},
                                     {"created", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
                                     {"source", QDir::toNativeSeparators(directory)}})
            .toJson());
    manifest.close();
    // Automatic backups keep only the newest few.
    if (keep > 0) {
        auto old = QDir(parent).entryList({"Owelk backup *"}, QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        while (old.size() > keep) QDir(parent + "/" + old.takeFirst()).removeRecursively();
    }
    return {true, target, "Backed up to " + QDir::toNativeSeparators(target)};
}
}

QString ResearchStore::checkBackup(const QString &folder) const
{
    const QDir backup(folder);
    if (!QFileInfo::exists(backup.filePath("owelk-backup.json"))
        || !QFileInfo::exists(backup.filePath("owelk.sqlite3")))
        return "This folder is not an Owelk backup.";
    const int version = schemaVersion(backup.filePath("owelk.sqlite3"));
    if (version < 0) return "The backup's database cannot be read.";
    QSqlQuery query(m_database);
    const int current = query.exec("PRAGMA user_version") && query.next() ? query.value(0).toInt() : 0;
    if (version > current) return "This backup was made by a newer Owelk.";
    return {};
}

void ResearchStore::backUp(const QString &folder)
{
    if (m_backingUp) return;
    const auto parent = folder.isEmpty() ? m_directory + "/backups/auto" : QDir::fromNativeSeparators(folder);
    if (!QDir().mkpath(parent)) {
        emit backupFinished(false, {}, "Cannot create " + QDir::toNativeSeparators(parent));
        return;
    }
    m_backingUp = true;
    emit backingUpChanged();
    auto *watcher = new QFutureWatcher<BackupResult>(this);
    connect(watcher, &QFutureWatcher<BackupResult>::finished, this, [this, watcher, automatic = folder.isEmpty()] {
        const auto result = watcher->result();
        watcher->deleteLater();
        m_backingUp = false;
        if (result.ok) setSetting("backup.last", QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
        emit backingUpChanged();
        emit backupFinished(result.ok, result.path, result.message);
        if (!automatic || !result.ok) emit message(result.message);
    });
    watcher->setFuture(
        QtConcurrent::run(&m_workers, [directory = m_directory, parent, keep = folder.isEmpty() ? 7 : 0] {
            return makeBackup(directory, parent, keep);
        }));
}

void ResearchStore::scheduleAutomaticBackup()
{
    // Once a day at most, a few minutes after start so it never competes with opening papers.
    if (setting("backup.auto", "1") != "1") return;
    const auto last = QDateTime::fromString(setting("backup.last"), Qt::ISODate);
    if (last.isValid() && last.secsTo(QDateTime::currentDateTimeUtc()) < 24 * 3600) return;
    QTimer::singleShot(3 * 60 * 1000, this, [this] { backUp({}); });
}

bool ResearchStore::scheduleRestore(const QString &folder)
{
    const auto problem = checkBackup(folder);
    if (!problem.isEmpty()) {
        emit message(problem);
        return false;
    }
    QFile pending(m_directory + "/restore-pending");
    if (!pending.open(QIODevice::WriteOnly)) return false;
    pending.write(QDir::fromNativeSeparators(folder).toUtf8());
    emit message("The backup is restored when Owelk starts next. Quit and reopen Owelk.");
    return true;
}

bool ResearchStore::applyPendingRestore(const QString &directory, QString *error)
{
    QFile pending(directory + "/restore-pending");
    if (!pending.exists()) return true;
    if (!pending.open(QIODevice::ReadOnly)) return true;
    const auto backup = QString::fromUtf8(pending.readAll()).trimmed();
    pending.close();
    pending.remove();
    if (!QFileInfo::exists(backup + "/owelk.sqlite3")) {
        *error = "The backup to restore is gone; your current data was kept.";
        return true;
    }
    // Current data moves aside first (never deleted), then the backup is copied in.
    const auto aside
        = directory + "/backups/before-restore-" + QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss");
    if (!QDir().mkpath(aside)) {
        *error = "Cannot make room to restore the backup; your current data was kept.";
        return true;
    }
    QStringList moved;
    for (const auto &name : QStringList{"owelk.sqlite3", "owelk.sqlite3-wal", "owelk.sqlite3-shm"} + restoredFolders)
        if (QFileInfo::exists(directory + "/" + name)) {
            if (!QDir().rename(directory + "/" + name, aside + "/" + name)) {
                for (const auto &back : moved) QDir().rename(aside + "/" + back, directory + "/" + back);
                *error = "Cannot move the current data aside; nothing was restored.";
                return true;
            }
            moved << name;
        }
    bool ok = QFile::copy(backup + "/owelk.sqlite3", directory + "/owelk.sqlite3");
    for (const auto &folder : restoredFolders) ok = ok && copyFolder(backup + "/" + folder, directory + "/" + folder);
    if (!ok) {
        // Put the previous data back exactly as it was.
        QFile::remove(directory + "/owelk.sqlite3");
        for (const auto &folder : restoredFolders) QDir(directory + "/" + folder).removeRecursively();
        for (const auto &back : moved) QDir().rename(aside + "/" + back, directory + "/" + back);
        *error = "The backup could not be copied; your current data was kept.";
        return true;
    }
    *error = "Restored the backup. The previous data is in " + QDir::toNativeSeparators(aside) + ".";
    return true;
}

// --- Crash recovery ---------------------------------------------------------------------------

void ResearchStore::markRunning()
{
    const auto marker = m_directory + "/.running";
    m_recovered = QFileInfo::exists(marker);
    if (m_recovered) {
        // After an unexpected exit, a quick integrity check; the session itself restores as usual.
        QSqlQuery check(m_database);
        if (check.exec("PRAGMA quick_check") && check.next() && check.value(0).toString() != "ok")
            m_startupMessage = "The library database reports damage. Restore a backup from Settings → Data.";
    }
    QFile file(marker);
    if (file.open(QIODevice::WriteOnly)) file.write(QByteArray::number(QCoreApplication::applicationPid()));
    connect(qApp, &QCoreApplication::aboutToQuit, this, &ResearchStore::markStopped, Qt::UniqueConnection);
}

void ResearchStore::markStopped()
{
    QFile::remove(m_directory + "/.running");
}

// Drafts live in the settings table under their own prefix (longer than ordinary preferences).
bool ResearchStore::saveDraft(const QString &key, const QString &text)
{
    if (key.isEmpty() || key.size() > 200 || text.size() > 20000) return false;
    if (text.isEmpty()) {
        clearDraft(key);
        return true;
    }
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)");
    query.addBindValue("draft." + key);
    query.addBindValue(text);
    return query.exec();
}

QString ResearchStore::draft(const QString &key) const
{
    if (key.isEmpty()) return {};
    QSqlQuery query(m_database);
    query.prepare("SELECT value FROM settings WHERE key=?");
    query.addBindValue("draft." + key);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

void ResearchStore::clearDraft(const QString &key)
{
    if (key.isEmpty()) return;
    QSqlQuery query(m_database);
    query.prepare("DELETE FROM settings WHERE key=?");
    query.addBindValue("draft." + key);
    query.exec();
}
