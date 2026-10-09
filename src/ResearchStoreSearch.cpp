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

// The words of a query. Every word has to appear (in any order, in any of an item's fields); the score
// prefers titles over bodies, whole words over prefixes over fragments, and the phrase as typed.
struct Query {
    QString phrase;
    QStringList terms;
    QString probe; // The longest word, for cheap SQL prefilters.
    explicit Query(const QString &text) : phrase(text.simplified())
    {
        terms = phrase.split(' ', Qt::SkipEmptyParts).mid(0, 8);
        for (const auto &term : std::as_const(terms))
            if (term.size() > probe.size()) probe = term;
    }
    bool matches(const QStringList &fields) const
    {
        return std::all_of(terms.cbegin(), terms.cend(), [&](const QString &term) {
            return std::any_of(fields.cbegin(), fields.cend(),
                [&](const QString &field) { return field.contains(term, Qt::CaseInsensitive); });
        });
    }
    static int termScore(const QString &text, const QString &term, int whole, int prefix, int part)
    {
        int best = 0;
        for (qsizetype at = text.indexOf(term, 0, Qt::CaseInsensitive); at >= 0 && best < whole;
            at = text.indexOf(term, at + 1, Qt::CaseInsensitive)) {
            const bool starts = at == 0 || !text.at(at - 1).isLetterOrNumber();
            const auto end = at + term.size();
            const bool ends = end >= text.size() || !text.at(end).isLetterOrNumber();
            best = std::max(best, starts && ends ? whole : starts ? prefix : part);
        }
        return best;
    }
    int score(const QString &title, const QString &body = {}) const
    {
        int total = 0;
        for (const auto &term : terms)
            total += std::max(termScore(title, term, 30, 20, 10), termScore(body, term, 8, 5, 3));
        if (terms.size() > 1 && title.contains(phrase, Qt::CaseInsensitive)) total += 25;
        if (title.startsWith(phrase, Qt::CaseInsensitive)) total += 15;
        return total;
    }
    // Where to cut a snippet: the first word found.
    int firstHit(const QString &text) const
    {
        int first = -1;
        for (const auto &term : terms) {
            const int at = text.indexOf(term, 0, Qt::CaseInsensitive);
            if (at >= 0 && (first < 0 || at < first)) first = at;
        }
        return first;
    }
};

// Saved names, notes, excerpts, annotations and workspaces. PDF body text is searched by PaperIndex.
// Runs on the UI thread for tests and on a worker with its own read-only connection for the app.
// allowed: when set, only papers with these URLs (library filters) and their saved items are searched.
QVariantList findKnowledge(const QSqlDatabase &db, const QVariantList &captures, const QList<QUrl> &indexed,
    const QString &queryText, const QUrl &scope, const QString &target, const std::optional<QSet<QString>> &allowed)
{
    const Query query(queryText);
    if (query.terms.isEmpty()) return {};
    const auto needle = query.phrase;
    const bool names = target == "all" || target == "filename";
    const bool saved = target == "all" || target == "captures";
    const auto inScope = [&](const QUrl &url) {
        return (scope.isEmpty() || url == scope) && (!allowed || allowed->contains(url.toString()));
    };
    QVariantList results;
    // Kinds start from a small weight so a strong title match of any kind can still come first.
    const auto add = [&](QVariantMap row, int score) {
        static const QHash<QString, int> weight{{"paper", 12}, {"standalone-note", 8}, {"note", 7}, {"capture", 6},
            {"highlight", 6}, {"ai", 5}, {"collection", 4}, {"tag", 4}, {"workspace", 4}};
        row.insert("score", score + weight.value(row.value("kind").toString()));
        results.append(row);
    };

    QHash<QString, QString> titles;
    {
        QSqlQuery rows(db);
        rows.exec("SELECT url,title FROM documents WHERE title<>''");
        while (rows.next()) titles.insert(rows.value(0).toString(), rows.value(1).toString());
    }
    const auto displayName = [&](const QUrl &url) { return titles.value(url.toString(), fileName(url)); };

    if (names) {
        int count = 0, rank = 0;
        QSet<QUrl> matchedPapers;
        const auto addPaper = [&](const QUrl &url, const QStringList &details, int boost) {
            const auto title = displayName(url);
            if (count >= 20 || matchedPapers.contains(url) || !inScope(url)) return;
            QStringList fields{title, fileName(url)};
            fields += details;
            if (!query.matches(fields)) return;
            const bool named = query.matches({title, fileName(url)});
            QStringList shown;
            for (const auto &detail : details)
                if (!detail.isEmpty()) shown.append(detail);
            QVariantMap row{{"kind", "paper"}, {"title", title}, {"source", url},
                {"position", readingPosition(db, url)}, {"authors", details.value(0)}, {"year", details.value(1)}};
            // Authors and year are always shown; say why it matched only when the hit is an identifier.
            if (!named && !query.matches({details.value(0), details.value(1)}))
                row.insert("snippet", shown.join(" · "));
            add(row, std::max(query.score(title), query.score(fileName(url), details.join(' '))) + boost);
            matchedPapers.insert(url);
            ++count;
        };
        QSqlQuery papers(db);
        papers.exec("SELECT d.url,d.authors,d.year,d.doi,d.arxiv,d.favorite,d.reading_state FROM documents d "
                    "LEFT JOIN recent_documents r ON r.document_id=d.id WHERE d.removed_at IS NULL "
                    "ORDER BY r.opened_at IS NULL,r.opened_at DESC");
        while (papers.next() && count < 20) {
            // Recently opened, favorite and in-progress papers come a little earlier.
            const int boost = (rank++ < 10 ? 5 : 0) + (papers.value(5).toBool() ? 3 : 0)
                + (papers.value(6).toString() == "reading" ? 2 : 0);
            addPaper(QUrl(papers.value(0).toString()),
                {papers.value(1).toString(), papers.value(2).toString(), papers.value(3).toString(),
                    papers.value(4).toString().isEmpty() ? QString() : "arXiv:" + papers.value(4).toString()},
                boost);
        }
        for (const auto &url : indexed) addPaper(url, {}, 0);
    }

    if (saved) {
        int notes = 0, excerpts = 0;
        for (const auto &value : captures) {
            if (notes >= 20 && excerpts >= 20) break;
            const auto capture = value.toMap();
            if (!inScope(capture.value("source").toUrl())) continue;
            const auto title
                = capture.value("name").toString() + " · p. " + QString::number(capture.value("page").toInt() + 1);
            const auto note = capture.value("note").toString();
            if (notes < 20 && query.matches({note})) {
                add(QVariantMap{{"kind", "note"}, {"id", capture.value("id")}, {"source", capture.value("source")},
                        {"title", "Note · " + title}, {"snippet", snippet(note, query.firstHit(note), needle.size())}},
                    query.score({}, note));
                ++notes;
            }
            if (excerpts >= 20) continue;
            // Region captures are found by their figure or table caption.
            const auto text = capture.value("text").toString().isEmpty() ? capture.value("caption").toString()
                                                                         : capture.value("text").toString();
            // Captures match their paper's title or file name as well as their text.
            if (!query.matches({text, title, fileName(capture.value("source").toUrl())})) continue;
            add(QVariantMap{{"kind", "capture"}, {"title", title}, {"id", capture.value("id")},
                    {"source", capture.value("source")},
                    {"snippet", snippet(text, query.firstHit(text), needle.size())}},
                query.score({}, text));
            ++excerpts;
        }
    }

    if (target == "all") {
        QSqlQuery highlights(db);
        highlights.prepare(
            "SELECT h.id,d.url,h.page,h.text,h.body FROM highlights h JOIN documents d ON d.id=h.document_id "
            "WHERE h.deleted_at IS NULL AND instr(lower(h.text || ' ' || h.body),lower(?))>0 "
            "AND (?=1 OR d.url=?) ORDER BY h.created_at DESC LIMIT 200");
        highlights.addBindValue(query.probe);
        highlights.addBindValue(scope.isEmpty());
        highlights.addBindValue(scope.toString());
        int count = 0;
        if (highlights.exec()) {
            while (highlights.next() && count < 20) {
                const QUrl source(highlights.value(1).toString());
                const auto text = highlights.value(3).toString() + " " + highlights.value(4).toString();
                if (!inScope(source) || !query.matches({text})) continue;
                add(QVariantMap{{"kind", "highlight"}, {"id", highlights.value(0)}, {"source", source},
                        {"title", displayName(source) + " · p. " + QString::number(highlights.value(2).toInt() + 1)},
                        {"snippet", snippet(text, query.firstHit(text), needle.size())}},
                    query.score({}, text));
                ++count;
            }
        }
    }

    if ((target == "all" || target == "captures") && scope.isEmpty() && !allowed) {
        // Standalone notes belong to no paper, so a paper scope leaves them out.
        QSqlQuery notes(db);
        notes.prepare("SELECT id,title,body FROM notes WHERE deleted_at IS NULL AND "
                      "(instr(lower(title),lower(?))>0 OR instr(lower(body),lower(?))>0) ORDER BY updated_at DESC "
                      "LIMIT 200");
        notes.addBindValue(query.probe);
        notes.addBindValue(query.probe);
        int count = 0;
        if (notes.exec())
            while (notes.next() && count < 20) {
                const auto body = notes.value(2).toString();
                const auto title = notes.value(1).toString();
                if (!query.matches({title, body})) continue;
                add(QVariantMap{{"kind", "standalone-note"}, {"id", notes.value(0)},
                        {"title", "Note · " + (title.isEmpty() ? QStringLiteral("Untitled") : title)},
                        {"snippet", snippet(body, query.firstHit(body), needle.size())}},
                    query.score(title, body));
                ++count;
            }
    }
    if ((target == "all" || target == "ai") && scope.isEmpty() && !allowed) {
        QSqlQuery answers(db);
        // One result per thread: its title, or the latest message mentioning the words.
        answers.prepare(
            "SELECT t.id,t.title,(SELECT group_concat(m.display || ' ' || m.content, ' ') FROM (SELECT display, "
            "content FROM ai_messages WHERE thread_id=t.id AND instr(lower(display || ' ' || content),lower(?))>0 "
            "ORDER BY created_at DESC LIMIT 4) m) AS hit FROM ai_threads t WHERE t.trashed_at IS NULL AND "
            "(instr(lower(t.title),lower(?))>0 OR hit IS NOT NULL) ORDER BY t.updated_at DESC LIMIT 60");
        answers.addBindValue(query.probe);
        answers.addBindValue(query.probe);
        int count = 0;
        if (answers.exec())
            while (answers.next() && count < 10) {
                const auto title = answers.value(1).toString();
                const auto answer = answers.value(2).toString();
                if (!query.matches({title, answer})) continue;
                add(QVariantMap{{"kind", "ai"}, {"id", answers.value(0)}, {"title", "AI · " + title},
                        {"snippet", snippet(answer, query.firstHit(answer), needle.size())}},
                    query.score(title, answer));
                ++count;
            }
    }
    if (target == "all" && scope.isEmpty() && !allowed) {
        // Collections and tags open the library filtered to them.
        for (const auto &[kind, sql] : {std::pair{"collection", "SELECT id,name FROM collections"},
                 std::pair{"tag", "SELECT id,name FROM tags"}}) {
            QSqlQuery rows(db);
            rows.exec(sql);
            int count = 0;
            while (rows.next() && count < 10) {
                const auto name = rows.value(1).toString();
                if (!query.matches({name})) continue;
                add(QVariantMap{{"kind", kind}, {"id", rows.value(0)},
                        {"title", (QString(kind) == "tag" ? "Tag · " : "Collection · ") + name}},
                    query.score(name));
                ++count;
            }
        }
        QSqlQuery workspaces(db);
        workspaces.exec("SELECT id,name FROM workspaces WHERE id NOT IN (SELECT id FROM deleted_workspaces) ORDER BY "
                        "opened_at DESC");
        int count = 0;
        while (workspaces.next() && count < 20) {
            const auto name = workspaces.value(1).toString();
            if (!query.matches({name})) continue;
            add(QVariantMap{{"kind", "workspace"}, {"title", name}, {"id", workspaces.value(0)}}, query.score(name));
            ++count;
        }
    }
    // Best first; equal scores keep the order above (recent papers, newest notes).
    std::stable_sort(results.begin(), results.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("score").toInt() > b.toMap().value("score").toInt();
    });
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
