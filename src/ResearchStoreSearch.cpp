#include "ResearchStore.h"
#include "PaperIndex.h"
#include "WorkerConnection.h"

#include <QFileInfo>
#include <QHash>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QSqlQuery>
#include <QtConcurrent>
#include <algorithm>
#include <optional>

namespace {
QString fileName(const QUrl &url)
{
    return QFileInfo(url.toLocalFile()).fileName();
}

QVariantMap readingPosition(const QSqlDatabase &db, const QUrl &source)
{
    QSqlQuery query(db);
    query.prepare("SELECT r.position FROM reading_positions r JOIN documents d ON d.id=r.document_id WHERE d.url=?");
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
// allowed: when set, only papers with these URLs (library filters) and their saved items are searched.
QVariantList findKnowledge(const QSqlDatabase &db, const QVariantList &captures, const QList<QUrl> &indexed,
    const QString &queryText, const QUrl &scope, const QString &target, const std::optional<QSet<QString>> &allowed)
{
    const auto needle = queryText.trimmed();
    if (needle.isEmpty()) return {};
    const bool names = target == "all" || target == "filename";
    const bool saved = target == "all" || target == "captures";
    const auto inScope = [&](const QUrl &url) {
        return (scope.isEmpty() || url == scope) && (!allowed || allowed->contains(url.toString()));
    };
    QVariantList results;

    QHash<QString, QString> titles;
    {
        QSqlQuery query(db);
        query.exec("SELECT url,title FROM documents WHERE title<>''");
        while (query.next()) titles.insert(query.value(0).toString(), query.value(1).toString());
    }
    const auto displayName = [&](const QUrl &url) { return titles.value(url.toString(), fileName(url)); };

    if (names) {
        int count = 0;
        QSet<QUrl> matchedPapers;
        const auto contains = [&](const QString &text) { return text.contains(needle, Qt::CaseInsensitive); };
        const auto addPaper = [&](const QUrl &url, const QStringList &details) {
            const auto title = displayName(url);
            if (count >= 20 || matchedPapers.contains(url) || !inScope(url)) return;
            const bool named = contains(title) || contains(fileName(url));
            if (!named && std::none_of(details.cbegin(), details.cend(), contains)) return;
            QStringList shown;
            for (const auto &detail : details)
                if (!detail.isEmpty()) shown.append(detail);
            QVariantMap row{{"kind", "paper"}, {"title", title}, {"source", url},
                {"position", readingPosition(db, url)}, {"year", details.value(1)}};
            // Show why it matched when the hit is in the authors, year or identifiers rather than the name.
            if (!named) row.insert("snippet", shown.join(" · "));
            results.append(row);
            matchedPapers.insert(url);
            ++count;
        };
        QSqlQuery papers(db);
        papers.exec("SELECT d.url,d.authors,d.year,d.doi,d.arxiv FROM documents d "
                    "LEFT JOIN recent_documents r ON r.document_id=d.id ORDER BY r.opened_at IS NULL,r.opened_at DESC");
        while (papers.next() && count < 20)
            addPaper(QUrl(papers.value(0).toString()),
                {papers.value(1).toString(), papers.value(2).toString(), papers.value(3).toString(),
                    papers.value(4).toString().isEmpty() ? QString() : "arXiv:" + papers.value(4).toString()});
        for (const auto &url : indexed) addPaper(url, {});
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
            // Region captures are found by their figure or table caption.
            const auto text = capture.value("text").toString().isEmpty() ? capture.value("caption").toString()
                                                                         : capture.value("text").toString();
            const int textMatch = text.indexOf(needle, 0, Qt::CaseInsensitive);
            // Captures match their paper's title or file name as well as their text.
            if (textMatch < 0 && !title.contains(needle, Qt::CaseInsensitive)
                && !fileName(capture.value("source").toUrl()).contains(needle, Qt::CaseInsensitive))
                continue;
            excerpts.append(QVariantMap{{"kind", "capture"}, {"title", title}, {"id", capture.value("id")},
                {"source", capture.value("source")}, {"snippet", snippet(text, textMatch, needle.size())}});
        }
        results += notes;
        results += excerpts;
    }

    if (target == "all") {
        QSqlQuery highlights(db);
        highlights.prepare(
            "SELECT h.id,d.url,h.page,h.text,h.body FROM highlights h JOIN documents d ON d.id=h.document_id "
            "WHERE h.deleted_at IS NULL AND instr(lower(h.text || ' ' || h.body),lower(?))>0 "
            "AND (?=1 OR d.url=?) ORDER BY h.created_at DESC LIMIT 20");
        highlights.addBindValue(needle);
        highlights.addBindValue(scope.isEmpty());
        highlights.addBindValue(scope.toString());
        if (highlights.exec()) {
            while (highlights.next()) {
                const QUrl source(highlights.value(1).toString());
                if (!inScope(source)) continue;
                const auto text = highlights.value(3).toString() + " " + highlights.value(4).toString();
                const int start = qMax(0, text.indexOf(needle, 0, Qt::CaseInsensitive) - 60);
                results.append(QVariantMap{{"kind", "highlight"}, {"id", highlights.value(0)}, {"source", source},
                    {"title", displayName(source) + " · p. " + QString::number(highlights.value(2).toInt() + 1)},
                    {"snippet", text.mid(start, qMax(200, needle.size()))}});
            }
        }
    }

    if ((target == "all" || target == "captures") && scope.isEmpty() && !allowed) {
        // Standalone notes belong to no paper, so a paper scope leaves them out.
        QSqlQuery notes(db);
        notes.prepare(
            "SELECT id,title,body FROM notes WHERE deleted_at IS NULL AND "
            "(instr(lower(title),lower(?))>0 OR instr(lower(body),lower(?))>0) ORDER BY updated_at DESC LIMIT 20");
        notes.addBindValue(needle);
        notes.addBindValue(needle);
        if (notes.exec())
            while (notes.next()) {
                const auto body = notes.value(2).toString();
                const auto title = notes.value(1).toString();
                results.append(QVariantMap{{"kind", "standalone-note"}, {"id", notes.value(0)},
                    {"title", "Note · " + (title.isEmpty() ? QStringLiteral("Untitled") : title)},
                    {"snippet", snippet(body, body.indexOf(needle, 0, Qt::CaseInsensitive), needle.size())}});
            }
    }
    if (target == "all" && scope.isEmpty() && !allowed) {
        QSqlQuery answers(db);
        // One result per thread: its title, or the latest message mentioning the words.
        answers.prepare(
            "SELECT t.id,t.title,(SELECT m.display || ' ' || m.content FROM ai_messages m WHERE m.thread_id=t.id "
            "AND instr(lower(m.display || ' ' || m.content),lower(?))>0 ORDER BY m.created_at DESC LIMIT 1) AS hit "
            "FROM ai_threads t WHERE instr(lower(t.title),lower(?))>0 OR hit IS NOT NULL ORDER BY t.updated_at DESC "
            "LIMIT 10");
        answers.addBindValue(needle);
        answers.addBindValue(needle);
        if (answers.exec())
            while (answers.next()) {
                const auto answer = answers.value(2).toString();
                results.append(QVariantMap{{"kind", "ai"}, {"id", answers.value(0)},
                    {"title", "AI · " + answers.value(1).toString()},
                    {"snippet", snippet(answer, answer.indexOf(needle, 0, Qt::CaseInsensitive), needle.size())}});
            }
    }
    if (target == "all" && scope.isEmpty() && !allowed) {
        // Collections and tags open the library filtered to them.
        for (const auto &[kind, sql] : {std::pair{"collection", "SELECT id,name FROM collections"},
                 std::pair{"tag", "SELECT id,name FROM tags"}}) {
            QSqlQuery query(db);
            query.exec(sql);
            int count = 0;
            while (query.next() && count < 10) {
                if (!query.value(1).toString().contains(needle, Qt::CaseInsensitive)) continue;
                results.append(QVariantMap{{"kind", kind}, {"id", query.value(0)},
                    {"title", (QString(kind) == "tag" ? "Tag · " : "Collection · ") + query.value(1).toString()}});
                ++count;
            }
        }
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

namespace {
std::optional<QSet<QString>> allowedUrls(const QVariant &scopeUrls)
{
    if (!scopeUrls.isValid() || scopeUrls.isNull()) return std::nullopt;
    QSet<QString> urls;
    for (const auto &value : scopeUrls.toList()) urls.insert(value.toUrl().toString());
    return urls;
}
}

QVariantList ResearchStore::searchKnowledge(
    const QString &queryText, const QUrl &scope, const QString &target, const QVariant &scopeUrls) const
{
    QList<QUrl> indexed;
    for (const auto &entry : m_index->documents()) indexed.append(entry.toMap().value("source").toUrl());
    return findKnowledge(m_database, m_captures, indexed, queryText, scope, target, allowedUrls(scopeUrls));
}

int ResearchStore::searchKnowledgeAsync(
    const QString &queryText, const QUrl &scope, const QString &target, const QVariant &scopeUrls)
{
    const auto allowed = allowedUrls(scopeUrls);
    const int request = ++m_knowledgeRequest;
    auto *watcher = new QFutureWatcher<QVariantList>(this);
    connect(watcher, &QFutureWatcher<QVariantList>::finished, this, [this, watcher, request] {
        const auto rows = watcher->result();
        watcher->deleteLater();
        emit knowledgeFound(request, rows);
    });
    // The capture list is an implicitly shared snapshot; later reloads detach and never touch this copy.
    watcher->setFuture(QtConcurrent::run(
        &m_verifiers, [directory = m_directory, captures = m_captures, queryText, scope, target, allowed] {
            WorkerConnection store(directory + "/owelk.sqlite3", true);
            WorkerConnection search(directory + "/search.sqlite3", true);
            if (!store.db.isOpen()) return QVariantList();
            return findKnowledge(store.db, captures, search.db.isOpen() ? indexedSources(search.db) : QList<QUrl>(),
                queryText, scope, target, allowed);
        }));
    return request;
}
