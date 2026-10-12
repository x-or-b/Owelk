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
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_threads(id,title,provider,model,source,created_at,updated_at) VALUES(?,?,?,?,?,?,?)");
    for (const QString &value : {id, title, thread.value("provider").toString(), thread.value("model").toString(),
             source.isValid() ? source.toString() : QString(), now(), now()})
        query.addBindValue(text(value));
    if (!query.exec()) {
        emit message(ui("Cannot start an AI thread."));
        return {};
    }
    // A thread about a paper links to it, so the paper's Links tab finds the conversation.
    const auto document = findDocument(source);
    if (!document.isEmpty()) addLink("ai", id, "document", document);
    // One asked of a collection is filed under it.
    const auto collection = thread.value("collection").toString();
    if (!collection.isEmpty()) setAiThreadCollection(id, collection, true);
    emit aiThreadsChanged();
    return id;
}

bool ResearchStore::appendAiMessage(const QString &threadId, const QVariantMap &message)
{
    const auto role = message.value("role").toString();
    if (role != "user" && role != "assistant") return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_messages SELECT ?,id,?,?,?,?,?,? FROM ai_threads WHERE id=?");
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
                  "links l WHERE l.from_kind='ai' AND l.from_id=t.id AND l.to_kind='document' LIMIT 1),(SELECT "
                  "group_concat(l.to_id,char(31)) FROM links l WHERE l.from_kind='ai' AND l.from_id=t.id AND "
                  "l.to_kind='collection') FROM ai_threads t LEFT JOIN recent_items r ON r.kind='ai' AND r.id=t.id "
                  "WHERE t.trashed_at IS NULL"
        + filter + " ORDER BY last DESC LIMIT 2000");
    if (!needle.isEmpty()) {
        auto escaped = needle;
        escaped.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
        for (int i = 0; i < 3; ++i) query.addBindValue("%" + escaped + "%");
    }
    if (!query.exec()) return rows;
    // The collections each paper is in, read once.
    QHash<QString, QStringList> paperCollections;
    QSqlQuery members(m_database);
    if (members.exec("SELECT cd.document_id,cd.collection_id FROM collection_documents cd WHERE cd.document_id IN "
                     "(SELECT to_id FROM links WHERE from_kind='ai' AND to_kind='document')"))
        while (members.next()) paperCollections[members.value(0).toString()] << members.value(1).toString();
    while (query.next()) {
        const QUrl source(query.value(4).toString());
        const auto document = query.value(8).toString();
        const auto chosen = query.value(9).toString().split(QChar(31), Qt::SkipEmptyParts);
        auto collections = chosen;
        for (const auto &id : paperCollections.value(document))
            if (!collections.contains(id)) collections << id;
        rows.append(QVariantMap{{"id", query.value(0)}, {"title", query.value(1)}, {"provider", query.value(2)},
            {"model", query.value(3)}, {"source", source}, {"updatedAt", query.value(5)}, {"messages", query.value(6)},
            {"openedAt", query.value(7)}, {"document", document},
            {"paper", source.isLocalFile() ? displayName(source) : QString()}, {"collections", collections},
            {"chosenCollections", chosen}});
    }
    return rows;
}

bool ResearchStore::setAiThreadCollection(const QString &id, const QString &collectionId, bool member)
{
    if (id.isEmpty() || collectionId.isEmpty()) return false;
    QSqlQuery query(m_database);
    query.prepare(member ? "INSERT OR IGNORE INTO links SELECT 'ai',t.id,'collection',c.id,? FROM ai_threads t, "
                           "collections c WHERE t.id=? AND c.id=?"
                         : "DELETE FROM links WHERE from_kind='ai' AND from_id=? AND to_kind='collection' AND to_id=?");
    if (member) query.addBindValue(now());
    query.addBindValue(id);
    query.addBindValue(collectionId);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit aiThreadsChanged();
    emit linksChanged();
    return true;
}

QVariantMap ResearchStore::aiThread(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT title,provider,model,source,created_at,updated_at,trashed_at IS NOT NULL FROM ai_threads WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    QVariantMap thread{{"id", id}, {"title", query.value(0)}, {"provider", query.value(1)}, {"model", query.value(2)},
        {"source", QUrl(query.value(3).toString())}, {"createdAt", query.value(4)}, {"updatedAt", query.value(5)},
        {"trashed", query.value(6).toBool()}};
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
    // The collections it is filed under (not the ones its paper is in).
    QSqlQuery filed(m_database);
    filed.prepare("SELECT c.id,c.name FROM links l JOIN collections c ON c.id=l.to_id WHERE l.from_kind='ai' AND "
                  "l.from_id=? AND l.to_kind='collection' ORDER BY c.name COLLATE NOCASE");
    filed.addBindValue(id);
    QVariantList collections;
    if (filed.exec())
        while (filed.next()) collections.append(QVariantMap{{"id", filed.value(0)}, {"name", filed.value(1)}});
    thread.insert("collections", collections);
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
