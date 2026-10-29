#include "ResearchStore.h"
#include "UiText.h"

#include <QDateTime>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlQuery>
#include <QUuid>

namespace {
QString now()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}
QString text(const QString &value)
{
    return value.isNull() ? QStringLiteral("") : value;
}
}

QString ResearchStore::createAiThread(const QVariantMap &thread)
{
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const auto source = thread.value("source").toUrl();
    auto title = thread.value("title").toString().simplified().left(160);
    if (title.isEmpty())
        title = source.isValid() && !source.isEmpty() ? displayName(source) : QStringLiteral("New thread");
    // In the folder it was started in; otherwise in its paper's or collection's own folder, made on first
    // use (the same ID on every computer, so synced folders meet), or unfiled.
    const auto document = findDocument(source);
    const auto collection = thread.value("collection").toString();
    auto folder = thread.value("folder").toString();
    if (!folder.isEmpty()) {
        QSqlQuery known(m_database);
        known.prepare("SELECT 1 FROM ai_folders WHERE id=?");
        known.addBindValue(folder);
        if (!known.exec() || !known.next()) folder.clear();
    } else if (!document.isEmpty() || !collection.isEmpty()) {
        folder = document.isEmpty() ? "collection:" + collection : "document:" + document;
        QSqlQuery made(m_database);
        made.prepare("INSERT OR IGNORE INTO ai_folders(id,name,created_at,updated_at) VALUES(?,'',?,?)");
        for (const auto &value : {folder, now(), now()}) made.addBindValue(value);
        if (!made.exec()) folder.clear();
    }
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_threads(id,title,provider,model,source,created_at,updated_at,folder_id) "
                  "VALUES(?,?,?,?,?,?,?,?)");
    for (const QString &value : {id, title, thread.value("provider").toString(), thread.value("model").toString(),
             source.isValid() ? source.toString() : QString(), now(), now()})
        query.addBindValue(text(value));
    query.addBindValue(folder.isEmpty() ? QVariant() : QVariant(folder));
    if (!query.exec()) {
        emit message(ui("Cannot start an AI thread."));
        return {};
    }
    // A thread about a paper links to it, so the paper's Links tab finds the conversation.
    if (!document.isEmpty()) addLink("ai", id, "document", document);
    emit aiThreadsChanged();
    return id;
}

bool ResearchStore::appendAiMessage(const QString &threadId, const QVariantMap &message)
{
    const auto role = message.value("role").toString();
    if (role != "user" && role != "assistant") return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_messages(id,thread_id,role,content,display,context_json,model,created_at) "
                  "SELECT ?,id,?,?,?,?,?,? FROM ai_threads WHERE id=?");
    query.addBindValue(QUuid::createUuid().toString(QUuid::WithoutBraces));
    query.addBindValue(role);
    query.addBindValue(text(message.value("content").toString()));
    query.addBindValue(text(message.value("display").toString()));
    query.addBindValue(QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(message.value("context").toMap())).toJson(QJsonDocument::Compact)));
    query.addBindValue(text(message.value("model").toString()));
    query.addBindValue(now());
    query.addBindValue(threadId);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    QSqlQuery touch(m_database);
    touch.prepare(
        "UPDATE ai_threads SET "
        "updated_at=?,provider=coalesce(nullif(?,''),provider),model=coalesce(nullif(?,''),model) WHERE id=?");
    touch.addBindValue(now());
    touch.addBindValue(text(message.value("provider").toString()));
    touch.addBindValue(text(message.value("model").toString()));
    touch.addBindValue(threadId);
    touch.exec();
    emit aiThreadsChanged();
    return true;
}

QVariantList ResearchStore::aiThreads(const QString &words) const
{
    QVariantList rows;
    QString filter;
    const auto needle = words.simplified();
    if (!needle.isEmpty())
        filter = " AND (t.title LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM ai_messages m WHERE m.thread_id=t.id AND "
                 "((m.role='user' AND m.display LIKE ? ESCAPE '\\') OR (m.role='assistant' AND m.content LIKE ? "
                 "ESCAPE '\\'))))";
    QSqlQuery query(m_database);
    query.prepare("SELECT t.id,t.title,t.provider,t.model,t.source,t.updated_at,(SELECT count(*) FROM ai_messages m "
                  "WHERE m.thread_id=t.id),max(coalesce(r.opened_at,''),t.updated_at) AS last,(SELECT l.to_id FROM "
                  "links l WHERE l.from_kind='ai' AND l.from_id=t.id AND l.to_kind='document' LIMIT 1),(SELECT f.id "
                  "FROM ai_folders f WHERE f.id=t.folder_id) FROM ai_threads t LEFT JOIN recent_items r ON "
                  "r.kind='ai' AND r.id=t.id WHERE t.trashed_at IS NULL"
        + filter + " ORDER BY last DESC LIMIT 2000");
    if (!needle.isEmpty()) {
        auto escaped = needle;
        escaped.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
        for (int i = 0; i < 3; ++i) query.addBindValue("%" + escaped + "%");
    }
    if (!query.exec()) return rows;
    while (query.next()) {
        const QUrl source(query.value(4).toString());
        rows.append(QVariantMap{{"id", query.value(0)}, {"title", query.value(1)}, {"provider", query.value(2)},
            {"model", query.value(3)}, {"source", source}, {"updatedAt", query.value(5)}, {"messages", query.value(6)},
            {"openedAt", query.value(7)}, {"document", query.value(8).toString()},
            {"paper", source.isLocalFile() ? displayName(source) : QString()}, {"folder", query.value(9).toString()}});
    }
    return rows;
}

QVariantList ResearchStore::aiFolders() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    // A paper's folder is named after the paper (or, once the paper is gone, a chat's file name).
    if (!query.exec("SELECT f.id,f.name,f.created_at,f.updated_at,coalesce((SELECT d.url FROM documents d WHERE f.id "
                    "LIKE 'document:%' AND d.id=substr(f.id,10)),(SELECT t.source FROM ai_threads t WHERE f.id LIKE "
                    "'document:%' AND t.folder_id=f.id AND t.source<>'' LIMIT 1)),(SELECT c.name FROM collections c "
                    "WHERE f.id LIKE 'collection:%' AND c.id=substr(f.id,12)) FROM ai_folders f"))
        return rows;
    while (query.next()) {
        const QUrl paper(query.value(4).toString());
        auto name = query.value(1).toString();
        if (name.isEmpty()) name = paper.isEmpty() ? query.value(5).toString() : displayName(paper);
        if (name.isEmpty()) name = ui("Untitled thread");
        rows.append(QVariantMap{{"id", query.value(0)}, {"name", name}, {"paper", paper}, {"createdAt", query.value(2)},
            {"updatedAt", query.value(3)}});
    }
    return rows;
}

QString ResearchStore::createAiFolder(const QString &name)
{
    const auto trimmed = name.simplified().left(160);
    if (trimmed.isEmpty()) return {};
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_folders(id,name,created_at,updated_at) VALUES(?,?,?,?)");
    for (const auto &value : {id, trimmed, now(), now()}) query.addBindValue(value);
    if (!query.exec()) return {};
    emit aiThreadsChanged();
    return id;
}

bool ResearchStore::renameAiFolder(const QString &id, const QString &name)
{
    const auto trimmed = name.simplified().left(160);
    if (trimmed.isEmpty()) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE ai_folders SET name=?,updated_at=? WHERE id=?");
    for (const auto &value : {trimmed, now(), id}) query.addBindValue(value);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit aiThreadsChanged();
    return true;
}

bool ResearchStore::deleteAiFolder(const QString &id)
{
    if (!m_database.transaction()) return false;
    QSqlQuery unfile(m_database), remove(m_database);
    unfile.prepare("UPDATE ai_threads SET folder_id=NULL WHERE folder_id=?");
    unfile.addBindValue(id);
    remove.prepare("DELETE FROM ai_folders WHERE id=?");
    remove.addBindValue(id);
    if (!unfile.exec() || !remove.exec() || remove.numRowsAffected() != 1 || !m_database.commit()) {
        m_database.rollback();
        return false;
    }
    emit aiThreadsChanged();
    return true;
}

int ResearchStore::moveAiThreads(const QStringList &ids, const QString &folderId)
{
    if (!folderId.isEmpty()) {
        QSqlQuery known(m_database);
        known.prepare("SELECT 1 FROM ai_folders WHERE id=?");
        known.addBindValue(folderId);
        if (!known.exec() || !known.next()) return 0;
    }
    int moved = 0;
    for (const auto &id : ids) {
        QSqlQuery query(m_database);
        query.prepare("UPDATE ai_threads SET folder_id=? WHERE id=? AND coalesce(folder_id,'')<>?");
        query.addBindValue(folderId.isEmpty() ? QVariant() : QVariant(folderId));
        query.addBindValue(id);
        query.addBindValue(folderId);
        if (query.exec()) moved += query.numRowsAffected();
    }
    // Moving files a chat, nothing more: a Thread's place among the recent ones stays as it was.
    if (!moved) return 0;
    emit aiThreadsChanged();
    return moved;
}

QVariantMap ResearchStore::aiThread(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT title,provider,model,source,created_at,updated_at,trashed_at IS NOT NULL,(SELECT f.id FROM "
                  "ai_folders f "
                  "WHERE f.id=ai_threads.folder_id) FROM ai_threads WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    QVariantMap thread{{"id", id}, {"title", query.value(0)}, {"provider", query.value(1)}, {"model", query.value(2)},
        {"source", QUrl(query.value(3).toString())}, {"createdAt", query.value(4)}, {"updatedAt", query.value(5)},
        {"trashed", query.value(6).toBool()}, {"folder", query.value(7).toString()}};
    QSqlQuery messages(m_database);
    messages.prepare("SELECT id,role,content,display,context_json,model,created_at FROM ai_messages WHERE thread_id=? "
                     "ORDER BY created_at, role DESC");
    messages.addBindValue(id);
    QVariantList list;
    if (messages.exec())
        while (messages.next())
            list.append(QVariantMap{{"id", messages.value(0)}, {"role", messages.value(1)},
                {"content", messages.value(2)}, {"display", messages.value(3)},
                {"context", QJsonDocument::fromJson(messages.value(4).toByteArray()).toVariant()},
                {"model", messages.value(5)}, {"createdAt", messages.value(6)}});
    thread.insert("messages", list);
    return thread;
}

bool ResearchStore::renameAiThread(const QString &id, const QString &title)
{
    const auto name = title.simplified().left(160);
    if (name.isEmpty()) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE ai_threads SET title=? WHERE id=?");
    query.addBindValue(name);
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit aiThreadsChanged();
    return true;
}

int ResearchStore::trashAiThreads(const QStringList &ids, bool trashed)
{
    // In the Trash a thread is hidden (list, search) but whole: restoring brings it back as it was.
    int moved = 0;
    const auto now = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
    for (const auto &id : ids) {
        QSqlQuery query(m_database);
        query.prepare(trashed ? "UPDATE ai_threads SET trashed_at=? WHERE id=? AND trashed_at IS NULL"
                              : "UPDATE ai_threads SET trashed_at=NULL WHERE id=? AND trashed_at IS NOT NULL");
        if (trashed) query.addBindValue(now);
        query.addBindValue(id);
        if (query.exec()) moved += query.numRowsAffected();
    }
    if (!moved) return 0;
    emit aiThreadsChanged();
    if (trashed) {
        const auto days = trashDays();
        emit message((moved == 1 ? ui("Moved the conversation to the Trash.")
                                 : QString(ui("Moved %1 conversations to the Trash.")).arg(moved))
            + (days > 0 ? QString(ui(" It is deleted for good after %1 days.")).arg(days) : QString()));
    }
    return moved;
}

int ResearchStore::purgeAiThreads(const QStringList &ids)
{
    int deleted = 0;
    for (const auto &id : ids)
        if (deleteAiThread(id)) ++deleted;
    return deleted;
}

bool ResearchStore::deleteAiThread(const QString &id)
{
    // Removes the conversation and its links; notes that quoted it keep their text.
    if (!m_database.transaction()) return false;
    const auto run = [&](const QString &sql, int bindings) {
        QSqlQuery query(m_database);
        query.prepare(sql);
        for (int i = 0; i < bindings; ++i) query.addBindValue(id);
        return query.exec();
    };
    const bool ok = run("DELETE FROM ai_messages WHERE thread_id=?", 1) && run("DELETE FROM ai_threads WHERE id=?", 1)
        && run("DELETE FROM ai_responses WHERE id=?", 1)
        && run("DELETE FROM links WHERE (from_kind='ai' AND from_id=?) OR (to_kind='ai' AND to_id=?)", 2);
    if (!ok || !m_database.commit()) {
        m_database.rollback();
        return false;
    }
    emit aiThreadsChanged();
    emit linksChanged();
    return true;
}
