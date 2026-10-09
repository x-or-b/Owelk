#include "ResearchStore.h"

#include <QDateTime>
#include <QSqlQuery>
#include <algorithm>

// One Trash for papers, notes and AI conversations. Each kind keeps its own mark (documents.trashed_at,
// notes.deleted_at, ai_threads.trashed_at) and its own delete/restore; this lists them together,
// restores or deletes chosen ones, and deletes for good what has been there longer than trash.days.

int ResearchStore::trashDays() const
{
    return setting("trash.days", "30").toInt();
}

QVariantList ResearchStore::trash() const
{
    QVariantList rows;
    const auto days = trashDays();
    const auto now = QDateTime::currentDateTimeUtc();
    const auto add = [&](const QString &kind, const QVariant &id, const QString &title, const QString &detail,
                         const QString &at, const QUrl &url = {}) {
        const auto trashed = QDateTime::fromString(at, Qt::ISODateWithMs);
        rows.append(QVariantMap{{"kind", kind}, {"id", id}, {"title", title}, {"detail", detail}, {"trashedAt", at},
            {"url", url},
            {"daysLeft", days > 0 && trashed.isValid() ? std::max<qint64>(0, days - trashed.daysTo(now)) : -1}});
    };
    QSqlQuery query(m_database);
    if (query.exec("SELECT id,url,trashed_at FROM documents WHERE trashed_at IS NOT NULL"))
        while (query.next()) {
            const QUrl url(query.value(1).toString());
            add("paper", query.value(0), displayName(url), fileName(url), query.value(2).toString(), url);
        }
    if (query.exec("SELECT id,title,deleted_at,substr(body,1,160) FROM notes WHERE deleted_at IS NOT NULL"))
        while (query.next())
            add("note", query.value(0),
                query.value(1).toString().isEmpty() ? "Untitled note" : query.value(1).toString(),
                query.value(3).toString().simplified(), query.value(2).toString());
    if (query.exec("SELECT id,title,trashed_at FROM ai_threads WHERE trashed_at IS NOT NULL"))
        while (query.next())
            add("ai", query.value(0), query.value(1).toString(), "AI conversation", query.value(2).toString());
    std::sort(rows.begin(), rows.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap()["trashedAt"].toString() > b.toMap()["trashedAt"].toString();
    });
    return rows;
}

int ResearchStore::trashCount() const
{
    QSqlQuery query(m_database);
    return query.exec("SELECT (SELECT count(*) FROM documents WHERE trashed_at IS NOT NULL)+(SELECT count(*) FROM "
                      "notes WHERE deleted_at IS NOT NULL)+(SELECT count(*) FROM ai_threads WHERE trashed_at IS NOT "
                      "NULL)")
            && query.next()
        ? query.value(0).toInt()
        : 0;
}

namespace {
// Trash rows (or {kind, id}) split by kind; papers by URL.
struct Chosen {
    QVariantList papers;
    QStringList notes, threads;
};
}

static Chosen sortOut(const QVariantList &items, const QSqlDatabase &db)
{
    Chosen chosen;
    for (const auto &value : items) {
        const auto item = value.toMap();
        const auto kind = item["kind"].toString(), id = item["id"].toString();
        if (kind == "note")
            chosen.notes << id;
        else if (kind == "ai")
            chosen.threads << id;
        else if (kind == "paper") {
            auto url = item["url"].toUrl();
            if (url.isEmpty()) {
                QSqlQuery query(db);
                query.prepare("SELECT url FROM documents WHERE id=?");
                query.addBindValue(id);
                if (query.exec() && query.next()) url = QUrl(query.value(0).toString());
            }
            if (!url.isEmpty()) chosen.papers << url;
        }
    }
    return chosen;
}

int ResearchStore::restoreFromTrash(const QVariantList &items)
{
    const auto chosen = sortOut(items, m_database);
    int restored = restorePapers(chosen.papers) + trashAiThreads(chosen.threads, false);
    for (const auto &id : chosen.notes) restored += restoreNote(id);
    return restored;
}

int ResearchStore::deleteForGood(const QVariantList &items)
{
    const auto chosen = sortOut(items, m_database);
    int deleted = purgePapers(chosen.papers) + purgeAiThreads(chosen.threads);
    for (const auto &id : chosen.notes) deleted += purgeNote(id);
    return deleted;
}

int ResearchStore::emptyTrash()
{
    return deleteForGood(trash());
}

int ResearchStore::notesLinkingTo(const QVariantList &items) const
{
    QSet<QString> notes;
    for (const auto &value : items) {
        const auto item = value.toMap();
        const auto kind = item["kind"].toString() == "paper" ? QStringLiteral("document") : item["kind"].toString();
        QSqlQuery query(m_database);
        query.prepare("SELECT from_id FROM links WHERE from_kind='note' AND to_kind=? AND to_id=? AND from_id IN "
                      "(SELECT id FROM notes WHERE deleted_at IS NULL)");
        query.addBindValue(kind);
        query.addBindValue(item["id"].toString());
        if (query.exec())
            while (query.next()) notes.insert(query.value(0).toString());
    }
    return int(notes.size());
}

void ResearchStore::purgeExpired()
{
    const auto days = trashDays();
    if (days <= 0) return;
    const auto cutoff = QDateTime::currentDateTimeUtc().addDays(-days).toString(Qt::ISODateWithMs);
    QVariantList expired;
    for (const auto &row : trash())
        if (row.toMap()["trashedAt"].toString() < cutoff) expired << row;
    if (!expired.isEmpty()) deleteForGood(expired);
}
