#include "ResearchStore.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSqlQuery>
#include <QUrlQuery>

// Citation relations from Semantic Scholar: the papers this one cites and the papers citing it.
// Asked for only when the reader presses the button; sends the DOI, arXiv ID or (failing those) the
// title. Answers are kept in <data>/citations/<document>.json for a month.

namespace {
QString normalTitle(const QString &title)
{
    return title.toLower().remove(QRegularExpression("[^\\p{L}\\p{N}]+"));
}

constexpr auto fields = "title,year,authors,externalIds,citationCount";
}

namespace CitationParse {
// The paper rows of a /references (citedPaper) or /citations (citingPaper) answer.
QVariantList papers(const QByteArray &json, const QString &key)
{
    QVariantList rows;
    for (const auto &value : QJsonDocument::fromJson(json).object().value("data").toArray()) {
        const auto paper = value.toObject().value(key).toObject();
        const auto title = paper.value("title").toString().simplified();
        if (title.isEmpty()) continue;
        const auto ids = paper.value("externalIds").toObject();
        QStringList authors;
        for (const auto &author : paper.value("authors").toArray())
            authors << author.toObject().value("name").toString();
        const auto doi = ids.value("DOI").toString(), arxiv = ids.value("ArXiv").toString();
        const auto id = paper.value("paperId").toString();
        const auto url = !doi.isEmpty() ? "https://doi.org/" + doi
            : !arxiv.isEmpty()          ? "https://arxiv.org/abs/" + arxiv
            : !id.isEmpty()             ? "https://www.semanticscholar.org/paper/" + id
                                        : QString();
        rows.append(QVariantMap{{"title", title},
            {"year", paper.value("year").isDouble() ? QString::number(paper.value("year").toInt()) : QString()},
            {"authors",
                authors.isEmpty()        ? QString()
                    : authors.size() > 1 ? authors.first() + " et al."
                                         : authors.first()},
            {"doi", doi}, {"arxiv", arxiv}, {"citations", paper.value("citationCount").toInt()}, {"url", url}});
    }
    return rows;
}
}

int ResearchStore::loadCitations(const QUrl &source, bool refresh, bool cachedOnly)
{
    const int request = ++m_citationRequest;
    const auto fail = [this, request, source](const QString &error) {
        QMetaObject::invokeMethod(
            this, [=, this] { emit citationsLoaded(request, source, {{"error", error}}); }, Qt::QueuedConnection);
        return request;
    };
    const auto document = documentLinkId(source);
    if (document.isEmpty()) return fail("Open the paper from the Library first.");
    QSqlQuery query(m_database);
    query.prepare("SELECT title,doi,arxiv FROM documents WHERE id=?");
    query.addBindValue(document);
    if (!query.exec() || !query.next()) return fail("This paper is not in the Library.");
    const auto title = query.value(0).toString().simplified(), doi = query.value(1).toString().trimmed();
    const auto arxiv = query.value(2).toString().trimmed().remove(QRegularExpression("v\\d+$"));
    const auto cachePath = m_directory + "/citations/" + document + ".json";
    QFile cached(cachePath);
    if (!refresh && cached.open(QIODevice::ReadOnly)) {
        const auto saved = QJsonDocument::fromJson(cached.readAll()).object().toVariantMap();
        if (saved.value("fetchedAt").toDateTime().daysTo(QDateTime::currentDateTimeUtc()) < 30) {
            auto result = withLibraryMatches(saved);
            result.insert("cached", true);
            QMetaObject::invokeMethod(
                this, [=, this] { emit citationsLoaded(request, source, result); }, Qt::QueuedConnection);
            return request;
        }
    }
    if (cachedOnly) {
        QMetaObject::invokeMethod(
            this, [=, this] { emit citationsLoaded(request, source, {{"notLoaded", true}}); }, Qt::QueuedConnection);
        return request;
    }
    if (doi.isEmpty() && arxiv.isEmpty() && title.size() < 8)
        return fail("This paper has no DOI, arXiv ID or title to look up. Add one in Paper Details.");
    if (!m_citationNetwork) m_citationNetwork = new QNetworkAccessManager(this);
    const auto base = setting("citations.baseUrl", "https://api.semanticscholar.org/graph/v1");
    const auto get = [this, request, source](const QUrl &url, std::function<void(const QByteArray &)> next) {
        QNetworkRequest call(url);
        call.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
        call.setTransferTimeout(20000);
        auto *reply = m_citationNetwork->get(call);
        connect(reply, &QNetworkReply::finished, this, [this, reply, request, source, next] {
            reply->deleteLater();
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (reply->error() != QNetworkReply::NoError || status >= 400) {
                const auto error = status == 404 ? QStringLiteral("Semantic Scholar does not know this paper.")
                    : status == 429              ? QStringLiteral("Semantic Scholar is busy. Try again in a minute.")
                                                 : "Cannot reach Semantic Scholar: " + reply->errorString();
                emit citationsLoaded(request, source, {{"error", error}});
                return;
            }
            next(reply->readAll());
        });
    };
    // References, then citations, then save and answer.
    const auto fetch = [=, this](const QString &paperId) {
        const auto list = [&](const QString &kind) {
            QUrl url(base + "/paper/" + QUrl::toPercentEncoding(paperId, ":/") + "/" + kind);
            url.setQuery(QUrlQuery{{"fields", fields}, {"limit", "100"}});
            return url;
        };
        const auto citationsUrl = list("citations");
        get(list("references"), [=, this](const QByteArray &references) {
            get(citationsUrl, [=, this](const QByteArray &citations) {
                auto citedBy = CitationParse::papers(citations, "citingPaper");
                std::stable_sort(citedBy.begin(), citedBy.end(), [](const QVariant &a, const QVariant &b) {
                    return a.toMap()["citations"].toInt() > b.toMap()["citations"].toInt();
                });
                const QVariantMap saved{{"fetchedAt", QDateTime::currentDateTimeUtc()}, {"paperId", paperId},
                    {"references", CitationParse::papers(references, "citedPaper")}, {"citedBy", citedBy}};
                QDir().mkpath(m_directory + "/citations");
                QFile file(cachePath);
                if (file.open(QIODevice::WriteOnly))
                    file.write(QJsonDocument(QJsonObject::fromVariantMap(saved)).toJson(QJsonDocument::Compact));
                emit citationsLoaded(request, source, withLibraryMatches(saved));
            });
        });
    };
    if (!doi.isEmpty())
        fetch("DOI:" + doi);
    else if (!arxiv.isEmpty())
        fetch("ARXIV:" + arxiv);
    else {
        QUrl match(base + "/paper/search/match");
        match.setQuery(QUrlQuery{{"query", title}, {"fields", "title"}});
        get(match, [=, this](const QByteArray &json) {
            const auto found = QJsonDocument::fromJson(json).object().value("data").toArray();
            const auto id = found.isEmpty() ? QString() : found.first().toObject().value("paperId").toString();
            if (id.isEmpty())
                emit citationsLoaded(request, source, {{"error", "Semantic Scholar does not know this paper."}});
            else
                fetch(id);
        });
    }
    return request;
}

// Marks rows that are already in the Library (same DOI, arXiv ID or title) with their file.
QVariantMap ResearchStore::withLibraryMatches(QVariantMap result) const
{
    QHash<QString, QString> byDoi, byArxiv, byTitle;
    QSqlQuery query(m_database);
    query.exec("SELECT url,doi,arxiv,title FROM documents WHERE removed_at IS NULL");
    while (query.next()) {
        const auto url = query.value(0).toString();
        if (!query.value(1).toString().isEmpty()) byDoi.insert(query.value(1).toString().toLower(), url);
        if (!query.value(2).toString().isEmpty())
            byArxiv.insert(query.value(2).toString().remove(QRegularExpression("v\\d+$")), url);
        const auto title = normalTitle(query.value(3).toString());
        if (title.size() >= 12) byTitle.insert(title, url);
    }
    for (const auto *key : {"references", "citedBy"}) {
        QVariantList rows;
        for (const auto &value : result.value(key).toList()) {
            auto row = value.toMap();
            auto match = byDoi.value(row["doi"].toString().toLower());
            if (match.isEmpty()) match = byArxiv.value(row["arxiv"].toString());
            if (match.isEmpty()) match = byTitle.value(normalTitle(row["title"].toString()));
            row.insert("inLibrary", match);
            rows.append(row);
        }
        result.insert(key, rows);
    }
    return result;
}
