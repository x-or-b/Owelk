#include "LibrarySync.h"
#include "WorkerConnection.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QSqlError>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QSysInfo>
#include <QUuid>
#include <QtConcurrent>
#include <algorithm>

namespace {
// A change file grows to about this size before the next one starts (a sync program uploads the
// whole file each time it changes).
constexpr qint64 segmentLimit = 256 * 1024;
const QString markerName = QStringLiteral("owelk-sync.json");
const QString nowMs = QStringLiteral("CAST((julianday('now')-2440587.5)*86400000 AS INTEGER)");

struct Table {
    QString name;
    QStringList keys;
};

// Every synced table with its primary key, parents first so a paper arrives before its annotations.
// Settings, relinks, drafts and the search caches stay on each computer.
const QList<Table> &tables()
{
    static const QList<Table> list{{"documents", {"id"}}, {"tags", {"id"}}, {"collections", {"id"}}, {"notes", {"id"}},
        {"highlights", {"id"}}, {"recent_documents", {"document_id"}}, {"reading_positions", {"document_id"}},
        {"collection_documents", {"collection_id", "document_id"}}, {"document_tags", {"document_id", "tag_id"}},
        {"links", {"from_kind", "from_id", "to_kind", "to_id"}}, {"ai_threads", {"id"}}, {"ai_messages", {"id"}},
        {"ai_responses", {"id"}}};
    return list;
}

int tableIndex(const QString &name)
{
    const auto &list = tables();
    for (int i = 0; i < list.size(); ++i)
        if (list[i].name == name) return i;
    return -1;
}

// What an ID column points at ("document", "tag" or nothing). When two computers added the same
// paper or tag under different IDs, only these columns are rewritten.
QString refersTo(const QString &table, const QString &column, const QVariantMap &values)
{
    if (column == "document_id" || (column == "id" && table == "documents")) return "document";
    if (column == "tag_id" || (column == "id" && table == "tags")) return "tag";
    if (table == "links" && (column == "from_id" || column == "to_id"))
        return values.value(column.chopped(2) + "kind").toString() == "document" ? "document" : QString();
    return {};
}

QString segmentName(int sequence)
{
    return QStringLiteral("%1.jsonl").arg(sequence, 8, 10, QLatin1Char('0'));
}

QJsonObject readJson(const QString &path)
{
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object() : QJsonObject();
}

bool copyFile(const QString &from, const QString &to)
{
    const auto part = to + ".part";
    QFile::remove(part);
    return QDir().mkpath(QFileInfo(to).absolutePath()) && QFile::copy(from, part) && QFile::rename(part, to);
}

QString setting(QSqlDatabase &db, const QString &key)
{
    QSqlQuery query(db);
    query.prepare("SELECT value FROM settings WHERE key=?");
    query.addBindValue(key);
    return query.exec() && query.next() ? query.value(0).toString() : QString();
}

bool setSetting(QSqlDatabase &db, const QString &key, const QString &value)
{
    QSqlQuery query(db);
    query.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)");
    query.addBindValue(key);
    query.addBindValue(value);
    return query.exec();
}

// Bookkeeping tables and the triggers that note changed rows. Installed when sync is first turned
// on and kept afterwards, so changes made while it is off still travel when it is turned on again.
bool installTracking(QSqlDatabase &db, QString *error)
{
    QStringList statements{
        "CREATE TABLE IF NOT EXISTS sync_dirty(tbl TEXT NOT NULL, key TEXT NOT NULL, time INTEGER NOT NULL, "
        "device TEXT, PRIMARY KEY(tbl,key))",
        "CREATE TABLE IF NOT EXISTS sync_rows(tbl TEXT NOT NULL, key TEXT NOT NULL, time INTEGER NOT NULL, "
        "device TEXT NOT NULL, PRIMARY KEY(tbl,key))",
        "CREATE TABLE IF NOT EXISTS sync_seen(device TEXT NOT NULL, file TEXT NOT NULL, size INTEGER NOT NULL, "
        "lines INTEGER NOT NULL, PRIMARY KEY(device,file))",
        "CREATE TABLE IF NOT EXISTS sync_alias(kind TEXT NOT NULL, from_id TEXT NOT NULL, to_id TEXT NOT NULL, "
        "PRIMARY KEY(kind,from_id))",
        "CREATE TABLE IF NOT EXISTS sync_pause(paused INTEGER)",
        "CREATE TABLE IF NOT EXISTS sync_files(local TEXT NOT NULL, remote TEXT NOT NULL, outgoing INTEGER NOT NULL, "
        "PRIMARY KEY(local,remote,outgoing))"};
    const QString mark = "INSERT OR REPLACE INTO sync_dirty(tbl,key,time,device) VALUES('%1',json_array(%2),%3,NULL);";
    for (const auto &table : tables()) {
        QStringList fresh, old;
        for (const auto &key : table.keys) {
            fresh << "NEW." + key;
            old << "OLD." + key;
        }
        const auto head = QStringLiteral("CREATE TRIGGER IF NOT EXISTS sync_%1_%2 AFTER %3 ON %1 "
                                         "WHEN NOT EXISTS(SELECT 1 FROM sync_pause) BEGIN ")
                              .arg(table.name);
        const auto newRow = mark.arg(table.name, fresh.join(','), nowMs);
        const auto oldRow = mark.arg(table.name, old.join(','), nowMs);
        statements << head.arg("insert", "INSERT") + newRow + " END"
                   << head.arg("update", "UPDATE") + oldRow + newRow + " END"
                   << head.arg("delete", "DELETE") + oldRow + " END";
    }
    for (const auto &statement : statements) {
        QSqlQuery query(db);
        if (!query.exec(statement)) {
            *error = query.lastError().text();
            return false;
        }
    }
    return true;
}

// A new sync folder starts empty: every row is written out again, keeping the version it had.
bool markEverything(QSqlDatabase &db, QString *error)
{
    QSqlQuery clear(db);
    if (!clear.exec("DELETE FROM sync_seen")) {
        *error = clear.lastError().text();
        return false;
    }
    for (const auto &table : tables()) {
        QSqlQuery query(db);
        const auto sql
            = QStringLiteral("INSERT OR IGNORE INTO sync_dirty(tbl,key,time,device) "
                             "SELECT '%1',s.k,coalesce(r.time,%3),r.device FROM (SELECT json_array(%2) AS k FROM %1) s "
                             "LEFT JOIN sync_rows r ON r.tbl='%1' AND r.key=s.k")
                  .arg(table.name, table.keys.join(','), nowMs);
        if (!query.exec(sql)) {
            *error = query.lastError().text();
            return false;
        }
    }
    return true;
}

// One sync pass over a database connection on the current thread.
class Pass {
public:
    Pass(QSqlDatabase &db, const QString &data, const QString &papers, const QString &folder, const QString &device,
        std::shared_ptr<std::atomic_bool> cancel)
        : m_db(db), m_data(data), m_papers(papers), m_folder(folder), m_device(device), m_cancel(std::move(cancel))
    {
    }
    LibrarySync::Outcome outcome;
    bool importChanges();
    bool exportChanges();
    void moveFiles();

private:
    bool run(QSqlQuery &query, const QString &sql, const QVariantList &args = {})
    {
        query.prepare(sql);
        for (const auto &arg : args) query.addBindValue(arg);
        if (query.exec()) return true;
        outcome.error = query.lastError().text();
        return false;
    }
    bool run(const QString &sql, const QVariantList &args = {})
    {
        QSqlQuery query(m_db);
        return run(query, sql, args);
    }
    QString keyText(const QVariantList &values)
    {
        QSqlQuery query(m_db);
        QStringList marks(values.size(), "?");
        return run(query, "SELECT json_array(" + marks.join(',') + ")", values) && query.next()
            ? query.value(0).toString()
            : QString();
    }
    QStringList columns(const QString &table)
    {
        if (!m_columns.contains(table)) {
            QSqlQuery query(m_db);
            QStringList names;
            if (query.exec("PRAGMA table_info(" + table + ")"))
                while (query.next()) names << query.value(1).toString();
            m_columns.insert(table, names);
        }
        return m_columns.value(table);
    }
    QString where(const QStringList &keys) { return keys.join("=? AND ") + "=?"; }
    QString alias(const QString &kind, QString id) const
    {
        for (int hop = 0; hop < 8 && m_aliases.value(kind).contains(id); ++hop) id = m_aliases[kind].value(id);
        return id;
    }
    bool addAlias(const QString &kind, const QString &from, const QString &to)
    {
        m_aliases[kind].insert(from, to);
        return run("INSERT OR REPLACE INTO sync_alias(kind,from_id,to_id) VALUES(?,?,?)", {kind, from, to});
    }
    bool applyFile(const QString &device, const QString &file, qint64 size, const QList<QByteArray> &lines, int from);
    bool applyChange(const QJsonObject &change);
    QString naturalMatch(const QString &table, const QVariantMap &row);
    bool rekey(const QString &table, const QString &from, const QString &to);
    bool upsert(const QString &table, QVariantMap row, const QStringList &keys, const QVariantList &keyValues);
    QString localPaperPath(const QVariantMap &row);
    bool writeSegments(const QByteArray &lines);

    QSqlDatabase &m_db;
    QString m_data, m_papers, m_folder, m_device;
    std::shared_ptr<std::atomic_bool> m_cancel;
    QHash<QString, QStringList> m_columns;
    QHash<QString, QHash<QString, QString>> m_aliases;
    QStringList m_removedPapers;
};

bool Pass::importChanges()
{
    QSqlQuery aliases(m_db);
    if (!run(aliases, "SELECT kind,from_id,to_id FROM sync_alias")) return false;
    while (aliases.next())
        m_aliases[aliases.value(0).toString()].insert(aliases.value(1).toString(), aliases.value(2).toString());
    const auto devices = QDir(m_folder + "/devices").entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const auto &device : devices) {
        const auto id = device.fileName();
        if (id == m_device) continue;
        const auto about = readJson(device.filePath() + "/device.json");
        outcome.computers << about.value("name").toString(id.left(8));
        QHash<QString, QPair<qint64, int>> seen;
        QSqlQuery query(m_db);
        if (!run(query, "SELECT file,size,lines FROM sync_seen WHERE device=?", {id})) return false;
        while (query.next())
            seen.insert(query.value(0).toString(), {query.value(1).toLongLong(), query.value(2).toInt()});
        for (const auto &file : QDir(device.filePath()).entryInfoList({"*.jsonl"}, QDir::Files, QDir::Name)) {
            const auto known = seen.value(file.fileName(), {-1, 0});
            if (known.first == file.size()) continue;
            QFile input(file.filePath());
            if (!input.open(QIODevice::ReadOnly)) continue; // Still arriving; read on the next pass.
            const auto data = input.readAll();
            auto lines = data.split('\n');
            lines.removeLast(); // An unfinished last line waits for the rest of the file.
            const int from = known.second <= lines.size() ? known.second : 0;
            if (!applyFile(id, file.fileName(), data.size(), lines, from)) return false;
        }
    }
    return true;
}

bool Pass::applyFile(const QString &device, const QString &file, qint64 size, const QList<QByteArray> &lines, int from)
{
    m_removedPapers.clear();
    if (!m_db.transaction()) {
        outcome.error = m_db.lastError().text();
        return false;
    }
    const auto abort = [&] {
        m_db.rollback();
        return false;
    };
    // Rows written here came from elsewhere: the triggers stay quiet.
    if (!run("INSERT INTO sync_pause(paused) VALUES(1)")) return abort();
    for (int i = from; i < lines.size(); ++i) {
        const auto change = QJsonDocument::fromJson(lines[i]).object();
        if (change.isEmpty()) continue; // A damaged line is skipped, not retried forever.
        if (!applyChange(change)) return abort();
    }
    if (!run("DELETE FROM sync_pause")
        || !run("INSERT OR REPLACE INTO sync_seen(device,file,size,lines) VALUES(?,?,?,?)",
            {device, file, size, lines.size()}))
        return abort();
    if (!m_db.commit()) {
        outcome.error = m_db.lastError().text();
        return abort();
    }
    for (const auto &path : std::as_const(m_removedPapers)) QFile::moveToTrash(path);
    return true;
}

bool Pass::applyChange(const QJsonObject &change)
{
    const auto table = change.value("t").toString();
    const int index = tableIndex(table);
    if (index < 0) return true; // A table from a newer Owelk.
    const auto &keys = tables()[index].keys;
    const auto keyArray = change.value("k").toArray();
    if (keyArray.size() != keys.size()) return true;
    const bool removal = !change.value("r").isObject();
    auto row = change.value("r").toObject().toVariantMap();
    QVariantMap keyMap;
    for (int i = 0; i < keys.size(); ++i) keyMap.insert(keys[i], keyArray[i].toVariant());
    if (removal) {
        // A paper or tag merged into another one here: its removal is that merge, not a deletion.
        for (const auto &key : keys) {
            const auto kind = refersTo(table, key, keyMap);
            if (!kind.isEmpty() && alias(kind, keyMap[key].toString()) != keyMap[key].toString()) return true;
        }
    } else {
        for (auto it = row.begin(); it != row.end(); ++it) {
            const auto kind = refersTo(table, it.key(), row);
            if (!kind.isEmpty()) it.value() = alias(kind, it.value().toString());
        }
        for (const auto &key : keys) keyMap[key] = row.value(key);
    }
    QVariantList keyValues;
    for (const auto &key : keys) keyValues << keyMap[key];
    QSqlQuery existing(m_db);
    if (!run(existing, "SELECT 1 FROM " + table + " WHERE " + where(keys), keyValues)) return false;
    const bool present = existing.next();
    existing.finish();
    // The same paper (same bytes) or tag (same name) added on two computers: both keep the smaller ID.
    if (!removal && !present && (table == "documents" || table == "tags")) {
        const auto match = naturalMatch(table, row);
        const auto id = row.value("id").toString();
        if (!match.isEmpty()) {
            if (match < id) return addAlias(table == "documents" ? "document" : "tag", id, match);
            if (!rekey(table, match, id)) return false;
        }
    }
    const auto key = keyText(keyValues);
    const qint64 time = change.value("v").toInteger();
    const auto device = change.value("d").toString();
    QSqlQuery version(m_db);
    if (!run(version,
            "SELECT time,device FROM sync_rows WHERE tbl=? AND key=? UNION ALL "
            "SELECT time,coalesce(device,?) FROM sync_dirty WHERE tbl=? AND key=?",
            {table, key, m_device, table, key}))
        return false;
    while (version.next()) {
        const auto localTime = version.value(0).toLongLong();
        if (localTime > time || (localTime == time && version.value(1).toString() >= device)) return true;
    }
    version.finish();
    if (removal) {
        if (table == "documents") {
            // A paper deleted for good elsewhere: the copy Owelk keeps here goes to the system Trash too.
            QSqlQuery url(m_db);
            if (run(url, "SELECT url FROM documents WHERE id=?", keyValues) && url.next()) {
                const auto path = QUrl(url.value(0).toString()).toLocalFile();
                if (path.startsWith(m_papers + "/")) m_removedPapers << path;
            }
        }
        if (!run("DELETE FROM " + table + " WHERE " + where(keys), keyValues)) return false;
    } else if (!upsert(table, row, keys, keyValues)) {
        return false;
    }
    outcome.tables.insert(table);
    ++outcome.received;
    return run("INSERT OR REPLACE INTO sync_rows(tbl,key,time,device) VALUES(?,?,?,?)", {table, key, time, device})
        && run("DELETE FROM sync_dirty WHERE tbl=? AND key=?", {table, key});
}

QString Pass::naturalMatch(const QString &table, const QVariantMap &row)
{
    QSqlQuery query(m_db);
    const auto id = row.value("id").toString();
    bool ok = false;
    if (table == "tags") {
        ok = run(query, "SELECT id FROM tags WHERE name=? COLLATE NOCASE AND id<>?", {row.value("name"), id});
    } else if (row.value("kind").toString() == "web") {
        ok = run(query, "SELECT id FROM documents WHERE url=? AND id<>?", {row.value("url"), id});
    } else {
        const auto sha = row.value("sha256").toString();
        if (sha.isEmpty()) return {};
        ok = run(query,
            "SELECT id FROM documents WHERE sha256=? AND kind='pdf' AND id<>? ORDER BY removed_at IS NOT NULL,id LIMIT "
            "1",
            {sha, id});
    }
    return ok && query.next() ? query.value(0).toString() : QString();
}

bool Pass::rekey(const QString &table, const QString &from, const QString &to)
{
    // References move with the triggers on, so the other computers hear about them.
    if (!run("DELETE FROM sync_pause")) return false;
    QList<QPair<QString, QVariantList>> statements;
    if (table == "documents") {
        for (const auto *child :
            {"recent_documents", "reading_positions", "collection_documents", "document_tags", "highlights"})
            statements.append(
                {QStringLiteral("UPDATE OR REPLACE %1 SET document_id=? WHERE document_id=?").arg(child), {to, from}});
        statements.append(
            {"UPDATE OR REPLACE links SET from_id=? WHERE from_kind='document' AND from_id=?", {to, from}});
        statements.append({"UPDATE OR REPLACE links SET to_id=? WHERE to_kind='document' AND to_id=?", {to, from}});
    } else {
        statements.append({"UPDATE OR REPLACE document_tags SET tag_id=? WHERE tag_id=?", {to, from}});
    }
    for (const auto &[sql, args] : std::as_const(statements))
        if (!run(sql, args)) return false;
    // The row itself takes the incoming ID quietly; the old ID is announced as gone.
    if (!run("INSERT INTO sync_pause(paused) VALUES(1)") || !run("UPDATE " + table + " SET id=? WHERE id=?", {to, from})
        || !run("INSERT OR REPLACE INTO sync_dirty(tbl,key,time,device) VALUES(?,?," + nowMs + ",NULL)",
            {table, keyText({from})}))
        return false;
    if (table == "documents") {
        QSqlQuery url(m_db);
        if (run(url, "SELECT url FROM documents WHERE id=?", {to}) && url.next())
            outcome.newSources << url.value(0).toString(); // The search cache takes the new ID.
    }
    outcome.tables.insert(table);
    return addAlias(table == "documents" ? "document" : "tag", from, to);
}

bool Pass::upsert(const QString &table, QVariantMap row, const QStringList &keys, const QVariantList &keyValues)
{
    if (table == "ai_threads" && row.contains("_source_document")) {
        QSqlQuery url(m_db);
        if (run(url, "SELECT url FROM documents WHERE id=?",
                {alias("document", row.value("_source_document").toString())})
            && url.next())
            row["source"] = url.value(0);
    }
    QStringList fields;
    for (const auto &column : columns(table))
        if (row.contains(column)) fields << column;
    QSqlQuery existing(m_db);
    if (!run(existing, "SELECT 1 FROM " + table + " WHERE " + where(keys), keyValues)) return false;
    const bool present = existing.next();
    existing.finish();
    QVariantList values;
    if (present) {
        // A paper's file location belongs to each computer.
        QStringList assignments;
        for (const auto &field : fields) {
            if (keys.contains(field) || (table == "documents" && field == "url")) continue;
            assignments << field + "=?";
            values << row.value(field);
        }
        // A paper that arrived before its file was fingerprinted is fetched once the fingerprint is known.
        if (table == "documents" && row.value("kind").toString() != "web" && !row.value("sha256").toString().isEmpty()
            && row.value("removed_at").isNull()) {
            QSqlQuery url(m_db);
            if (!run(url, "SELECT url FROM documents WHERE " + where(keys), keyValues)) return false;
            const auto path = url.next() ? QUrl(url.value(0).toString()).toLocalFile() : QString();
            if (path.startsWith(m_papers + "/") && !QFileInfo::exists(path)
                && !run("INSERT OR IGNORE INTO sync_files(local,remote,outgoing) VALUES(?,?,0)",
                    {path, "Papers/" + row.value("sha256").toString() + ".pdf"}))
                return false;
        }
        if (assignments.isEmpty()) return true;
        return run("UPDATE " + table + " SET " + assignments.join(',') + " WHERE " + where(keys), values + keyValues);
    }
    if (table == "documents" && row.value("kind").toString() != "web") {
        const auto path = localPaperPath(row);
        row["url"] = QUrl::fromLocalFile(path).toString();
        const auto sha = row.value("sha256").toString();
        // Papers taken out of the Library are listed without their file (only Library papers are sent).
        if (!sha.isEmpty() && row.value("removed_at").isNull()
            && !run("INSERT OR IGNORE INTO sync_files(local,remote,outgoing) VALUES(?,?,0)",
                {path, "Papers/" + sha + ".pdf"}))
            return false;
    }
    const auto image = row.value("image").toString();
    if (!image.isEmpty() && table == "highlights") {
        if (!run("INSERT OR IGNORE INTO sync_files(local,remote,outgoing) VALUES(?,?,0)",
                {m_data + "/annotations/" + image, "Files/annotations/" + image}))
            return false;
    }
    for (const auto &field : fields) values << row.value(field);
    QStringList marks(fields.size(), "?");
    return run("INSERT INTO " + table + "(" + fields.join(',') + ") VALUES(" + marks.join(',') + ")", values);
}

// Papers from other computers are copied into the store's PDF folder, under their file name.
QString Pass::localPaperPath(const QVariantMap &row)
{
    const auto sha = row.value("sha256").toString();
    auto name = QUrl(row.value("url").toString()).fileName();
    if (name.isEmpty() || name.startsWith('.'))
        name = (sha.isEmpty() ? row.value("id").toString() : sha.left(16)) + ".pdf";
    const auto folder = m_papers + "/";
    const auto taken = [&](const QString &path) {
        QSqlQuery query(m_db);
        return QFileInfo::exists(path)
            || (run(query, "SELECT 1 FROM documents WHERE url=?", {QUrl::fromLocalFile(path).toString()})
                && query.next());
    };
    auto path = folder + name;
    if (taken(path)) {
        const auto base = QFileInfo(name).completeBaseName();
        path = folder + base + " " + (sha.isEmpty() ? row.value("id").toString() : sha).left(8) + ".pdf";
        if (taken(path)) path = folder + base + " " + row.value("id").toString() + ".pdf";
    }
    return path;
}

bool Pass::exportChanges()
{
    struct Dirty {
        QString table, key, device;
        qint64 time;
    };
    QList<Dirty> dirty;
    {
        QSqlQuery query(m_db);
        if (!run(query, "SELECT tbl,key,time,device FROM sync_dirty")) return false;
        while (query.next())
            dirty.append({query.value(0).toString(), query.value(1).toString(),
                query.value(3).isNull() ? m_device : query.value(3).toString(), query.value(2).toLongLong()});
    }
    if (dirty.isEmpty()) return true;
    std::stable_sort(dirty.begin(), dirty.end(), [](const Dirty &a, const Dirty &b) {
        return std::pair(tableIndex(a.table), a.time) < std::pair(tableIndex(b.table), b.time);
    });
    QByteArray lines;
    QList<Dirty> written;
    for (const auto &change : std::as_const(dirty)) {
        const int index = tableIndex(change.table);
        const auto keyArray = QJsonDocument::fromJson(change.key.toUtf8()).array();
        written << change;
        if (index < 0 || keyArray.size() != tables()[index].keys.size()) continue;
        const auto &keys = tables()[index].keys;
        QVariantList keyValues;
        for (const auto &value : keyArray) keyValues << value.toVariant();
        QSqlQuery query(m_db);
        if (!run(query, "SELECT * FROM " + change.table + " WHERE " + where(keys), keyValues)) return false;
        QJsonValue row = QJsonValue::Null;
        if (query.next()) {
            QJsonObject object;
            const auto record = query.record();
            for (int i = 0; i < record.count(); ++i)
                object.insert(record.fieldName(i),
                    query.value(i).isNull() ? QJsonValue(QJsonValue::Null) : QJsonValue::fromVariant(query.value(i)));
            const auto text = [&](const char *name) { return object.value(name).toString(); };
            if (change.table == "ai_threads" && QUrl(text("source")).isLocalFile()) {
                QSqlQuery paper(m_db);
                if (run(paper, "SELECT id FROM documents WHERE url=?", {text("source")}) && paper.next())
                    object.insert("_source_document", paper.value(0).toString());
            }
            // Files the row needs go to the folder after the rows (the other computer waits for them).
            QString local, remote;
            if (change.table == "documents" && text("kind") == "pdf" && object.value("removed_at").isNull()
                && !text("sha256").isEmpty()) {
                local = QUrl(text("url")).toLocalFile();
                remote = "Papers/" + text("sha256") + ".pdf";
            } else if (change.table == "highlights" && !text("image").isEmpty()) {
                local = m_data + "/annotations/" + text("image");
                remote = "Files/annotations/" + text("image");
            }
            if (!local.isEmpty() && QFileInfo::exists(local) && !QFileInfo::exists(m_folder + "/" + remote)
                && !run("INSERT OR IGNORE INTO sync_files(local,remote,outgoing) VALUES(?,?,1)", {local, remote}))
                return false;
            row = object;
        }
        lines += QJsonDocument(QJsonObject{{"t", change.table}, {"k", keyArray}, {"v", change.time},
                                   {"d", change.device}, {"r", row}})
                     .toJson(QJsonDocument::Compact)
            + '\n';
    }
    if (!lines.isEmpty() && !writeSegments(lines)) return false;
    // Rows changed again while this pass ran keep their newer mark.
    if (!m_db.transaction()) {
        outcome.error = m_db.lastError().text();
        return false;
    }
    for (const auto &change : std::as_const(written)) {
        if (!run("INSERT OR REPLACE INTO sync_rows(tbl,key,time,device) VALUES(?,?,?,?)",
                {change.table, change.key, change.time, change.device})
            || !run(
                "DELETE FROM sync_dirty WHERE tbl=? AND key=? AND time=?", {change.table, change.key, change.time})) {
            m_db.rollback();
            return false;
        }
    }
    if (!m_db.commit()) {
        outcome.error = m_db.lastError().text();
        m_db.rollback();
        return false;
    }
    outcome.sent += written.size();
    return true;
}

bool Pass::writeSegments(const QByteArray &lines)
{
    const auto folder = m_folder + "/devices/" + m_device;
    if (!QDir().mkpath(folder)) {
        outcome.error = "Cannot write to the sync folder.";
        return false;
    }
    if (!QFileInfo::exists(folder + "/device.json")) {
        QFile about(folder + "/device.json");
        if (about.open(QIODevice::WriteOnly))
            about.write(QJsonDocument(
                QJsonObject{{"name", QSysInfo::machineHostName()}, {"system", QSysInfo::prettyProductName()}})
                    .toJson());
    }
    const auto existing = QDir(folder).entryList({"*.jsonl"}, QDir::Files, QDir::Name);
    int sequence = existing.isEmpty() ? 1 : QFileInfo(existing.last()).baseName().toInt();
    if (!existing.isEmpty()) {
        // Continue the last file only if it ends with a whole line.
        QFile last(folder + "/" + existing.last());
        bool whole = false;
        if (last.size() < segmentLimit && last.open(QIODevice::ReadOnly)) {
            whole = last.size() == 0 || (last.seek(last.size() - 1) && last.read(1) == "\n");
            last.close();
        }
        if (!whole) ++sequence;
    }
    qsizetype start = 0;
    while (start < lines.size()) {
        QFile file(folder + "/" + segmentName(sequence));
        if (!file.open(QIODevice::Append)) {
            outcome.error = "Cannot write to the sync folder.";
            return false;
        }
        // Whole lines up to the size limit (at least one line per file).
        qsizetype end = start;
        while (end < lines.size()) {
            const auto next = lines.indexOf('\n', end) + 1;
            if (end > start && file.size() + (next - start) > segmentLimit) break;
            end = next;
        }
        if (file.write(lines.mid(start, end - start)) != end - start || !file.flush()) {
            outcome.error = "Cannot write to the sync folder.";
            return false;
        }
        start = end;
        if (start < lines.size()) ++sequence;
    }
    return true;
}

void Pass::moveFiles()
{
    struct Item {
        QString local, remote;
        bool outgoing;
    };
    QList<Item> items;
    {
        QSqlQuery query(m_db);
        if (!run(query, "SELECT local,remote,outgoing FROM sync_files")) return;
        while (query.next())
            items.append({query.value(0).toString(), query.value(1).toString(), query.value(2).toBool()});
    }
    for (const auto &item : std::as_const(items)) {
        if (m_cancel->load()) return;
        const auto remote = m_folder + "/" + item.remote;
        bool done = true;
        if (item.outgoing) {
            if (!QFileInfo::exists(remote) && QFileInfo::exists(item.local)) done = copyFile(item.local, remote);
        } else {
            const auto &local = item.local;
            if (!QFileInfo::exists(local)) {
                if (!QFileInfo::exists(remote)) {
                    ++outcome.waiting; // Not here yet: the sync program is still bringing it.
                    continue;
                }
                done = copyFile(remote, local);
                if (done && item.remote.startsWith("Papers/"))
                    outcome.newSources << QUrl::fromLocalFile(local).toString();
            }
        }
        if (done)
            run("DELETE FROM sync_files WHERE local=? AND remote=? AND outgoing=?",
                {item.local, item.remote, item.outgoing});
    }
}

bool markerMatches(const QString &folder, const QString &library)
{
    return !library.isEmpty() && readJson(folder + "/" + markerName).value("library").toString() == library;
}

LibrarySync::Outcome runPass(const QString &data, const QString &papers, const QString &folder, const QString &device,
    const QString &library, std::shared_ptr<std::atomic_bool> cancel, bool exportOnly)
{
    if (!markerMatches(folder, library)) {
        LibrarySync::Outcome outcome;
        outcome.error
            = "The sync folder is not available. Check that its sync program (Google Drive, Dropbox, …) is running.";
        return outcome;
    }
    WorkerConnection connection(data + "/owelk.sqlite3");
    Pass pass(connection.db, data, papers, folder, device, std::move(cancel));
    if (!connection.db.isOpen()) {
        pass.outcome.error = connection.db.lastError().text();
        return pass.outcome;
    }
    if (!exportOnly && !pass.importChanges()) return pass.outcome;
    if (!pass.exportChanges()) return pass.outcome;
    if (!exportOnly) pass.moveFiles();
    return pass.outcome;
}
} // namespace

LibrarySync::LibrarySync(const QString &dataDirectory, QObject *parent) : QObject(parent), m_directory(dataDirectory)
{
    m_pool.setMaxThreadCount(1);
    m_timer.setInterval(30000);
    connect(&m_timer, &QTimer::timeout, this, &LibrarySync::syncNow);
}

LibrarySync::~LibrarySync()
{
    m_cancel->store(true);
    m_pool.waitForDone();
}

void LibrarySync::start()
{
    WorkerConnection db(m_directory + "/owelk.sqlite3");
    m_folder = setting(db.db, "sync.folder");
    m_device = setting(db.db, "sync.device");
    m_library = setting(db.db, "sync.library");
    if (m_folder.isEmpty()) return;
    QString error;
    if (!installTracking(db.db, &error)) m_status = error;
    m_timer.start();
    QTimer::singleShot(2000, this, &LibrarySync::syncNow);
    emit changed();
}

QString LibrarySync::setFolder(const QUrl &chosen)
{
    auto path = chosen.isLocalFile() ? chosen.toLocalFile() : chosen.toString();
    if (path.isEmpty() || !QFileInfo(path).isDir()) return "Choose a folder.";
    path = QDir(path).absolutePath();
    // Owelk always keeps its files in an "Owelk" folder inside the chosen one (choosing that folder
    // itself, or an existing sync folder, works too), so any drive folder gives the same place.
    if (!QFileInfo::exists(path + "/" + markerName) && QFileInfo(path).fileName() != "Owelk") path += "/Owelk";
    if (!QDir().mkpath(path)) return "Owelk cannot write to this folder.";
    auto library = readJson(path + "/" + markerName).value("library").toString();
    if (library.isEmpty()) {
        library = QUuid::createUuid().toString(QUuid::WithoutBraces);
        QFile marker(path + "/" + markerName);
        if (!marker.open(QIODevice::WriteOnly)
            || marker.write(QJsonDocument(QJsonObject{{"app", "Owelk"}, {"library", library},
                                              {"created", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}})
                       .toJson())
                <= 0)
            return "Owelk cannot write to this folder.";
    }
    m_cancel->store(true);
    m_pool.waitForDone();
    m_cancel = std::make_shared<std::atomic_bool>(false);
    WorkerConnection db(m_directory + "/owelk.sqlite3");
    QString error;
    if (!installTracking(db.db, &error)) return error;
    // A copied data folder (a backup restored on another computer) must not write as this one.
    const auto machine = QString::fromLatin1(QSysInfo::machineUniqueId());
    if (m_device.isEmpty() || (!machine.isEmpty() && setting(db.db, "sync.machine") != machine)) {
        m_device = QUuid::createUuid().toString(QUuid::WithoutBraces);
        setSetting(db.db, "sync.device", m_device);
        setSetting(db.db, "sync.machine", machine);
    }
    if (library != m_library && !markEverything(db.db, &error)) return error;
    if (!setSetting(db.db, "sync.folder", path) || !setSetting(db.db, "sync.library", library))
        return "Cannot save the sync folder.";
    m_folder = path;
    m_library = library;
    m_status.clear();
    m_timer.start();
    emit changed();
    syncNow();
    return {};
}

void LibrarySync::turnOff()
{
    m_timer.stop();
    m_cancel->store(true);
    m_pool.waitForDone();
    m_cancel = std::make_shared<std::atomic_bool>(false);
    WorkerConnection db(m_directory + "/owelk.sqlite3");
    setSetting(db.db, "sync.folder", QString());
    m_folder.clear();
    m_status.clear();
    m_computers.clear();
    emit changed();
}

void LibrarySync::syncNow()
{
    if (m_folder.isEmpty()) return;
    if (m_running) {
        m_again = true;
        return;
    }
    m_running = true;
    emit changed();
    auto *watcher = new QFutureWatcher<Outcome>(this);
    connect(watcher, &QFutureWatcher<Outcome>::finished, this, [this, watcher] {
        watcher->deleteLater();
        finished(watcher->result());
    });
    watcher->setFuture(
        QtConcurrent::run(&m_pool, runPass, m_directory, m_papers, m_folder, m_device, m_library, m_cancel, false));
}

LibrarySync::Outcome LibrarySync::syncBlocking()
{
    // A pass already started in the background reports first.
    while (m_running) {
        m_pool.waitForDone();
        QCoreApplication::processEvents();
    }
    const auto outcome = runPass(m_directory, m_papers, m_folder, m_device, m_library, m_cancel, false);
    m_running = true;
    finished(outcome);
    return outcome;
}

void LibrarySync::finish()
{
    m_timer.stop();
    if (m_folder.isEmpty()) return;
    m_cancel->store(true);
    m_pool.waitForDone();
    runPass(m_directory, m_papers, m_folder, m_device, m_library, m_cancel, true);
    m_folder.clear();
}

void LibrarySync::finished(const Outcome &outcome)
{
    m_running = false;
    m_computers = outcome.computers;
    if (!outcome.error.isEmpty())
        m_status = outcome.error;
    else
        m_status = "Synced at " + QLocale().toString(QTime::currentTime(), QLocale::ShortFormat)
            + (outcome.waiting ? QStringLiteral(" · waiting for %1 files from the folder").arg(outcome.waiting)
                               : QString());
    emit changed();
    if (outcome.received || !outcome.newSources.isEmpty()) emit received(outcome.tables, outcome.newSources);
    if (m_again) {
        m_again = false;
        syncNow();
    }
}
