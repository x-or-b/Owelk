#include "ResearchStore.h"

#include <QDateTime>
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
        emit message("Cannot start an AI thread.");
        return {};
    }
    // A thread about a paper links to it, so the paper's Links tab finds the conversation.
    const auto document = findDocument(source);
    if (!document.isEmpty()) addLink("ai", id, "document", document);
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
    const auto capture = message.value("context").toMap().value("captureId").toString();
    if (!capture.isEmpty()) addLink("ai", threadId, "capture", capture);
    emit aiThreadsChanged();
    return true;
}

QVariantList ResearchStore::aiThreads() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec(
        "SELECT t.id,t.title,t.provider,t.model,t.source,t.updated_at,(SELECT count(*) FROM ai_messages m "
        "WHERE m.thread_id=t.id) FROM ai_threads t WHERE t.trashed_at IS NULL ORDER BY t.updated_at DESC LIMIT 500");
    while (query.next())
        rows.append(QVariantMap{{"id", query.value(0)}, {"title", query.value(1)}, {"provider", query.value(2)},
            {"model", query.value(3)}, {"source", QUrl(query.value(4).toString())}, {"updatedAt", query.value(5)},
            {"messages", query.value(6)}});
    return rows;
}

QVariantMap ResearchStore::aiThread(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT title,provider,model,source,created_at,updated_at FROM ai_threads WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    QVariantMap thread{{"id", id}, {"title", query.value(0)}, {"provider", query.value(1)}, {"model", query.value(2)},
        {"source", QUrl(query.value(3).toString())}, {"createdAt", query.value(4)}, {"updatedAt", query.value(5)}};
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

QVariantList ResearchStore::trashedAiThreads() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    if (!query.exec("SELECT id,title,model,trashed_at FROM ai_threads WHERE trashed_at IS NOT NULL ORDER BY "
                    "trashed_at DESC"))
        return rows;
    const auto days = trashDays();
    while (query.next()) {
        const auto trashed = QDateTime::fromString(query.value(3).toString(), Qt::ISODateWithMs);
        rows.append(QVariantMap{{"id", query.value(0)}, {"title", query.value(1)}, {"model", query.value(2)},
            {"trashedAt", query.value(3)},
            {"daysLeft",
                days > 0 && trashed.isValid()
                    ? std::max<qint64>(0, days - trashed.daysTo(QDateTime::currentDateTimeUtc()))
                    : -1}});
    }
    return rows;
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
        emit message((moved == 1 ? QStringLiteral("Moved the conversation to the Trash.")
                                 : QString("Moved %1 conversations to the Trash.").arg(moved))
            + (days > 0 ? QString(" It is deleted for good after %1 days.").arg(days) : QString()));
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

int ResearchStore::emptyAiTrash()
{
    QStringList ids;
    for (const auto &row : trashedAiThreads()) ids << row.toMap().value("id").toString();
    return purgeAiThreads(ids);
}

void ResearchStore::purgeExpiredAiThreads()
{
    const auto days = trashDays();
    if (days <= 0) return;
    QSqlQuery query(m_database);
    query.prepare("SELECT id FROM ai_threads WHERE trashed_at IS NOT NULL AND trashed_at<?");
    query.addBindValue(QDateTime::currentDateTimeUtc().addDays(-days).toString(Qt::ISODateWithMs));
    QStringList ids;
    if (query.exec())
        while (query.next()) ids << query.value(0).toString();
    query.finish();
    purgeAiThreads(ids);
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

QString ResearchStore::saveAiResponse(const QVariantMap &response)
{
    // A single question and answer as a one-turn thread.
    const auto answer = response.value("answer").toString();
    if (answer.trimmed().isEmpty() || answer.size() > 400000) return {};
    const auto question = response.value("question").toString().simplified();
    const auto id = createAiThread({{"title", question.isEmpty() ? response.value("action").toString() : question},
        {"provider", response.value("provider")}, {"model", response.value("model")},
        {"source", response.value("source")}});
    if (id.isEmpty()) return {};
    QVariantMap context{{"captureId", response.value("captureId")}, {"page", response.value("page")}};
    appendAiMessage(id,
        {{"role", "user"},
            {"content", response.value("prompt").toString().isEmpty() ? question : response.value("prompt")},
            {"display", question}, {"context", context}});
    appendAiMessage(id, {{"role", "assistant"}, {"content", answer}, {"model", response.value("model")}});
    return id;
}

QVariantMap ResearchStore::aiResponse(const QString &id) const
{
    const auto thread = aiThread(id);
    if (thread.isEmpty()) return {};
    QString answer;
    for (const auto &value : thread.value("messages").toList())
        if (value.toMap().value("role") == "assistant") answer = value.toMap().value("content").toString();
    auto result = thread;
    result.insert("answer", answer);
    return result;
}
