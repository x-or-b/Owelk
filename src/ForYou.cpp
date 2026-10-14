#include "ForYou.h"

#include "FileFingerprint.h"
#include "LibrarySync.h"
#include "PaperMetadata.h"
#include "ResearchStore.h"
#include "UiText.h"
#include "ai/AiService.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QTimer>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <QXmlStreamReader>

namespace {
constexpr int keptItems = 300;
constexpr auto paperFields = "title,authors,year,publicationDate,externalIds,url,abstract,openAccessPdf";

QStringList listOf(const QString &text, const QString &separators)
{
    QStringList list;
    for (const auto &part : text.split(QRegularExpression(separators), Qt::SkipEmptyParts))
        if (const auto value = part.simplified(); !value.isEmpty()) list << value;
    return list;
}

QString arxivId(QString value)
{
    return value.trimmed().remove(QRegularExpression("v\\d+$"));
}
}

namespace ForYouParse {
QString arxivQuery(const QString &words, const QString &categories, const QDateTime &from, const QDateTime &to)
{
    const auto group
        = [](const QStringList &terms) { return terms.size() > 1 ? "(" + terms.join(" OR ") + ")" : terms.value(0); };
    QStringList phrases, cats, parts;
    for (auto phrase : listOf(words, ","))
        phrases << (phrase.remove('"').contains(' ') ? "all:\"" + phrase + "\"" : "all:" + phrase);
    for (const auto &category : listOf(categories, "[,\\s]+")) cats << "cat:" + category;
    if (!phrases.isEmpty()) parts << group(phrases);
    if (!cats.isEmpty()) parts << group(cats);
    if (parts.isEmpty()) return {};
    parts << QStringLiteral("submittedDate:[%1 TO %2]")
                 .arg(from.toUTC().toString("yyyyMMddHHmm"), to.toUTC().toString("yyyyMMddHHmm"));
    return parts.join(" AND ");
}

QVariantList arxivEntries(const QByteArray &atom)
{
    QVariantList list;
    QXmlStreamReader xml(atom);
    QVariantMap entry;
    QStringList authors;
    bool inEntry = false, inAuthor = false;
    static const QRegularExpression abs("/abs/(.+?)(v\\d+)?$");
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto name = xml.name();
            if (name == u"entry") {
                inEntry = true;
                entry.clear();
                authors.clear();
            } else if (!inEntry) {
                continue;
            } else if (name == u"author") {
                inAuthor = true;
            } else if (name == u"name" && inAuthor) {
                authors << xml.readElementText().simplified();
            } else if (name == u"id") {
                entry.insert("abs", xml.readElementText().trimmed());
            } else if (name == u"title") {
                entry.insert("title", xml.readElementText().simplified());
            } else if (name == u"summary") {
                entry.insert("abstract", xml.readElementText().simplified());
            } else if (name == u"published") {
                entry.insert("date", xml.readElementText().trimmed().left(10));
            } else if (name == u"doi") {
                entry.insert("doi", xml.readElementText().trimmed());
            } else if (name == u"link" && xml.attributes().value("title") == u"pdf") {
                entry.insert("pdf", xml.attributes().value("href").toString());
            }
        } else if (xml.isEndElement()) {
            if (xml.name() == u"author") {
                inAuthor = false;
            } else if (xml.name() == u"entry") {
                inEntry = false;
                const auto m = abs.match(entry.value("abs").toString());
                const auto title = entry.value("title").toString();
                if (!m.hasMatch() || title.isEmpty()) continue; // An API error comes as an entry too.
                const auto id = m.captured(1);
                auto pdf = entry.value("pdf").toString();
                if (pdf.startsWith("http://arxiv.org/")) pdf.replace(0, 4, "https");
                list.append(QVariantMap{{"title", title}, {"authors", authors.join(", ")},
                    {"date", entry.value("date")}, {"year", entry.value("date").toString().left(4)},
                    {"abstract", entry.value("abstract")}, {"arxiv", id}, {"doi", entry.value("doi")},
                    {"pdf", pdf.isEmpty() ? "https://arxiv.org/pdf/" + id : pdf},
                    {"url", "https://arxiv.org/abs/" + id}});
            }
        }
    }
    return list;
}

bool isPdfAddress(const QString &address)
{
    const QUrl url(address);
    return url.isValid() && url.scheme().startsWith("http") && !url.host().endsWith("doi.org");
}

QVariantList recommendations(const QByteArray &json)
{
    QVariantList list;
    for (const auto &value : QJsonDocument::fromJson(json).object().value("recommendedPapers").toArray()) {
        const auto paper = value.toObject();
        const auto title = paper.value("title").toString().simplified();
        if (title.isEmpty()) continue;
        QStringList authors;
        for (const auto &author : paper.value("authors").toArray())
            authors << author.toObject().value("name").toString().simplified();
        const auto ids = paper.value("externalIds").toObject();
        const auto arxiv = arxivId(ids.value("ArXiv").toString()), doi = ids.value("DOI").toString().trimmed();
        const auto date = paper.value("publicationDate").toString();
        const auto year = paper.value("year").isDouble() ? QString::number(paper.value("year").toInt()) : date.left(4);
        auto pdf = paper.value("openAccessPdf").toObject().value("url").toString();
        if (!ForYouParse::isPdfAddress(pdf)) pdf.clear(); // A DOI link leads to the publisher's page, not a PDF.
        if (pdf.isEmpty() && !arxiv.isEmpty()) pdf = "https://arxiv.org/pdf/" + arxiv;
        list.append(QVariantMap{{"title", title}, {"authors", authors.join(", ")}, {"date", date}, {"year", year},
            {"abstract", paper.value("abstract").toString().simplified()}, {"arxiv", arxiv}, {"doi", doi}, {"pdf", pdf},
            {"paperId", paper.value("paperId").toString()},
            {"url",
                !arxiv.isEmpty()     ? "https://arxiv.org/abs/" + arxiv
                    : !doi.isEmpty() ? "https://doi.org/" + doi
                                     : paper.value("url").toString()}});
    }
    return list;
}
}

ForYou::ForYou(ResearchStore *store, QObject *parent) : QObject(parent), m_store(store)
{
    // Options (how long papers stay) change what is shown.
    connect(store, &ResearchStore::settingsChanged, this, [this] {
        emit settingsChanged();
        emit changed();
    });
    m_libraryCheck = new QTimer(this);
    m_libraryCheck->setSingleShot(true);
    m_libraryCheck->setInterval(2000);
    connect(m_libraryCheck, &QTimer::timeout, this, &ForYou::dropKept);
    connect(store, &ResearchStore::documentsChanged, m_libraryCheck, qOverload<>(&QTimer::start));
    if (auto *ai = qobject_cast<AiService *>(store->ai())) {
        connect(ai, &AiService::papersRanked, this, &ForYou::ranked);
        // The AI may be ready only after a check (an account read a little after launch, a key added later):
        // papers still without a reason are explained then.
        connect(ai, &AiService::providersChanged, this, [this] {
            if (m_explaining || m_checking || m_store->setting("forYou.ai", "1") != "1" || !aiReady()) return;
            for (const auto &value : std::as_const(m_items))
                if (!value.toMap().contains("why")) {
                    QMetaObject::invokeMethod(this, &ForYou::explain, Qt::QueuedConnection);
                    return;
                }
        });
    }
}

bool ForYou::aiReady() const
{
    const auto *ai = qobject_cast<AiService *>(m_store->ai());
    return ai && ai->canSend();
}

QString ForYou::aiName() const
{
    const auto *ai = qobject_cast<AiService *>(m_store->ai());
    return ai ? ai->providerName() : QString();
}

QString ForYou::interests() const
{
    QStringList lines;
    for (const auto &value : topics()) {
        const auto topic = value.toMap();
        if (!topic.value("on", true).toBool()) continue;
        auto line = "- Topic: " + topic.value("words").toString();
        if (!topic.value("categories").toString().isEmpty())
            line += " (arXiv categories: " + topic.value("categories").toString() + ")";
        lines << line;
    }
    for (const auto &value : m_store->collections()) {
        const auto collection = value.toMap();
        if (!following(collection.value("id").toString())) continue;
        QStringList titles;
        for (const auto &paper : m_store->libraryDocuments({{"collection", collection.value("id")}, {"limit", 8}}))
            titles << paper.toMap().value("name").toString().left(160);
        lines << "- Collection \"" + collection.value("name").toString() + "\": " + titles.join("; ");
    }
    return lines.join('\n');
}

void ForYou::sortItems()
{
    // Newest first, then (stable) the AI's most relevant first.
    const auto date = [](const QVariant &value) {
        const auto item = value.toMap();
        const auto day = item.value("date").toString();
        return day.isEmpty() ? item.value("foundAt").toString().left(10) : day;
    };
    std::stable_sort(
        m_items.begin(), m_items.end(), [&](const QVariant &a, const QVariant &b) { return date(a) > date(b); });
    std::stable_sort(m_items.begin(), m_items.end(), [](const QVariant &a, const QVariant &b) {
        const auto score = [](const QVariant &value) {
            const auto item = value.toMap();
            return item.contains("score") ? item.value("score").toInt() : -1;
        };
        return score(a) > score(b);
    });
}
void ForYou::explain()
{
    auto *ai = qobject_cast<AiService *>(m_store->ai());
    if (m_explaining || !ai) return;
    QVariantList papers;
    for (const auto &value : std::as_const(m_items)) {
        const auto item = value.toMap();
        if (!item.contains("why") && papers.size() < 40) papers.append(item);
    }
    if (papers.isEmpty()) return;
    if (!ai->canSend()) {
        // Set up but not agreed to: the switch in Settings › For You is the OK.
        const auto id = m_store->setting("ai.provider", "claude");
        bool setUp = false;
        for (const auto &value : ai->providers())
            if (value.toMap().value("id").toString() == id) setUp = value.toMap().value("configured").toBool();
        m_aiProblem = setUp ? ui("Turn on Explain with AI in Settings › For You to send these papers to the AI.")
                            : ui("Set up AI in Settings › AI to have new papers explained.");
        emit changed();
        return;
    }
    m_explaining = true;
    m_aiProblem.clear();
    emit explainingChanged();
    m_store->startTask("forYouAi", ui("For You: AI is reading the new papers"));
    m_rankRequest = ai->rankPapers(papers, interests());
}

void ForYou::ranked(int request, const QVariantList &ranking, const QString &error)
{
    if (request != m_rankRequest) return;
    m_rankRequest = -1;
    m_explaining = false;
    m_store->finishTask("forYouAi");
    m_aiProblem = error;
    for (const auto &value : ranking) {
        const auto rank = value.toMap();
        exec("UPDATE foryou_items SET score=?,why=? WHERE id=? AND state='new'",
            {rank.value("score"), rank.value("why"), rank.value("id")});
    }
    load();
    emit explainingChanged();
}
void ForYou::start()
{
    load();
    // Once a day, a little after launch (not while the window opens) and again when the date changes.
    m_daily = new QTimer(this);
    m_daily->setInterval(60 * 60 * 1000);
    connect(m_daily, &QTimer::timeout, this, &ForYou::checkIfDue);
    m_daily->start();
    QTimer::singleShot(8000, this, &ForYou::checkIfDue);
}

bool ForYou::exec(const QString &sql, const QVariantList &values) const
{
    QSqlQuery query(m_store->m_database);
    query.prepare(sql);
    for (const auto &value : values) query.addBindValue(value);
    if (query.exec()) return true;
    qWarning("For You: %s", qPrintable(query.lastError().text()));
    return false;
}

void ForYou::reload()
{
    load();
    emit settingsChanged();
}
void ForYou::load()
{
    m_items.clear();
    m_handled.clear();
    QSqlQuery query(m_store->m_database);
    query.exec("SELECT id,state,paper,found_at,score,why FROM foryou_items ORDER BY found_at DESC");
    int waiting = 0;
    QStringList old;
    while (query.next()) {
        const auto id = query.value(0).toString();
        if (query.value(1).toString() != "new") {
            m_handled << id;
            continue;
        }
        // Only the newest few hundred wait; the rest are let go.
        if (++waiting > keptItems) {
            old << id;
            continue;
        }
        auto item = QJsonDocument::fromJson(query.value(2).toByteArray()).object().toVariantMap();
        item.insert({{"id", id}, {"foundAt", query.value(3)}});
        item.insert("hasPdf", ForYouParse::isPdfAddress(item.value("pdf").toString()));
        if (!query.value(4).isNull()) item.insert("score", query.value(4).toInt());
        if (!query.value(5).toString().isEmpty()) item.insert("why", query.value(5).toString());
        m_items.append(item);
    }
    query.finish();
    for (const auto &id : std::as_const(old)) exec("DELETE FROM foryou_items WHERE id=?", {id});
    sortItems();
    QSqlQuery meta(m_store->m_database);
    meta.exec("SELECT value FROM foryou_meta WHERE key='checkedAt'");
    m_lastChecked = meta.next() ? QDateTime::fromString(meta.value(0).toString(), Qt::ISODate) : QDateTime();
    emit changed();
}

QVariantList ForYou::items() const
{
    // Kept for the number of days chosen (Settings › For You; 0 keeps them until added or dismissed).
    const int days = m_store->setting("forYou.keepDays", "30").toInt();
    if (days <= 0) return m_items;
    const auto oldest = QDateTime::currentDateTimeUtc().addDays(-days);
    QVariantList shown;
    for (const auto &value : m_items)
        if (QDateTime::fromString(value.toMap().value("foundAt").toString(), Qt::ISODate) >= oldest)
            shown.append(value);
    return shown;
}

QVariantList ForYou::topics() const
{
    QVariantList list;
    QSqlQuery query(m_store->m_database);
    query.exec("SELECT id,words,categories,enabled FROM foryou_topics ORDER BY position,id");
    while (query.next())
        list.append(QVariantMap{{"id", query.value(0)}, {"words", query.value(1)}, {"categories", query.value(2)},
            {"on", query.value(3).toBool()}});
    return list;
}
bool ForYou::saveTopics(const QVariantList &topics)
{
    // Only rows that change are written, so syncing sends only them.
    QStringList kept;
    int position = 0;
    for (const auto &value : topics) {
        const auto topic = value.toMap();
        const auto words = topic.value("words").toString().simplified().left(300);
        const auto categories = topic.value("categories").toString().simplified().left(200);
        if (words.isEmpty() && categories.isEmpty()) continue;
        auto id = topic.value("id").toString();
        if (id.isEmpty()) id = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
        if (!exec("INSERT INTO foryou_topics(id,words,categories,enabled,position) VALUES(?,?,?,?,?) ON CONFLICT(id) "
                  "DO UPDATE SET words=excluded.words,categories=excluded.categories,enabled=excluded.enabled,"
                  "position=excluded.position WHERE words<>excluded.words OR categories<>excluded.categories OR "
                  "enabled<>excluded.enabled OR position<>excluded.position",
                // An empty part is "", not NULL (a null QString binds as NULL).
                {id, words.isNull() ? QString("") : words, categories.isNull() ? QString("") : categories,
                    topic.value("on", true).toBool() ? 1 : 0, position++}))
            return false;
        kept << id;
    }
    for (const auto &value : this->topics())
        if (!kept.contains(value.toMap().value("id").toString()))
            exec("DELETE FROM foryou_topics WHERE id=?", {value.toMap().value("id")});
    emit settingsChanged();
    return true;
}
bool ForYou::following(const QString &collectionId) const
{
    QSqlQuery query(m_store->m_database);
    query.prepare("SELECT 1 FROM foryou_follows WHERE collection_id=?");
    query.addBindValue(collectionId);
    return query.exec() && query.next();
}
void ForYou::follow(const QString &collectionId, bool on)
{
    if (collectionId.isEmpty()) return;
    exec(on ? "INSERT OR IGNORE INTO foryou_follows(collection_id) VALUES(?)"
            : "DELETE FROM foryou_follows WHERE collection_id=?",
        {collectionId});
    emit settingsChanged();
}
int ForYou::usablePapers(const QString &collectionId) const
{
    return int(m_store->collectionPaperKeys(collectionId, 1000).size());
}

bool ForYou::configured() const
{
    QSqlQuery query(m_store->m_database);
    return query.exec("SELECT 1 FROM foryou_topics WHERE enabled=1 UNION ALL SELECT 1 FROM foryou_follows f JOIN "
                      "collections c ON c.id=f.collection_id LIMIT 1")
        && query.next();
}
QDateTime ForYou::since() const
{
    const int days = qBound(1, m_store->setting("forYou.days", "7").toInt(), 90);
    return QDateTime::currentDateTimeUtc().addDays(-days);
}

QVariantList ForYou::sources() const
{
    QVariantList list;
    QHash<QString, int> counts;
    for (const auto &value : items()) {
        const auto item = value.toMap();
        const auto key = item.value("source").toString();
        if (!counts.contains(key)) list.append(QVariantMap{{"key", key}, {"name", item.value("sourceName")}});
        ++counts[key];
    }
    for (auto &value : list) {
        auto source = value.toMap();
        source.insert("count", counts.value(source.value("key").toString()));
        value = source;
    }
    return list;
}
void ForYou::checkIfDue()
{
    if (m_checking || !configured() || m_store->setting("forYou.auto", "1") != "1") return;
    // Syncing first: another computer may have looked today already (its papers and reasons come along).
    if (m_store->librarySync() && m_store->librarySync()->running()) {
        QTimer::singleShot(10000, this, &ForYou::checkIfDue);
        return;
    }
    if (m_lastChecked.isValid() && m_lastChecked.toLocalTime().date() == QDate::currentDate()) return;
    refresh();
}
void ForYou::refresh()
{
    if (m_checking) return;
    if (!m_network) m_network = new QNetworkAccessManager(this);
    m_jobs.clear();
    m_found.clear();
    m_problems.clear();
    const int limit = qBound(1, m_store->setting("forYou.perSource", "10").toInt(), 50);
    const auto from = since(), to = QDateTime::currentDateTimeUtc();
    const auto request = [](const QUrl &url) {
        QNetworkRequest call(url);
        call.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
        call.setTransferTimeout(30000);
        return call;
    };
    // Topics: new arXiv papers with any of the words in any of the categories.
    const auto arxiv = m_store->setting("forYou.arxivBaseUrl", "https://export.arxiv.org/api");
    for (const auto &value : topics()) {
        const auto topic = value.toMap();
        if (!topic.value("on", true).toBool()) continue;
        const auto query
            = ForYouParse::arxivQuery(topic.value("words").toString(), topic.value("categories").toString(), from, to);
        if (query.isEmpty()) continue;
        const auto name = topic.value("words").toString().isEmpty() ? topic.value("categories").toString()
                                                                    : topic.value("words").toString();
        const auto url = QUrl::fromEncoded(
            (arxiv + "/query?search_query=" + QString::fromLatin1(QUrl::toPercentEncoding(query)).replace("%20", "+")
                + "&sortBy=submittedDate&sortOrder=descending&max_results=" + QString::number(limit))
                .toUtf8());
        m_jobs.append({"topic:" + topic.value("id").toString(), name, [this, url, request](Job job) {
                           auto *reply = m_network->get(request(url));
                           connect(reply, &QNetworkReply::finished, this, [this, reply, job] {
                               reply->deleteLater();
                               if (reply->error() != QNetworkReply::NoError)
                                   m_problems << QString(ui("arXiv did not answer for “%1”.")).arg(job.sourceName);
                               else
                                   found(ForYouParse::arxivEntries(reply->readAll()), job.source, job.sourceName);
                               runNext();
                           });
                       }});
    }
    // Followed collections: papers like theirs, from Semantic Scholar.
    const auto recommend
        = m_store->setting("forYou.recommendBaseUrl", "https://api.semanticscholar.org/recommendations/v1");
    for (const auto &value : m_store->collections()) {
        const auto collection = value.toMap();
        const auto id = collection.value("id").toString();
        if (!following(id)) continue;
        const auto keys = m_store->collectionPaperKeys(id, 50);
        if (keys.isEmpty()) {
            m_problems << QString(ui("“%1” has no paper with an arXiv ID or DOI to look for others like it."))
                              .arg(collection.value("name").toString());
            continue;
        }
        QUrl url(recommend + "/papers/");
        url.setQuery(QStringLiteral("fields=%1&limit=%2").arg(paperFields).arg(limit));
        const auto body = QJsonDocument(QJsonObject{{"positivePaperIds", QJsonArray::fromStringList(keys)}})
                              .toJson(QJsonDocument::Compact);
        m_jobs.append(
            {"collection:" + id, collection.value("name").toString(), [this, url, body, request](Job job) {
                 auto call = request(url);
                 call.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
                 auto *reply = m_network->post(call, body);
                 connect(reply, &QNetworkReply::finished, this, [this, reply, job] {
                     reply->deleteLater();
                     const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                     if (reply->error() != QNetworkReply::NoError || status >= 400)
                         m_problems << (status == 429
                                 ? ui("Semantic Scholar is busy. Try again in a minute.")
                                 : QString(ui("Semantic Scholar did not answer for “%1”.")).arg(job.sourceName));
                     else
                         found(ForYouParse::recommendations(reply->readAll()), job.source, job.sourceName);
                     runNext();
                 });
             }});
    }
    if (m_jobs.isEmpty()) {
        m_problem = m_problems.join(' ');
        emit changed();
        return;
    }
    m_checking = true;
    m_jobCount = int(m_jobs.size());
    emit checkingChanged();
    m_store->startTask("forYou", ui("For You: looking for new papers"), m_jobCount);
    auto job = m_jobs.takeFirst();
    job.run(job);
}

void ForYou::runNext()
{
    m_store->progressTask("forYou", m_jobCount - m_jobs.size(), m_jobCount);
    if (m_jobs.isEmpty()) {
        finishCheck();
        return;
    }
    // arXiv asks for a few seconds between requests.
    QTimer::singleShot(m_store->setting("forYou.delayMs", "3000").toInt(), this, [this] {
        if (m_jobs.isEmpty()) return;
        auto job = m_jobs.takeFirst();
        job.run(job);
    });
}

void ForYou::found(const QVariantList &papers, const QString &source, const QString &sourceName)
{
    QStringList known = m_handled;
    for (const auto &list : {m_items, m_found})
        for (const auto &value : list) known << value.toMap().value("id").toString();
    const auto oldest = since().date();
    for (const auto &value : papers) {
        auto paper = value.toMap();
        const auto arxiv = arxivId(paper.value("arxiv").toString()), doi = paper.value("doi").toString();
        const auto id = !arxiv.isEmpty() ? "arxiv:" + arxiv
            : !doi.isEmpty()             ? "doi:" + doi.toLower()
                                         : "s2:" + paper.value("paperId").toString();
        if (id == "s2:" || known.contains(id) || m_store->hasPaper(arxiv, doi)) continue;
        // Recommendations come from any year; only recent ones are new (undated ones are kept).
        const auto date = QDate::fromString(paper.value("date").toString(), Qt::ISODate);
        if (date.isValid() && date < oldest) continue;
        paper.insert({{"id", id}, {"arxiv", arxiv}, {"source", source}, {"sourceName", sourceName}});
        m_found.append(paper);
        known << id;
    }
}
void ForYou::finishCheck()
{
    const auto now = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    int fresh = 0;
    for (const auto &value : std::as_const(m_found)) {
        auto paper = value.toMap();
        const auto id = paper.take("id").toString();
        // Another computer may have found it meanwhile (it came through sync): kept as it is.
        QSqlQuery insert(m_store->m_database);
        insert.prepare("INSERT OR IGNORE INTO foryou_items(id,state,paper,found_at) VALUES(?,'new',?,?)");
        insert.addBindValue(id);
        insert.addBindValue(
            QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(paper)).toJson(QJsonDocument::Compact)));
        insert.addBindValue(now);
        if (insert.exec() && insert.numRowsAffected() == 1) ++fresh;
    }
    // What was waiting stays, unless it has reached the Library since.
    for (const auto &value : std::as_const(m_items)) {
        const auto item = value.toMap();
        if (m_store->hasPaper(item.value("arxiv").toString(), item.value("doi").toString()))
            exec("UPDATE foryou_items SET state='added',paper='{}',score=NULL,why=NULL WHERE id=?", {item.value("id")});
    }
    exec("INSERT INTO foryou_meta(key,value) VALUES('checkedAt',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        {now});
    m_found.clear();
    m_problem = m_problems.join(' ');
    m_checking = false;
    load();
    m_store->finishTask("forYou");
    emit checkingChanged();
    if (fresh)
        m_store->notify(fresh == 1 ? ui("For You: 1 new paper.") : QString(ui("For You: %1 new papers.")).arg(fresh));
    // New papers explained by the AI, when that is on and the AI is set up.
    if (fresh && m_store->setting("forYou.ai", "1") == "1" && aiReady()) explain();
}
QVariantMap ForYou::item(const QString &id) const
{
    for (const auto &value : m_items)
        if (value.toMap().value("id").toString() == id) return value.toMap();
    return {};
}

void ForYou::dropKept()
{
    bool changed = false;
    for (const auto &value : std::as_const(m_items)) {
        const auto item = value.toMap();
        const auto id = item.value("id").toString();
        if (m_adding.contains(id)) continue;
        const auto url = m_store->paperUrlFor(item.value("arxiv").toString(), item.value("doi").toString());
        if (url.isEmpty()) continue;
        // Got through the browser for Add: its details and collection, as Add gives them.
        if (m_viaBrowser.contains(id)) finishDetails(m_viaBrowser.take(id), url);
        exec("UPDATE foryou_items SET state='added',paper='{}',score=NULL,why=NULL WHERE id=?", {id});
        changed = true;
    }
    if (changed) load();
}

void ForYou::dismiss(const QStringList &ids)
{
    for (const auto &id : ids)
        exec("UPDATE foryou_items SET state='dismissed',paper='{}',score=NULL,why=NULL WHERE id=?", {id});
    load();
}
void ForYou::add(const QStringList &ids)
{
    const bool idle = m_adding.isEmpty();
    int pageOnly = 0;
    for (const auto &id : ids) {
        const auto paper = item(id);
        if (m_adding.contains(id) || paper.isEmpty()) continue;
        // Several at once: a paper with no free PDF is left (its page would open in a tab of its own).
        if (ids.size() > 1 && !paper.value("hasPdf").toBool()) {
            ++pageOnly;
            continue;
        }
        m_adding << id;
        m_addQueue << id;
    }
    if (pageOnly)
        m_store->notify(QString(pageOnly == 1 ? ui("1 paper has no free PDF; open its page from the list.")
                                              : ui("%1 papers have no free PDF; open their pages from the list."))
                .arg(pageOnly));
    emit addingChanged();
    if (idle) addNext();
}

void ForYou::addNext()
{
    if (m_addQueue.isEmpty()) {
        m_store->finishTask("forYouAdd");
        return;
    }
    const auto id = m_addQueue.first();
    const auto paper = item(id);
    const auto done = [this, id] {
        m_addQueue.removeAll(id);
        m_adding.removeAll(id);
        emit addingChanged();
        addNext();
    };
    const auto pdf = paper.value("pdf").toString();
    if (!ForYouParse::isPdfAddress(pdf)) {
        // No free PDF: its page, where the reader may get one (a PDF downloaded there joins the Library, and
        // the paper then leaves For You).
        m_store->notify(QString(ui("No free PDF for “%1”: its page opens.")).arg(paper.value("title").toString()));
        if (!paper.value("url").toString().isEmpty()) emit webRequested(QUrl(paper.value("url").toString()));
        done();
        return;
    }
    if (!m_network) m_network = new QNetworkAccessManager(this);
    m_store->startTask("forYouAdd", ui("Downloading ") + paper.value("title").toString());
    QNetworkRequest request{QUrl(pdf)};
    request.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(90000);
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        m_store->progressTask("forYouAdd", double(received), total > 0 ? double(total) : 0);
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, paper, done] {
        reply->deleteLater();
        const auto bytes = reply->readAll();
        if (reply->error() != QNetworkReply::NoError || !bytes.startsWith("%PDF")) {
            // The browser often gets it where this did not (another network path, a site that wants one): the
            // PDF itself opens in a web tab, is downloaded there, and is finished when it reaches the Library.
            const QString why = reply->error() != QNetworkReply::NoError ? reply->errorString()
                                                                         : QString(ui("the answer was not a PDF"));
            m_store->notify(
                QString(ui("Getting “%1” through the browser (%2).")).arg(paper.value("title").toString(), why));
            m_viaBrowser.insert(paper.value("id").toString(), paper);
            emit webRequested(QUrl(paper.value("pdf").toString()));
            done();
            return;
        }
        // Named as the Library names papers (Settings › Library › Paper names).
        PaperMetadata metadata;
        metadata.title = paper.value("title").toString();
        metadata.authors = paper.value("authors").toString();
        metadata.year = paper.value("year").toString();
        metadata.arxiv = paper.value("arxiv").toString();
        auto stem = PaperMetadataText::fileStem(metadata, m_store->fileNameParts());
        if (stem.isEmpty()) stem = metadata.arxiv.isEmpty() ? QStringLiteral("paper") : metadata.arxiv;
        const auto target = m_store->downloadTarget(stem + ".pdf", true).value("url").toUrl();
        QFile file(target.toLocalFile());
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size()) {
            m_store->notify(ui("Could not save the PDF."));
            done();
            return;
        }
        file.close();
        finishAdd(paper, target);
        done();
    });
}

void ForYou::finishDetails(const QVariantMap &paper, const QUrl &url)
{
    static const QRegularExpression year("^\\d{4}$");
    m_store->updateDocumentDetails(url,
        {{"title", paper.value("title").toString().left(300)},
            {"authors", paper.value("authors").toString().left(1000)},
            {"year", year.match(paper.value("year").toString()).hasMatch() ? paper.value("year") : QString()},
            {"doi", paper.value("doi").toString().left(200)}, {"arxiv", paper.value("arxiv").toString().left(40)}});
    const auto source = paper.value("source").toString();
    if (source.startsWith("collection:")) m_store->setDocumentCollection(url, source.mid(11), true);
}

void ForYou::finishAdd(const QVariantMap &paper, const QUrl &file)
{
    const auto hash = FileFingerprint::sha256(file.toLocalFile());
    const auto source = paper.value("source").toString();
    const auto collection = source.startsWith("collection:") ? source.mid(11) : QString();
    m_store->addDocuments({file}, collection);
    // The same bytes may already be a paper (then the download was not kept): that one.
    const auto url = m_store->paperWithFile(file, hash);
    if (url.isValid() && !url.isEmpty()) finishDetails(paper, url);
    const auto id = paper.value("id").toString();
    // Off the list; once more a moment later should the library be busy (syncing) just then.
    if (!exec("UPDATE foryou_items SET state='added',paper='{}',score=NULL,why=NULL WHERE id=?", {id}))
        QTimer::singleShot(1500, this, [this, id] {
            exec("UPDATE foryou_items SET state='added',paper='{}',score=NULL,why=NULL WHERE id=?", {id});
            load();
        });
    load();
    m_store->notify(QString(ui("Added “%1” to the Library.")).arg(paper.value("title").toString()));
}
