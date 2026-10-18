#include "LibraryInsights.h"
#include "ResearchStore.h"
#include <QFile>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>

namespace {
constexpr qint64 day = 24 * 60 * 60;
QString cachePath(ResearchStore *store)
{
    return QDir(store->dataDirectory()).filePath("library-insights.json");
}
}
LibraryInsights::LibraryInsights(ResearchStore *store, QObject *parent)
    : QObject(parent), m_store(store), m_network(new QNetworkAccessManager(this))
{
    QFile file(cachePath(store));
    if (file.open(QIODevice::ReadOnly) && file.size() <= 32 * 1024 * 1024) {
        const auto data = QJsonDocument::fromJson(file.readAll()).object();
        if (data.value("version").toInt() == 1) {
            m_entries = data.value("entries").toObject();
            m_checked = QDateTime::fromString(data.value("checked").toString(), Qt::ISODate);
        }
    }
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, &LibraryInsights::check);
    connect(store, &ResearchStore::settingsChanged, this, &LibraryInsights::configure);
    m_enabled = store->setting("library.insights") == "1";
    // A little after launch (not while the window opens); at once when turned on.
    if (m_enabled) m_timer.start(8000);
}

bool LibraryInsights::enabled() const
{
    return m_enabled;
}

QString LibraryInsights::identifier(const QString &doi, const QString &arxiv)
{
    static const QRegularExpression doiPattern(R"(^10\.\d{4,9}/\S+$)", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression arxivPattern(
        R"(^(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?$)", QRegularExpression::CaseInsensitiveOption);
    if (doiPattern.match(doi.trimmed()).hasMatch()) return "DOI:" + doi.trimmed().toLower();
    auto id = arxiv.trimmed();
    if (!arxivPattern.match(id).hasMatch()) return {};
    id.remove(QRegularExpression("v\\d+$"));
    return "ARXIV:" + id;
}

QVariantMap LibraryInsights::details(const QString &doi, const QString &arxiv) const
{
    if (!enabled()) return {};
    const auto entry = m_entries.value(identifier(doi, arxiv)).toObject();
    QVariantMap result;
    if (entry.value("tldr").isString()) result["tldr"] = entry.value("tldr").toString();
    if (entry.value("citationCount").isDouble()) result["citationCount"] = entry.value("citationCount").toVariant();
    return result;
}

void LibraryInsights::configure()
{
    const bool on = m_store->setting("library.insights") == "1";
    if (on == m_enabled) return;
    m_enabled = on;
    ++m_generation;
    m_pending.clear();
    m_timer.stop();
    if (m_reply) {
        auto *reply = m_reply.data();
        m_reply.clear();
        reply->abort();
    }
    emit changed();
    if (on) m_timer.start(0);
}

void LibraryInsights::check()
{
    if (!enabled() || m_reply || !m_pending.isEmpty()) return;
    const auto now = QDateTime::currentDateTimeUtc();
    const auto elapsed = m_checked.isValid() ? m_checked.secsTo(now) : day;
    if (elapsed >= 0 && elapsed < day) {
        m_timer.start(int((day - elapsed) * 1000));
        return;
    }
    m_checked = now;
    QSet<QString> seen;
    for (const auto &value : m_store->libraryDocuments({})) {
        const auto paper = value.toMap();
        const auto key = identifier(paper.value("doi").toString(), paper.value("arxiv").toString());
        if (key.isEmpty() || seen.contains(key)) continue;
        seen.insert(key);
        const auto fetched
            = QDateTime::fromString(m_entries.value(key).toObject().value("fetched").toString(), Qt::ISODate);
        if (!fetched.isValid() || fetched > now || fetched.secsTo(now) >= 30 * day) m_pending << key;
    }
    save();
    m_timer.start(int(day * 1000));
    next();
}

void LibraryInsights::next()
{
    if (!enabled() || m_reply || m_pending.isEmpty()) return;
    const auto ids = m_pending.mid(0, 500);
    m_pending = m_pending.mid(ids.size());
    const auto base = m_store->setting("citations.baseUrl", "https://api.semanticscholar.org/graph/v1");
    QNetworkRequest request(QUrl(base + "/paper/batch?fields=tldr,citationCount"));
    request.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setTransferTimeout(20000);
    auto *reply = m_network->post(
        request, QJsonDocument(QJsonObject{{"ids", QJsonArray::fromStringList(ids)}}).toJson(QJsonDocument::Compact));
    m_reply = reply;
    const int generation = m_generation;
    connect(reply, &QNetworkReply::readyRead, this, [reply] {
        if (reply->bytesAvailable() > 8 * 1024 * 1024) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, ids, generation] {
        reply->deleteLater();
        if (m_reply == reply) m_reply.clear();
        if (generation != m_generation || !enabled()) return;
        const auto document = QJsonDocument::fromJson(reply->readAll());
        const auto rows = document.array();
        if (reply->error() != QNetworkReply::NoError
            || reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200 || !document.isArray()
            || rows.size() != ids.size()) {
            m_pending.clear(); // Retry at the next daily check, including rate limits.
            return;
        }
        const auto stamp = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        for (qsizetype i = 0; i < ids.size(); ++i) {
            if (!rows[i].isObject() && !rows[i].isNull()) continue;
            const auto row = rows[i].toObject();
            QJsonObject entry{{"fetched", stamp}};
            const auto summary = row.value("tldr").toObject().value("text");
            if (summary.isString()) entry["tldr"] = summary.toString().left(4000);
            const auto count = row.value("citationCount");
            if (count.isDouble() && count.toDouble() >= 0) entry["citationCount"] = count;
            m_entries[ids[i]] = entry;
        }
        save();
        emit changed();
        QTimer::singleShot(1000, this, [this, generation] {
            if (generation == m_generation) next();
        });
    });
}

void LibraryInsights::save()
{
    QSaveFile file(cachePath(m_store));
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(
        QJsonDocument(QJsonObject{{"version", 1}, {"checked", m_checked.toString(Qt::ISODate)}, {"entries", m_entries}})
            .toJson(QJsonDocument::Compact));
    file.commit();
}
