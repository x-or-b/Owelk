#include "ResearchStore.h"
#include "PaperIndex.h"
#include "WorkerConnection.h"

#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSqlQuery>
#include <QtConcurrent>

namespace {
QString fileName(const QUrl &url)
{
    return QFileInfo(url.toLocalFile()).fileName();
}

QVariantMap readingPosition(const QSqlDatabase &db, const QUrl &source)
{
    QSqlQuery query(db);
    query.prepare("SELECT position FROM reading_positions WHERE url=?");
    query.addBindValue(source.toString());
    if (!query.exec() || !query.next()) return {};
    return QJsonDocument::fromJson(query.value(0).toByteArray()).object().toVariantMap();
}

QString snippet(const QString &text, int match, int needleSize)
{
    const int start = qMax(0, match - 60);
    return (start ? QStringLiteral("…") : QString()) + text.mid(start, qMax(200, needleSize));
}

// Saved names, notes, excerpts, annotations and workspaces. PDF body text is searched by PaperIndex.
// Runs on the UI thread for tests and on a worker with its own read-only connection for the app.
QVariantList findKnowledge(const QSqlDatabase &db, const QVariantList &captures, const QList<QUrl> &indexed,
    const QString &queryText, const QUrl &scope, const QString &target)
{
    const auto needle = queryText.trimmed();
    if (needle.isEmpty()) return {};
    const bool names = target == "all" || target == "filename";
    const bool saved = target == "all" || target == "captures";
    const auto inScope = [&](const QUrl &url) { return scope.isEmpty() || url == scope; };
    QVariantList results;

    if (names) {
        int count = 0;
        QSet<QUrl> matchedPapers;
        const auto addPaper = [&](const QUrl &url) {
            const QString title = fileName(url);
            if (count >= 20 || matchedPapers.contains(url) || !inScope(url)
                || !title.contains(needle, Qt::CaseInsensitive))
                return;
            results.append(QVariantMap{
                {"kind", "paper"}, {"title", title}, {"source", url}, {"position", readingPosition(db, url)}});
            matchedPapers.insert(url);
            ++count;
        };
        QSqlQuery papers(db);
        papers.exec("SELECT url FROM recent_documents ORDER BY opened_at DESC");
        while (papers.next() && count < 20) addPaper(QUrl(papers.value(0).toString()));
        for (const auto &url : indexed) addPaper(url);
    }

    if (saved) {
        QVariantList notes, excerpts;
        for (const auto &value : captures) {
            if (notes.size() >= 20 && excerpts.size() >= 20) break;
            const auto capture = value.toMap();
            if (!inScope(capture.value("source").toUrl())) continue;
            const auto title
                = capture.value("name").toString() + " · p. " + QString::number(capture.value("page").toInt() + 1);
            const auto note = capture.value("note").toString();
            const int noteMatch = notes.size() < 20 ? note.indexOf(needle, 0, Qt::CaseInsensitive) : -1;
            if (noteMatch >= 0)
                notes.append(
                    QVariantMap{{"kind", "note"}, {"id", capture.value("id")}, {"source", capture.value("source")},
                        {"title", "Note · " + title}, {"snippet", snippet(note, noteMatch, needle.size())}});
            if (excerpts.size() >= 20) continue;
            const auto text = capture.value("text").toString();
            const int textMatch = text.indexOf(needle, 0, Qt::CaseInsensitive);
            if (textMatch < 0 && !title.contains(needle, Qt::CaseInsensitive)) continue;
            excerpts.append(QVariantMap{{"kind", "capture"}, {"title", title}, {"id", capture.value("id")},
                {"source", capture.value("source")}, {"snippet", snippet(text, textMatch, needle.size())}});
        }
        results += notes;
        results += excerpts;
    }

    if (target == "all") {
        QSqlQuery highlights(db);
        highlights.prepare("SELECT id,source,page,text,body FROM highlights WHERE deleted_at IS NULL "
                           "AND instr(lower(text || ' ' || body),lower(?))>0 AND (?=1 OR source=?) "
                           "ORDER BY created_at DESC LIMIT 20");
        highlights.addBindValue(needle);
        highlights.addBindValue(scope.isEmpty());
        highlights.addBindValue(scope.toString());
        if (highlights.exec()) {
            while (highlights.next()) {
                const QUrl source(highlights.value(1).toString());
                const auto text = highlights.value(3).toString() + " " + highlights.value(4).toString();
                const int start = qMax(0, text.indexOf(needle, 0, Qt::CaseInsensitive) - 60);
                results.append(QVariantMap{{"kind", "highlight"}, {"id", highlights.value(0)}, {"source", source},
                    {"title", fileName(source) + " · p. " + QString::number(highlights.value(2).toInt() + 1)},
                    {"snippet", text.mid(start, qMax(200, needle.size()))}});
            }
        }
    }

    if (target == "all" && scope.isEmpty()) {
        QSqlQuery workspaces(db);
        workspaces.exec("SELECT id,name FROM workspaces WHERE id NOT IN (SELECT id FROM deleted_workspaces) ORDER BY "
                        "opened_at DESC");
        int count = 0;
        while (workspaces.next() && count < 20) {
            if (!workspaces.value(1).toString().contains(needle, Qt::CaseInsensitive)) continue;
            results.append(
                QVariantMap{{"kind", "workspace"}, {"title", workspaces.value(1)}, {"id", workspaces.value(0)}});
            ++count;
        }
    }
    return results;
}

QList<QUrl> indexedSources(const QSqlDatabase &db)
{
    QList<QUrl> sources;
    QSqlQuery query(db);
    query.exec("SELECT url FROM documents ORDER BY url");
    while (query.next()) sources.append(QUrl(query.value(0).toString()));
    return sources;
}
}

QVariantList ResearchStore::searchKnowledge(const QString &queryText, const QUrl &scope, const QString &target) const
{
    QList<QUrl> indexed;
    for (const auto &entry : m_index->documents()) indexed.append(entry.toMap().value("source").toUrl());
    return findKnowledge(m_database, m_captures, indexed, queryText, scope, target);
}

int ResearchStore::searchKnowledgeAsync(const QString &queryText, const QUrl &scope, const QString &target)
{
    const int request = ++m_knowledgeRequest;
    auto *watcher = new QFutureWatcher<QVariantList>(this);
    connect(watcher, &QFutureWatcher<QVariantList>::finished, this, [this, watcher, request] {
        const auto rows = watcher->result();
        watcher->deleteLater();
        emit knowledgeFound(request, rows);
    });
    // The capture list is an implicitly shared snapshot; later reloads detach and never touch this copy.
    watcher->setFuture(
        QtConcurrent::run(&m_verifiers, [directory = m_directory, captures = m_captures, queryText, scope, target] {
            WorkerConnection store(directory + "/owelk.sqlite3", true);
            WorkerConnection search(directory + "/search.sqlite3", true);
            if (!store.db.isOpen()) return QVariantList();
            return findKnowledge(store.db, captures, search.db.isOpen() ? indexedSources(search.db) : QList<QUrl>(),
                queryText, scope, target);
        }));
    return request;
}
