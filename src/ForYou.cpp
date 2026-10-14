#include "ForYou.h"

#include "FileFingerprint.h"
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
    connect(store, &ResearchStore::settingsChanged, this, &ForYou::settingsChanged);
    if (auto *ai = qobject_cast<AiService *>(store->ai())) connect(ai, &AiService::papersRanked, this, &ForYou::ranked);
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
        m_aiProblem = ui("Set up AI in Settings › AI to have new papers explained.");
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
    QHash<QString, QVariantMap> byId;
    for (const auto &value : ranking) byId.insert(value.toMap().value("id").toString(), value.toMap());
    for (auto &value : m_items) {
        auto item = value.toMap();
        const auto found = byId.value(item.value("id").toString());
        if (found.isEmpty()) continue;
        item.insert("score", found.value("score"));
        item.insert("why", found.value("why"));
        value = item;
    }
    sortItems();
    save();
    emit explainingChanged();
    emit changed();
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

QString ForYou::path() const
{
    return m_store->dataDirectory() + "/foryou.json";
}

void ForYou::load()
{
    QFile file(path());
    if (!file.open(QIODevice::ReadOnly)) return;
    const auto saved = QJsonDocument::fromJson(file.readAll()).object();
    m_items = saved.value("items").toArray().toVariantList();
    m_dismissed = saved.value("dismissed").toVariant().toStringList();
    m_lastChecked = QDateTime::fromString(saved.value("checkedAt").toString(), Qt::ISODate);
    m_problem = saved.value("problem").toString();
    emit changed();
}

void ForYou::save() const
{
    QFile file(path());
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(QJsonDocument(QJsonObject{{"items", QJsonArray::fromVariantList(m_items)},
                                 {"dismissed", QJsonArray::fromStringList(m_dismissed)},
                                 {"checkedAt", m_lastChecked.toString(Qt::ISODate)}, {"problem", m_problem}})
            .toJson(QJsonDocument::Compact));
}

QVariantList ForYou::topics() const
{
    return QJsonDocument::fromJson(m_store->setting("forYou.topics", "[]").toUtf8()).array().toVariantList();
}

bool ForYou::saveTopics(const QVariantList &topics)
{
    QJsonArray kept;
    for (const auto &value : topics) {
        const auto topic = value.toMap();
        const auto words = topic.value("words").toString().simplified().left(300);
        const auto categories = topic.value("categories").toString().simplified().left(200);
        if (words.isEmpty() && categories.isEmpty()) continue;
        auto id = topic.value("id").toString();
        if (id.isEmpty()) id = QUuid::createUuid().toString(QUuid::WithoutBraces).left(8);
        kept.append(QJsonObject{
            {"id", id}, {"words", words}, {"categories", categories}, {"on", topic.value("on", true).toBool()}});
    }
    return m_store->setSetting("forYou.topics", QJsonDocument(kept).toJson(QJsonDocument::Compact));
}

bool ForYou::following(const QString &collectionId) const
{
    return m_store->setting("forYou.collections").split(',', Qt::SkipEmptyParts).contains(collectionId);
}

void ForYou::follow(const QString &collectionId, bool on)
{
    auto list = m_store->setting("forYou.collections").split(',', Qt::SkipEmptyParts);
    list.removeAll(collectionId);
    if (on && !collectionId.isEmpty()) list << collectionId;
    m_store->setSetting("forYou.collections", list.join(','));
}

int ForYou::usablePapers(const QString &collectionId) const
{
    return int(m_store->collectionPaperKeys(collectionId, 1000).size());
}

bool ForYou::configured() const
{
    for (const auto &value : topics())
        if (value.toMap().value("on", true).toBool()) return true;
    QStringList existing;
    for (const auto &value : m_store->collections()) existing << value.toMap().value("id").toString();
    for (const auto &id : m_store->setting("forYou.collections").split(',', Qt::SkipEmptyParts))
        if (existing.contains(id)) return true;
    return false;
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
    for (const auto &value : m_items) {
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
    QStringList known;
    for (const auto &list : {m_items, m_found})
        for (const auto &value : list) known << value.toMap().value("id").toString();
    const auto oldest = since().date();
    for (const auto &value : papers) {
        auto paper = value.toMap();
        const auto arxiv = arxivId(paper.value("arxiv").toString()), doi = paper.value("doi").toString();
        const auto id = !arxiv.isEmpty() ? "arxiv:" + arxiv
            : !doi.isEmpty()             ? "doi:" + doi.toLower()
                                         : "s2:" + paper.value("paperId").toString();
        if (id == "s2:" || known.contains(id) || m_dismissed.contains(id) || m_store->hasPaper(arxiv, doi)) continue;
        // Recommendations come from any year; only recent ones are new (undated ones are kept).
        const auto date = QDate::fromString(paper.value("date").toString(), Qt::ISODate);
        if (date.isValid() && date < oldest) continue;
        paper.insert({{"id", id}, {"arxiv", arxiv}, {"source", source}, {"sourceName", sourceName},
            {"foundAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}});
        m_found.append(paper);
        known << id;
    }
}

void ForYou::finishCheck()
{
    std::stable_sort(m_found.begin(), m_found.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("date").toString() > b.toMap().value("date").toString();
    });
    const int fresh = int(m_found.size());
    // What was waiting stays, unless it has reached the Library since.
    QVariantList kept = m_found;
    for (const auto &value : std::as_const(m_items)) {
        const auto item = value.toMap();
        if (!m_store->hasPaper(item.value("arxiv").toString(), item.value("doi").toString())) kept.append(item);
    }
    m_items = kept.mid(0, keptItems);
    sortItems();
    m_found.clear();
    m_lastChecked = QDateTime::currentDateTimeUtc();
    m_problem = m_problems.join(' ');
    m_checking = false;
    save();
    m_store->finishTask("forYou");
    emit checkingChanged();
    emit changed();
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

void ForYou::removeItems(const QStringList &ids)
{
    QVariantList kept;
    for (const auto &value : std::as_const(m_items))
        if (!ids.contains(value.toMap().value("id").toString())) kept.append(value);
    m_items = kept;
}

void ForYou::dismiss(const QStringList &ids)
{
    for (const auto &id : ids)
        if (!m_dismissed.contains(id)) m_dismissed << id;
    m_dismissed = m_dismissed.mid(qMax(0, int(m_dismissed.size()) - 2000));
    removeItems(ids);
    save();
    emit changed();
}

void ForYou::add(const QStringList &ids)
{
    const bool idle = m_adding.isEmpty();
    for (const auto &id : ids)
        if (!m_adding.contains(id) && !item(id).isEmpty()) {
            m_adding << id;
            m_addQueue << id;
        }
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
    if (pdf.isEmpty()) {
        // No PDF to fetch: its page, where the reader can find one.
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
            m_store->notify(
                QString(ui("Could not download “%1”. Its page opens instead.")).arg(paper.value("title").toString()));
            if (!paper.value("url").toString().isEmpty()) emit webRequested(QUrl(paper.value("url").toString()));
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

void ForYou::finishAdd(const QVariantMap &paper, const QUrl &file)
{
    const auto hash = FileFingerprint::sha256(file.toLocalFile());
    const auto source = paper.value("source").toString();
    const auto collection = source.startsWith("collection:") ? source.mid(11) : QString();
    m_store->addDocuments({file}, collection);
    // The same bytes may already be a paper (then the download was not kept): that one.
    const auto url = m_store->paperWithFile(file, hash);
    if (url.isValid() && !url.isEmpty()) {
        static const QRegularExpression year("^\\d{4}$");
        m_store->updateDocumentDetails(url,
            {{"title", paper.value("title").toString().left(300)},
                {"authors", paper.value("authors").toString().left(1000)},
                {"year", year.match(paper.value("year").toString()).hasMatch() ? paper.value("year") : QString()},
                {"doi", paper.value("doi").toString().left(200)}, {"arxiv", paper.value("arxiv").toString().left(40)}});
        if (!collection.isEmpty()) m_store->setDocumentCollection(url, collection, true);
    }
    removeItems({paper.value("id").toString()});
    save();
    emit changed();
    m_store->notify(QString(ui("Added “%1” to the Library.")).arg(paper.value("title").toString()));
}
